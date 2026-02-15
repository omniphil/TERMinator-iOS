import Foundation
import Combine

/// Transfer state enumeration.
enum TransferState: Equatable {
    case idle
    case receiving
    case sending
    case complete
    case error(String)
    case cancelled
}

/// Transfer direction.
enum TransferDirection {
    case none
    case send
    case receive
}

/// Transfer progress information.
struct TransferInfo {
    var state: TransferState = .idle
    var direction: TransferDirection = .none
    var fileName: String?
    var bytesTransferred: Int64 = 0
    var totalBytes: Int64 = 0
    var bytesPerSecond: Int64 = 0

    var progressPercent: Int {
        guard totalBytes > 0 else { return 0 }
        return Int((bytesTransferred * 100) / totalBytes).clamped(to: 0...100)
    }

    var formattedProgress: String {
        "\(formatBytes(bytesTransferred)) / \(formatBytes(totalBytes))"
    }

    var formattedSpeed: String {
        "\(formatBytes(bytesPerSecond))/s"
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
        } else if bytes >= 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        } else {
            return "\(bytes) B"
        }
    }
}

/// Transfer result.
enum TransferResult {
    case success(fileName: String, bytesTransferred: Int64)
    case error(String)
    case cancelled
}

/// Manages ZMODEM file transfers.
/// Provides progress updates and handles transfer lifecycle.
class TransferManager: ObservableObject {

    static let shared = TransferManager()

    @Published private(set) var transferInfo = TransferInfo()
    @Published private(set) var isTransferring = false

    private var initialized = false
    private let initLock = NSLock()
    private var transferQueue = DispatchQueue(label: "com.terminator.transfer", qos: .userInitiated)
    private var progressTimer: Timer?
    private var _transferStartTime: Date?
    private var _isCancelled = false
    private let stateLock = NSLock()  // Protects mutable state accessed from multiple threads

    /// Thread-safe access to transferStartTime
    private var transferStartTime: Date? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _transferStartTime
        }
        set {
            stateLock.lock()
            defer { stateLock.unlock() }
            _transferStartTime = newValue
        }
    }

    /// Thread-safe access to isCancelled flag
    private var isCancelled: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _isCancelled
        }
        set {
            stateLock.lock()
            defer { stateLock.unlock() }
            _isCancelled = newValue
        }
    }

    private init() {}

    // MARK: - Initialization

    /// Initialize the transfer subsystem.
    func initialize() -> Bool {
        initLock.lock()
        defer { initLock.unlock() }

        if initialized { return true }

        let success = NativeBridge.shared.transferInit()
        if success {
            // Set download directory to Documents (with fallback to temp directory)
            let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let downloadDir = documentsDir.appendingPathComponent("Downloads")

            // Create directory if needed
            try? FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)

            NativeBridge.shared.setDownloadDir(downloadDir.path)
            initialized = true
        }
        return success
    }

    // MARK: - Receive

    /// Start a ZMODEM receive operation.
    /// - Parameter completion: Completion handler called on main thread
    func startReceive(completion: @escaping (TransferResult) -> Void) {
        guard !isTransferring else {
            completion(.error("Transfer already in progress"))
            return
        }

        guard initialize() else {
            completion(.error("Failed to initialize transfer subsystem"))
            return
        }

        NativeBridge.shared.transferReset()
        isCancelled = false

        DispatchQueue.main.async {
            self.isTransferring = true
            self.transferInfo = TransferInfo(state: .receiving, direction: .receive)
        }

        // Push buffered ZMODEM data back into connection
        let _ = NativeBridge.shared.pushZmodemBuffer()

        transferStartTime = nil
        startProgressMonitor()

        transferQueue.async { [weak self] in
            guard let self = self else { return }

            let result = NativeBridge.shared.zmodemReceive()

            self.stopProgressMonitor()

            // result > 0 means success (count of files)
            let transferResult: TransferResult
            if result > 0 {
                let fileName = NativeBridge.shared.getTransferFileName() ?? "unknown"
                let progress = NativeBridge.shared.getTransferProgress()
                let bytesTransferred = progress?.bytesTransferred ?? 0

                DispatchQueue.main.async {
                    self.transferInfo = TransferInfo(
                        state: .complete,
                        direction: .receive,
                        fileName: fileName,
                        bytesTransferred: bytesTransferred,
                        totalBytes: bytesTransferred
                    )
                }
                transferResult = .success(fileName: fileName, bytesTransferred: bytesTransferred)
            } else if self.isCancelled {
                DispatchQueue.main.async {
                    self.transferInfo = TransferInfo(state: .cancelled, direction: .receive)
                }
                transferResult = .cancelled
            } else {
                let error = NativeBridge.shared.getTransferError() ?? "Transfer failed (code: \(result))"
                DispatchQueue.main.async {
                    self.transferInfo = TransferInfo(state: .error(error), direction: .receive)
                }
                transferResult = .error(error)
            }

            DispatchQueue.main.async {
                self.isTransferring = false
                completion(transferResult)
            }
        }
    }

    // MARK: - Send

    /// Start a ZMODEM send operation.
    /// - Parameters:
    ///   - fileURL: URL of the file to send
    ///   - completion: Completion handler called on main thread
    func startSend(fileURL: URL, completion: @escaping (TransferResult) -> Void) {
        guard !isTransferring else {
            completion(.error("Transfer already in progress"))
            return
        }

        guard initialize() else {
            completion(.error("Failed to initialize transfer subsystem"))
            return
        }

        // Verify file exists and get info
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            completion(.error("File not found"))
            return
        }

        let fileName = fileURL.lastPathComponent
        let fileSize: Int64
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            fileSize = (attributes[.size] as? Int64) ?? 0
        } catch {
            completion(.error("Failed to get file size"))
            return
        }

        NativeBridge.shared.transferReset()
        isCancelled = false

        DispatchQueue.main.async {
            self.isTransferring = true
            self.transferInfo = TransferInfo(
                state: .sending,
                direction: .send,
                fileName: fileName,
                totalBytes: fileSize
            )
        }

        transferStartTime = nil
        startProgressMonitor()

        transferQueue.async { [weak self] in
            guard let self = self else { return }

            let result = NativeBridge.shared.zmodemSend(filePath: fileURL.path)

            self.stopProgressMonitor()

            let transferResult: TransferResult
            if result == 0 {
                let progress = NativeBridge.shared.getTransferProgress()
                let bytesTransferred = progress?.bytesTransferred ?? fileSize

                DispatchQueue.main.async {
                    self.transferInfo = TransferInfo(
                        state: .complete,
                        direction: .send,
                        fileName: fileName,
                        bytesTransferred: bytesTransferred,
                        totalBytes: fileSize
                    )
                }
                transferResult = .success(fileName: fileName, bytesTransferred: bytesTransferred)
            } else if self.isCancelled {
                DispatchQueue.main.async {
                    self.transferInfo = TransferInfo(state: .cancelled, direction: .send, fileName: fileName)
                }
                transferResult = .cancelled
            } else {
                let error = NativeBridge.shared.getTransferError() ?? "Transfer failed (code: \(result))"
                DispatchQueue.main.async {
                    self.transferInfo = TransferInfo(state: .error(error), direction: .send, fileName: fileName)
                }
                transferResult = .error(error)
            }

            DispatchQueue.main.async {
                self.isTransferring = false
                completion(transferResult)
            }
        }
    }

    // MARK: - Cancel

    /// Cancel the current transfer.
    func cancelTransfer() {
        isCancelled = true
        NativeBridge.shared.transferCancel()
    }

    // MARK: - Progress Monitoring

    private func startProgressMonitor() {
        DispatchQueue.main.async { [weak self] in
            self?.progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.updateProgress()
            }
        }
    }

    private func stopProgressMonitor() {
        DispatchQueue.main.async { [weak self] in
            self?.progressTimer?.invalidate()
            self?.progressTimer = nil
        }
    }

    private func updateProgress() {
        // Check native state - this allows UI to update even if the native call
        // is blocked (e.g., in zmodem_send_zfin waiting for BBS acknowledgment)
        let nativeState = NativeBridge.shared.getTransferState()
        let currentState = transferInfo.state

        // If native reports completion/error/cancel but Swift still shows in-progress,
        // update Swift state immediately so the dialog shows correct buttons
        if case .sending = currentState {
            checkAndUpdateFromNativeState(nativeState)
        } else if case .receiving = currentState {
            checkAndUpdateFromNativeState(nativeState)
        }

        // Skip progress updates if we're already in a terminal state
        switch transferInfo.state {
        case .complete, .error, .cancelled:
            return
        default:
            break
        }

        guard let progress = NativeBridge.shared.getTransferProgress() else { return }

        let fileName = NativeBridge.shared.getTransferFileName()
        let bytesTransferred = progress.bytesTransferred
        let totalBytes = progress.totalBytes

        // Track start time for speed calculation
        if transferStartTime == nil && bytesTransferred > 0 {
            transferStartTime = Date()
        }

        var bytesPerSec: Int64 = 0
        if let startTime = transferStartTime {
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed > 0 {
                bytesPerSec = Int64(Double(bytesTransferred) / elapsed)
            }
        }

        transferInfo = TransferInfo(
            state: transferInfo.state,
            direction: transferInfo.direction,
            fileName: fileName ?? transferInfo.fileName,
            bytesTransferred: bytesTransferred,
            totalBytes: totalBytes,
            bytesPerSecond: bytesPerSec
        )
    }

    /// Check native state and update Swift state if native has completed/errored/cancelled.
    private func checkAndUpdateFromNativeState(_ nativeState: NativeBridge.TransferState) {
        switch nativeState {
        case .complete:
            transferInfo = TransferInfo(
                state: .complete,
                direction: transferInfo.direction,
                fileName: transferInfo.fileName,
                bytesTransferred: transferInfo.bytesTransferred,
                totalBytes: transferInfo.totalBytes,
                bytesPerSecond: transferInfo.bytesPerSecond
            )
        case .error:
            let error = NativeBridge.shared.getTransferError() ?? "Transfer failed"
            transferInfo = TransferInfo(
                state: .error(error),
                direction: transferInfo.direction,
                fileName: transferInfo.fileName
            )
        case .cancelled:
            transferInfo = TransferInfo(
                state: .cancelled,
                direction: transferInfo.direction,
                fileName: transferInfo.fileName
            )
        default:
            break
        }
    }

    // MARK: - Reset & Cleanup

    /// Reset state after transfer completion.
    func reset() {
        NativeBridge.shared.transferReset()
        transferInfo = TransferInfo()
        isTransferring = false
        transferStartTime = nil
        isCancelled = false
    }

    /// Clean up resources.
    func cleanup() {
        cancelTransfer()
        stopProgressMonitor()

        if initialized {
            NativeBridge.shared.transferCleanup()
            initialized = false
        }
    }

    // MARK: - Upload Queue

    /// Queue a file for upload.
    func queueUpload(fileURL: URL) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        NativeBridge.shared.queueUpload(filePath: fileURL.path)
    }

    /// Check if a file is queued for upload.
    var isUploadQueued: Bool {
        NativeBridge.shared.isUploadQueued()
    }

    /// Check if the BBS is ready for upload.
    var isUploadReady: Bool {
        NativeBridge.shared.isUploadReady()
    }

    /// Get the queued upload file path.
    var queuedUploadPath: String? {
        NativeBridge.shared.getQueuedUpload()
    }

    /// Clear the upload queue.
    func clearUploadQueue() {
        NativeBridge.shared.clearUploadQueue()
    }

    // MARK: - File Helpers

    /// Get the downloads directory URL.
    var downloadsDirectory: URL {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return documentsDir.appendingPathComponent("Downloads")
    }

    /// Get list of downloaded files.
    func getDownloadedFiles() -> [URL] {
        guard FileManager.default.fileExists(atPath: downloadsDirectory.path) else {
            return []
        }

        do {
            return try FileManager.default.contentsOfDirectory(at: downloadsDirectory,
                                                                includingPropertiesForKeys: [.contentModificationDateKey],
                                                                options: .skipsHiddenFiles)
                .sorted { url1, url2 in
                    let date1 = (try? url1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
                    let date2 = (try? url2.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
                    return date1 > date2
                }
        } catch {
            return []
        }
    }
}
