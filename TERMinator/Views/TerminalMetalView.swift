import MetalKit
import UIKit

/// Metal-based terminal renderer with guaranteed nearest-neighbor scaling.
/// Renders terminal at native resolution (cols*fontW x rows*fontH) then GPU-scales to screen.
final class TerminalMetalView: MTKView, MTKViewDelegate {
    weak var terminalViewModel: TerminalViewModel?
    var onReady: (() -> Void)?

    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var terminalTexture: MTLTexture?

    // Dynamic terminal dimensions (updated from viewModel each frame)
    private var currentWidth = 640   // screenColumns * fontWidth
    private var currentHeight = 400  // screenRows * fontHeight

    private var didNotifyReady = false
    private var didLogDebug = false

    // Persistent pixel buffer (reused across frames to avoid per-frame allocation)
    private var pixelBuffer: [UInt32] = []

    // Dirty tracking - skip re-render when screen hasn't changed
    private var lastRenderedVersion: Int = -1

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device ?? MTLCreateSystemDefaultDevice())
        commonInit()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        self.device = MTLCreateSystemDefaultDevice()
        commonInit()
    }

    private func commonInit() {
        guard let device = device else {
            print("[TerminalMetalView] No Metal device available")
            return
        }

        delegate = self
        framebufferOnly = true
        preferredFramesPerSecond = 60
        isPaused = false
        enableSetNeedsDisplay = false

        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.magnificationFilter = .nearest
            metalLayer.minificationFilter = .nearest
        }

        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        commandQueue = device.makeCommandQueue()

        setupPipeline()
        createTerminalTexture()
    }

    private func setupPipeline() {
        guard let device = device else { return }

        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexOut {
            float4 position [[position]];
            float2 texCoord;
        };

        struct QuadParams {
            float2 offset;
            float2 size;
        };

        vertex VertexOut vertexShader(uint vertexID [[vertex_id]],
                                      constant QuadParams &params [[buffer(0)]]) {
            float2 unitPos[4] = {
                float2(0, 0),  // bottom-left
                float2(1, 0),  // bottom-right
                float2(0, 1),  // top-left
                float2(1, 1)   // top-right
            };

            float2 texCoords[4] = {
                float2(0, 1),  // bottom-left -> top of texture
                float2(1, 1),  // bottom-right
                float2(0, 0),  // top-left -> bottom of texture
                float2(1, 0)   // top-right
            };

            float2 pos = unitPos[vertexID] * params.size + params.offset;
            pos = pos * 2.0 - 1.0;

            VertexOut out;
            out.position = float4(pos, 0, 1);
            out.texCoord = texCoords[vertexID];
            return out;
        }

        fragment float4 fragmentShader(VertexOut in [[stage_in]],
                                       texture2d<float, access::read> tex [[texture(0)]]) {
            // Direct texel read - guarantees nearest-neighbor, no half-texel quirks
            uint w = tex.get_width();
            uint h = tex.get_height();
            float2 uv = saturate(in.texCoord);
            uint x = min(uint(uv.x * float(w)), w - 1u);
            uint y = min(uint(uv.y * float(h)), h - 1u);
            return tex.read(uint2(x, y));
        }
        """

        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            let vertexFunction = library.makeFunction(name: "vertexShader")
            let fragmentFunction = library.makeFunction(name: "fragmentShader")

            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.vertexFunction = vertexFunction
            pipelineDescriptor.fragmentFunction = fragmentFunction
            pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            print("[TerminalMetalView] Failed to create pipeline: \(error)")
        }
    }

    private func createTerminalTexture() {
        guard let device = device else { return }

        let textureDescriptor = MTLTextureDescriptor()
        textureDescriptor.pixelFormat = .bgra8Unorm
        textureDescriptor.width = currentWidth
        textureDescriptor.height = currentHeight
        textureDescriptor.usage = [.shaderRead, .shaderWrite]
        textureDescriptor.storageMode = .shared

        terminalTexture = device.makeTexture(descriptor: textureDescriptor)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let viewModel = terminalViewModel,
              let pipelineState = pipelineState,
              let commandQueue = commandQueue,
              let drawable = currentDrawable,
              let renderPassDescriptor = currentRenderPassDescriptor else { return }

        if !didNotifyReady {
            didNotifyReady = true
            DispatchQueue.main.async { [weak self] in
                self?.onReady?()
            }
        }

        // Update texture dimensions from viewModel when screen size or font changes
        let fontW = viewModel.fontWidth > 0 ? viewModel.fontWidth : 8
        let fontH = viewModel.fontHeight > 0 ? viewModel.fontHeight : 16
        let cols = viewModel.screenColumns > 0 ? viewModel.screenColumns : 80
        let rows = viewModel.screenRows > 0 ? viewModel.screenRows : 25
        let neededWidth = cols * fontW
        let neededHeight = rows * fontH

        if neededWidth != currentWidth || neededHeight != currentHeight {
            currentWidth = neededWidth
            currentHeight = neededHeight
            createTerminalTexture()
            pixelBuffer = []  // Force reallocation at new size
            lastRenderedVersion = -1  // Force re-render
        }

        guard let texture = terminalTexture else { return }

        // Re-render terminal content to texture when display buffer has changed
        let currentVersion = viewModel.displayBufferVersion
        if currentVersion != lastRenderedVersion {
            if viewModel.displayBuffer.isEmpty {
                // Buffer was cleared (e.g. between connections) — black out the texture
                let pixelCount = currentWidth * currentHeight
                if pixelBuffer.count == pixelCount {
                    _ = pixelBuffer.withUnsafeMutableBytes { $0.initializeMemory(as: UInt32.self, repeating: 0xFF000000) }
                    let region = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                           size: MTLSize(width: currentWidth, height: currentHeight, depth: 1))
                    pixelBuffer.withUnsafeBytes { ptr in
                        guard let base = ptr.baseAddress else { return }
                        texture.replace(region: region, mipmapLevel: 0, withBytes: base, bytesPerRow: currentWidth * 4)
                    }
                }
            } else {
                renderTerminalToTexture(viewModel: viewModel, texture: texture)
            }
            lastRenderedVersion = currentVersion
        }

        // One-time debug: log dimensions to file
        if !didLogDebug && viewModel.screenColumns > 0 {
            didLogDebug = true
            let dw = drawable.texture.width
            let dh = drawable.texture.height
            let vw = bounds.size.width
            let vh = bounds.size.height
            let cs = contentScaleFactor
            let textureW = Float(currentWidth)
            let textureH = Float(currentHeight)
            let drawableW = Float(dw)
            let drawableH = Float(dh)
            let scale = min(drawableW / textureW, drawableH / textureH)
            let scaledW = textureW * scale
            let scaledH = textureH * scale
            let sizeX = scaledW / drawableW
            let sizeY = scaledH / drawableH
            let msg = """
            [MetalDebug] drawable=\(dw)x\(dh) viewBounds=\(vw)x\(vh) contentScale=\(cs)
            texture=\(currentWidth)x\(currentHeight) font=\(viewModel.fontWidth)x\(viewModel.fontHeight)
            cols=\(viewModel.screenColumns) rows=\(viewModel.screenRows)
            aspectScale=\(scale) scaledSize=\(scaledW)x\(scaledH)
            quadSizeX=\(sizeX) quadSizeY=\(sizeY)
            """
            if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                try? msg.write(to: docs.appendingPathComponent("metal_debug.log"), atomically: true, encoding: .utf8)
            }
        }

        // Always draw texture to screen (cheap quad draw)
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        // Aspect-fit scaling: fill width, preserve aspect ratio
        let drawableW = Float(drawable.texture.width)
        let drawableH = Float(drawable.texture.height)
        let textureW = Float(currentWidth)
        let textureH = Float(currentHeight)

        let scale = min(drawableW / textureW, drawableH / textureH)
        let scaledW = textureW * scale
        let scaledH = textureH * scale

        let sizeX = scaledW / drawableW
        let sizeY = scaledH / drawableH

        // Position at top-left of the drawable
        let offsetX: Float = 0.0
        let offsetY = 1.0 - sizeY  // Push to top in NDC (y=1 is top)

        var quadParams = (
            offset: SIMD2<Float>(offsetX, offsetY),
            size: SIMD2<Float>(sizeX, sizeY)
        )

        let viewport = MTLViewport(
            originX: 0, originY: 0,
            width: Double(drawableW), height: Double(drawableH),
            znear: 0.0, zfar: 1.0
        )
        renderEncoder.setViewport(viewport)
        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setVertexBytes(&quadParams, length: MemoryLayout.size(ofValue: quadParams), index: 0)
        renderEncoder.setFragmentTexture(texture, index: 0)
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        renderEncoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Render terminal content to texture at native resolution.
    /// Uses persistent pixel buffer and proper font stride calculation.
    private func renderTerminalToTexture(viewModel: TerminalViewModel, texture: MTLTexture) {
        let columns = viewModel.screenColumns
        let rows = viewModel.screenRows
        guard columns > 0, rows > 0 else { return }
        let fontWidth = viewModel.fontWidth > 0 ? viewModel.fontWidth : 8
        let fontHeight = viewModel.fontHeight > 0 ? viewModel.fontHeight : 16
        let bytesPerRow = (fontWidth + 7) / 8

        let pixelCount = currentWidth * currentHeight

        // Reuse pixel buffer - only reallocate if size changed
        if pixelBuffer.count != pixelCount {
            pixelBuffer = [UInt32](repeating: 0xFF000000, count: pixelCount)
        }

        guard let fontBitmap = viewModel.fontBitmap else { return }

        // Get custom palette (if any) for BGRA conversion
        let customPalette = viewModel.palette

        fontBitmap.withUnsafeBytes { (fontPtr: UnsafeRawBufferPointer) in
            guard let fontBase = fontPtr.baseAddress else { return }

            for row in 0..<min(rows, currentHeight / fontHeight) {
                for col in 0..<min(columns, currentWidth / fontWidth) {
                    let index = row * columns + col
                    guard index < viewModel.displayBuffer.count else { continue }

                    let cell = viewModel.displayBuffer[index]
                    let cellUnsigned = UInt32(bitPattern: cell)
                    let charCode = Int(cellUnsigned & 0xFF)
                    let attr = Int((cellUnsigned >> 8) & 0xFF)
                    // Use legacy_attr for colors (always reliably populated by native code)
                    let fgIndex = attr & 0x0F        // bits 0-3 (0-15)
                    let bgIndex = (attr >> 4) & 0x07  // bits 4-6 (0-7)

                    // Blink detection: bit 7 of legacy_attr
                    let isBlink = (attr & 0x80) != 0
                    let hideForeground = isBlink && !viewModel.blinkOn

                    let fgColor = colorBGRA(fgIndex, palette: customPalette)
                    let bgColor = colorBGRA(bgIndex, palette: customPalette)

                    let glyphOffset = charCode * fontHeight * bytesPerRow
                    let cellStartX = col * fontWidth
                    let cellStartY = row * fontHeight

                    for srcY in 0..<fontHeight {
                        let rowOffset = glyphOffset + srcY * bytesPerRow
                        let rowByte0: UInt8 = rowOffset < fontBitmap.count ?
                            fontBase.load(fromByteOffset: rowOffset, as: UInt8.self) : 0
                        let rowByte1: UInt8 = (bytesPerRow > 1 && rowOffset + 1 < fontBitmap.count) ?
                            fontBase.load(fromByteOffset: rowOffset + 1, as: UInt8.self) : 0

                        let destY = cellStartY + srcY
                        guard destY < currentHeight else { continue }
                        let pixelRowStart = destY * currentWidth
                        guard pixelRowStart + currentWidth <= pixelBuffer.count else { continue }

                        for srcX in 0..<fontWidth {
                            let destX = cellStartX + srcX
                            guard destX < currentWidth else { continue }

                            let isSet: Bool
                            if srcX < 8 {
                                isSet = ((Int(rowByte0) >> (7 - srcX)) & 1) == 1
                            } else {
                                isSet = ((Int(rowByte1) >> (15 - srcX)) & 1) == 1
                            }

                            pixelBuffer[pixelRowStart + destX] = (isSet && !hideForeground) ? fgColor : bgColor
                        }
                    }
                }
            }
        }

        // Upload pixel buffer to texture
        let region = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                               size: MTLSize(width: currentWidth, height: currentHeight, depth: 1))
        pixelBuffer.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            texture.replace(region: region, mipmapLevel: 0, withBytes: base, bytesPerRow: currentWidth * 4)
        }

    }

    /// Get color in BGRA format (0xAARRGGBB on little-endian) for Metal texture.
    /// Uses custom palette from viewModel if available, otherwise default VGA palette.
    private func colorBGRA(_ index: Int, palette: [Int32]) -> UInt32 {
        // Use custom palette if available
        if index >= 0 && index < palette.count && !palette.isEmpty {
            return 0xFF000000 | UInt32(bitPattern: palette[index])
        }

        // Default VGA 16-color palette in BGRA format (0xAARRGGBB on LE)
        let defaultPalette: [UInt32] = [
            0xFF000000, // 0: Black
            0xFF0000AA, // 1: Blue
            0xFF00AA00, // 2: Green
            0xFF00AAAA, // 3: Cyan
            0xFFAA0000, // 4: Red
            0xFFAA00AA, // 5: Magenta
            0xFFAA5500, // 6: Brown
            0xFFAAAAAA, // 7: Light Gray
            0xFF555555, // 8: Dark Gray
            0xFF5555FF, // 9: Light Blue
            0xFF55FF55, // 10: Light Green
            0xFF55FFFF, // 11: Light Cyan
            0xFFFF5555, // 12: Light Red
            0xFFFF55FF, // 13: Light Magenta
            0xFFFFFF55, // 14: Yellow
            0xFFFFFFFF  // 15: White
        ]

        if index >= 0 && index < defaultPalette.count {
            return defaultPalette[index]
        }
        return 0xFFFFFFFF
    }
}

// MARK: - SwiftUI Wrapper

import SwiftUI

struct TerminalMetalViewRepresentable: UIViewRepresentable {
    @ObservedObject var viewModel: TerminalViewModel
    var onReady: (() -> Void)?

    func makeUIView(context: Context) -> TerminalMetalView {
        let view = TerminalMetalView(frame: .zero, device: nil)
        view.terminalViewModel = viewModel
        view.onReady = onReady
        return view
    }

    func updateUIView(_ uiView: TerminalMetalView, context: Context) {
        uiView.terminalViewModel = viewModel
    }
}
