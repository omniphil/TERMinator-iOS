import SwiftUI
import CoreGraphics
import UIKit
import AVKit
import os.log

private let termLogger = Logger(subsystem: "com.jsonbourne.TERMinator", category: "TerminalView")

// MARK: - UIKit-based Terminal Renderer for Pixel-Perfect Drawing

final class TerminalUIView: UIView {
    weak var viewModel: TerminalViewModel?
    var onReady: (() -> Void)?

    private let baseCellWidth: CGFloat = 8
    private let baseCellHeight: CGFloat = 16

    // Track if we've notified readiness and scale is set
    private var isScaleConfigured = false
    private var didNotifyReady = false

    // Debug flag - log once per session
    private static var hasLoggedDebug = false

    // Cached terminal image for drawing
    private var cachedTerminalImage: CGImage?
    private var cachedImageRect: CGRect = .zero

    // Display link for smooth updates
    private var displayLink: CADisplayLink?

    // Dedicated layer for terminal image with nearest-neighbor scaling
    private var terminalImageLayer: CALayer?

    // MARK: - Proper window attachment detection

    override func didMoveToWindow() {
        super.didMoveToWindow()

        guard window != nil, !didNotifyReady else { return }

        // Force correct backing scale immediately
        let s = window?.screen.scale ?? UIScreen.main.scale
        contentScaleFactor = s
        layer.contentsScale = s

        // Mark scale as configured BEFORE any drawing
        isScaleConfigured = true
        didNotifyReady = true

        // Create dedicated layer for terminal image with nearest-neighbor scaling
        if terminalImageLayer == nil {
            let imgLayer = CALayer()
            imgLayer.magnificationFilter = .nearest
            imgLayer.minificationFilter = .nearest
            imgLayer.contentsGravity = .topLeft
            imgLayer.isOpaque = true
            imgLayer.backgroundColor = UIColor.black.cgColor
            layer.addSublayer(imgLayer)
            terminalImageLayer = imgLayer
        }

        termLogger.info("[TerminalUIView] didMoveToWindow - scale=\(s), notifying ready")

        // Start display link for updates
        displayLink = CADisplayLink(target: self, selector: #selector(updateTerminal))
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60)
        displayLink?.add(to: .main, forMode: .common)

        // Delay to ensure layout is complete before first render
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.updateTerminal()
            self?.onReady?()
        }
    }

    @objc private func updateTerminal() {
        guard isScaleConfigured,
              let viewModel = viewModel,
              !viewModel.screenBuffer.isEmpty else { return }

        let columns = viewModel.screenColumns
        let rows = viewModel.screenRows
        let fontWidth = viewModel.fontWidth > 0 ? viewModel.fontWidth : 8
        let fontHeight = viewModel.fontHeight > 0 ? viewModel.fontHeight : 16

        // Calculate display size to fill width while maintaining aspect ratio
        let nativeWidth = columns * fontWidth
        let nativeHeight = rows * fontHeight
        let intScale = 1

        // Render at integer-scaled resolution for crisp pixels
        let renderWidth = nativeWidth * intScale
        let renderHeight = nativeHeight * intScale

        // Create terminal image at integer-scaled resolution
        guard let terminalImage = viewModel.renderTerminalImage(
            columns: columns,
            rows: rows,
            cellWidthPx: fontWidth * intScale,
            cellHeightPx: fontHeight * intScale
        ) else { return }

        // Apply pan offset
        let panOffset = viewModel.panOffset

        // Cache the image and rect for draw()
        // Draw into a rect sized in points - the pixel dimensions divide by scale
        cachedTerminalImage = terminalImage
        let rectWidthPts = CGFloat(renderWidth) / contentScaleFactor
        let rectHeightPts = CGFloat(renderHeight) / contentScaleFactor
        cachedImageRect = CGRect(x: panOffset.width, y: panOffset.height,
                                  width: rectWidthPts, height: rectHeightPts)

        // Update the dedicated terminal image layer
        // Try TRANSFORM-based scaling so magnificationFilter actually applies
        if let imgLayer = terminalImageLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)  // Disable animations

            // Set the layer's contents to the CGImage
            imgLayer.contents = terminalImage

            // APPROACH: Use bounds at native size + transform to scale
            // This might engage the magnificationFilter properly
            let nativeW = CGFloat(renderWidth)
            let nativeH = CGFloat(renderHeight)

            // Set bounds to native image size
            imgLayer.bounds = CGRect(x: 0, y: 0, width: nativeW, height: nativeH)

            // Position at top-left (accounting for anchor point at center)
            let scaleX = rectWidthPts / nativeW
            let scaleY = rectHeightPts / nativeH
            imgLayer.position = CGPoint(
                x: panOffset.width + rectWidthPts / 2,
                y: panOffset.height + rectHeightPts / 2
            )

            // Apply scale transform
            imgLayer.transform = CATransform3DMakeScale(scaleX, scaleY, 1.0)

            // Set contentsScale to match image resolution
            imgLayer.contentsScale = 1.0

            // Ensure the magnification filter is set
            imgLayer.magnificationFilter = .nearest
            imgLayer.minificationFilter = .nearest

            CATransaction.commit()
        }

        // Also trigger draw() for comparison/debugging
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        // Black background only (CALayer handles the image via terminalImageLayer.contents)
        context.setFillColor(UIColor.black.cgColor)
        context.fill(bounds)
    }

    private func getPaletteColors(viewModel: TerminalViewModel) -> [CGColor] {
        let defaultPalette: [CGColor] = [
            CGColor(red: 0, green: 0, blue: 0, alpha: 1),           // 0: Black
            CGColor(red: 0, green: 0, blue: 0.667, alpha: 1),       // 1: Blue
            CGColor(red: 0, green: 0.667, blue: 0, alpha: 1),       // 2: Green
            CGColor(red: 0, green: 0.667, blue: 0.667, alpha: 1),   // 3: Cyan
            CGColor(red: 0.667, green: 0, blue: 0, alpha: 1),       // 4: Red
            CGColor(red: 0.667, green: 0, blue: 0.667, alpha: 1),   // 5: Magenta
            CGColor(red: 0.667, green: 0.333, blue: 0, alpha: 1),   // 6: Brown
            CGColor(red: 0.667, green: 0.667, blue: 0.667, alpha: 1),// 7: Light Gray
            CGColor(red: 0.333, green: 0.333, blue: 0.333, alpha: 1),// 8: Dark Gray
            CGColor(red: 0.333, green: 0.333, blue: 1, alpha: 1),   // 9: Light Blue
            CGColor(red: 0.333, green: 1, blue: 0.333, alpha: 1),   // 10: Light Green
            CGColor(red: 0.333, green: 1, blue: 1, alpha: 1),       // 11: Light Cyan
            CGColor(red: 1, green: 0.333, blue: 0.333, alpha: 1),   // 12: Light Red
            CGColor(red: 1, green: 0.333, blue: 1, alpha: 1),       // 13: Light Magenta
            CGColor(red: 1, green: 1, blue: 0.333, alpha: 1),       // 14: Yellow
            CGColor(red: 1, green: 1, blue: 1, alpha: 1),           // 15: White
        ]

        if !viewModel.palette.isEmpty && viewModel.palette.count >= 16 {
            return viewModel.palette.prefix(16).map { value in
                let uval = UInt32(bitPattern: value)
                let r = CGFloat((uval >> 16) & 0xFF) / 255.0
                let g = CGFloat((uval >> 8) & 0xFF) / 255.0
                let b = CGFloat(uval & 0xFF) / 255.0
                return CGColor(red: r, green: g, blue: b, alpha: 1)
            }
        }

        return defaultPalette
    }
}

struct TerminalUIViewRepresentable: UIViewRepresentable {
    @ObservedObject var viewModel: TerminalViewModel
    var onReady: (() -> Void)? = nil

    func makeUIView(context: Context) -> TerminalUIView {
        let view = TerminalUIView()
        view.viewModel = viewModel
        view.backgroundColor = .black
        view.isOpaque = true
        view.contentMode = .redraw
        view.onReady = onReady

        // Pre-set scale to screen scale (will be corrected in didMoveToWindow if different)
        let scale = UIScreen.main.scale
        view.contentScaleFactor = scale
        view.layer.contentsScale = scale
        view.layer.magnificationFilter = .nearest
        view.layer.minificationFilter = .nearest

        return view
    }

    func updateUIView(_ uiView: TerminalUIView, context: Context) {
        uiView.viewModel = viewModel
        uiView.setNeedsDisplay()
    }
}


// MARK: - Keyboard Input View (UIKit-based for reliable keyboard handling)

class KeyboardInputView: UIView, UIKeyInput {
    var onCharacter: ((Character) -> Void)?
    var onString: ((String) -> Void)?

    override var canBecomeFirstResponder: Bool { true }

    var hasText: Bool { false }

    func insertText(_ text: String) {
        for char in text {
            if char == "\n" {
                onCharacter?(Character("\r"))
            } else {
                onCharacter?(char)
            }
        }
    }

    func deleteBackward() {
        onCharacter?(Character(UnicodeScalar(8)))
    }

    // MARK: - Hardware Keyboard Support

    override var keyCommands: [UIKeyCommand]? {
        var commands: [UIKeyCommand] = []

        // ESC — send ESC byte to terminal (dismiss blocked by isModalInPresentation)
        let esc = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(handleEscape))
        esc.wantsPriorityOverSystemBehavior = true
        commands.append(esc)

        // Arrow keys
        commands.append(UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(handleUpArrow)))
        commands.append(UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(handleDownArrow)))
        commands.append(UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(handleRightArrow)))
        commands.append(UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(handleLeftArrow)))

        // Tab
        let tab = UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(handleTab))
        tab.wantsPriorityOverSystemBehavior = true
        commands.append(tab)

        // Control+letter (Ctrl+A through Ctrl+Z)
        for i: UInt8 in 0..<26 {
            let letter = String(UnicodeScalar(0x61 + i))
            let cmd = UIKeyCommand(input: letter, modifierFlags: .control, action: #selector(handleCtrlLetter(_:)))
            cmd.wantsPriorityOverSystemBehavior = true
            commands.append(cmd)
        }

        // Note: Enter/Return is NOT in keyCommands — it flows through insertText("\n") naturally

        return commands
    }

    @objc private func handleEscape() { onCharacter?(Character(UnicodeScalar(0x1B))) }
    @objc private func handleUpArrow() { onString?("\u{1B}[A") }
    @objc private func handleDownArrow() { onString?("\u{1B}[B") }
    @objc private func handleRightArrow() { onString?("\u{1B}[C") }
    @objc private func handleLeftArrow() { onString?("\u{1B}[D") }
    @objc private func handleTab() { onCharacter?(Character(UnicodeScalar(9))) }

    @objc private func handleCtrlLetter(_ command: UIKeyCommand) {
        guard let input = command.input?.lowercased().first,
              let ascii = input.asciiValue else { return }
        onCharacter?(Character(UnicodeScalar(ascii & 0x1F)))
    }

    // Handle keys without UIKeyCommand input constants
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else { continue }
            switch key.keyCode {
            case .keyboardDeleteOrBackspace:
                onCharacter?(Character(UnicodeScalar(8)))
                return
            case .keyboardDeleteForward:
                onString?("\u{1B}[3~")
                return
            case .keyboardHome:
                onString?("\u{1B}[H")
                return
            case .keyboardEnd:
                onString?("\u{1B}[F")
                return
            case .keyboardPageUp:
                onString?("\u{1B}[5~")
                return
            case .keyboardPageDown:
                onString?("\u{1B}[6~")
                return
            default:
                break
            }
        }
        super.pressesBegan(presses, with: event)
    }

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
}

struct KeyboardInputRepresentable: UIViewRepresentable {
    @Binding var isActive: Bool
    var onCharacter: (Character) -> Void
    var onString: (String) -> Void

    func makeUIView(context: Context) -> KeyboardInputView {
        let view = KeyboardInputView()
        view.onCharacter = onCharacter
        view.onString = onString
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: KeyboardInputView, context: Context) {
        uiView.onCharacter = onCharacter
        uiView.onString = onString
        if isActive && !uiView.isFirstResponder {
            DispatchQueue.main.async {
                uiView.becomeFirstResponder()
            }
        } else if !isActive && uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }
}

/// Terminal view that renders the screen buffer using bitmap fonts for accurate CP437/Topaz rendering.
struct TerminalView: View {
    @ObservedObject var viewModel: TerminalViewModel
    var onTripleTap: (() -> Void)? = nil

    // Gesture state
    @State private var lastZoomLevel: CGFloat = 1.0
    @State private var dragStartOffset: CGSize = .zero
    @State private var scrollbackStartOffset: Int = 0

    // Keyboard input state
    @State private var isKeyboardActive: Bool = false

    // Selection drag handle state
    enum DragHandle { case none, start, end }
    @State private var activeDragHandle: DragHandle = .none

    // Long-press detection state (timer-based, inside DragGesture)
    @State private var longPressTimer: DispatchWorkItem?
    @State private var longPressStartLocation: CGPoint = .zero
    @State private var longPressTriggered: Bool = false
    @State private var scrollPanStarted: Bool = false

    // Triple-tap detection
    @State private var tapCount: Int = 0
    @State private var lastTapTime: Date = .distantPast
    @State private var lastTapLocation: CGPoint = .zero
    @State private var pendingKeyboardTask: DispatchWorkItem?
    private let tripleTapTimeout: TimeInterval = 0.4
    private let tripleTapRadius: CGFloat = 50

    // Cell dimensions (based on font - 8x16 for standard bitmap fonts)
    private let baseCellWidth: CGFloat = 8
    private let baseCellHeight: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                // Background
                Color.black
                    .ignoresSafeArea()

                // Keyboard input handler (UIKit-based for reliability)
                KeyboardInputRepresentable(isActive: $isKeyboardActive, onCharacter: { char in
                    viewModel.sendCharacter(char)
                }, onString: { string in
                    viewModel.sendString(string)
                })
                .frame(width: 1, height: 1)

                // Terminal view with gestures - fills available space
                // Metal renderer with nearest-neighbor scaling (fixes black bars)
                TerminalMetalViewRepresentable(viewModel: viewModel) {
                    viewModel.rendererDidBecomeReady()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .scaleEffect(viewModel.zoomLevel, anchor: .topLeading)
                .offset(x: viewModel.panOffset.width, y: viewModel.panOffset.height)
                .clipped() // Clip content that extends beyond view bounds
                .contentShape(Rectangle())
                .simultaneousGesture(tapGesture(in: geometry))
                .simultaneousGesture(doubleTapGesture)
                .simultaneousGesture(magnificationGesture)
                .simultaneousGesture(dragGesture(in: geometry))
                .overlay {
                    if viewModel.isSelecting {
                        selectionOverlay(in: geometry)
                    }
                }

                // TAP+ video overlay
                if viewModel.videoActive, let player = viewModel.videoPlayer {
                    videoOverlay(player: player, in: geometry)
                }

                // TAP+ image overlay
                if viewModel.imageActive, let image = viewModel.imageData {
                    imageOverlay(image: image, in: geometry)
                }

                // TAP+ logo overlay (persistent, on top of image)
                if viewModel.logoActive, let logoImage = viewModel.logoImageData {
                    logoOverlay(image: logoImage, in: geometry)
                }

                // TAP+ visualizer overlay
                if viewModel.visualizerActive {
                    visualizerOverlay(in: geometry)
                }

                // Logging indicator
                if viewModel.isLogging {
                    loggingIndicator
                }

                // Transfer progress overlay
                if viewModel.showTransferView, let transferInfo = viewModel.transferInfo {
                    TransferProgressView(info: transferInfo) {
                        viewModel.cancelTransfer()
                    } onDismiss: {
                        viewModel.showTransferView = false
                    }
                }

                // Scrollback indicator
                if viewModel.isInScrollback {
                    scrollbackIndicator
                }

                // Zoom indicator
                if viewModel.zoomLevel != 1.0 {
                    zoomIndicator
                }
            }
            .onAppear {
                lastZoomLevel = viewModel.zoomLevel
                dragStartOffset = viewModel.panOffset
                viewModel.containerSize = geometry.size
                // Load font bitmap on appear (needed for proper initialization)
                // Note: Also loaded after 3-sec delay in connect() for rendering
                viewModel.loadFontBitmap()

                // Auto-show keyboard on appear
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    isKeyboardActive = true
                }
            }
            .onChange(of: geometry.size) { newSize in
                viewModel.containerSize = newSize
            }
        }
    }

    // MARK: - Terminal Canvas with Bitmap Font Rendering

    private func terminalCanvas(in geometry: GeometryProxy) -> some View {
        Canvas { context, size in
            guard !viewModel.screenBuffer.isEmpty else {
                return
            }

            // Use the context directly (interpolation is controlled at CGImage level)
            let ctx = context

            let columns = viewModel.screenColumns
            let rows = viewModel.screenRows

            // Calculate cell size based on font dimensions or defaults
            let fontWidth = viewModel.fontWidth > 0 ? CGFloat(viewModel.fontWidth) : baseCellWidth
            let fontHeight = viewModel.fontHeight > 0 ? CGFloat(viewModel.fontHeight) : baseCellHeight

            // Scale to fit screen while maintaining aspect ratio
            let scaleX = size.width / (CGFloat(columns) * fontWidth)
            let scaleY = size.height / (CGFloat(rows) * fontHeight)
            let scale = max(0.1, min(scaleX, scaleY))  // Ensure minimum scale of 0.1

            // Use integer cell dimensions to avoid sub-pixel rendering artifacts
            let cellWidthInt = max(1, Int((fontWidth * scale).rounded()))
            let cellHeightInt = max(1, Int((fontHeight * scale).rounded()))
            let cellWidth = CGFloat(cellWidthInt)
            let cellHeight = CGFloat(cellHeightInt)

            // Get palette colors
            let paletteColors = getPaletteColors()

            // Draw each cell using bitmap font
            for row in 0..<rows {
                for col in 0..<columns {
                    let index = row * columns + col
                    guard index < viewModel.screenBuffer.count else { continue }

                    let cell = viewModel.screenBuffer[index]
                    let charCode = Int(cell & 0xFF)
                    // Use legacy_attr for colors (always reliably populated by native code)
                    let attr = Int((cell >> 8) & 0xFF)
                    let fgIndex = attr & 0x0F        // bits 0-3 (0-15)
                    let bgIndex = (attr >> 4) & 0x07  // bits 4-6 (0-7)

                    // Blink detection: bit 7 of legacy_attr
                    let isBlink = (attr & 0x80) != 0
                    let hideForeground = isBlink && !viewModel.blinkOn

                    let x = CGFloat(col) * cellWidth
                    let y = CGFloat(row) * cellHeight
                    let rect = CGRect(x: x, y: y, width: cellWidth, height: cellHeight)

                    // Draw background
                    guard bgIndex < paletteColors.count, fgIndex < paletteColors.count else { continue }
                    let bgColor = paletteColors[bgIndex]
                    ctx.fill(Path(rect), with: .color(bgColor))

                    // Draw foreground (skip during blink-off phase for blinking cells)
                    if !hideForeground {
                        // Check if this cell is part of a URL
                        let isURL = viewModel.urlAt(column: col, row: row) != nil

                        // Draw character using bitmap font at exact cell size
                        if let glyphImage = viewModel.getGlyphImage(
                            charCode: charCode,
                            fgIndex: isURL ? 11 : fgIndex, // Cyan for URLs
                            bgIndex: bgIndex,
                            targetWidth: cellWidthInt,
                            targetHeight: cellHeightInt
                        ) {
                            ctx.draw(
                                Image(decorative: glyphImage, scale: 1.0, orientation: .up),
                                in: rect
                            )

                            // Draw underline for URLs
                            if isURL {
                                let underlineY = y + cellHeight - 2
                                let underlinePath = Path { path in
                                    path.move(to: CGPoint(x: x, y: underlineY))
                                    path.addLine(to: CGPoint(x: x + cellWidth, y: underlineY))
                                }
                                ctx.stroke(underlinePath, with: .color(.cyan), lineWidth: 3)
                            }
                        } else if charCode != 32 {
                            // Fallback: draw using system font if bitmap not available
                            let fgColor = isURL ? Color.cyan : paletteColors[fgIndex]
                            let displayChar = viewModel.mapCP437Char(charCode)
                            let text = Text(String(displayChar))
                                .font(.system(size: cellHeight * 0.8, design: .monospaced))
                                .foregroundColor(fgColor)
                            ctx.draw(text, at: CGPoint(x: x + cellWidth / 2, y: y + cellHeight / 2), anchor: .center)
                        }
                    }

                    // Draw cursor — SyncTERM style: bottom 2/16ths of cell,
                    // foreground color, only visible when screen idle + blink on
                    if !viewModel.userHideCursor && viewModel.cursorVisible &&
                       viewModel.screenIsIdle && viewModel.cursorBlinkOn &&
                       col == viewModel.cursorX && row == viewModel.cursorY {
                        // SyncTERM _NORMALCURSOR: bottom 2 scanlines of 16px cell (12.5%)
                        let cursorH = max(cellHeight * 2.0 / 16.0, 1.0)
                        let cursorY = y + cellHeight - cursorH
                        let cursorRect = CGRect(x: x, y: cursorY, width: cellWidth, height: cursorH)
                        // Use the foreground color of the character at cursor position
                        let cursorColor = fgIndex < paletteColors.count ? paletteColors[fgIndex] : .white
                        ctx.fill(Path(cursorRect), with: .color(cursorColor))
                    }
                }
            }
        }
        .frame(
            width: CGFloat(viewModel.screenColumns) * (viewModel.fontWidth > 0 ? CGFloat(viewModel.fontWidth) : baseCellWidth),
            height: CGFloat(viewModel.screenRows) * (viewModel.fontHeight > 0 ? CGFloat(viewModel.fontHeight) : baseCellHeight)
        )
    }

    // MARK: - Selection Helpers

    /// Convert a screen point to terminal cell (col, row).
    private func screenToCell(location: CGPoint, in geometry: GeometryProxy) -> (col: Int, row: Int) {
        let fontW = viewModel.fontWidth > 0 ? CGFloat(viewModel.fontWidth) : baseCellWidth
        let fontH = viewModel.fontHeight > 0 ? CGFloat(viewModel.fontHeight) : baseCellHeight
        let terminalNativeWidth = CGFloat(viewModel.screenColumns) * fontW
        let baseScale = geometry.size.width > 0 && terminalNativeWidth > 0
            ? geometry.size.width / terminalNativeWidth : 1.0
        let effectiveScale = baseScale * viewModel.zoomLevel
        let relativeX = (location.x - viewModel.panOffset.width) / effectiveScale
        let relativeY = (location.y - viewModel.panOffset.height) / effectiveScale
        let col = max(0, min(Int(relativeX / fontW), viewModel.screenColumns - 1))
        let row = max(0, min(Int(relativeY / fontH), viewModel.screenRows - 1))
        return (col, row)
    }

    /// Calculate the pixel rect for the selection overlay.
    private func selectionRect(in geometry: GeometryProxy) -> CGRect {
        let fontW = viewModel.fontWidth > 0 ? CGFloat(viewModel.fontWidth) : baseCellWidth
        let fontH = viewModel.fontHeight > 0 ? CGFloat(viewModel.fontHeight) : baseCellHeight
        let terminalNativeWidth = CGFloat(viewModel.screenColumns) * fontW
        let baseScale = geometry.size.width > 0 && terminalNativeWidth > 0
            ? geometry.size.width / terminalNativeWidth : 1.0
        let effectiveScale = baseScale * viewModel.zoomLevel

        let x = CGFloat(viewModel.selectionMinCol) * fontW * effectiveScale + viewModel.panOffset.width
        let y = CGFloat(viewModel.selectionMinRow) * fontH * effectiveScale + viewModel.panOffset.height
        let w = CGFloat(viewModel.selectionMaxCol - viewModel.selectionMinCol + 1) * fontW * effectiveScale
        let h = CGFloat(viewModel.selectionMaxRow - viewModel.selectionMinRow + 1) * fontH * effectiveScale
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Selection overlay with blue highlight and draggable lollipop handles.
    private func selectionOverlay(in geometry: GeometryProxy) -> some View {
        let rect = selectionRect(in: geometry)
        let handleVisualRadius: CGFloat = 10
        let handleTouchSize: CGFloat = 44
        let stemLength: CGFloat = 14

        return ZStack {
            // Semi-transparent blue fill (no hit testing)
            Rectangle()
                .fill(Color.blue.opacity(0.25))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)

            // Blue border (no hit testing)
            Rectangle()
                .stroke(Color.blue, lineWidth: 2)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)

            // Top-left drag handle (lollipop pointing up-left)
            ZStack {
                // Stem line
                Path { path in
                    path.move(to: CGPoint(x: handleTouchSize / 2, y: handleTouchSize / 2))
                    path.addLine(to: CGPoint(x: handleTouchSize / 2 - stemLength * 0.5, y: handleTouchSize / 2 - stemLength))
                }
                .stroke(Color.blue, lineWidth: 2)

                // Circle at end of stem
                Circle()
                    .fill(Color.blue)
                    .frame(width: handleVisualRadius * 2, height: handleVisualRadius * 2)
                    .offset(x: -stemLength * 0.5, y: -stemLength)
            }
            .frame(width: handleTouchSize, height: handleTouchSize)
            .contentShape(Rectangle())
            .position(x: rect.minX, y: rect.minY)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        activeDragHandle = .start
                        let cell = screenToCell(location: value.location, in: geometry)
                        viewModel.updateSelectionAnchor(col: cell.col, row: cell.row)
                    }
                    .onEnded { _ in
                        activeDragHandle = .none
                    }
            )

            // Bottom-right drag handle (lollipop pointing down-right)
            ZStack {
                // Stem line
                Path { path in
                    path.move(to: CGPoint(x: handleTouchSize / 2, y: handleTouchSize / 2))
                    path.addLine(to: CGPoint(x: handleTouchSize / 2 + stemLength * 0.5, y: handleTouchSize / 2 + stemLength))
                }
                .stroke(Color.blue, lineWidth: 2)

                // Circle at end of stem
                Circle()
                    .fill(Color.blue)
                    .frame(width: handleVisualRadius * 2, height: handleVisualRadius * 2)
                    .offset(x: stemLength * 0.5, y: stemLength)
            }
            .frame(width: handleTouchSize, height: handleTouchSize)
            .contentShape(Rectangle())
            .position(x: rect.maxX, y: rect.maxY)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        activeDragHandle = .end
                        let cell = screenToCell(location: value.location, in: geometry)
                        viewModel.updateSelection(col: cell.col, row: cell.row)
                    }
                    .onEnded { _ in
                        activeDragHandle = .none
                    }
            )
        }
    }

    // MARK: - Gestures

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if viewModel.isSelecting { viewModel.cancelSelection() }
                // Apply zoom continuously during pinch for live feedback
                let newZoom = lastZoomLevel * value
                viewModel.setZoom(newZoom)
            }
            .onEnded { value in
                // Finalize zoom level
                let newZoom = lastZoomLevel * value
                viewModel.setZoom(newZoom)
                lastZoomLevel = viewModel.zoomLevel
            }
    }

    private func dragGesture(in geometry: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // If a handle drag is active, skip normal gesture processing
                if activeDragHandle != .none { return }

                let dist = hypot(value.translation.width, value.translation.height)

                // --- First touch (translation near zero): start long-press timer ---
                if !longPressTriggered && !scrollPanStarted && longPressTimer == nil {
                    longPressStartLocation = value.startLocation
                    scrollbackStartOffset = viewModel.scrollbackOffset
                    dragStartOffset = viewModel.panOffset
                    let timer = DispatchWorkItem { [self] in
                        // Timer fired → trigger selection
                        longPressTriggered = true
                        let cell = screenToCell(location: value.startLocation, in: geometry)
                        viewModel.startSelection(col: cell.col, row: cell.row)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                    longPressTimer = timer
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: timer)
                    return
                }

                // --- Finger moved >10pt before timer fired → cancel timer, enter scroll/pan ---
                if !longPressTriggered && !scrollPanStarted && dist > 10 {
                    longPressTimer?.cancel()
                    longPressTimer = nil
                    scrollPanStarted = true
                    // Cancel any active selection from a previous gesture
                    if viewModel.isSelecting { viewModel.cancelSelection() }
                }

                // --- Selection mode: extend selection as finger drags ---
                if longPressTriggered {
                    let cell = screenToCell(location: value.location, in: geometry)
                    viewModel.updateSelection(col: cell.col, row: cell.row)
                    return
                }

                // --- Scroll / Pan mode ---
                if scrollPanStarted {
                    if viewModel.zoomLevel <= 1.0 {
                        let fontHeight = viewModel.fontHeight > 0 ? CGFloat(viewModel.fontHeight) : baseCellHeight
                        let terminalNativeWidth = CGFloat(viewModel.screenColumns) * (viewModel.fontWidth > 0 ? CGFloat(viewModel.fontWidth) : baseCellWidth)
                        let baseScale = geometry.size.width > 0 && terminalNativeWidth > 0
                            ? geometry.size.width / terminalNativeWidth : 1.0
                        let cellScreenHeight = fontHeight * baseScale
                        let lineDelta = Int(value.translation.height / cellScreenHeight)
                        viewModel.setScrollbackOffset(scrollbackStartOffset + lineDelta)
                    } else {
                        let newOffset = CGSize(
                            width: dragStartOffset.width + value.translation.width,
                            height: dragStartOffset.height + value.translation.height
                        )
                        viewModel.updatePan(newOffset)
                    }
                }
            }
            .onEnded { _ in
                // Clean up timer
                longPressTimer?.cancel()
                longPressTimer = nil

                // Reset state for next gesture
                longPressTriggered = false
                scrollPanStarted = false

                if viewModel.zoomLevel <= 1.0 {
                    scrollbackStartOffset = viewModel.scrollbackOffset
                } else {
                    dragStartOffset = viewModel.panOffset
                }
            }
    }

    private func tapGesture(in geometry: GeometryProxy) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                handleTap(at: value.location, in: geometry)
            }
    }

    private var doubleTapGesture: some Gesture {
        TapGesture(count: 2)
            .onEnded {
                viewModel.resetZoom()
                lastZoomLevel = 1.0
                viewModel.resetScrollback()
                scrollbackStartOffset = 0
            }
    }


    // MARK: - Tap Handling

    private func handleTap(at location: CGPoint, in geometry: GeometryProxy) {
        // Cancel any pending keyboard show
        pendingKeyboardTask?.cancel()
        pendingKeyboardTask = nil

        // If selecting, tap cancels the selection
        if viewModel.isSelecting {
            viewModel.cancelSelection()
            tapCount = 0
            return
        }

        // Check for URL tap first
        let cell = screenToCell(location: location, in: geometry)
        if cell.col >= 0 && cell.col < viewModel.screenColumns &&
           cell.row >= 0 && cell.row < viewModel.screenRows {
            if let url = viewModel.urlAt(column: cell.col, row: cell.row) {
                viewModel.openURL(url)
                tapCount = 0
                return
            }
        }

        // Triple-tap detection
        let now = Date()
        let timeSinceLastTap = now.timeIntervalSince(lastTapTime)
        let dx = location.x - lastTapLocation.x
        let dy = location.y - lastTapLocation.y
        let dist = sqrt(dx * dx + dy * dy)

        if timeSinceLastTap < tripleTapTimeout && dist < tripleTapRadius {
            tapCount += 1
        } else {
            tapCount = 1
        }

        lastTapTime = now
        lastTapLocation = location

        if tapCount >= 3 {
            tapCount = 0
            onTripleTap?()
            return
        }

        // Suppress keyboard on tap 2 (let double-tap zoom reset handle it)
        if tapCount == 2 {
            return
        }

        // Delayed keyboard show (cancelled if more taps come)
        let task = DispatchWorkItem {
            isKeyboardActive = true
        }
        pendingKeyboardTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + tripleTapTimeout, execute: task)
    }

    // MARK: - TAP+ Overlays

    /// Compute cell size in points, accounting for zoom + container scaling.
    /// Cell size in points, matching the Metal renderer's aspect-fit scaling.
    /// Uses min(scaleW, scaleH) so the full terminal grid fits within the visible area
    /// in both dimensions — same algorithm as the Metal vertex shader.
    private func cellSizeInPoints(in geometry: GeometryProxy) -> (w: CGFloat, h: CGFloat) {
        let fontW = viewModel.fontWidth > 0 ? CGFloat(viewModel.fontWidth) : baseCellWidth
        let fontH = viewModel.fontHeight > 0 ? CGFloat(viewModel.fontHeight) : baseCellHeight
        let cols = CGFloat(viewModel.screenColumns > 0 ? viewModel.screenColumns : 80)
        let rows = CGFloat(viewModel.screenRows > 0 ? viewModel.screenRows : 25)
        let termNativeW = cols * fontW
        let termNativeH = rows * fontH
        let scaleW = (geometry.size.width > 0 && termNativeW > 0)
            ? geometry.size.width / termNativeW : 1.0
        let scaleH = (geometry.size.height > 0 && termNativeH > 0)
            ? geometry.size.height / termNativeH : 1.0
        let baseScale = min(scaleW, scaleH)
        let cellW = fontW * baseScale * viewModel.zoomLevel
        let cellH = fontH * baseScale * viewModel.zoomLevel

        return (cellW, cellH)
    }

    private func videoOverlay(player: AVPlayer, in geometry: GeometryProxy) -> some View {
        let cell = cellSizeInPoints(in: geometry)
        let x = CGFloat(viewModel.videoCol - 1) * cell.w + viewModel.panOffset.width
        let y = CGFloat(viewModel.videoRow - 1) * cell.h + viewModel.panOffset.height
        let w = CGFloat(viewModel.videoCellW) * cell.w
        let h = CGFloat(viewModel.videoCellH) * cell.h

        // Size the view to match the video's native aspect ratio within the
        // cell bounding box — no letterboxing, matching Android's fitWithinRect.
        let nw = viewModel.videoNativeWidth
        let nh = viewModel.videoNativeHeight
        let fitW: CGFloat
        let fitH: CGFloat
        let offX: CGFloat
        let offY: CGFloat
        if nw > 0 && nh > 0 {
            let scale = min(w / nw, h / nh)
            fitW = nw * scale
            fitH = nh * scale
            offX = x + (w - fitW) / 2
            offY = y + (h - fitH) / 2
        } else {
            // Dimensions not known yet — fill the cell area as placeholder
            fitW = w
            fitH = h
            offX = x
            offY = y
        }

        return AVPlayerLayerView(player: player)
            .frame(width: fitW, height: fitH)
            .position(x: offX + fitW / 2, y: offY + fitH / 2)
            .allowsHitTesting(false)
    }

    private func imageOverlay(image: UIImage, in geometry: GeometryProxy) -> some View {
        let cell = cellSizeInPoints(in: geometry)
        let x = CGFloat(viewModel.imageCol - 1) * cell.w + viewModel.panOffset.width
        let y = CGFloat(viewModel.imageRow - 1) * cell.h + viewModel.panOffset.height
        let w = CGFloat(viewModel.imageCellW) * cell.w
        let h = CGFloat(viewModel.imageCellH) * cell.h

        // Scale image to fit within the cell area while preserving aspect ratio
        // (matches Android's TapCoordinateMapper.fitWithinRect)
        let bw = image.size.width
        let bh = image.size.height
        let scale = min(w / bw, h / bh)
        let fitW = bw * scale
        let fitH = bh * scale

        return AnimatedImageView(image: image)
            .frame(width: fitW, height: fitH)
            .position(x: x + w / 2, y: y + h / 2)
            .allowsHitTesting(false)
    }

    private func logoOverlay(image: UIImage, in geometry: GeometryProxy) -> some View {
        let cell = cellSizeInPoints(in: geometry)
        // Clamp logo dimensions to terminal grid bounds
        let maxCols = CGFloat(viewModel.screenColumns)
        let maxRows = CGFloat(viewModel.screenRows)
        let clampedW = min(CGFloat(viewModel.logoCellW), maxCols)
        let clampedH = min(CGFloat(viewModel.logoCellH), maxRows)
        let x = CGFloat(viewModel.logoCol - 1) * cell.w + viewModel.panOffset.width
        let y = CGFloat(viewModel.logoRow - 1) * cell.h + viewModel.panOffset.height
        let w = clampedW * cell.w
        let h = clampedH * cell.h

        // Fill the full cell area — scaleToFill stretches the logo to fill,
        // matching Android's fillRect + scaleType="fitXY" behavior
        return AnimatedImageView(image: image, contentMode: .scaleToFill)
            .frame(width: w, height: h)
            .position(x: x + w / 2, y: y + h / 2)
            .allowsHitTesting(false)
    }

    private func visualizerOverlay(in geometry: GeometryProxy) -> some View {
        let cell = cellSizeInPoints(in: geometry)
        return VisualizerOverlayView(
            audioAnalyzer: SoundtrackManager.shared.audioAnalyzer,
            row: viewModel.visualizerRow,
            col: viewModel.visualizerCol,
            cellsWide: viewModel.visualizerCellW,
            cellsHigh: viewModel.visualizerCellH,
            style: viewModel.visualizerStyle,
            cellWidth: cell.w,
            cellHeight: cell.h,
            panOffsetX: viewModel.panOffset.width,
            panOffsetY: viewModel.panOffset.height
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Overlays

    private var loggingIndicator: some View {
        VStack {
            HStack {
                Spacer()
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text("REC")
                        .font(.caption)
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.6))
                .cornerRadius(4)
                .padding()
            }
            Spacer()
        }
    }

    private var scrollbackIndicator: some View {
        VStack {
            Spacer()
            HStack {
                Text("SCROLL \u{2191} \(viewModel.scrollbackOffset)")
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(4)
                    .padding()
                Spacer()
            }
        }
    }

    private var zoomIndicator: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Text("\(Int(viewModel.zoomLevel * 100))%")
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(4)
                    .padding()
            }
        }
    }

    // MARK: - Colors

    private func getPaletteColors() -> [Color] {
        // Default CGA/VGA 16-color palette
        let defaultPalette: [Color] = [
            Color(red: 0, green: 0, blue: 0),                    // 0: Black
            Color(red: 0, green: 0, blue: 0.667),                // 1: Blue
            Color(red: 0, green: 0.667, blue: 0),                // 2: Green
            Color(red: 0, green: 0.667, blue: 0.667),            // 3: Cyan
            Color(red: 0.667, green: 0, blue: 0),                // 4: Red
            Color(red: 0.667, green: 0, blue: 0.667),            // 5: Magenta
            Color(red: 0.667, green: 0.333, blue: 0),            // 6: Brown
            Color(red: 0.667, green: 0.667, blue: 0.667),        // 7: Light Gray
            Color(red: 0.333, green: 0.333, blue: 0.333),        // 8: Dark Gray
            Color(red: 0.333, green: 0.333, blue: 1),            // 9: Light Blue
            Color(red: 0.333, green: 1, blue: 0.333),            // 10: Light Green
            Color(red: 0.333, green: 1, blue: 1),                // 11: Light Cyan
            Color(red: 1, green: 0.333, blue: 0.333),            // 12: Light Red
            Color(red: 1, green: 0.333, blue: 1),                // 13: Light Magenta
            Color(red: 1, green: 1, blue: 0.333),                // 14: Yellow
            Color(red: 1, green: 1, blue: 1),                    // 15: White
        ]

        // Use custom palette if available
        if !viewModel.palette.isEmpty && viewModel.palette.count >= 16 {
            return viewModel.palette.prefix(16).map { value in
                let uval = UInt32(bitPattern: value)
                let r = CGFloat((uval >> 16) & 0xFF) / 255.0
                let g = CGFloat((uval >> 8) & 0xFF) / 255.0
                let b = CGFloat(uval & 0xFF) / 255.0
                return Color(red: r, green: g, blue: b)
            }
        }

        return defaultPalette
    }
}

// MARK: - AVPlayer Layer View (lightweight video rendering without controls)

struct AVPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> UIView {
        let view = PlayerContainerView()
        view.backgroundColor = .clear
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let container = uiView as? PlayerContainerView else { return }
        if container.playerLayer.player !== player {
            container.playerLayer.player = player
        }
    }

    private class PlayerContainerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

// MARK: - Animated Image View (supports animated GIFs via UIImageView)

struct AnimatedImageView: UIViewRepresentable {
    let image: UIImage
    var contentMode: UIView.ContentMode = .scaleToFill

    func makeUIView(context: Context) -> UIImageView {
        let iv = UIImageView()
        iv.contentMode = contentMode
        iv.clipsToBounds = true
        iv.backgroundColor = .clear
        // Prevent intrinsic content size from overriding SwiftUI frame constraints
        iv.setContentHuggingPriority(.defaultLow, for: .horizontal)
        iv.setContentHuggingPriority(.defaultLow, for: .vertical)
        iv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        iv.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return iv
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        if uiView.contentMode != contentMode {
            uiView.contentMode = contentMode
        }
        if uiView.image !== image {
            uiView.image = image
            if image.images != nil {
                uiView.startAnimating()
            }
        }
    }

    /// Accept whatever size SwiftUI proposes — don't use the image's intrinsic size.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIImageView, context: Context) -> CGSize? {
        guard let w = proposal.width, let h = proposal.height else { return nil }
        return CGSize(width: w, height: h)
    }
}

// MARK: - Preview

struct TerminalView_Previews: PreviewProvider {
    static var previews: some View {
        TerminalView(viewModel: TerminalViewModel())
    }
}
