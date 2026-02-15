import SwiftUI

/// Retro DOS-style view showing file transfer progress.
/// Styled to look like classic ZMODEM transfer screens - matches Android app.
struct TransferProgressView: View {
    let info: TransferInfo
    let onCancel: () -> Void
    let onDismiss: (() -> Void)?

    private let progressWidth = 25  // Number of characters in progress bar
    private let filledChar: Character = "█"  // Full block
    private let emptyChar: Character = "░"   // Light shade
    private let autoCloseSeconds = 5  // Auto-close countdown duration

    // State for bell and auto-close
    @State private var bellPlayed: Bool = false
    @State private var autoCloseSecondsLeft: Int? = nil
    @State private var autoCloseTimer: Timer? = nil

    init(info: TransferInfo, onCancel: @escaping () -> Void, onDismiss: (() -> Void)? = nil) {
        self.info = info
        self.onCancel = onCancel
        self.onDismiss = onDismiss
    }

    var body: some View {
        // Outer border (logo_term_color - matches Android)
        VStack(spacing: 0) {
            // Inner content area
            VStack(spacing: 0) {
                // Title bar with centered text (logo_term_color background, white text)
                Text(titleText)
                    .font(.system(size: 14 * UIScale.factor, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(Color.logoTermColor)
                    .padding(.bottom, 12)

                // Content area
                VStack(alignment: .leading, spacing: 0) {
                    // File info row
                    HStack(spacing: 0) {
                        Text("File: ")
                            .font(.system(size: 12 * UIScale.factor, design: .monospaced))
                            .foregroundColor(.appPrimary)
                        Text(info.fileName ?? "--")
                            .font(.system(size: 12 * UIScale.factor, design: .monospaced))
                            .foregroundColor(.appPrimaryLight)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                    }
                    .padding(.bottom, 6)

                    // Retro text-based progress bar row
                    HStack(spacing: 0) {
                        Text(buildProgressBar())
                            .font(.system(size: 11 * UIScale.factor, design: .monospaced))
                            .foregroundColor(.appPrimary)
                            .tracking(-0.5) // Tighter letter spacing like Android
                        Spacer()
                        Text(String(format: "%3d%%", info.progressPercent))
                            .font(.system(size: 11 * UIScale.factor, design: .monospaced))
                            .foregroundColor(.appPrimaryLight)
                            .frame(minWidth: 44 * UIScale.factor, alignment: .trailing)
                    }
                    .padding(.bottom, 6)

                    // Size info (Bytes: X / Y format - classic DOS style)
                    Text("Bytes: \(formatNumber(info.bytesTransferred)) / \(formatNumber(info.totalBytes))")
                        .font(.system(size: 11 * UIScale.factor, design: .monospaced))
                        .foregroundColor(.appPrimary)
                        .padding(.bottom, 2)

                    // Speed in cps (characters per second - classic BBS terminology)
                    Text("Speed: \(formatNumber(info.bytesPerSecond)) cps")
                        .font(.system(size: 11 * UIScale.factor, design: .monospaced))
                        .foregroundColor(.appPrimary)
                        .padding(.bottom, 8)

                    // Status message (centered)
                    HStack {
                        Spacer()
                        Text(statusText)
                            .font(.system(size: 12 * UIScale.factor, design: .monospaced))
                            .foregroundColor(statusColor)
                        Spacer()
                    }
                    .padding(.bottom, 12)

                    // Retro-style buttons (centered)
                    HStack(spacing: 0) {
                        Spacer()

                        if shouldShowCancel {
                            Button(action: onCancel) {
                                Text("[ Cancel ]")
                                    .font(.system(size: 12 * UIScale.factor, design: .monospaced))
                                    .foregroundColor(.termLightRed)
                                    .padding(8)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }

                        if shouldShowClose {
                            Button(action: { onDismiss?() }) {
                                Text("[  OK  ]")
                                    .font(.system(size: 12 * UIScale.factor, design: .monospaced))
                                    .foregroundColor(.accent)
                                    .padding(8)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }

                        Spacer()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .frame(width: 300 * UIScale.factor)
            .background(Color.crtBackground) // #081320 - matches Android grid_background
        }
        .padding(2) // Border thickness
        .background(Color.logoTermColor) // #335094 - matches Android border
        .onAppear {
            // Handle case where view appears with already-completed transfer
            handleStateChange(info.state)
        }
        .onChange(of: info.state) { newState in
            handleStateChange(newState)
        }
        .onDisappear {
            // Clean up timer when view disappears
            autoCloseTimer?.invalidate()
            autoCloseTimer = nil
        }
    }

    // MARK: - Auto-close Logic

    /// Handle transfer state changes - play bell and start auto-close on completion
    private func handleStateChange(_ state: TransferState) {
        switch state {
        case .complete, .error, .cancelled:
            onTransferEnded()
        default:
            break
        }
    }

    /// Called when transfer ends (complete, error, or cancelled)
    private func onTransferEnded() {
        // Play bell once
        if !bellPlayed {
            bellPlayed = true
            BellManager.shared.playBell()
        }

        // Start auto-close countdown if not already running
        guard autoCloseTimer == nil else { return }

        autoCloseSecondsLeft = autoCloseSeconds

        autoCloseTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            if let secondsLeft = autoCloseSecondsLeft, secondsLeft > 1 {
                autoCloseSecondsLeft = secondsLeft - 1
            } else {
                // Time's up - dismiss
                timer.invalidate()
                autoCloseTimer = nil
                onDismiss?()
            }
        }
    }

    // MARK: - Progress Bar

    private func buildProgressBar() -> String {
        let percent = info.progressPercent
        let filled = max(0, min(progressWidth, (percent * progressWidth) / 100))
        let empty = progressWidth - filled
        return "[" + String(repeating: filledChar, count: filled) + String(repeating: emptyChar, count: empty) + "]"
    }

    // MARK: - Number Formatting

    private func formatNumber(_ num: Int64) -> String {
        return "\(num)"
    }

    private func formatNumber(_ num: Int) -> String {
        return "\(num)"
    }

    // MARK: - Computed Properties

    private var titleText: String {
        switch info.direction {
        case .send: return " ZMODEM Send "
        case .receive: return " ZMODEM Recv "
        case .none: return " ZMODEM Transfer "
        }
    }

    private var statusText: String {
        let baseText: String
        switch info.state {
        case .idle: baseText = "Waiting for remote..."
        case .receiving, .sending: baseText = "Transferring..."
        case .complete: baseText = "Transfer OK!"
        case .error(let message): baseText = "ERROR: \(message)"
        case .cancelled: baseText = "Transfer ABORTED"
        }

        // Add countdown suffix when auto-closing
        if let secondsLeft = autoCloseSecondsLeft {
            return "\(baseText) (closing in \(secondsLeft)s)"
        }
        return baseText
    }

    private var statusColor: Color {
        switch info.state {
        case .idle: return .termYellow
        case .receiving, .sending: return .accent
        case .complete: return .accent
        case .error: return .termLightRed
        case .cancelled: return .termYellow
        }
    }

    private var shouldShowCancel: Bool {
        switch info.state {
        case .receiving, .sending, .idle:
            return true
        default:
            return false
        }
    }

    private var shouldShowClose: Bool {
        switch info.state {
        case .complete, .error, .cancelled:
            return true
        default:
            return false
        }
    }
}

// MARK: - Preview

struct TransferProgressView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            // Idle/Waiting
            TransferProgressView(
                info: TransferInfo(
                    state: .idle,
                    direction: .receive,
                    fileName: nil,
                    bytesTransferred: 0,
                    totalBytes: 0,
                    bytesPerSecond: 0
                ),
                onCancel: {}
            )
            .previewDisplayName("Waiting")

            // Receiving
            TransferProgressView(
                info: TransferInfo(
                    state: .receiving,
                    direction: .receive,
                    fileName: "example_file.zip",
                    bytesTransferred: 512000,
                    totalBytes: 1024000,
                    bytesPerSecond: 128000
                ),
                onCancel: {}
            )
            .previewDisplayName("Receiving")

            // Sending
            TransferProgressView(
                info: TransferInfo(
                    state: .sending,
                    direction: .send,
                    fileName: "upload.txt",
                    bytesTransferred: 256000,
                    totalBytes: 512000,
                    bytesPerSecond: 64000
                ),
                onCancel: {}
            )
            .previewDisplayName("Sending")

            // Complete
            TransferProgressView(
                info: TransferInfo(
                    state: .complete,
                    direction: .receive,
                    fileName: "downloaded.zip",
                    bytesTransferred: 1024000,
                    totalBytes: 1024000
                ),
                onCancel: {},
                onDismiss: {}
            )
            .previewDisplayName("Complete")

            // Error
            TransferProgressView(
                info: TransferInfo(
                    state: .error("Connection timeout"),
                    direction: .receive,
                    fileName: "failed.zip"
                ),
                onCancel: {},
                onDismiss: {}
            )
            .previewDisplayName("Error")

            // Cancelled
            TransferProgressView(
                info: TransferInfo(
                    state: .cancelled,
                    direction: .send,
                    fileName: "cancelled.txt"
                ),
                onCancel: {},
                onDismiss: {}
            )
            .previewDisplayName("Cancelled")
        }
        .padding()
        .background(Color.black)
    }
}
