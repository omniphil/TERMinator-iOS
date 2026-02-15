import Foundation

/// Manages session logging for terminal sessions.
/// Captures terminal output and saves to a text file with ANSI code stripping.
class SessionLogger {

    static let shared = SessionLogger()

    private let logDirectory = "session_logs"
    private let flushIntervalBytes: Int = 4096

    private var fileHandle: FileHandle?
    private var logFileURL: URL?
    private var isLoggingActive = false
    private var sessionName = ""
    private var startTime: Date?
    private var bytesLogged: Int64 = 0
    private var lastFlushBytes: Int64 = 0

    private let queue = DispatchQueue(label: "com.terminator.sessionlogger", qos: .utility)

    private init() {}

    // MARK: - Public Interface

    /// Check if logging is currently active.
    var isLogging: Bool {
        return isLoggingActive
    }

    /// Get the current log file name.
    var logFileName: String? {
        return logFileURL?.lastPathComponent
    }

    /// Get bytes logged in current session.
    var totalBytesLogged: Int64 {
        return bytesLogged
    }

    /// Start logging a session.
    /// - Parameter bbsName: Name of the BBS for the log filename
    /// - Returns: True if logging started successfully
    func startLogging(bbsName: String) -> Bool {
        guard !isLoggingActive else {
            print("SessionLogger: Already logging")
            return false
        }

        // Sanitize the BBS name for filename
        sessionName = bbsName.replacingOccurrences(of: "[^a-zA-Z0-9._-]",
                                                    with: "_",
                                                    options: .regularExpression)
        startTime = Date()
        bytesLogged = 0
        lastFlushBytes = 0

        do {
            // Create log directory if needed
            let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let logDir = documentsDir.appendingPathComponent(logDirectory)

            if !FileManager.default.fileExists(atPath: logDir.path) {
                try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
            }

            // Create log file with timestamp
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            let timestamp = formatter.string(from: Date())
            let fileName = "\(sessionName)_\(timestamp).log"
            logFileURL = logDir.appendingPathComponent(fileName)

            // Create the file
            guard let url = logFileURL else { return false }
            FileManager.default.createFile(atPath: url.path, contents: nil)
            fileHandle = try FileHandle(forWritingTo: url)

            // Write session header
            let header = createSessionHeader(bbsName: bbsName)
            if let headerData = header.data(using: .utf8) {
                fileHandle?.write(headerData)
                try fileHandle?.synchronize()
            }

            isLoggingActive = true
            print("SessionLogger: Started logging to \(logFileURL?.path ?? "unknown")")
            return true

        } catch {
            print("SessionLogger: Failed to start logging - \(error)")
            cleanup()
            return false
        }
    }

    /// Log raw data received from the terminal.
    /// Strips ANSI escape sequences for cleaner logs.
    /// - Parameter data: Raw bytes from terminal
    func logData(_ data: Data) {
        guard isLoggingActive else { return }

        queue.async { [weak self] in
            guard let self = self, let handle = self.fileHandle else { return }

            // Convert to string and strip ANSI codes
            let text = String(data: data, encoding: .isoLatin1) ?? ""
            let cleanText = self.stripAnsiCodes(text)

            guard !cleanText.isEmpty, let cleanData = cleanText.data(using: .utf8) else { return }

            do {
                handle.write(cleanData)
                self.bytesLogged += Int64(cleanData.count)

                // Flush periodically
                if self.bytesLogged - self.lastFlushBytes >= Int64(self.flushIntervalBytes) {
                    try handle.synchronize()
                    self.lastFlushBytes = self.bytesLogged
                }
            } catch {
                print("SessionLogger: Error writing - \(error)")
            }
        }
    }

    /// Log a string directly (for sent data or markers).
    func logString(_ text: String) {
        guard isLoggingActive else { return }

        queue.async { [weak self] in
            guard let self = self,
                  let handle = self.fileHandle,
                  let data = text.data(using: .utf8) else { return }

            handle.write(data)
            self.bytesLogged += Int64(data.count)
        }
    }

    /// Add a timestamp marker to the log.
    func addTimestamp() {
        guard isLoggingActive else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        logString("\n--- [\(timestamp)] ---\n")
    }

    /// Stop logging and close the file.
    /// - Returns: The path of the saved log file, or nil if not logging
    func stopLogging() -> String? {
        guard isLoggingActive else { return nil }

        var result: String?

        queue.sync { [weak self] in
            guard let self = self, let handle = self.fileHandle else { return }

            // Write session footer
            let footer = self.createSessionFooter()
            if let footerData = footer.data(using: .utf8) {
                handle.write(footerData)
            }

            do {
                try handle.synchronize()
                try handle.close()
            } catch {
                print("SessionLogger: Error closing file - \(error)")
            }

            result = self.logFileURL?.path
            print("SessionLogger: Stopped logging. File: \(result ?? "unknown")")
        }

        cleanup()
        return result
    }

    // MARK: - Log File Management

    /// Get list of saved log files.
    func getLogFiles() -> [URL] {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logDir = documentsDir.appendingPathComponent(logDirectory)

        guard FileManager.default.fileExists(atPath: logDir.path) else {
            return []
        }

        do {
            let files = try FileManager.default.contentsOfDirectory(at: logDir,
                                                                     includingPropertiesForKeys: [.contentModificationDateKey],
                                                                     options: .skipsHiddenFiles)
            return files
                .filter { $0.pathExtension == "log" }
                .sorted { url1, url2 in
                    let date1 = (try? url1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
                    let date2 = (try? url2.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
                    return date1 > date2
                }
        } catch {
            print("SessionLogger: Error listing log files - \(error)")
            return []
        }
    }

    /// Delete a log file.
    func deleteLogFile(_ url: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            print("SessionLogger: Error deleting log file - \(error)")
            return false
        }
    }

    /// Get the contents of a log file.
    func readLogFile(_ url: URL) -> String? {
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Private Methods

    private func cleanup() {
        fileHandle = nil
        logFileURL = nil
        isLoggingActive = false
        sessionName = ""
        startTime = nil
        lastFlushBytes = 0
    }

    private func createSessionHeader(bbsName: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let dateStr = formatter.string(from: Date())

        return """
        ============================================================
        TERMinator Session Log
        BBS: \(bbsName)
        Started: \(dateStr)
        ============================================================

        """
    }

    private func createSessionFooter() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let dateStr = formatter.string(from: Date())

        var durationStr = "00:00:00"
        if let start = startTime {
            let duration = Int(Date().timeIntervalSince(start))
            let hours = duration / 3600
            let minutes = (duration % 3600) / 60
            let seconds = duration % 60
            durationStr = String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }

        return """


        ============================================================
        Session ended: \(dateStr)
        Duration: \(durationStr)
        Bytes logged: \(formatBytes(bytesLogged))
        ============================================================

        """
    }

    /// Strip ANSI escape sequences from text.
    private func stripAnsiCodes(_ text: String) -> String {
        var result = text

        // CSI sequences: ESC [ ... letter
        result = result.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]",
                                              with: "",
                                              options: .regularExpression)

        // OSC sequences ending with BEL
        result = result.replacingOccurrences(of: "\u{1B}\\][^\u{07}\u{1B}]*\u{07}",
                                              with: "",
                                              options: .regularExpression)

        // OSC sequences ending with ST (ESC \)
        result = result.replacingOccurrences(of: "\u{1B}\\][^\u{07}\u{1B}]*\u{1B}\\\\",
                                              with: "",
                                              options: .regularExpression)

        // Other escape sequences
        result = result.replacingOccurrences(of: "\u{1B}[^\\[\\]][A-Za-z]",
                                              with: "",
                                              options: .regularExpression)

        // BEL character
        result = result.replacingOccurrences(of: "\u{07}", with: "")

        return result
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
        } else if bytes >= 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        } else {
            return "\(bytes) bytes"
        }
    }
}
