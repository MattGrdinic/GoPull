//
//  GaugeTests.swift
//  GoPullTests
//

import CoreGraphics
import Foundation
import Testing
@testable import GoPull

struct GaugeTests {

    // MARK: - Scale

    /// A dial reading 0, 8, 15, 23 … is what happens without this; real
    /// speedometers are marked in round numbers.
    @Test func tickStepsLandOnRoundNumbers() {
        for maximum in [20.0, 30, 40, 60, 80, 100, 120, 160, 200] {
            let step = GaugeRenderer.tickStep(for: maximum)
            let majors = maximum / step
            #expect(majors >= 4 && majors <= 8, "\(maximum) gave \(majors) major ticks")
            #expect((maximum / step).rounded() == maximum / step,
                    "\(maximum) does not divide by \(step)")
        }
    }

    @Test func theDialAlwaysHasHeadroomAboveTheClip() {
        #expect(GaugeConfig.niceMaximum(above: 49.9) == 60)
        #expect(GaugeConfig.niceMaximum(above: 12) == 20)
        #expect(GaugeConfig.niceMaximum(above: 95) == 120)
        for top in stride(from: 5.0, to: 200, by: 5) {
            #expect(GaugeConfig.niceMaximum(above: top) >= top)
        }
    }

    // MARK: - Placement

    private let frame = CGSize(width: 1920, height: 1080)

    @Test func theGaugeSitsWhereItIsPlaced() {
        var config = GaugeConfig()
        config.placement = .corner(.bottomLeft, aspect: 1920.0 / 1080.0)
        let bottomLeft = GaugeRenderer.frame(in: frame, config: config)
        config.placement = .corner(.topRight, aspect: 1920.0 / 1080.0)
        let topRight = GaugeRenderer.frame(in: frame, config: config)

        #expect(bottomLeft.minX < frame.width / 2)
        #expect(bottomLeft.midY < frame.height / 2)   // CG: bottom is low y
        #expect(topRight.maxX > frame.width / 2)
        #expect(topRight.midY > frame.height / 2)
    }

    /// The gauge is free-placed, not snapped to a corner.
    @Test func theGaugeCanGoAnywhere() {
        var config = GaugeConfig()
        config.placement = OverlayPlacement(x: 0.33, y: 0.66, scale: 0.2)
        let rect = GaugeRenderer.frame(in: frame, config: config)
        #expect(abs(rect.midX - frame.width * 0.33) < 0.5)
        #expect(abs(rect.midY - frame.height * (1 - 0.66)) < 0.5)
    }

    @Test func theGaugeStaysInsideTheFrame() {
        for corner in OverlayCorner.allCases {
            for kind in GaugeKind.allCases {
                var config = GaugeConfig()
                config.placement = .corner(corner, aspect: 1920.0 / 1080.0)
                config.kind = kind
                let rect = GaugeRenderer.frame(in: frame, config: config)
                #expect(rect.minX >= 0 && rect.minY >= 0)
                #expect(rect.maxX <= frame.width && rect.maxY <= frame.height)
            }
        }
    }

    /// Sizes are fractions of the frame, so a gauge looks the same on 1080p
    /// and on the 8K these clips actually are.
    @Test func sizingIsRelativeToTheFrame() {
        var config = GaugeConfig()
        config.kind = .dial
        let hd = GaugeRenderer.frame(in: CGSize(width: 1920, height: 1080), config: config)
        let uhd = GaugeRenderer.frame(in: CGSize(width: 7680, height: 4320), config: config)
        #expect(abs(uhd.width / hd.width - 4) < 0.001)
    }

    // MARK: - Presets

    @Test func applyingAPresetKeepsPlacementAndUnits() {
        var config = GaugeConfig()
        config.unit = .kph
        config.placement = OverlayPlacement(x: 0.8, y: 0.2, scale: 0.3)
        config.smoothingSeconds = 1.5
        config.apply(.classic)

        #expect(config.preset == .classic)
        #expect(config.style == .preset(.classic))
        #expect(config.unit == .kph)
        #expect(config.placement == OverlayPlacement(x: 0.8, y: 0.2, scale: 0.3))
        #expect(config.smoothingSeconds == 1.5)
    }

    @Test func everyPresetIsDistinctAndDrawable() {
        let styles = GaugePreset.allCases.map { GaugeStyle.preset($0) }
        for style in styles {
            #expect(style.text.a > 0)                 // the reading must be visible
            #expect(!style.numberFont.isEmpty)
        }
        #expect(Set(GaugePreset.allCases.map(\.rawValue)).count == GaugePreset.allCases.count)
    }

    @Test func unitsConvertFromMetresPerSecond() {
        #expect(abs(SpeedUnit.mph.value(fromMetresPerSecond: 10) - 22.369) < 0.001)
        #expect(abs(SpeedUnit.kph.value(fromMetresPerSecond: 10) - 36) < 0.001)
    }

    // MARK: - Smoothing

    private func jitteryTrack() -> TelemetryTrack {
        var track = TelemetryTrack()
        // 10 Hz, a steady 20 m/s with alternating +/-1 m/s of noise.
        track.samples = (0..<100).map { i in
            GPSSample(latitude: 32, longitude: -111, altitude: 700,
                      speed2D: 20 + (i % 2 == 0 ? 1 : -1),
                      speed3D: 20, time: Double(i) / 10, timestamp: nil,
                      dop: 2, fix: 3)
        }
        return track
    }

    @Test func smoothingCutsTheJitter() {
        let raw = jitteryTrack()
        let smooth = raw.smoothed(.default)

        func meanStep(_ track: TelemetryTrack) -> Double {
            let s = track.samples.map(\.speed2D)
            return zip(s, s.dropFirst()).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(s.count - 1)
        }
        #expect(meanStep(smooth) < meanStep(raw) / 2)
    }

    @Test func aWiderWindowSmoothsMore() {
        let raw = jitteryTrack()
        func spread(_ t: TelemetryTrack) -> Double {
            let s = t.samples.map(\.speed2D).dropFirst(20)   // past the ramp-up
            return (s.max() ?? 0) - (s.min() ?? 0)
        }
        #expect(spread(raw.smoothed(.heavy)) < spread(raw.smoothed(.default)))
        #expect(spread(raw.smoothed(.default)) < spread(raw.smoothed(.none)))
    }

    @Test func smoothingOffChangesNothing() {
        let raw = jitteryTrack()
        #expect(raw.smoothed(.none).samples.map(\.speed2D) == raw.samples.map(\.speed2D))
    }

    /// Averaging positions would round off real corners on a map trace.
    @Test func smoothingLeavesPositionsAlone() {
        var raw = jitteryTrack()
        for i in raw.samples.indices { raw.samples[i].latitude = 32 + Double(i) / 1000 }
        let smooth = raw.smoothed(.heavy)
        #expect(smooth.samples.map(\.latitude) == raw.samples.map(\.latitude))
    }

    /// The window is trailing: a gauge cannot average readings that have not
    /// happened yet without lagging by the whole window.
    @Test func smoothingNeverReadsAhead() {
        var track = TelemetryTrack()
        track.samples = (0..<40).map { i in
            GPSSample(latitude: 32, longitude: -111, altitude: 700,
                      speed2D: i < 20 ? 0 : 100, speed3D: 0,
                      time: Double(i) / 10, timestamp: nil, dop: 2, fix: 3)
        }
        let smooth = track.smoothed(Smoothing(seconds: 1.0))
        // Everything before the step must still read zero.
        for sample in smooth.samples where sample.time < 2.0 {
            #expect(sample.speed2D == 0)
        }
    }

    @Test func smoothingSurvivesAnEmptyTrack() {
        #expect(TelemetryTrack().smoothed(.default).samples.isEmpty)
    }
}
