import SwiftUI
import UIKit

/// A scrolling marquee view with authentic CRT effects matching the Android version.
/// Features per-character brightness variation, phosphor glow, scanlines,
/// micro-jitter, major glitch events, random case flips, and noise artifacts.
struct CrtMarqueeView: View {
    let text: String
    var textColor: Color = Color(red: 0.4, green: 0.93, blue: 0.4) // #66EE66 - phosphor green
    var backgroundColor: Color = Color(red: 0.031, green: 0.075, blue: 0.125) // #081320
    var scrollSpeed: Double = 50 // pixels per second (slower, smoother scroll)

    @State private var offset: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0

    // Micro-jitter (updates every 50ms)
    @State private var microJitterX: CGFloat = 0

    // Major glitch state (every 3-8 seconds)
    @State private var isGlitching: Bool = false
    @State private var glitchVerticalOffset: CGFloat = 0
    @State private var glitchHorizontalOffset: CGFloat = 0
    @State private var glitchAlpha: Double = 1.0

    // Per-character brightness variation (index -> brightness multiplier 0.5-1.0)
    @State private var characterBrightness: [Int: Double] = [:]

    // Case flips with expiration times (index -> expiration Date)
    @State private var caseFlips: [Int: Date] = [:]

    // The modified display text with case flips applied
    @State private var displayText: String = ""

    // Noise artifacts
    @State private var noiseArtifacts: [NoiseBar] = []

    // Timers
    @State private var scrollTimer: Timer?
    @State private var microJitterTimer: Timer?
    @State private var brightnessTimer: Timer?
    @State private var glitchScheduleTimer: Timer?
    @State private var noiseTimer: Timer?

    struct NoiseBar: Identifiable {
        let id = UUID()
        let y: CGFloat
        let height: CGFloat
        let opacity: Double
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background
                backgroundColor

                // Scrolling text with effects
                ZStack {
                    // Glow layer (15% opacity blur behind text)
                    marqueeText
                        .foregroundColor(textColor.opacity(0.15))
                        .blur(radius: 4)
                        .offset(
                            x: offset + microJitterX + glitchHorizontalOffset,
                            y: glitchVerticalOffset
                        )

                    // Main text with brightness variation
                    marqueeText
                        .foregroundColor(textColor.opacity(0.78 * glitchAlpha))
                        .offset(
                            x: offset + microJitterX + glitchHorizontalOffset,
                            y: glitchVerticalOffset
                        )
                }

                // Scanline overlay removed to match app background
            }
            .clipped()
            .onAppear {
                containerWidth = geometry.size.width
                displayText = text
                startEffects()
            }
            .onDisappear {
                stopEffects()
            }
            .onChange(of: geometry.size.width) { newWidth in
                containerWidth = newWidth
            }
        }
        .frame(height: 36 * UIScale.factor)
    }

    /// Retro pixel-style font - uses Press Start 2P if available, falls back to Menlo
    private var retroFont: Font {
        let baseSize: CGFloat = UIFont(name: "PressStart2P-Regular", size: 14) != nil ? 14 : 16
        let scaledSize = baseSize * UIScale.factor
        // Try Press Start 2P first (if bundled), otherwise use Menlo for retro look
        if UIFont(name: "PressStart2P-Regular", size: scaledSize) != nil {
            return .custom("PressStart2P-Regular", size: scaledSize)
        } else {
            return .custom("Menlo-Bold", size: scaledSize)
        }
    }

    private var marqueeText: some View {
        HStack(spacing: 0) {
            Text(displayText)
                .font(retroFont)
                .tracking(1)
                .fixedSize()
                .background(
                    GeometryReader { textGeometry in
                        Color.clear
                            .onAppear {
                                textWidth = textGeometry.size.width
                            }
                            .onChange(of: textGeometry.size.width) { newWidth in
                                if newWidth > textWidth {
                                    textWidth = newWidth
                                }
                            }
                    }
                )

            Spacer().frame(width: max(containerWidth, 100))

            Text(displayText)
                .font(retroFont)
                .tracking(1)
                .fixedSize()
        }
    }

    // MARK: - Effect Management

    private func startEffects() {
        startScrolling()
        startMicroJitter()
        startBrightnessVariation()
        scheduleNextGlitch()
    }

    private func stopEffects() {
        scrollTimer?.invalidate()
        microJitterTimer?.invalidate()
        brightnessTimer?.invalidate()
        glitchScheduleTimer?.invalidate()
        noiseTimer?.invalidate()
        scrollTimer = nil
        microJitterTimer = nil
        brightnessTimer = nil
        glitchScheduleTimer = nil
        noiseTimer = nil
    }

    // MARK: - Scrolling

    private func startScrolling() {
        // Start from right edge
        offset = containerWidth

        scrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { _ in
            // Don't scroll if textWidth hasn't been measured yet
            guard textWidth > 0 else { return }

            let delta = CGFloat(scrollSpeed / 60.0)
            offset -= delta

            // Reset when first text has fully scrolled off and second text is at start position
            // This creates a seamless loop: Text 2 appears at containerWidth when offset = -textWidth
            if offset <= -textWidth {
                offset = containerWidth
            }
        }
    }

    // MARK: - Micro-Jitter (subtle CRT instability)

    private func startMicroJitter() {
        microJitterTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
            microJitterX = CGFloat.random(in: -2...2)
        }
    }

    // MARK: - Case Flips (every 100ms)

    private func startBrightnessVariation() {
        brightnessTimer = Timer.scheduledTimer(withTimeInterval: 0.10, repeats: true) { _ in
            updateDisplayText()
        }
    }

    private func updateDisplayText() {
        let now = Date()
        var chars = Array(text)

        // Remove expired case flips
        caseFlips = caseFlips.filter { $0.value > now }

        // Add new case flips (1-2 new characters per update)
        let flipCount = Int.random(in: 1...2)
        for _ in 0..<flipCount {
            let index = Int.random(in: 0..<chars.count)
            // Case flip persists for 0.25 seconds
            let duration = 0.25
            caseFlips[index] = now.addingTimeInterval(duration)
        }

        // Apply all active case flips
        for (index, _) in caseFlips {
            guard index < chars.count else { continue }
            let char = chars[index]
            if char.isLowercase {
                chars[index] = Character(char.uppercased())
            } else if char.isUppercase {
                chars[index] = Character(char.lowercased())
            }
        }

        displayText = String(chars)
    }

    // MARK: - Major Glitch Events (every 1.5-4 seconds for more frequent effect)

    private func scheduleNextGlitch() {
        let delay = Double.random(in: 1.5...4.0)
        glitchScheduleTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            triggerMajorGlitch()
        }
    }

    private func triggerMajorGlitch() {
        isGlitching = true

        // Glitch duration: 30-80ms (subtle)
        let glitchDuration = Double.random(in: 0.03...0.08)

        // Apply subtle glitch effects
        withAnimation(.linear(duration: 0.02)) {
            glitchVerticalOffset = CGFloat.random(in: -1...1)
            glitchHorizontalOffset = CGFloat.random(in: -2...2)
            glitchAlpha = Double.random(in: 0.7...0.85)
        }

        // End glitch after duration
        DispatchQueue.main.asyncAfter(deadline: .now() + glitchDuration) {
            withAnimation(.linear(duration: 0.02)) {
                glitchVerticalOffset = 0
                glitchHorizontalOffset = 0
                glitchAlpha = 1.0
            }
            isGlitching = false
            scheduleNextGlitch()
        }
    }

    // MARK: - Noise Artifacts (3% chance per frame)

    private func startNoiseArtifacts() {
        noiseTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { _ in
            // 3% chance to show noise
            if Int.random(in: 0..<100) < 3 {
                let height = CGFloat.random(in: 2...5)
                let y = CGFloat.random(in: 0...28)
                let opacity = Double.random(in: 0.2...0.6)

                let noise = NoiseBar(y: y, height: height, opacity: opacity)
                noiseArtifacts = [noise]

                // Remove after brief display
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    noiseArtifacts = []
                }
            }
        }
    }
}

/// Scanline overlay effect for authentic CRT look
/// Alternating opacity lines for realistic cathode ray tube pattern
struct ScanlinesView: View {
    var body: some View {
        Canvas { context, size in
            let lineSpacing: CGFloat = 2

            var y: CGFloat = 0
            var alternate = false
            while y < size.height {
                let opacity: Double = alternate ? 0.31 : 0.19 // 0x50/255 and 0x30/255
                let rect = CGRect(x: 0, y: y, width: size.width, height: 1)
                context.fill(Path(rect), with: .color(.black.opacity(opacity)))
                y += lineSpacing
                alternate.toggle()
            }
        }
    }
}

// MARK: - Preview

struct CrtMarqueeView_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            CrtMarqueeView(
                text: ">>> You're looking at a fresh zero day drop from JSONBourne <<< TERMinator, a fresh new BBS terminal app for people who live their life 64K at a time. Greetings to all the crews still pushing pixels in 16 colors..."
            )

            Spacer()
        }
        .background(Color.black)
    }
}
