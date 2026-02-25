import Foundation
import AVFoundation
import os.log

private let logger = Logger(subsystem: "com.jsonbourne.TERMinator", category: "Soundtrack")

/// Manages BBS soundtrack playback via OSC 800 (TAP) protocol.
///
/// Handles downloading, caching, and playing audio files (MP3/WAV/OGG)
/// triggered by escape sequences from the BBS. MOD/S3M/XM/IT tracker
/// formats are delegated to ModPlayer.
class SoundtrackManager: ObservableObject {

    static let shared = SoundtrackManager()

    // MARK: - Constants

    private static let cacheDirName = "soundtracks"
    private static let maxURLLength = 2048
    private static let maxFilenameLength = 128
    private static let maxFileSize: Int64 = 10 * 1024 * 1024  // 10MB per file
    private static let defaultCacheLimitMB = 50
    private static let downloadTimeoutSeconds: TimeInterval = 15

    private static let allowedExtensions: Set<String> = ["mp3", "wav", "ogg", "mod", "s3m", "xm", "it"]
    private static let trackerExtensions: Set<String> = ["mod", "s3m", "xm", "it"]
    private static let filenamePattern = try! NSRegularExpression(pattern: "^[a-zA-Z0-9._-]+$")

    // Settings keys
    static let keySoundtrackEnabled = "soundtrack_enabled"
    static let keySoundtrackVolume = "soundtrack_volume"
    static let keySoundtrackCacheLimit = "soundtrack_cache_limit"

    // MARK: - Published State

    @Published var cacheSize: Int64 = 0

    // MARK: - Private State

    private let cacheDir: URL
    private var audioPlayer: AVAudioPlayer?
    private var modPlayer: ModPlayer?
    private var currentVolume: Float = 0.7
    private var fadeTimer: Timer?
    private var playing = false
    private var currentFilename: String?
    private let downloadSession: URLSession

    // Maps TAP display names to actual cached filenames (e.g. "Axel F" -> "AxelF.mod")
    private var displayNameMap: [String: String] = [:]

    // MARK: - Init

    private init() {
        let cacheBase = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDir = cacheBase.appendingPathComponent(SoundtrackManager.cacheDirName)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = SoundtrackManager.downloadTimeoutSeconds
        config.timeoutIntervalForResource = SoundtrackManager.downloadTimeoutSeconds * 2
        downloadSession = URLSession(configuration: config)

        // Register defaults so values are correct before user visits Settings
        UserDefaults.standard.register(defaults: [
            SoundtrackManager.keySoundtrackEnabled: true,
            SoundtrackManager.keySoundtrackVolume: 10,
            SoundtrackManager.keySoundtrackCacheLimit: SoundtrackManager.defaultCacheLimitMB
        ])

        applySettingsVolume()
        updateCacheSize()
    }

    // MARK: - Command Handling

    /// Parse and execute an OSC 800 command string.
    /// Format: "command;param1;param2;..."
    func handleCommand(_ cmd: String) {
        guard isEnabled() else { return }

        let parts = cmd.components(separatedBy: ";")
        guard !parts.isEmpty else { return }

        switch parts[0].lowercased() {
        case "cache":
            if parts.count >= 3 {
                cacheFile(url: parts[1], displayName: parts[2])
            }
        case "play":
            if parts.count >= 2 {
                let loop = parts.count >= 3 && parts[2] == "1"
                play(filename: parts[1], loop: loop)
            }
        case "stop":
            stop()
        case "pause":
            pause()
        case "resume":
            resume()
        case "volume":
            if parts.count >= 2, let vol = Int(parts[1]) {
                setVolume(vol)
            }
        case "fade":
            if parts.count >= 3, let targetVol = Int(parts[1]), let durationMs = Int(parts[2]) {
                fade(targetVolPercent: targetVol, durationMs: durationMs)
            }
        default:
            logger.warning("Unknown audio command: \(parts[0])")
        }
    }

    // MARK: - Download & Cache

    private func cacheFile(url urlString: String, displayName: String) {
        guard isValidUrl(urlString) else {
            logger.warning("Invalid URL rejected: \(urlString)")
            return
        }

        // Extract the real filename from the URL (e.g. "AxelF.mod" from ".../AxelF.mod")
        guard let url = URL(string: urlString) else { return }
        let realFilename = url.lastPathComponent

        guard let safeFilename = sanitizeFilename(realFilename) else {
            logger.warning("Invalid filename from URL rejected: \(realFilename)")
            return
        }

        // Map the display name to the real cached filename
        if !displayName.isEmpty {
            displayNameMap[displayName] = safeFilename
        }

        let targetFile = cacheDir.appendingPathComponent(safeFilename)
        if FileManager.default.fileExists(atPath: targetFile.path) {
            return
        }

        let task = downloadSession.downloadTask(with: url) { [weak self] tempURL, response, error in
            guard let self = self, let tempURL = tempURL, error == nil else {
                if let error = error {
                    logger.error("Download error: \(error.localizedDescription)")
                }
                return
            }

            // Check response
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                logger.warning("Download failed: HTTP \(httpResponse.statusCode)")
                return
            }

            // Check file size
            if let attrs = try? FileManager.default.attributesOfItem(atPath: tempURL.path),
               let fileSize = attrs[.size] as? Int64,
               fileSize > SoundtrackManager.maxFileSize {
                logger.warning("File too large: \(fileSize) bytes")
                return
            }

            // Move to cache
            do {
                try FileManager.default.moveItem(at: tempURL, to: targetFile)
                logger.info("Cached: \(safeFilename)")
                self.pruneCache()
                DispatchQueue.main.async {
                    self.updateCacheSize()
                }
            } catch {
                logger.error("Cache move error: \(error.localizedDescription)")
            }
        }
        task.resume()
    }

    // MARK: - Playback

    private func play(filename: String, loop: Bool) {
        // First try the display name map (TAP sends display names like "Axel F")
        let resolved = displayNameMap[filename]
        if let resolved = resolved {
            logger.info("Resolved display name '\(filename)' -> '\(resolved)'")
        }

        var safeFilename = sanitizeFilename(resolved ?? filename)
        if safeFilename == nil {
            // Last resort — search cache for a matching file by base name
            safeFilename = findCachedFile(baseName: filename)
            if safeFilename == nil {
                logger.warning("No cached file found for: \(filename)")
                return
            }
        }

        let file = cacheDir.appendingPathComponent(safeFilename!)

        // If file doesn't exist yet, it may still be downloading - wait briefly
        if !FileManager.default.fileExists(atPath: file.path) {
            logger.info("File not cached yet, waiting: \(safeFilename!)")
            let waitFilename = safeFilename!
            DispatchQueue.global().async { [weak self] in
                for i in 0..<40 { // Up to 10 seconds (40 * 250ms)
                    Thread.sleep(forTimeInterval: 0.25)
                    guard let self = self else { return }
                    let waitFile = self.cacheDir.appendingPathComponent(waitFilename)
                    if FileManager.default.fileExists(atPath: waitFile.path) {
                        logger.info("File ready after \((i + 1) * 250)ms: \(waitFilename)")
                        DispatchQueue.main.async {
                            self.playInternal(file: waitFile, safeFilename: waitFilename, loop: loop)
                        }
                        return
                    }
                }
                logger.warning("Timed out waiting for file: \(waitFilename)")
            }
            return
        }

        playInternal(file: file, safeFilename: safeFilename!, loop: loop)
    }

    /// Search the cache for a file matching the base name with any allowed extension.
    private func findCachedFile(baseName: String) -> String? {
        guard !baseName.isEmpty, baseName.count <= SoundtrackManager.maxFilenameLength else { return nil }
        for ext in SoundtrackManager.allowedExtensions {
            let candidate = "\(baseName).\(ext)"
            if sanitizeFilename(candidate) != nil {
                let file = cacheDir.appendingPathComponent(candidate)
                if FileManager.default.fileExists(atPath: file.path) {
                    return candidate
                }
            }
        }
        return nil
    }

    private func playInternal(file: URL, safeFilename: String, loop: Bool) {
        // Stop any current playback
        stopInternal()

        let ext = (safeFilename as NSString).pathExtension.lowercased()
        if SoundtrackManager.trackerExtensions.contains(ext) {
            playTracker(file: file, loop: loop)
        } else {
            playAudioPlayer(file: file, loop: loop)
        }

        currentFilename = safeFilename
        playing = true
    }

    private func playAudioPlayer(file: URL, loop: Bool) {
        do {
            // Configure audio session for playback
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: .mixWithOthers)
            try AVAudioSession.sharedInstance().setActive(true)

            let player = try AVAudioPlayer(contentsOf: file)
            player.numberOfLoops = loop ? -1 : 0
            player.volume = currentVolume
            player.prepareToPlay()
            player.play()
            audioPlayer = player
            logger.info("Playing: \(file.lastPathComponent) (loop=\(loop))")
        } catch {
            logger.error("AVAudioPlayer play error: \(error.localizedDescription)")
            audioPlayer = nil
        }
    }

    private func playTracker(file: URL, loop: Bool) {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: .mixWithOthers)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            logger.error("Audio session error: \(error.localizedDescription)")
        }

        let player = ModPlayer()
        guard player.load(file.path) else {
            logger.error("ModPlayer load failed: \(file.lastPathComponent)")
            return
        }
        player.setVolume(currentVolume)
        player.setLooping(loop)
        player.start()
        modPlayer = player
        logger.info("Playing tracker: \(file.lastPathComponent) (loop=\(loop))")
    }

    // MARK: - Controls

    /// Stop all playback.
    func stop() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        stopInternal()
    }

    private func stopInternal() {
        audioPlayer?.stop()
        audioPlayer = nil

        modPlayer?.stop()
        modPlayer = nil

        playing = false
        currentFilename = nil
    }

    private func pause() {
        audioPlayer?.pause()
        modPlayer?.pause()
    }

    private func resume() {
        audioPlayer?.play()
        modPlayer?.resume()
    }

    private func setVolume(_ volumePercent: Int) {
        let vol = Float(max(0, min(100, volumePercent))) / 100.0
        applyVolume(vol)
    }

    private func applyVolume(_ vol: Float) {
        currentVolume = max(0, min(1, vol))
        audioPlayer?.volume = currentVolume
        modPlayer?.setVolume(currentVolume)
    }

    private func fade(targetVolPercent: Int, durationMs: Int) {
        guard durationMs > 0 else {
            setVolume(targetVolPercent)
            return
        }

        fadeTimer?.invalidate()

        let targetVol = Float(max(0, min(100, targetVolPercent))) / 100.0
        let startVol = currentVolume
        let steps = max(1, min(200, durationMs / 50))
        let stepDelay = TimeInterval(durationMs) / TimeInterval(steps) / 1000.0
        let volStep = (targetVol - startVol) / Float(steps)
        var currentStep = 0

        fadeTimer = Timer.scheduledTimer(withTimeInterval: stepDelay, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            currentStep += 1
            if currentStep >= steps {
                timer.invalidate()
                self.fadeTimer = nil
                self.applyVolume(targetVol)
                if targetVol <= 0 {
                    self.stop()
                }
            } else {
                self.applyVolume(startVol + volStep * Float(currentStep))
            }
        }
    }

    // MARK: - Validation

    private func sanitizeFilename(_ filename: String) -> String? {
        guard filename.count <= SoundtrackManager.maxFilenameLength else { return nil }
        let range = NSRange(filename.startIndex..., in: filename)
        guard SoundtrackManager.filenamePattern.firstMatch(in: filename, range: range) != nil else { return nil }
        guard !filename.contains("..") else { return nil }
        let ext = (filename as NSString).pathExtension.lowercased()
        guard SoundtrackManager.allowedExtensions.contains(ext) else { return nil }
        return filename
    }

    private func isValidUrl(_ urlString: String) -> Bool {
        guard urlString.count <= SoundtrackManager.maxURLLength else { return false }
        guard let url = URL(string: urlString) else { return false }
        return url.scheme == "http" || url.scheme == "https"
    }

    // MARK: - Settings

    private func isEnabled() -> Bool {
        return UserDefaults.standard.bool(forKey: SoundtrackManager.keySoundtrackEnabled)
    }

    private func getCacheLimitBytes() -> Int64 {
        let limitMB = UserDefaults.standard.integer(forKey: SoundtrackManager.keySoundtrackCacheLimit)
        return Int64(limitMB > 0 ? limitMB : SoundtrackManager.defaultCacheLimitMB) * 1024 * 1024
    }

    func applySettingsVolume() {
        let vol = UserDefaults.standard.integer(forKey: SoundtrackManager.keySoundtrackVolume)
        // Volume stored as 0-10 (slider steps), convert to 0.0-1.0
        currentVolume = Float(max(0, min(10, vol))) / 10.0
    }

    // MARK: - Cache Management

    private func pruneCache() {
        let limit = getCacheLimitBytes()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return }

        let validFiles = files.filter { !$0.lastPathComponent.hasSuffix(".tmp") }
        var totalSize: Int64 = validFiles.compactMap {
            (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
        }.reduce(0, +)

        guard totalSize > limit else { return }

        // Sort by modification date (oldest first)
        let sorted = validFiles.sorted {
            let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return d1 < d2
        }

        for file in sorted {
            guard totalSize > limit else { break }
            if file.lastPathComponent == currentFilename { continue }
            if let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                try? FileManager.default.removeItem(at: file)
                totalSize -= Int64(size)
                logger.info("Pruned: \(file.lastPathComponent)")
            }
        }
    }

    func updateCacheSize() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: [.fileSizeKey]
        ) else {
            cacheSize = 0
            return
        }
        cacheSize = files.filter { !$0.lastPathComponent.hasSuffix(".tmp") }.compactMap {
            (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
        }.reduce(0, +)
    }

    /// Delete all cached audio files.
    func clearCache() {
        stop()
        if let files = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) {
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }
        updateCacheSize()
        logger.info("Cache cleared")
    }
}
