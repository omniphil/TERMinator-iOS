import SwiftUI

/// Transparent overlay that renders a real-time audio visualizer on top
/// of the terminal. Supports "bars" (16-band EQ), "scope" (multi-trace
/// oscilloscope), "fire" (demoscene fire), and "starfield" modes.
///
/// Uses SwiftUI Canvas + TimelineView for ~30fps rendering.
/// All drawing snaps to a virtual VGA pixel grid for an authentic chunky
/// retro look (except scope, which uses anti-aliased lines).
struct VisualizerOverlayView: View {

    let audioAnalyzer: AudioAnalyzer
    let row: Double
    let col: Double
    let cellsWide: Double
    let cellsHigh: Double
    let style: String
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let panOffsetX: CGFloat
    let panOffsetY: CGFloat

    fileprivate static let numBands = 16
    fileprivate static let fireW = 64
    fileprivate static let fireH = 32
    fileprivate static let fireCooling: Float = 1.0
    fileprivate static let numStars = 80
    fileprivate static let starBaseSpeed: Float = 0.015
    fileprivate static let starAudioSpeed: Float = 0.8

    // Mutable state wrapped in a class for Canvas rendering
    @StateObject private var state = VisualizerState()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                // Reference timeline.date so SwiftUI knows Canvas must redraw each tick
                let _ = timeline.date.timeIntervalSinceReferenceDate

                guard cellWidth > 0 && cellHeight > 0 else { return }

                let pixelLeft = CGFloat(col - 1) * cellWidth + panOffsetX
                let pixelTop = CGFloat(row - 1) * cellHeight + panOffsetY
                let pixelWidth = CGFloat(cellsWide) * cellWidth
                let pixelHeight = CGFloat(cellsHigh) * cellHeight

                // Clipping
                if pixelLeft + pixelWidth < 0 || pixelLeft > size.width ||
                   pixelTop + pixelHeight < 0 || pixelTop > size.height {
                    return
                }

                // Semi-transparent background
                let bgRect = CGRect(x: pixelLeft, y: pixelTop, width: pixelWidth, height: pixelHeight)
                context.fill(Path(bgRect), with: .color(.black.opacity(0.63)))

                let lowerStyle = style.lowercased()
                switch lowerStyle {
                case "scope":
                    drawScope(context: &context, left: pixelLeft, top: pixelTop,
                              areaWidth: pixelWidth, areaHeight: pixelHeight)
                case "fire":
                    drawFire(context: &context, left: pixelLeft, top: pixelTop,
                             areaWidth: pixelWidth, areaHeight: pixelHeight)
                case "starfield":
                    drawStarfield(context: &context, left: pixelLeft, top: pixelTop,
                                  areaWidth: pixelWidth, areaHeight: pixelHeight)
                default:
                    drawBars(context: &context, left: pixelLeft, top: pixelTop,
                             areaWidth: pixelWidth, areaHeight: pixelHeight)
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Bars

    private func drawBars(context: inout GraphicsContext, left: CGFloat, top: CGFloat,
                          areaWidth: CGFloat, areaHeight: CGFloat) {
        let bands = audioAnalyzer.getBands()
        guard bands.count >= Self.numBands else { return }

        let maxSegs = 12
        let blockH = max(areaHeight / CGFloat(maxSegs + 2), 2)
        let blockW = max(areaWidth / 48, 2)
        let gap = blockW
        let barWidth = max((areaWidth - gap * CGFloat(Self.numBands + 1)) / CGFloat(Self.numBands), blockW)

        let totalBarsWidth = barWidth * CGFloat(Self.numBands) + gap * CGFloat(Self.numBands - 1)
        let startX = left + (areaWidth - totalBarsWidth) / 2

        let pad = blockH
        let maxBarHeight = areaHeight - pad * 2
        let bottomY = top + areaHeight - pad

        for i in 0..<Self.numBands {
            let level = CGFloat(max(0, min(1, bands[i])))
            let barHeight = level * maxBarHeight
            if barHeight <= 0 { continue }

            let barLeft = startX + CGFloat(i) * (barWidth + gap)
            let numSegs = max(Int(barHeight / blockH), 1)
            let segGap = max(blockH * 0.15, 1)

            for s in 0..<numSegs {
                let segBottom = bottomY - CGFloat(s) * blockH
                let segTop = segBottom - blockH + segGap
                let ratio = CGFloat(s) / CGFloat(maxSegs)

                let color: Color
                if ratio < 0.5 {
                    let t = ratio * 2
                    color = Color(
                        red: Double(t),
                        green: Double(200 + 55 * (1 - t)) / 255.0,
                        blue: 0
                    )
                } else {
                    let t = (ratio - 0.5) * 2
                    color = Color(
                        red: 1.0,
                        green: Double(1 - t),
                        blue: 0
                    )
                }

                let rect = CGRect(x: barLeft, y: segTop, width: barWidth, height: blockH - segGap)
                context.fill(Path(rect), with: .color(color))
            }
        }
    }

    // MARK: - Scope

    private func drawScope(context: inout GraphicsContext, left: CGFloat, top: CGFloat,
                           areaWidth: CGFloat, areaHeight: CGFloat) {
        let bands = audioAnalyzer.getBands()
        guard bands.count >= Self.numBands else { return }

        let amplitude = areaHeight / 2 * 0.9
        let offsets: [CGFloat] = [-0.15, -0.05, 0.05, 0.15]
        let colors: [Color] = [
            Color(red: 1.0, green: 100.0/255, blue: 30.0/255),    // red-orange
            Color(red: 1.0, green: 220.0/255, blue: 50.0/255),    // yellow
            Color(red: 50.0/255, green: 220.0/255, blue: 50.0/255), // green
            Color(red: 50.0/255, green: 200.0/255, blue: 1.0)      // cyan
        ]
        let lineWidths: [CGFloat] = [4, 3, 3, 2]
        let phaseSpeeds: [Float] = [0.08, 0.12, 0.18, 0.25]
        let scopeCycles: [[Float]] = [
            [1.0, 1.5, 2.0, 2.7],
            [3.0, 4.2, 5.5, 6.8],
            [8.0, 10.0, 12.5, 15.0],
            [17.0, 21.0, 26.0, 32.0]
        ]

        let numPoints = 128
        let step = areaWidth / CGFloat(max(numPoints - 1, 1))
        let twoPi = Float.pi * 2

        for t in 0..<4 {
            let bandStart = t * 4
            let b0 = bands[bandStart]
            let b1 = bands[bandStart + 1]
            let b2 = bands[bandStart + 2]
            let b3 = bands[bandStart + 3]
            let groupEnergy = (b0 + b1 + b2 + b3) / 4

            state.scopePhase[t] += phaseSpeeds[t] + groupEnergy * 0.4
            let phase = state.scopePhase[t]
            let cycles = scopeCycles[t]
            let traceMidY = top + areaHeight / 2 + offsets[t] * areaHeight

            var path = Path()
            for i in 0..<numPoints {
                let frac = Float(i) / Float(numPoints)
                let x = left + CGFloat(i) * step
                let synth = b0 * sin(frac * cycles[0] * twoPi + phase) +
                            b1 * sin(frac * cycles[1] * twoPi + phase * 1.3) +
                            b2 * sin(frac * cycles[2] * twoPi + phase * 0.7) +
                            b3 * sin(frac * cycles[3] * twoPi + phase * 1.6)
                let y = traceMidY - CGFloat(synth) * amplitude

                if i == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }

            context.stroke(path, with: .color(colors[t]),
                          style: StrokeStyle(lineWidth: lineWidths[t], lineCap: .round, lineJoin: .round))
        }
    }

    // MARK: - Fire

    private func drawFire(context: inout GraphicsContext, left: CGFloat, top: CGFloat,
                          areaWidth: CGFloat, areaHeight: CGFloat) {
        let bands = audioAnalyzer.getBands()

        // Seed bottom three rows
        for row in (Self.fireH - 3)..<Self.fireH {
            let energyScale: Float = row == Self.fireH - 1 ? 320 : (row == Self.fireH - 2 ? 260 : 200)
            let jitterRange: Float = row == Self.fireH - 1 ? 40 : 30
            for x in 0..<Self.fireW {
                let bandIdx = min(x * Self.numBands / Self.fireW, Self.numBands - 1)
                let energy = bands.count > bandIdx ? bands[bandIdx] : 0
                let jitter = Float.random(in: -jitterRange...jitterRange)
                state.fireHeat[row * Self.fireW + x] = max(0, min(255, energy * energyScale + jitter))
            }
        }

        // Propagate fire upward
        for y in 0..<(Self.fireH - 2) {
            for x in 0..<Self.fireW {
                let xl = max(x - 1, 0)
                let xr = min(x + 1, Self.fireW - 1)
                let below = state.fireHeat[(y + 2) * Self.fireW + x]
                let belowL = state.fireHeat[(y + 2) * Self.fireW + xl]
                let belowR = state.fireHeat[(y + 2) * Self.fireW + xr]
                let mid = state.fireHeat[(y + 1) * Self.fireW + x]
                state.fireHeat[y * Self.fireW + x] = max(0, (below + belowL + belowR + mid) / 4 - Self.fireCooling)
            }
        }

        // Render
        let cellW = areaWidth / CGFloat(Self.fireW)
        let cellH = areaHeight / CGFloat(Self.fireH)

        for y in 0..<Self.fireH {
            for x in 0..<Self.fireW {
                let heat = Int(max(0, min(255, state.fireHeat[y * Self.fireW + x])))
                if heat <= 2 { continue }

                let color = state.firePalette[heat]
                let px = left + CGFloat(x) * cellW
                let py = top + CGFloat(y) * cellH
                let rect = CGRect(x: px, y: py, width: cellW + 0.5, height: cellH + 0.5)
                context.fill(Path(rect), with: .color(color))
            }
        }
    }

    // MARK: - Starfield

    private func drawStarfield(context: inout GraphicsContext, left: CGFloat, top: CGFloat,
                               areaWidth: CGFloat, areaHeight: CGFloat) {
        let bands = audioAnalyzer.getBands()

        // Per-range energy levels
        let bassEnergy: Float
        if bands.count >= 4 {
            bassEnergy = (bands[0] + bands[1] + bands[2] + bands[3]) / 4
        } else { bassEnergy = 0 }

        let midEnergy: Float
        if bands.count >= 12 {
            var s: Float = 0
            for i in 4...11 { s += bands[i] }
            midEnergy = s / 8
        } else { midEnergy = 0 }

        let trebleEnergy: Float
        if bands.count >= 16 {
            trebleEnergy = (bands[12] + bands[13] + bands[14] + bands[15]) / 4
        } else { trebleEnergy = 0 }

        let bandEnergies: [Float] = [bassEnergy, midEnergy, trebleEnergy]

        let centerX = left + areaWidth / 2
        let centerY = top + areaHeight / 2
        let halfW = areaWidth / 2
        let halfH = areaHeight / 2

        for star in state.stars {
            let energy = bandEnergies[star.band]
            let speedMult = Self.starBaseSpeed + energy * Self.starAudioSpeed

            let dist = max(sqrt(star.x * star.x + star.y * star.y), 0.001)
            let dirX = star.x / dist
            let dirY = star.y / dist

            let push = speedMult * star.speed * 0.01
            star.x += dirX * push + star.x * speedMult * star.speed
            star.y += dirY * push + star.y * speedMult * star.speed
            star.z = min(star.z + speedMult * star.speed * 0.5, 1)

            let screenX = centerX + CGFloat(star.x) * halfW
            let screenY = centerY + CGFloat(star.y) * halfH

            // Respawn if outside
            if screenX < left - 5 || screenX > left + areaWidth + 5 ||
               screenY < top - 5 || screenY > top + areaHeight + 5 {
                let angle = Float.random(in: 0...(Float.pi * 2))
                star.x = cos(angle) * 0.02
                star.y = sin(angle) * 0.02
                star.z = 0
                star.speed = 0.3 + Float.random(in: 0...0.7)
                star.band = Int.random(in: 0...2)
                star.color = VisualizerState.Star.randomColor(band: star.band)
            }

            let size = CGFloat((0.8 + star.z * 1.2) * (0.5 + energy * 1.5))
            let brightness = (0.35 + energy * 0.65) * (0.5 + star.z * 0.5)
            let baseR = star.color.r
            let baseG = star.color.g
            let baseB = star.color.b
            let r = Double(min(max(baseR * brightness, 0), 1))
            let g = Double(min(max(baseG * brightness, 0), 1))
            let b = Double(min(max(baseB * brightness, 0), 1))
            let starColor = Color(red: r, green: g, blue: b)

            // Trail
            let sdirX = screenX - centerX
            let sdirY = screenY - centerY
            let sdist = sqrt(sdirX * sdirX + sdirY * sdirY)
            if sdist > 1 {
                let ndirX = sdirX / sdist
                let ndirY = sdirY / sdist
                let trailLen = CGFloat((4 + star.z * 16) * (0.5 + energy * 4))
                let tailX = screenX - ndirX * trailLen
                let tailY = screenY - ndirY * trailLen

                let tailColor = Color(red: r, green: g, blue: b).opacity(0.24)
                let gradient = Gradient(colors: [tailColor, starColor])
                var trailPath = Path()
                trailPath.move(to: CGPoint(x: tailX, y: tailY))
                trailPath.addLine(to: CGPoint(x: screenX, y: screenY))

                context.stroke(trailPath,
                              with: .linearGradient(gradient,
                                                    startPoint: CGPoint(x: tailX, y: tailY),
                                                    endPoint: CGPoint(x: screenX, y: screenY)),
                              style: StrokeStyle(lineWidth: max(size * 0.5, 1.5), lineCap: .round))
            }

            // Star head
            let rect = CGRect(x: screenX - size / 2, y: screenY - size / 2, width: size, height: size)
            context.fill(Path(rect), with: .color(starColor))
        }
    }
}

// MARK: - Mutable State (class for reference semantics in Canvas)

private class VisualizerState: ObservableObject {

    class Star {
        var x: Float
        var y: Float
        var z: Float
        var speed: Float
        var color: (r: Float, g: Float, b: Float)
        var band: Int

        init(scattered: Bool) {
            let angle = Float.random(in: 0...(Float.pi * 2))
            let dist: Float = scattered ? 0.05 + Float.random(in: 0...0.75) : 0.02
            band = Int.random(in: 0...2)
            color = Star.randomColor(band: band)
            x = cos(angle) * dist
            y = sin(angle) * dist
            z = scattered ? Float.random(in: 0...1) : 0
            speed = 0.3 + Float.random(in: 0...0.7)
        }

        static func randomColor(band: Int) -> (r: Float, g: Float, b: Float) {
            switch band {
            case 0:
                return (1.0, Float.random(in: 80...160) / 255, Float.random(in: 20...60) / 255)
            case 1:
                return (Float.random(in: 50...100) / 255, Float.random(in: 200...255) / 255, Float.random(in: 50...100) / 255)
            default:
                return (Float.random(in: 50...100) / 255, Float.random(in: 180...255) / 255, 1.0)
            }
        }
    }

    var scopePhase: [Float] = [0, 0, 0, 0]
    var fireHeat: [Float]
    var stars: [Star]
    let firePalette: [Color]

    init() {
        fireHeat = [Float](repeating: 0, count: VisualizerOverlayView.fireW * VisualizerOverlayView.fireH)
        stars = (0..<VisualizerOverlayView.numStars).map { _ in Star(scattered: true) }

        // Build fire palette: black -> dark red -> red -> orange -> yellow -> white
        var palette = [Color](repeating: .black, count: 256)
        for i in 0..<256 {
            let r: Int
            let g: Int
            let b: Int
            switch i {
            case 0..<64:
                r = i * 4; g = 0; b = 0
            case 64..<128:
                r = 255; g = (i - 64) * 3; b = 0
            case 128..<192:
                r = 255; g = 192 + (i - 128); b = 0
            default:
                r = 255; g = 255; b = (i - 192) * 4
            }
            palette[i] = Color(
                red: Double(min(max(r, 0), 255)) / 255,
                green: Double(min(max(g, 0), 255)) / 255,
                blue: Double(min(max(b, 0), 255)) / 255
            )
        }
        firePalette = palette
    }
}
