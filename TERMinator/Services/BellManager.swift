import Foundation
import AVFoundation
import UIKit

/// Bell sound types - sorted by year (oldest to newest).
enum BellSound: Int, CaseIterable, Identifiable {
    case altair = 0         // 1975 - Altair 8800
    case appleII = 1        // 1977 - Apple II
    case pet = 2            // 1977 - Commodore PET
    case trs80 = 3          // 1977 - TRS-80
    case vt100 = 4          // 1978 - DEC VT100
    case atari = 5          // 1979 - Atari 800
    case appleIII = 6       // 1980 - Apple III
    case vic20 = 7          // 1980 - Commodore VIC-20
    case coco = 8           // 1980 - Tandy Color Computer
    case ibmPC = 9          // 1981 - IBM PC
    case bbcMicro = 10      // 1981 - BBC Micro
    case zx81 = 11          // 1981 - Sinclair ZX81
    case ti99 = 12          // 1981 - TI-99/4A
    case osborne = 13       // 1981 - Osborne 1
    case c64 = 14           // 1982 - Commodore 64
    case zxSpectrum = 15    // 1982 - ZX Spectrum
    case kaypro = 16        // 1982 - Kaypro
    case coleco = 17        // 1982 - Colecovision
    case nes = 18           // 1983 - NES/Famicom
    case msx = 19           // 1983 - MSX
    case macClassic = 20    // 1984 - Macintosh
    case amstradCPC = 21    // 1984 - Amstrad CPC
    case tandy1000 = 22     // 1984 - Tandy 1000
    case pcjr = 23          // 1984 - IBM PCjr
    case amiga = 24         // 1985 - Amiga
    case archimedes = 25    // 1987 - Acorn Archimedes
    case next = 26          // 1988 - NeXT Computer
    case gameBoy = 27       // 1989 - Game Boy
    case sun = 28           // 1989 - Sun SPARCstation
    case system = 29        // System notification

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .altair: return "Altair 8800 (1975)"
        case .appleII: return "Apple II (1977)"
        case .pet: return "Commodore PET (1977)"
        case .trs80: return "TRS-80 (1977)"
        case .vt100: return "DEC VT100 (1978)"
        case .atari: return "Atari 800 (1979)"
        case .appleIII: return "Apple III (1980)"
        case .vic20: return "VIC-20 (1980)"
        case .coco: return "Color Computer (1980)"
        case .ibmPC: return "IBM PC (1981)"
        case .bbcMicro: return "BBC Micro (1981)"
        case .zx81: return "ZX81 (1981)"
        case .ti99: return "TI-99/4A (1981)"
        case .osborne: return "Osborne 1 (1981)"
        case .c64: return "Commodore 64 (1982)"
        case .zxSpectrum: return "ZX Spectrum (1982)"
        case .kaypro: return "Kaypro (1982)"
        case .coleco: return "Colecovision (1982)"
        case .nes: return "NES/Famicom (1983)"
        case .msx: return "MSX (1983)"
        case .macClassic: return "Macintosh (1984)"
        case .amstradCPC: return "Amstrad CPC (1984)"
        case .tandy1000: return "Tandy 1000 (1984)"
        case .pcjr: return "IBM PCjr (1984)"
        case .amiga: return "Amiga (1985)"
        case .archimedes: return "Archimedes (1987)"
        case .next: return "NeXT (1988)"
        case .gameBoy: return "Game Boy (1989)"
        case .sun: return "Sun SPARC (1989)"
        case .system: return "System Sound"
        }
    }
}

/// Manages bell sounds and vibration for terminal BEL character.
class BellManager: ObservableObject {

    static let shared = BellManager()

    private let sampleRate: Float = 44100
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private let soundQueue = DispatchQueue(label: "com.terminator.bellmanager", qos: .userInteractive)

    // Settings keys
    private let soundEnabledKey = "sound_enabled"
    private let bellSoundKey = "bell_sound"
    private let bellVolumeKey = "bell_volume"
    private let vibrationEnabledKey = "vibration_enabled"

    @Published var soundEnabled: Bool {
        didSet { UserDefaults.standard.set(soundEnabled, forKey: soundEnabledKey) }
    }

    @Published var bellSound: BellSound {
        didSet { UserDefaults.standard.set(bellSound.rawValue, forKey: bellSoundKey) }
    }

    @Published var volume: Float {
        didSet { UserDefaults.standard.set(volume, forKey: bellVolumeKey) }
    }

    @Published var vibrationEnabled: Bool {
        didSet { UserDefaults.standard.set(vibrationEnabled, forKey: vibrationEnabledKey) }
    }

    private init() {
        // Load settings
        soundEnabled = UserDefaults.standard.object(forKey: soundEnabledKey) as? Bool ?? true
        if let soundValue = UserDefaults.standard.object(forKey: bellSoundKey) as? Int {
            bellSound = BellSound(rawValue: soundValue) ?? .vt100
        } else {
            bellSound = .vt100
        }
        volume = UserDefaults.standard.object(forKey: bellVolumeKey) as? Float ?? 0.5
        vibrationEnabled = UserDefaults.standard.object(forKey: vibrationEnabledKey) as? Bool ?? true

        setupAudioEngine()
    }

    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()

        guard let engine = audioEngine, let player = playerNode else { return }

        engine.attach(player)

        let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: format)

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: .mixWithOthers)
            try engine.start()
        } catch {
            print("BellManager: Failed to start audio engine - \(error)")
        }
    }

    // MARK: - Public Interface

    /// Play the bell sound and/or vibrate based on settings.
    func playBell() {
        if soundEnabled {
            playSound(bellSound)
        }

        if vibrationEnabled {
            vibrate()
        }
    }

    /// Play a specific bell sound.
    func playSound(_ sound: BellSound) {
        soundQueue.async { [weak self] in
            self?.generateAndPlaySound(sound)
        }
    }

    /// Test a specific bell sound.
    func testSound(_ sound: BellSound) {
        soundQueue.async { [weak self] in
            self?.generateAndPlaySound(sound)
        }
    }

    /// Vibrate the device briefly.
    func vibrate() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
    }

    // MARK: - Sound Generation

    private func generateAndPlaySound(_ sound: BellSound) {
        guard let engine = audioEngine, engine.isRunning else {
            setupAudioEngine()
            return
        }

        let samples: [Float]

        switch sound {
        case .vt100: samples = generateVT100Bell()
        case .appleII: samples = generateAppleIIBell()
        case .c64: samples = generateC64Bell()
        case .atari: samples = generateAtariBell()
        case .bbcMicro: samples = generateBBCMicroBell()
        case .zxSpectrum: samples = generateZXSpectrumBell()
        case .amiga: samples = generateAmigaBell()
        case .macClassic: samples = generateMacClassicBell()
        case .amstradCPC: samples = generateAmstradCPCBell()
        case .pet: samples = generatePETBell()
        case .tandy1000: samples = generateTandy1000Bell()
        case .ti99: samples = generateTI99Bell()
        case .next: samples = generateNeXTBell()
        case .gameBoy: samples = generateGameBoyBell()
        case .nes: samples = generateNESBell()
        case .archimedes: samples = generateArchimedesBell()
        case .sun: samples = generateSunBell()
        case .msx: samples = generateMSXBell()
        case .osborne: samples = generateOsborneBell()
        case .altair: samples = generateAltairBell()
        case .vic20: samples = generateVIC20Bell()
        case .zx81: samples = generateZX81Bell()
        case .coco: samples = generateCoCoBell()
        case .appleIII: samples = generateAppleIIIBell()
        case .kaypro: samples = generateKayproBell()
        case .coleco: samples = generateColecoBell()
        case .pcjr: samples = generatePCjrBell()
        case .trs80: samples = generateTRS80Bell()
        case .ibmPC: samples = generateSquareWave(frequency: 1000, durationMs: 150)
        case .system: playSystemSound(); return
        }

        playSamples(samples)
    }

    private func playSamples(_ samples: [Float]) {
        guard let player = playerNode, let engine = audioEngine, engine.isRunning else { return }

        let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)

        let channelData = buffer.floatChannelData![0]
        for i in 0..<samples.count {
            channelData[i] = samples[i] * volume
        }

        player.stop()
        player.scheduleBuffer(buffer, completionHandler: nil)
        player.play()
    }

    private func playSystemSound() {
        AudioServicesPlaySystemSound(1104)
    }

    // MARK: - Sound Generators

    private func generateSquareWave(frequency: Float, durationMs: Int) -> [Float] {
        let numSamples = Int(sampleRate * Float(durationMs) / 1000.0)
        var samples = [Float](repeating: 0, count: numSamples)
        let period = Int(sampleRate / frequency)
        let fadeLength = min(numSamples / 10, 500)

        for i in 0..<numSamples {
            var amplitude: Float = (i % period) < (period / 2) ? 1.0 : -1.0

            // Fade envelope
            if i < fadeLength {
                amplitude *= Float(i) / Float(fadeLength)
            } else if i > numSamples - fadeLength {
                amplitude *= Float(numSamples - i) / Float(fadeLength)
            }

            samples[i] = amplitude * 0.3
        }
        return samples
    }

    private func generateVT100Bell() -> [Float] {
        let durationMs = 100
        let frequency: Float = 750
        let numSamples = Int(sampleRate * Float(durationMs) / 1000.0)
        var samples = [Float](repeating: 0, count: numSamples)

        let attackLength = numSamples / 20
        let decayStart = numSamples / 3

        for i in 0..<numSamples {
            let angle = 2.0 * Float.pi * Float(i) * frequency / sampleRate
            var amplitude = sin(angle)

            if i < attackLength {
                amplitude *= Float(i) / Float(attackLength)
            } else if i > decayStart {
                let decayProgress = Float(i - decayStart) / Float(numSamples - decayStart)
                amplitude *= 1.0 - (decayProgress * decayProgress)
            }

            samples[i] = amplitude * 0.75
        }
        return samples
    }

    private func generateAppleIIBell() -> [Float] {
        let highDuration = 80
        let lowDuration = 80
        let highSamples = Int(sampleRate * Float(highDuration) / 1000.0)
        let lowSamples = Int(sampleRate * Float(lowDuration) / 1000.0)
        let numSamples = highSamples + lowSamples
        var samples = [Float](repeating: 0, count: numSamples)

        // High tone (880Hz)
        for i in 0..<highSamples {
            let angle = 2.0 * Float.pi * Float(i) * 880 / sampleRate
            var amplitude = sin(angle)
            if i < 100 { amplitude *= Float(i) / 100.0 }
            samples[i] = amplitude * 0.7
        }

        // Low tone (440Hz)
        for i in 0..<lowSamples {
            let angle = 2.0 * Float.pi * Float(i) * 440 / sampleRate
            var amplitude = sin(angle)
            if i > lowSamples - 100 { amplitude *= Float(lowSamples - i) / 100.0 }
            samples[highSamples + i] = amplitude * 0.7
        }

        return samples
    }

    private func generateC64Bell() -> [Float] {
        let durationMs = 180
        let frequency: Float = 523
        let numSamples = Int(sampleRate * Float(durationMs) / 1000.0)
        var samples = [Float](repeating: 0, count: numSamples)
        let period = sampleRate / frequency
        let fadeLength = min(numSamples / 8, 400)

        for i in 0..<numSamples {
            let progress = Float(i) / Float(numSamples)
            let dutyCycle = 0.25 + 0.25 * progress
            let posInPeriod = Float(i % Int(period)) / period

            var amplitude: Float = posInPeriod < dutyCycle ? 1.0 : -1.0

            // Triangle component for warmth
            let trianglePhase = (Float(i) * frequency / sampleRate).truncatingRemainder(dividingBy: 1.0)
            let triangle = trianglePhase < 0.5 ? 4 * trianglePhase - 1 : 3 - 4 * trianglePhase
            amplitude = amplitude * 0.7 + triangle * 0.3

            if i < fadeLength {
                amplitude *= Float(i) / Float(fadeLength)
            } else if i > numSamples - fadeLength {
                amplitude *= Float(numSamples - i) / Float(fadeLength)
            }

            samples[i] = amplitude * 0.6
        }
        return samples
    }

    private func generateAtariBell() -> [Float] {
        let durationMs = 120
        let baseFreq: Float = 1200
        let numSamples = Int(sampleRate * Float(durationMs) / 1000.0)
        var samples = [Float](repeating: 0, count: numSamples)
        let fadeLength = min(numSamples / 10, 300)

        for i in 0..<numSamples {
            let angle1 = 2.0 * Float.pi * Float(i) * baseFreq / sampleRate
            let angle2 = 2.0 * Float.pi * Float(i) * (baseFreq * 1.5) / sampleRate
            let angle3 = 2.0 * Float.pi * Float(i) * (baseFreq * 0.5) / sampleRate

            var amplitude = sin(angle1) * 0.5 + sin(angle2) * 0.3 + sin(angle3) * 0.2

            if (i / 50) % 2 == 0 { amplitude *= 0.9 }

            if i < fadeLength {
                amplitude *= Float(i) / Float(fadeLength)
            } else if i > numSamples - fadeLength {
                amplitude *= Float(numSamples - i) / Float(fadeLength)
            }

            samples[i] = amplitude * 0.65
        }
        return samples
    }

    private func generateBBCMicroBell() -> [Float] {
        let durationMs = 200
        let startFreq: Float = 2000
        let endFreq: Float = 800
        let numSamples = Int(sampleRate * Float(durationMs) / 1000.0)
        var samples = [Float](repeating: 0, count: numSamples)
        let fadeLength = min(numSamples / 10, 400)
        var phase: Float = 0

        for i in 0..<numSamples {
            let progress = Float(i) / Float(numSamples)
            let frequency = startFreq + (endFreq - startFreq) * progress

            phase += 2.0 * Float.pi * frequency / sampleRate
            var amplitude = sin(phase)

            if i < fadeLength {
                amplitude *= Float(i) / Float(fadeLength)
            } else if i > numSamples - fadeLength {
                amplitude *= Float(numSamples - i) / Float(fadeLength)
            }

            samples[i] = amplitude * 0.7
        }
        return samples
    }

    private func generateZXSpectrumBell() -> [Float] {
        let durationMs = 150
        let numSamples = Int(sampleRate * Float(durationMs) / 1000.0)
        var samples = [Float](repeating: 0, count: numSamples)
        let fadeLength = numSamples / 12
        var phase: Float = 0

        for i in 0..<numSamples {
            let progress = Float(i) / Float(numSamples)
            let frequency: Float
            if progress < 0.1 {
                frequency = 2400 - (progress / 0.1) * 1400
            } else if progress < 0.3 {
                frequency = 1000 - ((progress - 0.1) / 0.2) * 200
            } else {
                frequency = 800
            }

            phase += 2.0 * Float.pi * frequency / sampleRate
            var amplitude: Float = sin(phase) > 0 ? 1.0 : -1.0

            if i < fadeLength {
                amplitude *= Float(i) / Float(fadeLength)
            } else if i > numSamples - fadeLength {
                amplitude *= Float(numSamples - i) / Float(fadeLength)
            }

            samples[i] = amplitude * 0.5
        }
        return samples
    }

    private func generateAmigaBell() -> [Float] {
        let durationMs = 160
        let frequency: Float = 698
        let numSamples = Int(sampleRate * Float(durationMs) / 1000.0)
        var samples = [Float](repeating: 0, count: numSamples)
        let attackLength = numSamples / 15
        let sustainEnd = numSamples * 2 / 3

        for i in 0..<numSamples {
            let angle = 2.0 * Float.pi * Float(i) * frequency / sampleRate
            var amplitude = sin(angle) * 0.7 + sin(angle * 2) * 0.2 + sin(angle * 3) * 0.1

            // 8-bit quantization
            amplitude = Float(Int(amplitude * 127)) / 127.0

            if i < attackLength {
                amplitude *= Float(i) / Float(attackLength)
            } else if i > sustainEnd {
                let releaseProgress = Float(i - sustainEnd) / Float(numSamples - sustainEnd)
                amplitude *= 1.0 - releaseProgress
            }

            samples[i] = amplitude * 0.7
        }
        return samples
    }

    private func generateMacClassicBell() -> [Float] {
        let durationMs = 180
        let baseFreq: Float = 480
        let numSamples = Int(sampleRate * Float(durationMs) / 1000.0)
        var samples = [Float](repeating: 0, count: numSamples)
        let attackLength = numSamples / 25
        let decayStart = numSamples / 4

        for i in 0..<numSamples {
            let angle1 = 2.0 * Float.pi * Float(i) * baseFreq / sampleRate
            let angle2 = 2.0 * Float.pi * Float(i) * (baseFreq * 1.003) / sampleRate

            var amplitude = (sin(angle1) + sin(angle2)) / 2
            amplitude = amplitude * 0.85 + sin(angle1 * 2) * 0.15

            if i < attackLength {
                amplitude *= Float(i) / Float(attackLength)
            } else if i > decayStart {
                let decayProgress = Float(i - decayStart) / Float(numSamples - decayStart)
                amplitude *= 1.0 - (decayProgress * decayProgress * 0.7)
            }

            samples[i] = amplitude * 0.65
        }
        return samples
    }

    private func generateAmstradCPCBell() -> [Float] {
        let noteMs = 50
        let notes: [Float] = [880, 1109, 1319]
        let samplesPerNote = Int(sampleRate * Float(noteMs) / 1000.0)
        let totalSamples = samplesPerNote * notes.count
        var samples = [Float](repeating: 0, count: totalSamples)

        for (noteIdx, freq) in notes.enumerated() {
            let period = Int(sampleRate / freq)
            let noteStart = noteIdx * samplesPerNote

            for i in 0..<samplesPerNote {
                var amplitude: Float = (i % period) < (period / 2) ? 1.0 : -1.0

                let noteProgress = Float(i) / Float(samplesPerNote)
                if noteProgress < 0.1 {
                    amplitude *= noteProgress / 0.1
                } else if noteProgress > 0.8 {
                    amplitude *= (1.0 - noteProgress) / 0.2
                }

                samples[noteStart + i] = amplitude * 0.5
            }
        }
        return samples
    }

    private func generatePETBell() -> [Float] {
        let durationMs = 30
        let frequency: Float = 1000
        let numSamples = Int(sampleRate * Float(durationMs) / 1000.0)
        var samples = [Float](repeating: 0, count: numSamples)
        let period = Int(sampleRate / frequency)

        for i in 0..<numSamples {
            var amplitude: Float = (i % period) < (period / 2) ? 1.0 : -1.0
            let progress = Float(i) / Float(numSamples)
            amplitude *= exp(-progress * 4)
            samples[i] = amplitude * 0.7
        }
        return samples
    }

    private func generateTandy1000Bell() -> [Float] {
        let durationMs = 140
        let numSamples = Int(sampleRate * Float(durationMs) / 1000.0)
        var samples = [Float](repeating: 0, count: numSamples)

        let freq1: Float = 523
        let freq2: Float = 659
        let freq3: Float = 784
        let fadeLength = numSamples / 8

        for i in 0..<numSamples {
            let period1 = Int(sampleRate / freq1)
            let period2 = Int(sampleRate / freq2)
            let period3 = Int(sampleRate / freq3)

            let wave1: Float = (i % period1) < (period1 / 2) ? 1.0 : -1.0
            let wave2: Float = (i % period2) < (period2 / 2) ? 1.0 : -1.0
            let wave3: Float = (i % period3) < (period3 / 2) ? 1.0 : -1.0

            var amplitude = (wave1 + wave2 * 0.8 + wave3 * 0.6) / 2.4

            if i < fadeLength {
                amplitude *= Float(i) / Float(fadeLength)
            } else if i > numSamples - fadeLength * 2 {
                amplitude *= Float(numSamples - i) / Float(fadeLength * 2)
            }

            samples[i] = amplitude * 0.45
        }
        return samples
    }

    private func generateTI99Bell() -> [Float] {
        let durationMs = 200
        let baseFreq: Float = 660
        let numSamples = Int(sampleRate * Float(durationMs) / 1000.0)
        var samples = [Float](repeating: 0, count: numSamples)
        let fadeLength = numSamples / 10

        for i in 0..<numSamples {
            let vibratoRate: Float = 25.0
            let vibratoDepth: Float = 0.03
            let vibrato = 1.0 + vibratoDepth * sin(2.0 * Float.pi * Float(i) * vibratoRate / sampleRate)
            let frequency = baseFreq * vibrato

            let period = max(Int(sampleRate / frequency), 1)
            var amplitude: Float = (i % period) < (period / 2) ? 1.0 : -1.0

            let freq2 = baseFreq * 1.5 * vibrato
            let period2 = max(Int(sampleRate / freq2), 1)
            let wave2: Float = (i % period2) < (period2 / 2) ? 1.0 : -1.0
            amplitude = amplitude * 0.6 + wave2 * 0.4

            if i < fadeLength {
                amplitude *= Float(i) / Float(fadeLength)
            } else if i > numSamples - fadeLength {
                amplitude *= Float(numSamples - i) / Float(fadeLength)
            }

            samples[i] = amplitude * 0.5
        }
        return samples
    }

    private func generateNeXTBell() -> [Float] {
        let durationMs = 250
        let numSamples = Int(sampleRate * Float(durationMs) / 1000.0)
        var samples = [Float](repeating: 0, count: numSamples)

        let carrierFreq: Float = 587
        let modulatorFreq: Float = 587 * 2
        let modulationIndex: Float = 0.3
        let attackLength = numSamples / 20
        let sustainEnd = numSamples / 2

        for i in 0..<numSamples {
            let modulator = sin(2.0 * Float.pi * Float(i) * modulatorFreq / sampleRate)
            let carrier = sin(2.0 * Float.pi * Float(i) * carrierFreq / sampleRate + modulationIndex * modulator)
            let sub = sin(2.0 * Float.pi * Float(i) * (carrierFreq / 2) / sampleRate)

            var amplitude = carrier * 0.8 + sub * 0.2

            if i < attackLength {
                let attackCurve = Float(i) / Float(attackLength)
                amplitude *= attackCurve * attackCurve
            } else if i > sustainEnd {
                let releaseProgress = Float(i - sustainEnd) / Float(numSamples - sustainEnd)
                amplitude *= (1.0 - releaseProgress) * (1.0 - releaseProgress)
            }

            samples[i] = amplitude * 0.6
        }
        return samples
    }

    private func generateGameBoyBell() -> [Float] {
        let durationMs = 120
        let frequency: Float = 880
        let numSamples = Int(sampleRate * Float(durationMs) / 1000.0)
        var samples = [Float](repeating: 0, count: numSamples)

        for i in 0..<numSamples {
            let progress = Float(i) / Float(numSamples)
            let dutyCycle = 0.125 + progress * 0.375
            let period = sampleRate / frequency
            let posInPeriod = Float(i % Int(period)) / period

            var amplitude: Float = posInPeriod < Float(dutyCycle) ? 1.0 : -1.0
            amplitude *= max(0.0, 1.0 - progress * 1.5)
            amplitude = Float(Int(amplitude * 7.5)) / 7.5

            samples[i] = amplitude * 0.6
        }
        return samples
    }

    private func generateNESBell() -> [Float] {
        let durationMs = 150
        let numSamples = Int(sampleRate * Float(durationMs) / 1000.0)
        var samples = [Float](repeating: 0, count: numSamples)

        let pulseFreq: Float = 440
        let triFreq: Float = 220
        let fadeLength = numSamples / 8

        for i in 0..<numSamples {
            let triPhase = (Float(i) * triFreq / sampleRate).truncatingRemainder(dividingBy: 1.0)
            var triValue: Float = triPhase < 0.5 ? 4 * triPhase - 1 : 3 - 4 * triPhase
            triValue = Float(Int(triValue * 7.5)) / 7.5

            let pulsePhase = (Float(i) * pulseFreq / sampleRate).truncatingRemainder(dividingBy: 1.0)
            let pulse: Float = pulsePhase < 0.25 ? 1.0 : -1.0

            var amplitude = triValue * 0.6 + pulse * 0.4

            if i < fadeLength {
                amplitude *= Float(i) / Float(fadeLength)
            } else if i > numSamples - fadeLength {
                amplitude *= Float(numSamples - i) / Float(fadeLength)
            }

            samples[i] = amplitude * 0.55
        }
        return samples
    }

    private func generateArchimedesBell() -> [Float] {
        let durationMs = 180
        let baseFreq: Float = 523
        let numSamples = Int(sampleRate * Float(durationMs) / 1000.0)
        var samples = [Float](repeating: 0, count: numSamples)

        let attackEnd = numSamples / 10
        let sustainEnd = numSamples * 2 / 3

        for i in 0..<numSamples {
            let phase = (Float(i) * baseFreq / sampleRate).truncatingRemainder(dividingBy: 1.0)

            var amplitude = sin(2.0 * Float.pi * phase) * 0.5 +
                           sin(4.0 * Float.pi * phase) * 0.25 +
                           sin(6.0 * Float.pi * phase) * 0.15 +
                           sin(8.0 * Float.pi * phase) * 0.1

            let pitchEnv = 1.0 + 0.02 * exp(Float(-i) * 10.0 / Float(numSamples))
            let phase2 = (Float(i) * baseFreq * pitchEnv / sampleRate).truncatingRemainder(dividingBy: 1.0)
            amplitude = amplitude * 0.7 + sin(2.0 * Float.pi * phase2) * 0.3

            if i < attackEnd {
                amplitude *= Float(i) / Float(attackEnd)
            } else if i > sustainEnd {
                let release = Float(i - sustainEnd) / Float(numSamples - sustainEnd)
                amplitude *= 1.0 - release * release
            }

            amplitude = Float(Int(amplitude * 127)) / 127.0
            samples[i] = amplitude * 0.6
        }
        return samples
    }

    private func generateSunBell() -> [Float] {
        let durationMs = 100
        let frequency: Float = 440
        let numSamples = Int(sampleRate * Float(durationMs) / 1000.0)
        var samples = [Float](repeating: 0, count: numSamples)
        let fadeLength = numSamples / 15

        for i in 0..<numSamples {
            let angle = 2.0 * Float.pi * Float(i) * frequency / sampleRate
            var amplitude = sin(angle) * 0.95 + sin(angle * 2) * 0.05

            if i < fadeLength {
                amplitude *= Float(i) / Float(fadeLength)
            } else if i > numSamples - fadeLength {
                amplitude *= Float(numSamples - i) / Float(fadeLength)
            }

            samples[i] = amplitude * 0.7
        }
        return samples
    }

    private func generateMSXBell() -> [Float] {
        let note1Ms = 60
        let note2Ms = 80
        let freq1: Float = 1047
        let freq2: Float = 784
        let note1Samples = Int(sampleRate * Float(note1Ms) / 1000.0)
        let totalSamples = note1Samples + Int(sampleRate * Float(note2Ms) / 1000.0)
        var samples = [Float](repeating: 0, count: totalSamples)

        for i in 0..<totalSamples {
            let freq: Float = i < note1Samples ? freq1 : freq2
            let noteStart = i < note1Samples ? 0 : note1Samples
            let noteLen = i < note1Samples ? note1Samples : totalSamples - note1Samples
            let notePos = i - noteStart
            let period = Int(sampleRate / freq)

            var amplitude: Float = (notePos % period) < (period / 2) ? 1.0 : -1.0

            let noteProgress = Float(notePos) / Float(noteLen)
            if noteProgress < 0.05 {
                amplitude *= noteProgress / 0.05
            } else if noteProgress > 0.7 {
                amplitude *= (1.0 - noteProgress) / 0.3
            }

            samples[i] = amplitude * 0.5
        }
        return samples
    }

    private func generateOsborneBell() -> [Float] {
        let durationMs = 80
        let frequency: Float = 2000
        let numSamples = Int(sampleRate * Float(durationMs) / 1000.0)
        var samples = [Float](repeating: 0, count: numSamples)
        let period = Int(sampleRate / frequency)

        for i in 0..<numSamples {
            var amplitude: Float = (i % period) < (period / 2) ? 1.0 : -1.0
            let ring = sin(2.0 * Float.pi * Float(i) * 4000 / sampleRate) * 0.15
            amplitude = amplitude * 0.85 + ring

            let progress = Float(i) / Float(numSamples)
            amplitude *= 1.0 - progress * progress

            samples[i] = amplitude * 0.5
        }
        return samples
    }

    private func generateAltairBell() -> [Float] {
        let durationMs = 200
        let numSamples = Int(sampleRate * Float(durationMs) / 1000.0)
        var samples = [Float](repeating: 0, count: numSamples)
        var phase: Float = 0
        let fadeLength = numSamples / 10

        for i in 0..<numSamples {
            let freq1 = Float(800 + (i % 100) * 5)
            let freq2 = Float(1200 + (i % 73) * 7)
            let freq3 = Float(400 + (i % 150) * 3)

            phase += 2.0 * Float.pi / sampleRate
            var amplitude = sin(phase * freq1) * 0.4 +
                           sin(phase * freq2) * 0.3 +
                           sin(phase * freq3) * 0.3

            if i % 44 < 22 { amplitude *= 0.8 }

            if i < fadeLength {
                amplitude *= Float(i) / Float(fadeLength)
            } else if i > numSamples - fadeLength {
                amplitude *= Float(numSamples - i) / Float(fadeLength)
            }

            samples[i] = amplitude * 0.5
        }
        return samples
    }

    private func generateVIC20Bell() -> [Float] {
        let durationMs = 150
        let numSamples = Int(sampleRate * Float(durationMs) / 1000.0)
        var samples = [Float](repeating: 0, count: numSamples)

        let freq1: Float = 523
        let freq2: Float = 659
        let fadeLength = numSamples / 8

        for i in 0..<numSamples {
            let period1 = Int(sampleRate / freq1)
            let period2 = Int(sampleRate / freq2)

            let wave1: Float = (i % period1) < (period1 / 2) ? 1.0 : -1.0
            let wave2: Float = (i % period2) < (period2 / 2) ? 1.0 : -1.0

            var amplitude = wave1 * 0.6 + wave2 * 0.4
            amplitude = Float(Int(amplitude * 8)) / 8.0

            if i < fadeLength {
                amplitude *= Float(i) / Float(fadeLength)
            } else if i > numSamples - fadeLength {
                amplitude *= Float(numSamples - i) / Float(fadeLength)
            }

            samples[i] = amplitude * 0.55
        }
        return samples
    }

    private func generateZX81Bell() -> [Float] {
        let durationMs = 60
        let frequency: Float = 900
        let numSamples = Int(sampleRate * Float(durationMs) / 1000.0)
        var samples = [Float](repeating: 0, count: numSamples)
        let period = Int(sampleRate / frequency)

        for i in 0..<numSamples {
            var amplitude: Float = (i % period) < (period / 2) ? 1.0 : -1.0
            let progress = Float(i) / Float(numSamples)
            amplitude *= 1.0 - progress * 0.5
            samples[i] = amplitude * 0.5
        }
        return samples
    }

    private func generateCoCoBell() -> [Float] {
        let durationMs = 130
        let frequency: Float = 660
        let numSamples = Int(sampleRate * Float(durationMs) / 1000.0)
        var samples = [Float](repeating: 0, count: numSamples)
        let fadeLength = numSamples / 10

        for i in 0..<numSamples {
            let angle = 2.0 * Float.pi * Float(i) * frequency / sampleRate
            var amplitude = sin(angle) * 0.7 + sin(angle * 2) * 0.2 + sin(angle * 3) * 0.1
            amplitude = Float(Int(amplitude * 32)) / 32.0

            if i < fadeLength {
                amplitude *= Float(i) / Float(fadeLength)
            } else if i > numSamples - fadeLength {
                amplitude *= Float(numSamples - i) / Float(fadeLength)
            }

            samples[i] = amplitude * 0.6
        }
        return samples
    }

    private func generateAppleIIIBell() -> [Float] {
        let durationMs = 140
        let frequency: Float = 770
        let numSamples = Int(sampleRate * Float(durationMs) / 1000.0)
        var samples = [Float](repeating: 0, count: numSamples)
        let fadeLength = numSamples / 12

        for i in 0..<numSamples {
            let angle = 2.0 * Float.pi * Float(i) * frequency / sampleRate
            var amplitude = sin(angle) * 0.8 + sin(angle * 3) * 0.2
            amplitude = Float(Int(amplitude * 32)) / 32.0

            if i < fadeLength {
                amplitude *= Float(i) / Float(fadeLength)
            } else if i > numSamples - fadeLength {
                amplitude *= Float(numSamples - i) / Float(fadeLength)
            }

            samples[i] = amplitude * 0.6
        }
        return samples
    }

    private func generateKayproBell() -> [Float] {
        let durationMs = 100
        let frequency: Float = 800
        let numSamples = Int(sampleRate * Float(durationMs) / 1000.0)
        var samples = [Float](repeating: 0, count: numSamples)
        let period = Int(sampleRate / frequency)
        let fadeLength = numSamples / 15

        for i in 0..<numSamples {
            var amplitude: Float = (i % period) < (period / 2) ? 1.0 : -1.0

            if i < fadeLength {
                amplitude *= Float(i) / Float(fadeLength)
            } else if i > numSamples - fadeLength {
                amplitude *= Float(numSamples - i) / Float(fadeLength)
            }

            samples[i] = amplitude * 0.5
        }
        return samples
    }

    private func generateColecoBell() -> [Float] {
        let durationMs = 120
        let numSamples = Int(sampleRate * Float(durationMs) / 1000.0)
        var samples = [Float](repeating: 0, count: numSamples)

        let freqs: [Float] = [1047, 880, 698]
        let samplesPerNote = numSamples / freqs.count

        for (noteIdx, freq) in freqs.enumerated() {
            let period = Int(sampleRate / freq)
            let noteStart = noteIdx * samplesPerNote

            for i in 0..<samplesPerNote {
                var amplitude: Float = (i % period) < (period / 2) ? 1.0 : -1.0

                let progress = Float(i) / Float(samplesPerNote)
                if progress < 0.1 {
                    amplitude *= progress / 0.1
                } else if progress > 0.7 {
                    amplitude *= (1.0 - progress) / 0.3
                }

                samples[noteStart + i] = amplitude * 0.5
            }
        }
        return samples
    }

    private func generatePCjrBell() -> [Float] {
        let durationMs = 150
        let numSamples = Int(sampleRate * Float(durationMs) / 1000.0)
        var samples = [Float](repeating: 0, count: numSamples)

        let freq1: Float = 440
        let freq2: Float = 880
        let fadeLength = numSamples / 10

        for i in 0..<numSamples {
            let period1 = Int(sampleRate / freq1)
            let period2 = Int(sampleRate / freq2)

            let wave1: Float = (i % period1) < (period1 / 2) ? 1.0 : -1.0
            let wave2: Float = (i % period2) < (period2 / 2) ? 1.0 : -1.0

            var amplitude = wave1 * 0.7 + wave2 * 0.3

            if i < fadeLength {
                amplitude *= Float(i) / Float(fadeLength)
            } else if i > numSamples - fadeLength {
                amplitude *= Float(numSamples - i) / Float(fadeLength)
            }

            samples[i] = amplitude * 0.5
        }
        return samples
    }

    private func generateTRS80Bell() -> [Float] {
        let durationMs = 120
        let baseFreq: Float = 450
        let numSamples = Int(sampleRate * Float(durationMs) / 1000.0)
        var samples = [Float](repeating: 0, count: numSamples)
        let fadeLength = numSamples / 10

        for i in 0..<numSamples {
            let wobble = 1.0 + 0.02 * sin(2.0 * Float.pi * Float(i) * 30 / sampleRate)
            let frequency = baseFreq * wobble
            let period = max(Int(sampleRate / frequency), 1)

            var amplitude: Float = (i % period) < (period / 2) ? 1.0 : -1.0

            if i < fadeLength {
                amplitude *= Float(i) / Float(fadeLength)
            } else if i > numSamples - fadeLength {
                amplitude *= Float(numSamples - i) / Float(fadeLength)
            }

            samples[i] = amplitude * 0.55
        }
        return samples
    }

    // MARK: - Cleanup

    deinit {
        audioEngine?.stop()
        audioEngine = nil
        playerNode = nil
    }
}
