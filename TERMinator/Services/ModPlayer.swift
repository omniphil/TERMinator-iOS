import Foundation
import AVFoundation
import os.log

private let logger = Logger(subsystem: "com.jsonbourne.TERMinator", category: "ModPlayer")

/// Plays MOD/S3M/XM/IT tracker files using libxmp via AVAudioEngine.
/// Uses AVAudioSourceNode (pull-based) to render PCM from libxmp on the audio thread.
class ModPlayer {

    private static let sampleRate: Double = 44100
    private static let framesPerBuffer: Int = 2048

    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var playing = false
    private var paused = false
    private var looping = false
    private var volume: Float = 1.0

    /// PCM listener callback — called from the audio thread with stereo Int16 PCM data.
    var pcmListener: (([Int16], Int) -> Void)?

    /// Called on main queue when non-looping playback finishes naturally.
    var onCompletion: (() -> Void)?

    /// Load a tracker module file.
    func load(_ filePath: String) -> Bool {
        let success = NativeBridge.shared.modLoad(filePath)
        if !success {
            logger.error("Failed to load module: \(filePath)")
        }
        return success
    }

    /// Set looping mode.
    func setLooping(_ loop: Bool) {
        looping = loop
    }

    /// Set playback volume (0.0 - 1.0).
    func setVolume(_ vol: Float) {
        volume = max(0, min(1, vol))
        NativeBridge.shared.modSetVolume(volume)
        sourceNode?.volume = volume
    }

    /// Start playback via AVAudioEngine.
    func start() {
        guard !playing else { return }

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: ModPlayer.sampleRate,
            channels: 2,
            interleaved: false
        )!

        let loopingCapture = looping

        // Create a source node that pulls PCM from libxmp
        let node = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self, self.playing else {
                // Fill silence
                let bufferList = UnsafeMutableAudioBufferListPointer(audioBufferList)
                for buffer in bufferList {
                    memset(buffer.mData, 0, Int(buffer.mDataByteSize))
                }
                return noErr
            }

            if self.paused {
                let bufferList = UnsafeMutableAudioBufferListPointer(audioBufferList)
                for buffer in bufferList {
                    memset(buffer.mData, 0, Int(buffer.mDataByteSize))
                }
                return noErr
            }

            let frames = Int(frameCount)
            // Render 16-bit stereo interleaved from libxmp
            var pcmBuffer = [Int16](repeating: 0, count: frames * 2)
            let rendered = NativeBridge.shared.modGetPcm(&pcmBuffer, frames: frames)

            // Feed PCM data to listener (audio analyzer) before checking for end
            if rendered > 0 {
                self.pcmListener?(pcmBuffer, rendered)
            }

            if rendered <= 0 {
                if loopingCapture {
                    // Fill silence this round; looping handled by libxmp loop param
                    let bufferList = UnsafeMutableAudioBufferListPointer(audioBufferList)
                    for buffer in bufferList {
                        memset(buffer.mData, 0, Int(buffer.mDataByteSize))
                    }
                    return noErr
                }
                // Module ended
                let bufferList = UnsafeMutableAudioBufferListPointer(audioBufferList)
                for buffer in bufferList {
                    memset(buffer.mData, 0, Int(buffer.mDataByteSize))
                }
                DispatchQueue.main.async {
                    self.playing = false
                    self.onCompletion?()
                }
                return noErr
            }

            // Convert interleaved Int16 to non-interleaved Float32
            let bufferList = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let scale: Float = 1.0 / 32768.0
            for ch in 0..<min(2, bufferList.count) {
                if let data = bufferList[ch].mData?.assumingMemoryBound(to: Float.self) {
                    for i in 0..<frames {
                        data[i] = Float(pcmBuffer[i * 2 + ch]) * scale
                    }
                }
            }

            return noErr
        }

        sourceNode = node

        let audioEngine = AVAudioEngine()
        audioEngine.attach(node)
        audioEngine.connect(node, to: audioEngine.mainMixerNode, format: format)
        node.volume = volume

        do {
            try audioEngine.start()
            engine = audioEngine
            playing = true
            paused = false
            logger.info("ModPlayer started")
        } catch {
            logger.error("Failed to start audio engine: \(error.localizedDescription)")
            audioEngine.detach(node)
            sourceNode = nil
        }
    }

    /// Pause playback.
    func pause() {
        guard playing, !paused else { return }
        paused = true
        engine?.pause()
    }

    /// Resume playback.
    func resume() {
        guard playing, paused else { return }
        paused = false
        try? engine?.start()
    }

    /// Stop playback and release resources.
    func stop() {
        playing = false
        paused = false

        engine?.stop()
        if let node = sourceNode {
            engine?.detach(node)
        }
        sourceNode = nil
        engine = nil

        NativeBridge.shared.modStop()
        logger.info("ModPlayer stopped")
    }
}
