import Foundation

/// JNI-style bridge to native SyncTERM terminal emulator code.
/// This interfaces with C code compiled for iOS.
final class NativeBridge {

    static let shared = NativeBridge()

    private var isLibraryLoaded = false

    // Connection type constants
    static let CONN_TYPE_TELNET = 3
    static let CONN_TYPE_SSH = 5

    // Transfer state constants
    enum TransferState: Int {
        case idle = 0
        case receiving = 1
        case sending = 2
        case complete = 3
        case error = 4
        case cancelled = 5
    }

    private init() {
        // Native library is linked at compile time for iOS
        isLibraryLoaded = true
    }

    /// Check if the native library is available.
    func isNativeLibraryLoaded() -> Bool {
        return isLibraryLoaded
    }

    // MARK: - Initialization

    /// Set the files directory for SSH keys and other data.
    func setFilesDir(_ path: String) {
        native_set_files_dir(path)
    }

    /// Initialize the native terminal system.
    func initialize() -> Bool {
        return native_init()
    }

    /// Clean up native resources.
    func destroy() {
        native_destroy()
    }

    // MARK: - Connection Management

    /// Connect to a server (synchronous - use connectAsync for non-blocking).
    /// - Parameters:
    ///   - host: Hostname or IP address
    ///   - port: Port number
    ///   - protocol: CONN_TYPE_TELNET (3) or CONN_TYPE_SSH (5)
    ///   - username: Username for SSH (nil for Telnet)
    ///   - password: Password for SSH (nil for Telnet)
    func connect(host: String, port: Int, protocol connProtocol: Int = CONN_TYPE_TELNET,
                 username: String? = nil, password: String? = nil) -> Bool {
        return native_connect(host, Int32(port), Int32(connProtocol), username, password)
    }

    /// Connect to a server asynchronously (non-blocking).
    func connectAsync(host: String, port: Int, protocol connProtocol: Int = CONN_TYPE_TELNET,
                      username: String? = nil, password: String? = nil) async -> Bool {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInteractive).async {
                let result = native_connect(host, Int32(port), Int32(connProtocol), username, password)
                continuation.resume(returning: result)
            }
        }
    }

    /// Disconnect from the server.
    func disconnect() {
        native_disconnect()
    }

    /// Check if connected.
    func isConnected() -> Bool {
        return native_is_connected()
    }

    // MARK: - Data Transfer

    /// Send raw data to the server.
    func sendData(_ data: Data) -> Int {
        return data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return -1
            }
            return Int(native_send_data(ptr, Int32(data.count)))
        }
    }

    /// Send a key code to the server.
    func sendKey(_ keyCode: Int) -> Int {
        return Int(native_send_key(Int32(keyCode)))
    }

    /// Send a string to the server.
    func sendString(_ str: String) -> Int {
        return Int(native_send_string(str))
    }

    /// Process incoming data.
    /// Returns bytes processed, or -100 for ZMODEM download detected, -101 for upload ready.
    func processData() -> Int {
        return Int(native_process_data())
    }

    /// Check if data is waiting.
    func dataWaiting() -> Int {
        return Int(native_data_waiting())
    }

    // MARK: - Screen State

    /// Get the screen buffer as packed integers.
    /// Each int: character | (attr << 8) | (fg << 16) | (bg << 24)
    /// Maximum screen buffer size: 132 cols * 50 rows = 6600 cells
    private static let maxScreenBufferCount: Int32 = 132 * 50

    func getScreenBuffer() -> [Int32]? {
        var count: Int32 = 0
        guard let ptr = native_get_screen_buffer(&count),
              count > 0, count <= NativeBridge.maxScreenBufferCount else {
            return nil
        }
        let buffer = Array(UnsafeBufferPointer(start: ptr, count: Int(count)))
        // Note: Caller should not free ptr as it points to internal buffer
        return buffer
    }

    /// Get the color palette.
    func getPalette() -> [Int32]? {
        var count: Int32 = 0
        guard let ptr = native_get_palette(&count), count > 0, count <= 256 else {
            return nil
        }
        return Array(UnsafeBufferPointer(start: ptr, count: Int(count)))
    }

    /// Get the screen size as [columns, rows].
    func getScreenSize() -> (columns: Int, rows: Int) {
        var columns: Int32 = 0
        var rows: Int32 = 0
        native_get_screen_size(&columns, &rows)
        return (Int(columns), Int(rows))
    }

    /// Get cursor position as [x, y].
    func getCursorPos() -> (x: Int, y: Int) {
        var x: Int32 = 0
        var y: Int32 = 0
        native_get_cursor_pos(&x, &y)
        return (Int(x), Int(y))
    }

    /// Check if cursor is visible.
    func isCursorVisible() -> Bool {
        return native_is_cursor_visible()
    }

    /// Check if the screen has changed since last render.
    func isScreenDirty() -> Bool {
        return native_is_screen_dirty()
    }

    /// Get dirty region bounds for partial redraw optimization.
    func getDirtyRegion() -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        var minX: Int32 = 0, minY: Int32 = 0, maxX: Int32 = 0, maxY: Int32 = 0
        if native_get_dirty_region(&minX, &minY, &maxX, &maxY) {
            return (Int(minX), Int(minY), Int(maxX), Int(maxY))
        }
        return nil
    }

    // MARK: - Terminal Control

    /// Set terminal size.
    func setTerminalSize(width: Int, height: Int) {
        native_set_terminal_size(Int32(width), Int32(height))
    }

    /// Set font by name.
    func setFont(_ fontName: String) -> Bool {
        return native_set_font(fontName)
    }

    /// Set font by ID.
    func setFontById(_ fontId: Int) -> Bool {
        return native_set_font_by_id(Int32(fontId))
    }

    /// Clear the screen.
    func clearScreen() {
        native_clear_screen()
    }

    /// Reset terminal state completely (screen + scrollback).
    /// Call this when connecting to a new BBS.
    func resetTerminal() {
        native_reset_terminal()
    }

    /// Push input data to the terminal.
    func pushInput(_ data: Data) {
        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            native_push_input(ptr, Int32(data.count))
        }
    }

    /// Hide or show the status line.
    func setHideStatusLine(_ hide: Bool) {
        native_set_hide_status_line(hide)
    }

    /// Set screen mode (0=80x25, 1=80x30, 2=80x50, 3=132x25, 4=132x50, 5=80x40).
    func setScreenMode(_ mode: Int) {
        native_set_screen_mode(Int32(mode))
    }

    // MARK: - Status

    /// Get status information string.
    func getStatusInfo() -> String {
        guard let cStr = native_get_status_info() else {
            return ""
        }
        return String(cString: cStr)
    }

    /// Get connection statistics: [bytesSent, bytesReceived, connectTimeMs, currentTimeMs].
    func getConnectionStats() -> (bytesSent: Int64, bytesReceived: Int64, connectTimeMs: Int64, currentTimeMs: Int64)? {
        var sent: Int64 = 0, received: Int64 = 0, connectTime: Int64 = 0, currentTime: Int64 = 0
        if native_get_connection_stats(&sent, &received, &connectTime, &currentTime) {
            return (sent, received, connectTime, currentTime)
        }
        return nil
    }

    // MARK: - Font Bitmap

    /// Get font dimensions only (width and height).
    func getFontDimensions() -> (width: Int, height: Int) {
        var width: Int32 = 0
        var height: Int32 = 0
        var count: Int32 = 0
        _ = native_get_font_bitmap(&width, &height, &count)
        return (Int(width), Int(height))
    }

    /// Get font bitmap data.
    /// Returns (width, height, bitmapData).
    /// Maximum font bitmap size: 256 chars * 32 height * 2 bytes/row = 16384
    private static let maxFontBitmapSize: Int32 = 256 * 32 * 2

    func getFontBitmap() -> (width: Int, height: Int, data: Data)? {
        var width: Int32 = 0
        var height: Int32 = 0
        var count: Int32 = 0
        guard let ptr = native_get_font_bitmap(&width, &height, &count),
              count > 0, count <= NativeBridge.maxFontBitmapSize else {
            return nil
        }
        let data = Data(bytes: ptr, count: Int(count))
        return (Int(width), Int(height), data)
    }

    // MARK: - File Transfer (ZMODEM)

    /// Initialize the file transfer subsystem.
    func transferInit() -> Bool {
        return native_transfer_init()
    }

    /// Set the download directory.
    func setDownloadDir(_ dir: String) {
        native_set_download_dir(dir)
    }

    /// Start a ZMODEM receive operation (blocks until complete).
    func zmodemReceive() -> Int {
        return Int(native_zmodem_receive())
    }

    /// Start a ZMODEM send operation (blocks until complete).
    func zmodemSend(filePath: String) -> Int {
        return Int(native_zmodem_send(filePath))
    }

    /// Cancel the current transfer.
    func transferCancel() {
        native_transfer_cancel()
    }

    /// Get the current transfer state.
    func getTransferState() -> TransferState {
        let state = Int(native_get_transfer_state())
        return TransferState(rawValue: state) ?? .idle
    }

    /// Get transfer progress: [bytesTransferred, totalBytes].
    func getTransferProgress() -> (bytesTransferred: Int64, totalBytes: Int64)? {
        var transferred: Int64 = 0
        var total: Int64 = 0
        if native_get_transfer_progress(&transferred, &total) {
            return (transferred, total)
        }
        return nil
    }

    /// Get the name of the file being transferred.
    func getTransferFileName() -> String? {
        guard let cStr = native_get_transfer_file_name() else {
            return nil
        }
        return String(cString: cStr)
    }

    /// Get the error message from the last failed transfer.
    func getTransferError() -> String? {
        guard let cStr = native_get_transfer_error() else {
            return nil
        }
        return String(cString: cStr)
    }

    /// Reset transfer state after completion or error.
    func transferReset() {
        native_transfer_reset()
    }

    /// Cleanup file transfer resources.
    func transferCleanup() {
        native_transfer_cleanup()
    }

    // MARK: - ZMODEM Auto-Detection

    /// Check if ZMODEM was auto-detected.
    func isZmodemDetected() -> Bool {
        return native_is_zmodem_detected()
    }

    /// Get buffered ZMODEM data from detection.
    func getZmodemBuffer() -> Data? {
        var count: Int32 = 0
        guard let ptr = native_get_zmodem_buffer(&count), count > 0 else {
            return nil
        }
        return Data(bytes: ptr, count: Int(count))
    }

    /// Clear ZMODEM detection state.
    func clearZmodemDetected() {
        native_clear_zmodem_detected()
    }

    /// Push buffered ZMODEM data back into connection buffer.
    func pushZmodemBuffer() -> Int {
        return Int(native_push_zmodem_buffer())
    }

    // MARK: - Upload Queue

    /// Queue a file for upload.
    func queueUpload(filePath: String) {
        native_queue_upload(filePath)
    }

    /// Check if a file is queued for upload.
    func isUploadQueued() -> Bool {
        return native_is_upload_queued()
    }

    /// Check if the BBS is ready for upload (ZRINIT received).
    func isUploadReady() -> Bool {
        return native_is_upload_ready()
    }

    /// Get the path of the queued upload file.
    func getQueuedUpload() -> String? {
        guard let cStr = native_get_queued_upload() else {
            return nil
        }
        return String(cString: cStr)
    }

    /// Clear the upload queue.
    func clearUploadQueue() {
        native_clear_upload_queue()
    }

    // MARK: - Scrollback Buffer

    /// Get scrollback buffer info: [filledLines, totalCapacity, columns].
    func getScrollbackInfo() -> (filledLines: Int, totalCapacity: Int, columns: Int)? {
        var filled: Int32 = 0, capacity: Int32 = 0, columns: Int32 = 0
        if native_get_scrollback_info(&filled, &capacity, &columns) {
            return (Int(filled), Int(capacity), Int(columns))
        }
        return nil
    }

    /// Get scrollback buffer content.
    /// Maximum scrollback result: 132 cols * 100 rows = 13200 cells
    private static let maxScrollbackCount: Int32 = 132 * 100

    func getScrollbackBuffer(offset: Int, count: Int) -> [Int32]? {
        var resultCount: Int32 = 0
        guard let ptr = native_get_scrollback_buffer(Int32(clamping: offset), Int32(clamping: count), &resultCount),
              resultCount > 0, resultCount <= NativeBridge.maxScrollbackCount else {
            return nil
        }
        return Array(UnsafeBufferPointer(start: ptr, count: Int(resultCount)))
    }

    // MARK: - Bell Detection

    /// Check if a bell (BEL character) was received and clear the flag.
    func checkBell() -> Bool {
        return native_check_bell()
    }

    // MARK: - Session Logging

    /// Enable or disable session logging.
    func setLoggingEnabled(_ enabled: Bool) {
        native_set_logging_enabled(enabled)
    }

    /// Get and clear logged data from the buffer.
    func getLoggedData() -> Data? {
        var count: Int32 = 0
        guard let ptr = native_get_logged_data(&count), count > 0 else {
            return nil
        }
        return Data(bytes: ptr, count: Int(count))
    }

    // MARK: - Helper Functions

    /// Unpack character from packed cell value.
    static func unpackChar(_ cell: Int32) -> Character {
        return Character(UnicodeScalar(Int(cell & 0xFF)) ?? UnicodeScalar(32))
    }

    /// Unpack legacy attribute from packed cell value.
    static func unpackAttr(_ cell: Int32) -> Int {
        return Int((cell >> 8) & 0xFF)
    }

    /// Get foreground color from attribute byte.
    static func attrToFg(_ attr: Int) -> Int {
        return attr & 0x0F
    }

    /// Get background color from attribute byte (4 bits for iCE bright backgrounds).
    static func attrToBg(_ attr: Int) -> Int {
        return (attr >> 4) & 0x0F
    }
}

// MARK: - C Function Declarations

// These are the C functions that need to be implemented in the native library.
// For now they are declared as stubs that will link to the actual implementation.

@_silgen_name("native_set_files_dir")
private func native_set_files_dir(_ path: UnsafePointer<CChar>)

@_silgen_name("native_init")
private func native_init() -> Bool

@_silgen_name("native_destroy")
private func native_destroy()

@_silgen_name("native_connect")
private func native_connect(_ host: UnsafePointer<CChar>, _ port: Int32, _ protocol: Int32,
                            _ username: UnsafePointer<CChar>?, _ password: UnsafePointer<CChar>?) -> Bool

@_silgen_name("native_disconnect")
private func native_disconnect()

@_silgen_name("native_is_connected")
private func native_is_connected() -> Bool

@_silgen_name("native_send_data")
private func native_send_data(_ data: UnsafePointer<UInt8>, _ count: Int32) -> Int32

@_silgen_name("native_send_key")
private func native_send_key(_ keyCode: Int32) -> Int32

@_silgen_name("native_send_string")
private func native_send_string(_ str: UnsafePointer<CChar>) -> Int32

@_silgen_name("native_process_data")
private func native_process_data() -> Int32

@_silgen_name("native_data_waiting")
private func native_data_waiting() -> Int32

@_silgen_name("native_get_screen_buffer")
private func native_get_screen_buffer(_ count: UnsafeMutablePointer<Int32>) -> UnsafePointer<Int32>?

@_silgen_name("native_get_palette")
private func native_get_palette(_ count: UnsafeMutablePointer<Int32>) -> UnsafePointer<Int32>?

@_silgen_name("native_get_screen_size")
private func native_get_screen_size(_ columns: UnsafeMutablePointer<Int32>, _ rows: UnsafeMutablePointer<Int32>)

@_silgen_name("native_get_cursor_pos")
private func native_get_cursor_pos(_ x: UnsafeMutablePointer<Int32>, _ y: UnsafeMutablePointer<Int32>)

@_silgen_name("native_is_cursor_visible")
private func native_is_cursor_visible() -> Bool

@_silgen_name("native_is_screen_dirty")
private func native_is_screen_dirty() -> Bool

@_silgen_name("native_get_dirty_region")
private func native_get_dirty_region(_ minX: UnsafeMutablePointer<Int32>, _ minY: UnsafeMutablePointer<Int32>,
                                     _ maxX: UnsafeMutablePointer<Int32>, _ maxY: UnsafeMutablePointer<Int32>) -> Bool

@_silgen_name("native_set_terminal_size")
private func native_set_terminal_size(_ width: Int32, _ height: Int32)

@_silgen_name("native_set_font")
private func native_set_font(_ fontName: UnsafePointer<CChar>) -> Bool

@_silgen_name("native_set_font_by_id")
private func native_set_font_by_id(_ fontId: Int32) -> Bool

@_silgen_name("native_clear_screen")
private func native_clear_screen()

@_silgen_name("native_reset_terminal")
private func native_reset_terminal()

@_silgen_name("native_push_input")
private func native_push_input(_ data: UnsafePointer<UInt8>, _ count: Int32)

@_silgen_name("native_set_hide_status_line")
private func native_set_hide_status_line(_ hide: Bool)

@_silgen_name("native_set_screen_mode")
private func native_set_screen_mode(_ mode: Int32)

@_silgen_name("native_get_status_info")
private func native_get_status_info() -> UnsafePointer<CChar>?

@_silgen_name("native_get_connection_stats")
private func native_get_connection_stats(_ sent: UnsafeMutablePointer<Int64>, _ received: UnsafeMutablePointer<Int64>,
                                         _ connectTime: UnsafeMutablePointer<Int64>, _ currentTime: UnsafeMutablePointer<Int64>) -> Bool

@_silgen_name("native_get_font_bitmap")
private func native_get_font_bitmap(_ width: UnsafeMutablePointer<Int32>, _ height: UnsafeMutablePointer<Int32>,
                                    _ count: UnsafeMutablePointer<Int32>) -> UnsafePointer<UInt8>?

@_silgen_name("native_transfer_init")
private func native_transfer_init() -> Bool

@_silgen_name("native_set_download_dir")
private func native_set_download_dir(_ dir: UnsafePointer<CChar>)

@_silgen_name("native_zmodem_receive")
private func native_zmodem_receive() -> Int32

@_silgen_name("native_zmodem_send")
private func native_zmodem_send(_ filePath: UnsafePointer<CChar>) -> Int32

@_silgen_name("native_transfer_cancel")
private func native_transfer_cancel()

@_silgen_name("native_get_transfer_state")
private func native_get_transfer_state() -> Int32

@_silgen_name("native_get_transfer_progress")
private func native_get_transfer_progress(_ transferred: UnsafeMutablePointer<Int64>, _ total: UnsafeMutablePointer<Int64>) -> Bool

@_silgen_name("native_get_transfer_file_name")
private func native_get_transfer_file_name() -> UnsafePointer<CChar>?

@_silgen_name("native_get_transfer_error")
private func native_get_transfer_error() -> UnsafePointer<CChar>?

@_silgen_name("native_transfer_reset")
private func native_transfer_reset()

@_silgen_name("native_transfer_cleanup")
private func native_transfer_cleanup()

@_silgen_name("native_is_zmodem_detected")
private func native_is_zmodem_detected() -> Bool

@_silgen_name("native_get_zmodem_buffer")
private func native_get_zmodem_buffer(_ count: UnsafeMutablePointer<Int32>) -> UnsafePointer<UInt8>?

@_silgen_name("native_clear_zmodem_detected")
private func native_clear_zmodem_detected()

@_silgen_name("native_push_zmodem_buffer")
private func native_push_zmodem_buffer() -> Int32

@_silgen_name("native_queue_upload")
private func native_queue_upload(_ filePath: UnsafePointer<CChar>)

@_silgen_name("native_is_upload_queued")
private func native_is_upload_queued() -> Bool

@_silgen_name("native_is_upload_ready")
private func native_is_upload_ready() -> Bool

@_silgen_name("native_get_queued_upload")
private func native_get_queued_upload() -> UnsafePointer<CChar>?

@_silgen_name("native_clear_upload_queue")
private func native_clear_upload_queue()

@_silgen_name("native_get_scrollback_info")
private func native_get_scrollback_info(_ filled: UnsafeMutablePointer<Int32>, _ capacity: UnsafeMutablePointer<Int32>,
                                        _ columns: UnsafeMutablePointer<Int32>) -> Bool

@_silgen_name("native_get_scrollback_buffer")
private func native_get_scrollback_buffer(_ offset: Int32, _ count: Int32,
                                          _ resultCount: UnsafeMutablePointer<Int32>) -> UnsafePointer<Int32>?

@_silgen_name("native_check_bell")
private func native_check_bell() -> Bool

@_silgen_name("native_set_logging_enabled")
private func native_set_logging_enabled(_ enabled: Bool)

@_silgen_name("native_get_logged_data")
private func native_get_logged_data(_ count: UnsafeMutablePointer<Int32>) -> UnsafePointer<UInt8>?
