import Foundation
import AVFoundation
import os.log

private let logger = Logger(subsystem: "com.jsonbourne.TERMinator", category: "Soundtrack")

/// Manages BBS soundtrack playback via OSC 800 / TAP+ protocol.
///
/// TAP+ extensions:
///   - 4 audio channels (0-3) for simultaneous playback
///   - Seek to absolute position in current track
///   - Channel 0 supports all formats (tracker + streaming)
///   - Channels 1-3 support streaming formats only (MP3/WAV/OGG)
///   - Video/image file caching for TAP+ multimedia commands
///
/// Commands not handled here (visualizer, images, video) return false
/// so TerminalViewModel can route them to handleTapPlusCommand().
class SoundtrackManager: ObservableObject {

    static let shared = SoundtrackManager()

    // MARK: - Constants

    private static let cacheDirName = "soundtracks"
    private static let maxURLLength = 2048
    private static let maxFilenameLength = 128
    private static let maxFileSize: Int64 = 50 * 1024 * 1024  // 50MB per file (video support)
    private static let defaultCacheLimitMB = 100
    private static let downloadTimeoutSeconds: TimeInterval = 15
    private static let masterGain: Float = 0.85
    private static let numChannels = 4

    private static let videoExtensions: Set<String> = ["mp4", "m4v", "webm"]
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp"]
    private static let allowedExtensions: Set<String> = [
        "mp3", "wav", "ogg", "mod", "s3m", "xm", "it",
        "mp4", "m4v", "webm",
        "jpg", "jpeg", "png", "gif", "webp"
    ]
    private static let trackerExtensions: Set<String> = ["mod", "s3m", "xm", "it"]
    private static let filenamePattern = try! NSRegularExpression(pattern: "^[a-zA-Z0-9._ -]+$")

    // Settings keys
    static let keySoundtrackEnabled = "soundtrack_enabled"
    static let keySoundtrackVolume = "soundtrack_volume"
    static let keySoundtrackCacheLimit = "soundtrack_cache_limit"

    // MARK: - Published State

    @Published var cacheSize: Int64 = 0

    // MARK: - Audio Analyzer

    let audioAnalyzer = AudioAnalyzer()

    // MARK: - Per-Channel State

    private struct QueuedTrack {
        let filename: String
        let delaySec: Int
    }

    private class AudioChannel {
        let index: Int
        // Engine-based streaming playback (with PCM tap for visualizer)
        var audioEngine: AVAudioEngine?
        var playerNode: AVAudioPlayerNode?
        var audioFile: AVAudioFile?
        var looping: Bool = false
        // Tracker playback
        var modPlayer: ModPlayer?
        var volume: Float = 1.0
        var fadeTimer: Timer?
        var playing = false
        var currentFilename: String?

        // Queue for auto-advance playback
        var queue: [QueuedTrack] = []
        var queueIndex: Int = 0
        var queueTimer: DispatchWorkItem?

        init(index: Int) {
            self.index = index
        }

        func stopInternal() {
            playerNode?.stop()
            if let engine = audioEngine {
                engine.mainMixerNode.removeTap(onBus: 0)
                engine.stop()
                if let node = playerNode {
                    engine.detach(node)
                }
            }
            audioEngine = nil
            playerNode = nil
            audioFile = nil
            looping = false

            modPlayer?.stop()
            modPlayer = nil

            playing = false
            currentFilename = nil
        }
    }

    // MARK: - Private State

    private let cacheDir: URL
    private var channels: [AudioChannel] = []
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

        for i in 0..<SoundtrackManager.numChannels {
            channels.append(AudioChannel(index: i))
        }

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
    /// Returns true if the command was handled, false if it should be
    /// routed elsewhere (e.g. visualizer, image commands).
    @discardableResult
    func handleCommand(_ cmd: String) -> Bool {
        guard isEnabled() else { return true }

        let parts = cmd.components(separatedBy: ";")
        guard !parts.isEmpty else { return true }

        switch parts[0].lowercased() {
        case "cache":
            if parts.count >= 3 {
                cacheFile(url: parts[1], displayName: parts[2])
            }
        case "play":
            if parts.count >= 2 {
                let loop = parts.count >= 3 && parts[2] == "1"
                let channel = parts.count >= 4 ? (Int(parts[3]) ?? 0) : 0
                // Explicit play clears any existing queue
                if let ch = getChannel(channel) {
                    ch.queue.removeAll()
                    ch.queueIndex = 0
                    ch.queueTimer?.cancel()
                    ch.queueTimer = nil
                }
                play(filename: parts[1], loop: loop, channelIdx: channel)
            }
        case "queue":
            // queue;filename;channel;delay_seconds
            if parts.count >= 4 {
                let channel = Int(parts[2]) ?? 0
                let delay = max(0, Int(parts[3]) ?? 3)
                if let ch = getChannel(channel) {
                    ch.queue.append(QueuedTrack(filename: parts[1], delaySec: delay))
                    logger.info("Queued '\(parts[1])' on ch\(channel) (delay=\(delay)s, queue=\(ch.queue.count))")
                }
            }
        case "stop":
            let channel = parts.count >= 2 ? Int(parts[1]) : nil
            if let channel = channel {
                stopChannel(channel)
            } else {
                stopAll()
            }
        case "pause":
            let channel = parts.count >= 2 ? Int(parts[1]) : nil
            if let channel = channel {
                pauseChannel(channel)
            } else {
                for ch in channels { pauseChannel(ch.index) }
            }
        case "resume":
            let channel = parts.count >= 2 ? Int(parts[1]) : nil
            if let channel = channel {
                resumeChannel(channel)
            } else {
                for ch in channels { resumeChannel(ch.index) }
            }
        case "volume":
            if parts.count >= 2, let vol = Int(parts[1]) {
                let channel = parts.count >= 3 ? Int(parts[2]) : nil
                if let channel = channel {
                    setVolume(vol, channelIdx: channel)
                } else {
                    for ch in channels { setVolume(vol, channelIdx: ch.index) }
                }
            }
        case "fade":
            if parts.count >= 3, let targetVol = Int(parts[1]), let durationMs = Int(parts[2]) {
                let channel = parts.count >= 4 ? Int(parts[3]) : nil
                if let channel = channel {
                    fade(targetVolPercent: targetVol, durationMs: durationMs, channelIdx: channel)
                } else {
                    for ch in channels { fade(targetVolPercent: targetVol, durationMs: durationMs, channelIdx: ch.index) }
                }
            }
        case "seek":
            if parts.count >= 2, let posMs = Int(parts[1]) {
                let channel = parts.count >= 3 ? (Int(parts[2]) ?? 0) : 0
                seek(positionMs: posMs, channelIdx: channel)
            }
        default:
            return false  // Not an audio command — route to TAP+ handler
        }
        return true
    }

    // MARK: - Download & Cache

    private func cacheFile(url urlString: String, displayName: String) {
        guard isValidUrl(urlString) else {
            logger.warning("Invalid URL rejected: \(urlString)")
            return
        }

        guard let url = URL(string: urlString) else { return }
        let realFilename = url.lastPathComponent

        guard let safeFilename = sanitizeFilename(realFilename) else {
            logger.warning("Invalid filename from URL rejected: \(realFilename)")
            return
        }

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

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                logger.warning("Download failed: HTTP \(httpResponse.statusCode)")
                return
            }

            if let attrs = try? FileManager.default.attributesOfItem(atPath: tempURL.path),
               let fileSize = attrs[.size] as? Int64,
               fileSize > SoundtrackManager.maxFileSize {
                logger.warning("File too large: \(fileSize) bytes")
                return
            }

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

    private func play(filename: String, loop: Bool, channelIdx: Int) {
        guard let ch = getChannel(channelIdx) else { return }

        let resolved = displayNameMap[filename]
        if let resolved = resolved {
            logger.info("Resolved display name '\(filename)' -> '\(resolved)'")
        }

        var safeFilename = sanitizeFilename(resolved ?? filename)
        if safeFilename == nil {
            safeFilename = findCachedFile(baseName: filename)
            if safeFilename == nil {
                logger.warning("No cached file found for: \(filename)")
                return
            }
        }

        let file = cacheDir.appendingPathComponent(safeFilename!)

        if !FileManager.default.fileExists(atPath: file.path) {
            logger.info("File not cached yet, waiting: \(safeFilename!)")
            let waitFilename = safeFilename!
            let waitChannel = channelIdx
            DispatchQueue.global().async { [weak self] in
                for i in 0..<40 {
                    Thread.sleep(forTimeInterval: 0.25)
                    guard let self = self else { return }
                    let waitFile = self.cacheDir.appendingPathComponent(waitFilename)
                    if FileManager.default.fileExists(atPath: waitFile.path) {
                        logger.info("File ready after \((i + 1) * 250)ms: \(waitFilename)")
                        DispatchQueue.main.async {
                            self.playInternal(file: waitFile, safeFilename: waitFilename, loop: loop, channelIdx: waitChannel)
                        }
                        return
                    }
                }
                logger.warning("Timed out waiting for file: \(waitFilename)")
            }
            return
        }

        playInternal(file: file, safeFilename: safeFilename!, loop: loop, channelIdx: channelIdx)
    }

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

    private func playInternal(file: URL, safeFilename: String, loop: Bool, channelIdx: Int) {
        guard let ch = getChannel(channelIdx) else { return }

        ch.fadeTimer?.invalidate()
        ch.fadeTimer = nil
        ch.stopInternal()

        let ext = (safeFilename as NSString).pathExtension.lowercased()
        if SoundtrackManager.trackerExtensions.contains(ext) {
            if channelIdx != 0 {
                logger.warning("Tracker formats only supported on channel 0, redirecting")
                playInternal(file: file, safeFilename: safeFilename, loop: loop, channelIdx: 0)
                return
            }
            playTracker(ch: ch, file: file, loop: loop)
        } else {
            playAudioPlayer(ch: ch, file: file, loop: loop)
        }

        ch.currentFilename = safeFilename
        ch.playing = true
    }

    private func playAudioPlayer(ch: AudioChannel, file: URL, loop: Bool) {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: .mixWithOthers)
            try AVAudioSession.sharedInstance().setActive(true)

            let audioFile = try AVAudioFile(forReading: file)
            let engine = AVAudioEngine()
            let playerNode = AVAudioPlayerNode()

            engine.attach(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: audioFile.processingFormat)

            // Install PCM tap for visualizer (any channel feeds the analyzer)
            let tapFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)
            engine.mainMixerNode.installTap(onBus: 0, bufferSize: 2048, format: tapFormat) { [weak self] buffer, _ in
                guard let self = self else { return }
                let frameCount = Int(buffer.frameLength)
                guard let channelData = buffer.floatChannelData, buffer.format.channelCount >= 1 else { return }

                var pcmBuffer = [Int16](repeating: 0, count: frameCount * 2)
                let ch0 = channelData[0]
                let ch1 = buffer.format.channelCount >= 2 ? channelData[1] : channelData[0]
                for i in 0..<frameCount {
                    pcmBuffer[i * 2] = Int16(max(-1, min(1, ch0[i])) * 32767)
                    pcmBuffer[i * 2 + 1] = Int16(max(-1, min(1, ch1[i])) * 32767)
                }
                self.audioAnalyzer.feedPcm(buffer: pcmBuffer, frames: frameCount)
            }

            try engine.start()

            ch.audioEngine = engine
            ch.playerNode = playerNode
            ch.audioFile = audioFile
            ch.looping = loop

            scheduleStreamingFile(ch: ch)
            playerNode.play()
            playerNode.volume = toPerceptualVolume(ch.volume)

            logger.info("Ch\(ch.index) playing (engine): \(file.lastPathComponent) (loop=\(loop))")
        } catch {
            logger.error("Ch\(ch.index) engine play error: \(error.localizedDescription)")
        }
    }

    private func scheduleStreamingFile(ch: AudioChannel) {
        guard let playerNode = ch.playerNode, let audioFile = ch.audioFile else { return }
        playerNode.scheduleFile(audioFile, at: nil) { [weak self] in
            guard let self = self else { return }
            if ch.looping && ch.playing {
                audioFile.framePosition = 0
                self.scheduleStreamingFile(ch: ch)
            } else if ch.playing {
                // Playback ended naturally — auto-advance from queue
                DispatchQueue.main.async {
                    ch.playing = false
                    ch.currentFilename = nil
                    self.playNextFromQueue(ch.index)
                }
            }
        }
    }

    private func playTracker(ch: AudioChannel, file: URL, loop: Bool) {
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
        player.setVolume(toPerceptualVolume(ch.volume))
        player.setLooping(loop)

        // Feed PCM to the audio analyzer for visualizer
        player.pcmListener = { [weak self] buffer, frames in
            self?.audioAnalyzer.feedPcm(buffer: buffer, frames: frames)
        }

        player.onCompletion = { [weak self] in
            guard let self = self else { return }
            ch.modPlayer = nil
            ch.playing = false
            ch.currentFilename = nil
            self.playNextFromQueue(ch.index)
        }

        player.start()
        ch.modPlayer = player
        logger.info("Ch\(ch.index) playing tracker: \(file.lastPathComponent) (loop=\(loop))")
    }

    /// Auto-advance to the next track in the channel's queue.
    private func playNextFromQueue(_ channelIdx: Int) {
        guard let ch = getChannel(channelIdx), !ch.queue.isEmpty else { return }

        let track = ch.queue[ch.queueIndex]
        ch.queueIndex = (ch.queueIndex + 1) % ch.queue.count

        logger.info("Auto-advance ch\(channelIdx) -> '\(track.filename)' in \(track.delaySec)s")

        ch.queueTimer?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.play(filename: track.filename, loop: false, channelIdx: channelIdx)
        }
        ch.queueTimer = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .seconds(track.delaySec),
            execute: workItem
        )
    }

    // MARK: - Stop / Pause / Resume

    func stopAll() {
        for ch in channels {
            ch.fadeTimer?.invalidate()
            ch.fadeTimer = nil
            ch.queue.removeAll()
            ch.queueIndex = 0
            ch.queueTimer?.cancel()
            ch.queueTimer = nil
            ch.stopInternal()
        }
        audioAnalyzer.reset()
    }

    private func stopChannel(_ channelIdx: Int) {
        guard let ch = getChannel(channelIdx) else { return }
        ch.fadeTimer?.invalidate()
        ch.fadeTimer = nil
        ch.queue.removeAll()
        ch.queueIndex = 0
        ch.queueTimer?.cancel()
        ch.queueTimer = nil
        ch.stopInternal()
        audioAnalyzer.reset()
    }

    func stop() { stopAll() }

    private func pauseChannel(_ channelIdx: Int) {
        guard let ch = getChannel(channelIdx) else { return }
        ch.playerNode?.pause()
        ch.audioEngine?.pause()
        ch.modPlayer?.pause()
    }

    private func resumeChannel(_ channelIdx: Int) {
        guard let ch = getChannel(channelIdx) else { return }
        try? ch.audioEngine?.start()
        ch.playerNode?.play()
        ch.modPlayer?.resume()
    }

    // MARK: - Volume / Fade

    private func setVolume(_ volumePercent: Int, channelIdx: Int) {
        guard let ch = getChannel(channelIdx) else { return }
        let clamped = max(0, min(100, volumePercent))
        applyVolume(ch: ch, vol: Float(clamped) / 100.0)
    }

    private func toPerceptualVolume(_ linear: Float) -> Float {
        guard linear > 0 else { return 0 }
        return min(linear * SoundtrackManager.masterGain, 1)
    }

    private func applyVolume(ch: AudioChannel, vol: Float) {
        ch.volume = max(0, min(1, vol))
        let amplitude = toPerceptualVolume(ch.volume)
        ch.playerNode?.volume = amplitude
        ch.modPlayer?.setVolume(amplitude)
    }

    private func fade(targetVolPercent: Int, durationMs: Int, channelIdx: Int) {
        guard let ch = getChannel(channelIdx) else { return }

        guard durationMs > 0 else {
            setVolume(targetVolPercent, channelIdx: channelIdx)
            return
        }

        ch.fadeTimer?.invalidate()

        let targetVol = Float(max(0, min(100, targetVolPercent))) / 100.0
        let startVol = ch.volume
        let steps = max(1, min(200, durationMs / 50))
        let stepDelay = TimeInterval(durationMs) / TimeInterval(steps) / 1000.0
        let volStep = (targetVol - startVol) / Float(steps)
        var currentStep = 0

        ch.fadeTimer = Timer.scheduledTimer(withTimeInterval: stepDelay, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            currentStep += 1
            if currentStep >= steps {
                timer.invalidate()
                ch.fadeTimer = nil
                self.applyVolume(ch: ch, vol: targetVol)
                if targetVol <= 0 {
                    self.stopChannel(channelIdx)
                }
            } else {
                self.applyVolume(ch: ch, vol: startVol + volStep * Float(currentStep))
            }
        }
    }

    // MARK: - Seek

    private func seek(positionMs: Int, channelIdx: Int) {
        guard let ch = getChannel(channelIdx), ch.playing else { return }

        // Engine-based streaming seek
        if let playerNode = ch.playerNode, let audioFile = ch.audioFile {
            let sampleRate = audioFile.processingFormat.sampleRate
            let targetFrame = AVAudioFramePosition(Double(positionMs) / 1000.0 * sampleRate)
            let clampedFrame = max(0, min(targetFrame, audioFile.length))
            let remainingFrames = AVAudioFrameCount(audioFile.length - clampedFrame)
            guard remainingFrames > 0 else { return }

            playerNode.stop()
            audioFile.framePosition = clampedFrame
            playerNode.scheduleSegment(audioFile, startingFrame: clampedFrame, frameCount: remainingFrames, at: nil) { [weak self] in
                guard let self = self, ch.looping, ch.playing else { return }
                audioFile.framePosition = 0
                self.scheduleStreamingFile(ch: ch)
            }
            playerNode.play()
        }

        if ch.modPlayer != nil {
            NativeBridge.shared.modSeek(positionMs)
        }
        logger.info("Ch\(channelIdx) seek to \(positionMs)ms")
    }

    // MARK: - Helpers

    private func getChannel(_ index: Int) -> AudioChannel? {
        guard index >= 0 && index < SoundtrackManager.numChannels else {
            logger.warning("Invalid channel: \(index)")
            return nil
        }
        return channels[index]
    }

    // MARK: - Public API

    /// Resolve a TAP display name to a cached file URL, or nil if not found.
    func resolveFile(displayName: String) -> URL? {
        let resolved = displayNameMap[displayName]
        let safeFilename: String?
        if let resolved = resolved {
            safeFilename = sanitizeFilename(resolved)
        } else {
            safeFilename = sanitizeFilename(displayName) ?? findCachedFile(baseName: displayName)
        }
        guard let safeFilename = safeFilename else { return nil }
        let file = cacheDir.appendingPathComponent(safeFilename)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
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
        let volume = Float(max(0, min(10, vol))) / 10.0
        for ch in channels {
            applyVolume(ch: ch, vol: volume)
        }
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

        let playingFiles = Set(channels.compactMap { $0.currentFilename })

        let sorted = validFiles.sorted {
            let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return d1 < d2
        }

        for file in sorted {
            guard totalSize > limit else { break }
            if playingFiles.contains(file.lastPathComponent) { continue }
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
