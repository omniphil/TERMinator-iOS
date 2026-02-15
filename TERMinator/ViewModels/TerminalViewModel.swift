import Foundation
import Combine
import UIKit
import os.log

private let logger = Logger(subsystem: "com.jsonbourne.TERMinator", category: "Terminal")

/// Connection state for the terminal.
enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case disconnecting
    case error(String)
}

/// Represents a detected URL in the terminal screen.
struct DetectedURL {
    let url: String
    let startColumn: Int
    let endColumn: Int
    let row: Int
}

/// ViewModel for the terminal view.
/// Manages connection, screen state, logging, and file transfers.
@MainActor
class TerminalViewModel: ObservableObject {

    // MARK: - Published Properties

    @Published var connectionState: ConnectionState = .disconnected
    @Published var screenBuffer: [Int32] = []
    @Published var screenColumns: Int = 80
    @Published var screenRows: Int = 25
    @Published var cursorX: Int = 0
    @Published var cursorY: Int = 0
    @Published var cursorVisible: Bool = true
    @Published var palette: [Int32] = []

    @Published var isLogging: Bool = false
    @Published var transferInfo: TransferInfo?
    @Published var showTransferView: Bool = false
    @Published var showUploadPicker: Bool = false

    @Published var zoomLevel: CGFloat = 1.0
    @Published var panOffset: CGSize = .zero

    @Published var detectedURLs: [DetectedURL] = []

    // Scrollback state
    @Published var scrollbackOffset: Int = 0  // 0 = live, >0 = lines scrolled back
    var isInScrollback: Bool { scrollbackOffset > 0 }
    private(set) var displayBuffer: [Int32] = []
    private(set) var displayBufferVersion: Int = 0

    // Byte counters
    @Published var bytesReceived: Int = 0
    @Published var bytesSent: Int = 0

    // Font dimensions (from native font bitmap)
    @Published var fontWidth: Int = 0
    @Published var fontHeight: Int = 0

    // Renderer readiness state (for proper first-render timing)
    @Published var rendererReady = false

    // Screen buffer version counter - incremented when buffer changes.
    // Used by Metal renderer to skip re-rendering when nothing changed.
    private(set) var screenBufferVersion: Int = 0

    // MARK: - Private Properties

    private var entry: BBSEntry?
    private var pollingTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var isTransferInProgress = false
    private var pendingStartAfterConnect = false

    // Bitmap font data
    // Exposed for Metal renderer access
    private(set) var fontBitmap: Data?
    private var glyphCache = NSCache<NSString, CGImage>()

    // ZMODEM detection return codes from native layer
    // These MUST match values in native code (conn_api.c)
    private let ZMODEM_DOWNLOAD_DETECTED = -100  // ZRQINIT received - BBS wants to send file
    private let ZMODEM_UPLOAD_READY = -101       // ZRINIT received - BBS ready to receive file

    // URL detection regex - initialized lazily to avoid crash on invalid pattern
    private lazy var urlPattern: NSRegularExpression? = {
        do {
            return try NSRegularExpression(
                pattern: "(https?://|ftp://|www\\.)[^\\s<>\\[\\](){}'\"`,;]+[^\\s<>\\[\\](){}'\"`,;.!?]",
                options: .caseInsensitive
            )
        } catch {
            print("TerminalViewModel: Failed to create URL pattern: \(error)")
            return nil
        }
    }()

    // CP437 to Unicode mapping table
    private let cp437ToUnicode: [Character] = [
        // 0x00-0x1F: Control characters displayed as graphics in CP437
        "\u{0000}", "\u{263A}", "\u{263B}", "\u{2665}", "\u{2666}", "\u{2663}", "\u{2660}", "\u{2022}",
        "\u{25D8}", "\u{25CB}", "\u{25D9}", "\u{2642}", "\u{2640}", "\u{266A}", "\u{266B}", "\u{263C}",
        "\u{25BA}", "\u{25C4}", "\u{2195}", "\u{203C}", "\u{00B6}", "\u{00A7}", "\u{25AC}", "\u{21A8}",
        "\u{2191}", "\u{2193}", "\u{2192}", "\u{2190}", "\u{221F}", "\u{2194}", "\u{25B2}", "\u{25BC}",
        // 0x20-0x7E: Standard ASCII
        " ", "!", "\"", "#", "$", "%", "&", "'", "(", ")", "*", "+", ",", "-", ".", "/",
        "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", ":", ";", "<", "=", ">", "?",
        "@", "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O",
        "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "[", "\\", "]", "^", "_",
        "`", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o",
        "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "{", "|", "}", "~", "\u{2302}",
        // 0x80-0xFF: Extended characters
        "\u{00C7}", "\u{00FC}", "\u{00E9}", "\u{00E2}", "\u{00E4}", "\u{00E0}", "\u{00E5}", "\u{00E7}",
        "\u{00EA}", "\u{00EB}", "\u{00E8}", "\u{00EF}", "\u{00EE}", "\u{00EC}", "\u{00C4}", "\u{00C5}",
        "\u{00C9}", "\u{00E6}", "\u{00C6}", "\u{00F4}", "\u{00F6}", "\u{00F2}", "\u{00FB}", "\u{00F9}",
        "\u{00FF}", "\u{00D6}", "\u{00DC}", "\u{00A2}", "\u{00A3}", "\u{00A5}", "\u{20A7}", "\u{0192}",
        "\u{00E1}", "\u{00ED}", "\u{00F3}", "\u{00FA}", "\u{00F1}", "\u{00D1}", "\u{00AA}", "\u{00BA}",
        "\u{00BF}", "\u{2310}", "\u{00AC}", "\u{00BD}", "\u{00BC}", "\u{00A1}", "\u{00AB}", "\u{00BB}",
        "\u{2591}", "\u{2592}", "\u{2593}", "\u{2502}", "\u{2524}", "\u{2561}", "\u{2562}", "\u{2556}",
        "\u{2555}", "\u{2563}", "\u{2551}", "\u{2557}", "\u{255D}", "\u{255C}", "\u{255B}", "\u{2510}",
        "\u{2514}", "\u{2534}", "\u{252C}", "\u{251C}", "\u{2500}", "\u{253C}", "\u{255E}", "\u{255F}",
        "\u{255A}", "\u{2554}", "\u{2569}", "\u{2566}", "\u{2560}", "\u{2550}", "\u{256C}", "\u{2567}",
        "\u{2568}", "\u{2564}", "\u{2565}", "\u{2559}", "\u{2558}", "\u{2552}", "\u{2553}", "\u{256B}",
        "\u{256A}", "\u{2518}", "\u{250C}", "\u{2588}", "\u{2584}", "\u{258C}", "\u{2590}", "\u{2580}",
        "\u{03B1}", "\u{00DF}", "\u{0393}", "\u{03C0}", "\u{03A3}", "\u{03C3}", "\u{00B5}", "\u{03C4}",
        "\u{03A6}", "\u{0398}", "\u{03A9}", "\u{03B4}", "\u{221E}", "\u{03C6}", "\u{03B5}", "\u{2229}",
        "\u{2261}", "\u{00B1}", "\u{2265}", "\u{2264}", "\u{2320}", "\u{2321}", "\u{00F7}", "\u{2248}",
        "\u{00B0}", "\u{2219}", "\u{00B7}", "\u{221A}", "\u{207F}", "\u{00B2}", "\u{25A0}", "\u{00A0}"
    ]

    // Amiga Topaz font uses slightly different mapping for some characters
    private let amigaToUnicode: [Character] = [
        // 0x00-0x1F: Control characters (same as CP437 for most)
        "\u{0000}", "\u{263A}", "\u{263B}", "\u{2665}", "\u{2666}", "\u{2663}", "\u{2660}", "\u{2022}",
        "\u{25D8}", "\u{25CB}", "\u{25D9}", "\u{2642}", "\u{2640}", "\u{266A}", "\u{266B}", "\u{263C}",
        "\u{25BA}", "\u{25C4}", "\u{2195}", "\u{203C}", "\u{00B6}", "\u{00A7}", "\u{25AC}", "\u{21A8}",
        "\u{2191}", "\u{2193}", "\u{2192}", "\u{2190}", "\u{221F}", "\u{2194}", "\u{25B2}", "\u{25BC}",
        // 0x20-0x7E: Standard ASCII (same)
        " ", "!", "\"", "#", "$", "%", "&", "'", "(", ")", "*", "+", ",", "-", ".", "/",
        "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", ":", ";", "<", "=", ">", "?",
        "@", "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O",
        "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "[", "\\", "]", "^", "_",
        "`", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o",
        "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "{", "|", "}", "~", "\u{2302}",
        // 0x80-0xFF: Extended - Amiga uses ISO-8859-1 style for some
        "\u{00C7}", "\u{00FC}", "\u{00E9}", "\u{00E2}", "\u{00E4}", "\u{00E0}", "\u{00E5}", "\u{00E7}",
        "\u{00EA}", "\u{00EB}", "\u{00E8}", "\u{00EF}", "\u{00EE}", "\u{00EC}", "\u{00C4}", "\u{00C5}",
        "\u{00C9}", "\u{00E6}", "\u{00C6}", "\u{00F4}", "\u{00F6}", "\u{00F2}", "\u{00FB}", "\u{00F9}",
        "\u{00FF}", "\u{00D6}", "\u{00DC}", "\u{00A2}", "\u{00A3}", "\u{00A5}", "\u{20A7}", "\u{0192}",
        "\u{00E1}", "\u{00ED}", "\u{00F3}", "\u{00FA}", "\u{00F1}", "\u{00D1}", "\u{00AA}", "\u{00BA}",
        "\u{00BF}", "\u{2310}", "\u{00AC}", "\u{00BD}", "\u{00BC}", "\u{00A1}", "\u{00AB}", "\u{00BB}",
        "\u{2591}", "\u{2592}", "\u{2593}", "\u{2502}", "\u{2524}", "\u{2561}", "\u{2562}", "\u{2556}",
        "\u{2555}", "\u{2563}", "\u{2551}", "\u{2557}", "\u{255D}", "\u{255C}", "\u{255B}", "\u{2510}",
        "\u{2514}", "\u{2534}", "\u{252C}", "\u{251C}", "\u{2500}", "\u{253C}", "\u{255E}", "\u{255F}",
        "\u{255A}", "\u{2554}", "\u{2569}", "\u{2566}", "\u{2560}", "\u{2550}", "\u{256C}", "\u{2567}",
        "\u{2568}", "\u{2564}", "\u{2565}", "\u{2559}", "\u{2558}", "\u{2552}", "\u{2553}", "\u{256B}",
        "\u{256A}", "\u{2518}", "\u{250C}", "\u{2588}", "\u{2584}", "\u{258C}", "\u{2590}", "\u{2580}",
        "\u{03B1}", "\u{00DF}", "\u{0393}", "\u{03C0}", "\u{03A3}", "\u{03C3}", "\u{00B5}", "\u{03C4}",
        "\u{03A6}", "\u{0398}", "\u{03A9}", "\u{03B4}", "\u{221E}", "\u{03C6}", "\u{03B5}", "\u{2229}",
        "\u{2261}", "\u{00B1}", "\u{2265}", "\u{2264}", "\u{2320}", "\u{2321}", "\u{00F7}", "\u{2248}",
        "\u{00B0}", "\u{2219}", "\u{00B7}", "\u{221A}", "\u{207F}", "\u{00B2}", "\u{25A0}", "\u{00A0}"
    ]

    // MARK: - Initialization

    init() {
        setupTransferObserver()
    }

    private func setupTransferObserver() {
        TransferManager.shared.$transferInfo
            .receive(on: DispatchQueue.main)
            .sink { [weak self] info in
                self?.transferInfo = info
            }
            .store(in: &cancellables)

        TransferManager.shared.$isTransferring
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isTransferring in
                self?.isTransferInProgress = isTransferring
                if isTransferring {
                    self?.showTransferView = true
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Connection

    /// Connect to a BBS entry.
    func connect(to entry: BBSEntry) {
        // Only allow connection if truly disconnected and not already connecting
        guard connectionState == .disconnected else {
            logger.info("Connect called but state is \(String(describing: self.connectionState))")
            return
        }

        logger.info("Connecting to \(entry.host):\(entry.port) font=\(entry.font.rawValue)")

        self.entry = entry
        connectionState = .connecting

        // Reset terminal state for clean connection
        resetState()

        // Apply zoom level
        zoomLevel = CGFloat(entry.zoomLevel) / 100.0
        panOffset = .zero

        Task {
            // Destroy and reinitialize native system for clean state
            NativeBridge.shared.destroy()

            guard NativeBridge.shared.initialize() else {
                logger.error("Failed to initialize native system")
                connectionState = .error("Failed to initialize terminal")
                return
            }
            logger.info("Native system initialized")

            // Configure terminal settings AFTER initialization
            NativeBridge.shared.setScreenMode(entry.screenMode.rawValue)
            NativeBridge.shared.setHideStatusLine(!entry.showStatusBar)
            _ = NativeBridge.shared.setFontById(entry.font.rawValue)

            // Connect asynchronously (non-blocking)
            logger.info("Calling connectAsync...")
            print("[TerminalViewModel] About to call connectAsync to \(entry.host):\(entry.port)")
            let success = await NativeBridge.shared.connectAsync(
                host: entry.host,
                port: entry.port,
                protocol: entry.connectionProtocol.rawValue,
                username: entry.username.isEmpty ? nil : entry.username,
                password: entry.password?.isEmpty == true ? nil : entry.password
            )
            print("[TerminalViewModel] connectAsync returned: \(success)")
            logger.info("connectAsync returned: \(success)")

            if success {
                logger.info("Connection successful")
                connectionState = .connected

                // Wait for renderer to be ready before starting terminal rendering
                // This prevents black bars by ensuring the view has proper backing store
                if rendererReady {
                    startTerminalRendering()
                } else {
                    pendingStartAfterConnect = true
                    logger.info("Waiting for renderer to be ready...")
                }

                // Start logging if enabled in settings
                if UserDefaults.standard.bool(forKey: "logging_enabled") {
                    startLogging()
                }

                // Update last connected
                BBSEntryStore.shared.updateLastConnected(for: entry)
            } else {
                logger.error("Connection failed to \(entry.host):\(entry.port)")
                connectionState = .error("Failed to connect to \(entry.host):\(entry.port)")
            }
        }
    }

    /// Disconnect from the current connection.
    func disconnect() {
        guard connectionState == .connected else { return }

        connectionState = .disconnecting
        stopPolling()

        if isLogging {
            stopLogging()
        }

        NativeBridge.shared.disconnect()
        connectionState = .disconnected
    }

    // MARK: - Renderer Readiness

    /// Called when the UIView is attached to a window and has correct scale.
    /// This ensures first render happens with proper backing store.
    func rendererDidBecomeReady() {
        guard !rendererReady else { return }
        rendererReady = true
        logger.info("Renderer ready")

        if pendingStartAfterConnect && connectionState == .connected {
            pendingStartAfterConnect = false
            startTerminalRendering()
        }
    }

    /// Start terminal rendering after both connection and renderer are ready.
    private func startTerminalRendering() {
        loadFontBitmap()
        logger.info("Font loaded: \(self.fontWidth)x\(self.fontHeight)")

        startPolling()
        updateScreen()
    }

    // MARK: - Data Polling

    private func startPolling() {
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollData()
            }
        }
    }

    private func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    private func pollData() {
        guard connectionState == .connected, !isTransferInProgress else { return }

        // Check connection
        if !NativeBridge.shared.isConnected() {
            handleDisconnection()
            return
        }

        // Process incoming data
        let result = NativeBridge.shared.processData()

        // Track bytes received (positive result indicates bytes processed)
        if result > 0 {
            bytesReceived += result
        }

        // Check for ZMODEM detection
        if result == ZMODEM_DOWNLOAD_DETECTED {
            // ZMODEM download detected
            handleZmodemDownload()
            return
        } else if result == ZMODEM_UPLOAD_READY {
            // ZMODEM upload ready
            handleZmodemUploadReady()
            return
        }

        // Check for bell
        if NativeBridge.shared.checkBell() {
            BellManager.shared.playBell()
        }

        // Update screen if dirty
        if NativeBridge.shared.isScreenDirty() || result > 0 {
            updateScreen()
        }

        // Log data if logging is enabled
        if isLogging, let logData = NativeBridge.shared.getLoggedData() {
            SessionLogger.shared.logData(logData)
        }
    }

    private func handleDisconnection() {
        // Stop polling first to prevent re-entry
        stopPolling()

        // Process any remaining data in the buffer before showing disconnect
        var processedMore = true
        while processedMore {
            let result = NativeBridge.shared.processData()
            if result > 0 {
                bytesReceived += result
            } else {
                processedMore = false
            }
        }

        // Final screen update to show goodbye message
        updateScreen()

        if isLogging {
            stopLogging()
        }

        // Delay before showing disconnect alert so user can see final content
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.connectionState = .error("Connection closed by remote host")
        }
    }

    // MARK: - Screen Update

    private func updateScreen() {
        // Get screen size
        let size = NativeBridge.shared.getScreenSize()
        screenColumns = size.columns
        screenRows = size.rows

        // Get screen buffer
        if let buffer = NativeBridge.shared.getScreenBuffer() {
            // Only log occasionally to avoid spam
            if screenBuffer.isEmpty {
                logger.info("Got screen buffer: \(buffer.count) cells, \(size.columns)x\(size.rows)")

                // Debug: log first 20 non-space cells
                var debugCells: [String] = []
                for (i, cell) in buffer.enumerated() {
                    let charCode = Int(cell & 0xFF)
                    let fg = Int((cell >> 16) & 0xF)
                    let bg = Int((cell >> 24) & 0xF)
                    if charCode != 32 && charCode != 0 {  // Not space or null
                        debugCells.append("[\(i):c\(charCode)/fg\(fg)/bg\(bg)]")
                        if debugCells.count >= 20 { break }
                    }
                }
                if debugCells.isEmpty {
                    logger.info("Screen buffer has no visible chars (all space/null)")
                } else {
                    logger.info("First visible cells: \(debugCells.joined(separator: " "))")
                }
            }
            screenBuffer = buffer
            screenBufferVersion += 1

            // Keep display buffer in sync
            if scrollbackOffset > 0 {
                rebuildDisplayBuffer()
            } else {
                displayBuffer = buffer
                displayBufferVersion += 1
            }

            detectURLs()
        } else {
            logger.warning("getScreenBuffer returned nil!")
        }

        // Get cursor position
        let cursor = NativeBridge.shared.getCursorPos()
        cursorX = cursor.x
        cursorY = cursor.y
        cursorVisible = NativeBridge.shared.isCursorVisible()

        // Get palette
        if let pal = NativeBridge.shared.getPalette() {
            palette = pal
        }
    }

    // MARK: - Input

    /// Send a character to the terminal.
    func sendCharacter(_ char: Character) {
        guard connectionState == .connected else { return }
        resetScrollback()
        let data = String(char).data(using: .utf8) ?? Data()
        let sent = NativeBridge.shared.sendData(data)
        if sent > 0 {
            bytesSent += sent
        }
    }

    /// Send a string to the terminal.
    func sendString(_ string: String) {
        guard connectionState == .connected else { return }
        resetScrollback()
        let sent = NativeBridge.shared.sendString(string)
        if sent > 0 {
            bytesSent += sent
        }
    }

    /// Send a key code to the terminal.
    func sendKey(_ keyCode: Int) {
        guard connectionState == .connected else { return }
        resetScrollback()
        let sent = NativeBridge.shared.sendKey(keyCode)
        if sent > 0 {
            bytesSent += sent
        }
    }

    /// Send raw data to the terminal.
    func sendData(_ data: Data) {
        guard connectionState == .connected else { return }
        resetScrollback()
        let sent = NativeBridge.shared.sendData(data)
        if sent > 0 {
            bytesSent += sent
        }
    }

    /// Set cursor visibility manually (for toggle feature).
    func setCursorVisible(_ visible: Bool) {
        cursorVisible = visible
    }

    // MARK: - Logging

    /// Start session logging.
    func startLogging() {
        guard let entry = entry, !isLogging else { return }

        if SessionLogger.shared.startLogging(bbsName: entry.name) {
            isLogging = true
            NativeBridge.shared.setLoggingEnabled(true)
        }
    }

    /// Stop session logging.
    func stopLogging() {
        guard isLogging else { return }

        NativeBridge.shared.setLoggingEnabled(false)
        _ = SessionLogger.shared.stopLogging()
        isLogging = false
    }

    // MARK: - File Transfer

    private func handleZmodemDownload() {
        isTransferInProgress = true
        showTransferView = true

        TransferManager.shared.startReceive { [weak self] result in
            self?.isTransferInProgress = false

            switch result {
            case .success(let fileName, _):
                print("Download complete: \(fileName)")
            case .error(let message):
                print("Download failed: \(message)")
            case .cancelled:
                print("Download cancelled")
            }

            // Delay hiding to show completion status
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                self?.showTransferView = false
            }
        }
    }

    private func handleZmodemUploadReady() {
        // If a file is queued, start the upload
        if TransferManager.shared.isUploadQueued,
           let queuedPath = TransferManager.shared.queuedUploadPath {
            startQueuedUpload(path: queuedPath)
        } else {
            // No file queued - prompt user to pick one
            DispatchQueue.main.async {
                self.showUploadPicker = true
            }
        }
    }

    /// Start uploading an already-queued file.
    func startQueuedUpload(path: String) {
        isTransferInProgress = true
        showTransferView = true

        let fileURL = URL(fileURLWithPath: path)
        TransferManager.shared.startSend(fileURL: fileURL) { [weak self] result in
            self?.isTransferInProgress = false
            TransferManager.shared.clearUploadQueue()

            switch result {
            case .success(let fileName, _):
                print("Upload complete: \(fileName)")
            case .error(let message):
                print("Upload failed: \(message)")
            case .cancelled:
                print("Upload cancelled")
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                self?.showTransferView = false
            }
        }
    }

    /// Queue a file for upload.
    func queueUpload(fileURL: URL) {
        TransferManager.shared.queueUpload(fileURL: fileURL)
    }

    /// Cancel the current transfer.
    func cancelTransfer() {
        TransferManager.shared.cancelTransfer()
    }

    // MARK: - URL Detection

    private func detectURLs() {
        detectedURLs = []

        guard !screenBuffer.isEmpty, screenColumns > 0, screenRows > 0 else { return }

        // Build text from screen buffer, tracking positions
        for row in 0..<screenRows {
            var rowText = ""
            for col in 0..<screenColumns {
                let index = row * screenColumns + col
                if index < screenBuffer.count {
                    let char = NativeBridge.unpackChar(screenBuffer[index])
                    rowText.append(char)
                }
            }

            // Find URLs in this row (skip if regex failed to compile)
            guard let pattern = urlPattern else { continue }
            let range = NSRange(rowText.startIndex..., in: rowText)
            let matches = pattern.matches(in: rowText, options: [], range: range)

            for match in matches {
                if let urlRange = Range(match.range, in: rowText) {
                    let url = String(rowText[urlRange])
                    let startCol = rowText.distance(from: rowText.startIndex, to: urlRange.lowerBound)
                    let endCol = rowText.distance(from: rowText.startIndex, to: urlRange.upperBound)

                    detectedURLs.append(DetectedURL(
                        url: url,
                        startColumn: startCol,
                        endColumn: endCol,
                        row: row
                    ))
                }
            }
        }
    }

    /// Check if a cell position contains a URL.
    func urlAt(column: Int, row: Int) -> String? {
        for detected in detectedURLs {
            if detected.row == row && column >= detected.startColumn && column < detected.endColumn {
                return detected.url
            }
        }
        return nil
    }

    /// Open a URL.
    func openURL(_ urlString: String) {
        var finalURL = urlString

        // Add protocol if missing
        if finalURL.lowercased().hasPrefix("www.") {
            finalURL = "https://" + finalURL
        }

        guard let url = URL(string: finalURL) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Zoom & Pan

    /// Set zoom level (20-150%).
    func setZoom(_ level: CGFloat) {
        zoomLevel = max(0.2, min(1.5, level))

        // Reset pan if zoomed out to 100% or less
        if zoomLevel <= 1.0 {
            panOffset = .zero
        }

        // Save to entry if connected
        if var entry = entry {
            entry.zoomLevel = Int(zoomLevel * 100)
            BBSEntryStore.shared.updateEntry(entry)
        }
    }

    /// Reset zoom to 100%.
    func resetZoom() {
        zoomLevel = 1.0
        panOffset = .zero

        if var entry = entry {
            entry.zoomLevel = 100
            BBSEntryStore.shared.updateEntry(entry)
        }
    }

    /// Update pan offset for scrolling around zoomed content.
    func updatePan(_ offset: CGSize) {
        panOffset = offset
    }

    // MARK: - Scrollback

    /// Set the scrollback offset and rebuild the composite display buffer.
    /// offset 0 = live screen, >0 = number of lines scrolled back into history.
    func setScrollbackOffset(_ offset: Int) {
        guard let info = NativeBridge.shared.getScrollbackInfo() else {
            scrollbackOffset = 0
            return
        }

        let maxOffset = info.filledLines
        let clamped = max(0, min(offset, maxOffset))
        scrollbackOffset = clamped

        rebuildDisplayBuffer()
    }

    /// Reset scrollback to live screen.
    func resetScrollback() {
        guard scrollbackOffset > 0 else { return }
        scrollbackOffset = 0
        displayBuffer = screenBuffer
        displayBufferVersion += 1
    }

    /// Rebuild the composite display buffer from scrollback + screen data.
    private func rebuildDisplayBuffer() {
        if scrollbackOffset == 0 {
            displayBuffer = screenBuffer
            displayBufferVersion += 1
            return
        }

        guard screenColumns > 0, screenRows > 0 else { return }

        // How many scrollback lines to show at the top of the display
        let scrollbackLinesToShow = min(scrollbackOffset, screenRows)
        // How many live screen lines remain visible at the bottom
        let screenLinesVisible = screenRows - scrollbackLinesToShow

        // Fetch scrollback lines from NativeBridge
        // offset parameter: how far back from most recent scrollback line
        // We want the lines starting at (scrollbackOffset - scrollbackLinesToShow) from the top
        let fetchOffset = scrollbackOffset - scrollbackLinesToShow
        guard let scrollbackCells = NativeBridge.shared.getScrollbackBuffer(
            offset: fetchOffset, count: scrollbackLinesToShow
        ) else {
            // Fallback: just show live screen
            displayBuffer = screenBuffer
            displayBufferVersion += 1
            return
        }

        let totalCells = screenRows * screenColumns
        var composite = [Int32](repeating: 0, count: totalCells)

        // Fill top rows from scrollback
        let scrollbackCellCount = min(scrollbackCells.count, scrollbackLinesToShow * screenColumns)
        for i in 0..<scrollbackCellCount {
            composite[i] = scrollbackCells[i]
        }

        // Fill remaining rows from the top of the live screen buffer
        if screenLinesVisible > 0 {
            let screenCellsToCopy = screenLinesVisible * screenColumns
            let destOffset = scrollbackLinesToShow * screenColumns
            let srcCount = min(screenCellsToCopy, screenBuffer.count)
            for i in 0..<srcCount {
                composite[destOffset + i] = screenBuffer[i]
            }
        }

        displayBuffer = composite
        displayBufferVersion += 1
    }

    // MARK: - Snapshot

    /// Capture a snapshot of the current terminal screen.
    func captureSnapshot() -> UIImage? {
        guard !screenBuffer.isEmpty, fontWidth > 0, fontHeight > 0 else { return nil }
        guard screenColumns > 0, screenRows > 0 else { return nil }

        let width = screenColumns * fontWidth
        let height = screenRows * fontHeight

        // Validate dimensions to prevent memory issues (max 4K resolution)
        guard width > 0, height > 0, width <= 4096, height <= 4096 else { return nil }

        UIGraphicsBeginImageContextWithOptions(CGSize(width: width, height: height), true, 1.0)
        guard let context = UIGraphicsGetCurrentContext() else {
            UIGraphicsEndImageContext()
            return nil
        }

        // Fill background with black
        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Get palette colors
        let paletteColors = getUIColorPalette()

        // Draw each cell
        for row in 0..<screenRows {
            for col in 0..<screenColumns {
                let index = row * screenColumns + col
                guard index < screenBuffer.count else { continue }

                let cell = screenBuffer[index]
                let charCode = Int(cell & 0xFF)
                let attr = Int((cell >> 8) & 0xFF)
                let fgIndex = attr & 0x0F
                let bgIndex = (attr >> 4) & 0x07

                let x = CGFloat(col * fontWidth)
                let y = CGFloat(row * fontHeight)
                let rect = CGRect(x: x, y: y, width: CGFloat(fontWidth), height: CGFloat(fontHeight))

                // Draw background (with bounds check)
                let bgColor = bgIndex < paletteColors.count ? paletteColors[bgIndex] : UIColor.black
                context.setFillColor(bgColor.cgColor)
                context.fill(rect)

                // Draw glyph at native font size (snapshot is at 1:1 scale)
                if let glyphImage = getGlyphImage(charCode: charCode, fgIndex: fgIndex, bgIndex: bgIndex,
                                                   targetWidth: fontWidth, targetHeight: fontHeight) {
                    context.draw(glyphImage, in: rect)
                }
            }
        }

        let image = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return image
    }

    /// Capture snapshot as Data for saving.
    func captureSnapshotData() -> Data? {
        return captureSnapshot()?.pngData()
    }

    /// Save snapshot for the current entry.
    func saveSnapshot(_ data: Data) {
        guard let entry = entry else { return }
        BBSEntryStore.shared.updateSnapshot(data, for: entry)
    }

    /// Get UIColor palette for snapshot rendering.
    private func getUIColorPalette() -> [UIColor] {
        let defaultPalette: [UIColor] = [
            UIColor(red: 0, green: 0, blue: 0, alpha: 1),                    // 0: Black
            UIColor(red: 0, green: 0, blue: 0.667, alpha: 1),                // 1: Blue
            UIColor(red: 0, green: 0.667, blue: 0, alpha: 1),                // 2: Green
            UIColor(red: 0, green: 0.667, blue: 0.667, alpha: 1),            // 3: Cyan
            UIColor(red: 0.667, green: 0, blue: 0, alpha: 1),                // 4: Red
            UIColor(red: 0.667, green: 0, blue: 0.667, alpha: 1),            // 5: Magenta
            UIColor(red: 0.667, green: 0.333, blue: 0, alpha: 1),            // 6: Brown
            UIColor(red: 0.667, green: 0.667, blue: 0.667, alpha: 1),        // 7: Light Gray
            UIColor(red: 0.333, green: 0.333, blue: 0.333, alpha: 1),        // 8: Dark Gray
            UIColor(red: 0.333, green: 0.333, blue: 1, alpha: 1),            // 9: Light Blue
            UIColor(red: 0.333, green: 1, blue: 0.333, alpha: 1),            // 10: Light Green
            UIColor(red: 0.333, green: 1, blue: 1, alpha: 1),                // 11: Light Cyan
            UIColor(red: 1, green: 0.333, blue: 0.333, alpha: 1),            // 12: Light Red
            UIColor(red: 1, green: 0.333, blue: 1, alpha: 1),                // 13: Light Magenta
            UIColor(red: 1, green: 1, blue: 0.333, alpha: 1),                // 14: Yellow
            UIColor(red: 1, green: 1, blue: 1, alpha: 1),                    // 15: White
        ]

        if !palette.isEmpty && palette.count >= 16 {
            return palette.prefix(16).map { value in
                let uval = UInt32(bitPattern: value)
                let r = CGFloat((uval >> 16) & 0xFF) / 255.0
                let g = CGFloat((uval >> 8) & 0xFF) / 255.0
                let b = CGFloat(uval & 0xFF) / 255.0
                return UIColor(red: r, green: g, blue: b, alpha: 1)
            }
        }

        return defaultPalette
    }

    // MARK: - State Reset

    /// Reset all terminal state for a new connection.
    /// Call this before connecting to a new BBS to ensure clean state.
    private func resetState() {
        // Reset byte counters
        bytesReceived = 0
        bytesSent = 0

        // Clear screen buffer (native screen cleared separately after init)
        screenBuffer = []

        // Reset cursor to home position
        cursorX = 0
        cursorY = 0
        cursorVisible = true

        // Reset screen dimensions to defaults
        screenColumns = 80
        screenRows = 25

        // Reset palette to defaults
        palette = []

        // Reset scrollback
        scrollbackOffset = 0
        displayBuffer = []
        displayBufferVersion += 1

        // Clear detected URLs
        detectedURLs = []

        // Clear glyph cache
        glyphCache.removeAllObjects()

        // Reset zoom and pan
        zoomLevel = 1.0
        panOffset = .zero

        // Clear font data to force reload
        fontBitmap = nil
        fontWidth = 0
        fontHeight = 0

        // Force Metal to re-render after reset
        screenBufferVersion += 1
    }

    // MARK: - Cleanup

    func cleanup() {
        stopPolling()
        if isLogging {
            stopLogging()
        }
        TransferManager.shared.cleanup()
        cancellables.removeAll()
        glyphCache.removeAllObjects()
    }

    deinit {
        // Note: Can't call cleanup() from deinit since it's @MainActor
    }

    // MARK: - Bitmap Font Rendering

    /// Load the font bitmap from native code.
    func loadFontBitmap() {
        // Clear existing cache when font changes
        glyphCache.removeAllObjects()

        let fontIdDebug = entry?.font.rawValue ?? -1
        logger.info("loadFontBitmap called, entry.font.rawValue=\(fontIdDebug)")

        // IMPORTANT: Ensure the correct font ID is set before loading the bitmap
        // This prevents issues where another connection might have changed the font
        if let entry = entry {
            _ = NativeBridge.shared.setFontById(entry.font.rawValue)
        }

        // Get font bitmap data including dimensions
        if let fontInfo = NativeBridge.shared.getFontBitmap() {
            fontWidth = fontInfo.width
            fontHeight = fontInfo.height
            fontBitmap = fontInfo.data

            // Validate font dimensions
            let expectedSize = 256 * fontInfo.height * ((fontInfo.width + 7) / 8)
            if fontInfo.data.count != expectedSize {
                logger.warning("Font bitmap size mismatch: got \(fontInfo.data.count), expected \(expectedSize)")
            }

            // Log first few bytes of character 65 ('A') to verify font loaded correctly
            let char65Offset = 65 * fontInfo.height
            if fontInfo.data.count > char65Offset + fontInfo.height {
                var bytes: [String] = []
                for i in 0..<min(fontInfo.height, 16) {
                    bytes.append(String(format: "%02X", fontInfo.data[char65Offset + i]))
                }
                logger.info("Font loaded: \(fontInfo.width)x\(fontInfo.height), fontID=\(fontIdDebug), charA=[\(bytes.joined(separator: " "))]")
            } else {
                logger.info("Font loaded: \(fontInfo.width)x\(fontInfo.height), \(fontInfo.data.count) bytes, fontID=\(fontIdDebug)")
            }

            // Also log character 32 (space) to verify
            let char32Offset = 32 * fontInfo.height
            if fontInfo.data.count > char32Offset + fontInfo.height {
                var spaceBytes: [String] = []
                for i in 0..<min(fontInfo.height, 16) {
                    spaceBytes.append(String(format: "%02X", fontInfo.data[char32Offset + i]))
                }
                logger.info("Space char (32): [\(spaceBytes.joined(separator: " "))]")
            }
        } else {
            // Set default dimensions if font fails to load
            fontWidth = 8
            fontHeight = 16
            logger.error("Failed to load font bitmap, using defaults, fontID=\(fontIdDebug)")
        }
    }

    /// Map a CP437 character code to its Unicode equivalent for fallback rendering.
    func mapCP437Char(_ charCode: Int) -> Character {
        guard charCode >= 0 && charCode < 256 else { return " " }

        // Use Amiga mapping for Topaz Plus font, CP437 for others
        if let entry = entry, entry.font == .topazPlus {
            return amigaToUnicode[charCode]
        }
        return cp437ToUnicode[charCode]
    }

    /// Get a cached or newly created glyph image for rendering.
    /// Creates glyphs at the exact target pixel size to avoid scaling artifacts.
    /// - Parameters:
    ///   - charCode: The character code (0-255)
    ///   - fgIndex: Foreground color index (0-15)
    ///   - bgIndex: Background color index (0-7)
    ///   - targetWidth: Target width in pixels (must be > 0)
    ///   - targetHeight: Target height in pixels (must be > 0)
    /// - Returns: A CGImage for the glyph, or nil if bitmap font not available
    func getGlyphImage(charCode: Int, fgIndex: Int, bgIndex: Int, targetWidth: Int, targetHeight: Int) -> CGImage? {
        // Validate font data exists and dimensions are reasonable
        guard let bitmap = fontBitmap, fontWidth > 0, fontHeight > 0 else { return nil }

        // Ensure character code is valid
        guard charCode >= 0 && charCode < 256 else { return nil }

        // Ensure target size is valid
        guard targetWidth > 0 && targetHeight > 0 else { return nil }

        // Validate bitmap has enough data for this character
        let bytesPerGlyphRow = (fontWidth + 7) / 8
        let expectedOffset = (charCode + 1) * fontHeight * bytesPerGlyphRow
        guard bitmap.count >= expectedOffset else { return nil }

        // Cache key includes target size since glyphs are pre-scaled
        let cacheKey = "\(charCode)_\(fgIndex)_\(bgIndex)_\(targetWidth)x\(targetHeight)" as NSString

        // Check cache
        if let cached = glyphCache.object(forKey: cacheKey) {
            return cached
        }

        // Create new glyph image at exact target size (no scaling at draw time)
        if let glyph = createGlyphImage(charCode: charCode, fgIndex: fgIndex, bgIndex: bgIndex,
                                         targetWidth: targetWidth, targetHeight: targetHeight) {
            glyphCache.setObject(glyph, forKey: cacheKey)
            return glyph
        }

        return nil
    }

    /// Render the entire terminal to a single CGImage - like Android's Bitmap approach.
    /// This avoids sub-pixel positioning issues from drawing many small images.
    func renderTerminalImage(columns: Int, rows: Int, cellWidthPx: Int, cellHeightPx: Int) -> CGImage? {
        guard let fontBitmap = fontBitmap,
              fontWidth > 0, fontHeight > 0,
              !screenBuffer.isEmpty,
              columns > 0, rows > 0,
              cellWidthPx > 0, cellHeightPx > 0 else {
            return nil
        }

        let termWidthPx = columns * cellWidthPx
        let termHeightPx = rows * cellHeightPx
        let pixelCount = termWidthPx * termHeightPx

        // Sanity check to prevent huge allocations (max ~16MB at 4 bytes/pixel)
        guard pixelCount <= 4000 * 2000 else { return nil }

        var pixels = [UInt32](repeating: 0xFF000000, count: pixelCount)

        let fontBytes = [UInt8](fontBitmap)
        let bytesPerRow = (fontWidth + 7) / 8

        for row in 0..<rows {
            for col in 0..<columns {
                let index = row * columns + col
                guard index < screenBuffer.count else { continue }

                let cell = screenBuffer[index]
                let cellUnsigned = UInt32(bitPattern: cell)
                let charCode = Int(cellUnsigned & 0xFF)
                let fgIndex = Int((cellUnsigned >> 16) & 0x0F)
                let bgIndex = Int((cellUnsigned >> 24) & 0x0F)

                let fgColor = getColorForIndex(fgIndex)
                let bgColor = getColorForIndex(bgIndex)
                let fgPixel: UInt32 = 0xFF000000 | (fgColor & 0xFFFFFF)
                let bgPixel: UInt32 = 0xFF000000 | (bgColor & 0xFFFFFF)

                let glyphOffset = charCode * fontHeight * bytesPerRow
                let cellStartX = col * cellWidthPx
                let cellStartY = row * cellHeightPx

                for destY in 0..<cellHeightPx {
                    // Center-sampling: map destination pixel to source pixel center
                    let srcY = ((2 * destY + 1) * fontHeight) / (2 * cellHeightPx)
                    let rowOffset = glyphOffset + srcY * bytesPerRow
                    let rowByte0: UInt8 = rowOffset < fontBytes.count ? fontBytes[rowOffset] : 0
                    let rowByte1: UInt8 = (bytesPerRow > 1 && rowOffset + 1 < fontBytes.count) ? fontBytes[rowOffset + 1] : 0

                    let termY = cellStartY + destY
                    let rowStart = termY * termWidthPx

                    for destX in 0..<cellWidthPx {
                        // Center-sampling for horizontal axis
                        let srcX = ((2 * destX + 1) * fontWidth) / (2 * cellWidthPx)

                        let isSet: Bool
                        if srcX < 8 {
                            isSet = ((Int(rowByte0) >> (7 - srcX)) & 1) == 1
                        } else {
                            isSet = ((Int(rowByte1) >> (15 - srcX)) & 1) == 1
                        }

                        let termX = cellStartX + destX
                        let pixelIdx = rowStart + termX
                        guard pixelIdx < pixelCount else { continue }
                        pixels[pixelIdx] = isSet ? fgPixel : bgPixel
                    }
                }
            }
        }

        // Create CGImage from pixel buffer
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)

        let pixelData = pixels.withUnsafeBytes { rawBuffer -> Data in
            Data(rawBuffer)
        }

        guard let provider = CGDataProvider(data: pixelData as CFData) else { return nil }

        return CGImage(
            width: termWidthPx,
            height: termHeightPx,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: termWidthPx * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Create a glyph image from the font bitmap at EXACT target size.
    /// Uses center-sampling from native font size to target size.
    private func createGlyphImage(charCode: Int, fgIndex: Int, bgIndex: Int,
                                   targetWidth: Int, targetHeight: Int) -> CGImage? {
        guard let fontBitmap = fontBitmap,
              fontWidth > 0, fontHeight > 0 else { return nil }

        let bytesPerRow = (fontWidth + 7) / 8
        let glyphOffset = charCode * fontHeight * bytesPerRow

        guard glyphOffset + fontHeight * bytesPerRow <= fontBitmap.count else { return nil }

        let fgColor = getColorForIndex(fgIndex)
        let bgColor = getColorForIndex(bgIndex)
        let fgPixel: UInt32 = 0xFF000000 | (fgColor & 0xFFFFFF)
        let bgPixel: UInt32 = 0xFF000000 | (bgColor & 0xFFFFFF)

        let pixelCount = targetWidth * targetHeight
        var pixels = [UInt32](repeating: bgPixel, count: pixelCount)

        fontBitmap.withUnsafeBytes { (fontPtr: UnsafeRawBufferPointer) in
            guard let fontBase = fontPtr.baseAddress else { return }

            for destY in 0..<targetHeight {
                // Center-sampling with clamp
                let srcY = min(fontHeight - 1, ((2 * destY + 1) * fontHeight) / (2 * targetHeight))
                let rowOffset = glyphOffset + srcY * bytesPerRow
                let rowByte0 = fontBase.load(fromByteOffset: rowOffset, as: UInt8.self)
                let rowByte1: UInt8 = (bytesPerRow > 1 && rowOffset + 1 < fontBitmap.count) ?
                    fontBase.load(fromByteOffset: rowOffset + 1, as: UInt8.self) : 0

                for destX in 0..<targetWidth {
                    let srcX = min(fontWidth - 1, ((2 * destX + 1) * fontWidth) / (2 * targetWidth))

                    let isSet: Bool
                    if srcX < 8 {
                        isSet = ((Int(rowByte0) >> (7 - srcX)) & 1) == 1
                    } else {
                        isSet = ((Int(rowByte1) >> (15 - srcX)) & 1) == 1
                    }

                    pixels[destY * targetWidth + destX] = isSet ? fgPixel : bgPixel
                }
            }
        }

        // Create CGImage from pixel data at target size
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)

        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }

        return CGImage(
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: targetWidth * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Get RGB color value for a palette index.
    private func getColorForIndex(_ index: Int) -> UInt32 {
        // Default CGA/VGA 16-color palette
        let defaultPalette: [UInt32] = [
            0x000000, // 0: Black
            0x0000AA, // 1: Blue
            0x00AA00, // 2: Green
            0x00AAAA, // 3: Cyan
            0xAA0000, // 4: Red
            0xAA00AA, // 5: Magenta
            0xAA5500, // 6: Brown
            0xAAAAAA, // 7: Light Gray
            0x555555, // 8: Dark Gray
            0x5555FF, // 9: Light Blue
            0x55FF55, // 10: Light Green
            0x55FFFF, // 11: Light Cyan
            0xFF5555, // 12: Light Red
            0xFF55FF, // 13: Light Magenta
            0xFFFF55, // 14: Yellow
            0xFFFFFF  // 15: White
        ]

        // Use custom palette if available
        if index >= 0 && index < palette.count && !palette.isEmpty {
            return UInt32(bitPattern: palette[index])
        }

        // Fall back to default palette
        if index >= 0 && index < defaultPalette.count {
            return defaultPalette[index]
        }

        return 0xFFFFFF // Default to white
    }
}
