import Foundation

/// Real-time audio analyzer for visualizer overlay.
///
/// Uses Goertzel algorithm to directly compute energy at 16 logarithmic
/// frequency bands (60Hz - 16kHz). Also provides a waveform buffer for
/// oscilloscope mode.
///
/// Thread-safe: audio thread writes via atomic reference swap,
/// UI thread reads snapshots.
class AudioAnalyzer {

    private static let numBands = 16
    private static let scopeSamples = 128
    private static let sampleRate: Float = 44100
    private static let blockSize = 1024

    // Smoothing
    private static let attack: Float = 0.6
    private static let decay: Float = 0.25

    // Band center frequencies (logarithmic from 60Hz to 16kHz)
    private let bandFreqs: [Float]

    // Pre-computed Goertzel coefficients for each band
    private let goertzelCoeff: [Float]

    // Per-band gain to compensate for music's natural high-freq rolloff
    private let bandGain: [Float]

    // Current smoothed output - accessed from multiple threads via value-type copy
    private let lock = NSLock()
    private var _currentBands = [Float](repeating: 0, count: numBands)
    private var _currentScope = [Float](repeating: 0, count: scopeSamples)

    // Working buffers (audio thread only)
    private var monoBuffer = [Float](repeating: 0, count: blockSize)
    private var smoothedBands = [Float](repeating: 0, count: numBands)

    init() {
        let minFreq = 60.0
        let maxFreq = 16000.0
        let logMin = log(minFreq)
        let logMax = log(maxFreq)

        var freqs = [Float](repeating: 0, count: AudioAnalyzer.numBands)
        var coeffs = [Float](repeating: 0, count: AudioAnalyzer.numBands)
        var gains = [Float](repeating: 0, count: AudioAnalyzer.numBands)

        for b in 0..<AudioAnalyzer.numBands {
            let freqLow = exp(logMin + (logMax - logMin) * Double(b) / Double(AudioAnalyzer.numBands))
            let freqHigh = exp(logMin + (logMax - logMin) * Double(b + 1) / Double(AudioAnalyzer.numBands))
            freqs[b] = Float(sqrt(freqLow * freqHigh))

            let k = freqs[b] * Float(AudioAnalyzer.blockSize) / AudioAnalyzer.sampleRate
            coeffs[b] = Float(2.0 * cos(2.0 * Double.pi * Double(k) / Double(AudioAnalyzer.blockSize)))

            gains[b] = 6.0 * (1.0 + Float(b) * 0.5)
        }

        bandFreqs = freqs
        goertzelCoeff = coeffs
        bandGain = gains
    }

    /// Feed stereo 16-bit PCM data from the audio playback thread.
    func feedPcm(buffer: [Int16], frames: Int) {
        let count = min(frames, AudioAnalyzer.blockSize)

        // Mix stereo to mono, normalize to [-1, 1]
        for i in 0..<count {
            let left = Float(buffer[i * 2])
            let right = Float(buffer[i * 2 + 1])
            monoBuffer[i] = (left + right) * 0.5 / 32768.0
        }
        for i in count..<AudioAnalyzer.blockSize {
            monoBuffer[i] = 0
        }

        // Capture scope waveform
        var scopeBuf = [Float](repeating: 0, count: AudioAnalyzer.scopeSamples)
        let scopeCount = min(count, AudioAnalyzer.scopeSamples)
        for i in 0..<scopeCount {
            scopeBuf[i] = monoBuffer[i]
        }

        // Compute energy per band using Goertzel algorithm
        var newBands = [Float](repeating: 0, count: AudioAnalyzer.numBands)
        for b in 0..<AudioAnalyzer.numBands {
            let coeff = goertzelCoeff[b]
            var s0: Float
            var s1: Float = 0
            var s2: Float = 0

            for i in 0..<count {
                s0 = monoBuffer[i] + coeff * s1 - s2
                s2 = s1
                s1 = s0
            }

            let magSq = s1 * s1 + s2 * s2 - coeff * s1 * s2
            let mag = sqrt(max(magSq, 0)) / Float(count)

            let scaled = sqrt(min(mag * bandGain[b], 1.0))

            if scaled > smoothedBands[b] {
                smoothedBands[b] += (scaled - smoothedBands[b]) * AudioAnalyzer.attack
            } else {
                smoothedBands[b] += (scaled - smoothedBands[b]) * AudioAnalyzer.decay
            }
            newBands[b] = smoothedBands[b]
        }

        lock.lock()
        _currentBands = newBands
        _currentScope = scopeBuf
        lock.unlock()
    }

    /// Reset all bands and scope to zero (e.g. when playback stops).
    func reset() {
        smoothedBands = [Float](repeating: 0, count: AudioAnalyzer.numBands)
        lock.lock()
        _currentBands = [Float](repeating: 0, count: AudioAnalyzer.numBands)
        _currentScope = [Float](repeating: 0, count: AudioAnalyzer.scopeSamples)
        lock.unlock()
    }

    /// Get current band levels. Safe to call from UI thread.
    func getBands() -> [Float] {
        lock.lock()
        let copy = _currentBands
        lock.unlock()
        return copy
    }

    /// Get current scope waveform. Safe to call from UI thread.
    func getScope() -> [Float] {
        lock.lock()
        let copy = _currentScope
        lock.unlock()
        return copy
    }
}
