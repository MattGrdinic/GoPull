//
//  GForceTests.swift
//  GoPullTests
//

// CoreGraphics explicitly: MEMBER_IMPORT_VISIBILITY hides CGSize.width without
// it, even though the type itself resolves.
import CoreGraphics
import Foundation
import Testing
@testable import GoPull

struct GForceTests {

    /// Raw readings at 200 Hz, as the reader produces them.
    private func readings(_ triples: [(Double, Double, Double)], rate: Double = 200)
        -> [(time: Double, x: Double, y: Double, z: Double)] {
        triples.enumerated().map { index, v in
            (time: Double(index) / rate, x: v.0, y: v.1, z: v.2)
        }
    }

    // MARK: - Gravity

    /// A camera sitting still reads 1 g, not 0. Everything else depends on that
    /// being removed.
    @Test func aStationaryCameraReadsZero() {
        let still = readings(Array(repeating: (9.80665, 0, 0), count: 400))
        let track = GForceReader.track(from: still)
        #expect(track.samples.count == 400)
        for sample in track.samples {
            #expect(abs(sample.planar) < 0.01)
            #expect(abs(sample.vertical) < 0.01)
        }
    }

    /// Whichever way the camera is mounted, the average points at the ground,
    /// so this must hold for any axis carrying the 1 g.
    @Test func gravityIsRemovedWhicheverAxisItIsOn() {
        for axis in 0..<3 {
            var triple = (0.0, 0.0, 0.0)
            switch axis {
            case 0: triple = (-9.80665, 0, 0)
            case 1: triple = (0, 9.80665, 0)
            default: triple = (0, 0, -9.80665)
            }
            let track = GForceReader.track(from: readings(Array(repeating: triple, count: 400)))
            #expect(track.samples.allSatisfy { $0.total < 0.01 }, "axis \(axis)")
        }
    }

    /// A step in one axis shows up as real acceleration once gravity settles.
    @Test func aSustainedPushShowsUpThenFadesIntoGravity() {
        var values = Array(repeating: (9.80665, 0.0, 0.0), count: 200)
        values += Array(repeating: (9.80665, 0.0, -9.80665 / 2), count: 200)   // 0.5 g
        let track = GForceReader.track(from: readings(values), window: 1.0)
        // Just after the step, before the one-second average has caught up.
        let during = track.sample(at: 1.05)
        #expect(during != nil)
        #expect(during!.longitudinal > 0.15)
    }

    // MARK: - The track

    private func track(_ samples: [(t: Double, lat: Double, lon: Double)]) -> GForceTrack {
        var track = GForceTrack()
        track.samples = samples.map {
            GForceSample(time: $0.t, lateral: $0.lat, longitudinal: $0.lon, vertical: 0)
        }
        return track
    }

    @Test func planarIgnoresTheVerticalAxis() {
        let sample = GForceSample(time: 0, lateral: 3, longitudinal: 4, vertical: 12)
        #expect(abs(sample.planar - 5) < 0.0001)
        #expect(abs(sample.total - 13) < 0.0001)
    }

    @Test func readingsAreInterpolated() throws {
        let t = track([(0, 0, 0), (1, 1, 0)])
        let mid = try #require(t.sample(at: 0.5))
        #expect(abs(mid.lateral - 0.5) < 0.0001)
    }

    @Test func thereIsNoReadingOutsideTheTrack() {
        let t = track([(10, 0, 0), (20, 0, 0)])
        #expect(t.sample(at: 5) == nil)
        #expect(t.sample(at: 25) == nil)
        #expect(t.sample(at: 15) != nil)
    }

    @Test func anEmptyTrackAnswersSafely() {
        let empty = GForceTrack()
        #expect(empty.isEmpty)
        #expect(empty.sample(at: 1) == nil)
        #expect(empty.peakPlanar == 0)
        #expect(empty.smoothed(.default).isEmpty)
    }

    @Test func peakIsTheHardestPlanarMoment() {
        let t = track([(0, 0.1, 0), (1, 0, -0.9), (2, 0.2, 0.2)])
        #expect(abs(t.peakPlanar - 0.9) < 0.0001)
    }

    /// 200 Hz accelerometer is far too lively to read unsmoothed.
    @Test func smoothingCalmsTheSignal() {
        var samples: [(t: Double, lat: Double, lon: Double)] = []
        for i in 0..<200 {
            samples.append((Double(i) / 200, i % 2 == 0 ? 0.5 : -0.5, 0))
        }
        let raw = track(samples)
        let smooth = raw.smoothed(Smoothing(seconds: 0.2))
        let spread = { (t: GForceTrack) -> Double in
            let values = t.samples.map(\.lateral).dropFirst(50)
            return (values.max() ?? 0) - (values.min() ?? 0)
        }
        #expect(spread(smooth) < spread(raw) / 4)
    }

    // MARK: - Scale

    /// Scaling from the raw signal put full scale at 4 g on the strength of one
    /// bump, leaving the ball parked in the middle for the whole ride.
    @Test func fullScaleIsARoundNumberAboveThePeak() {
        #expect(GForceConfig.niceMaximum(above: 1.01) == 1.5)
        #expect(GForceConfig.niceMaximum(above: 0.3) == 0.5)
        #expect(GForceConfig.niceMaximum(above: 2.82) == 4.0)
        for peak in stride(from: 0.1, to: 3.5, by: 0.1) {
            #expect(GForceConfig.niceMaximum(above: peak) >= peak)
        }
    }

    @Test func anExplicitScaleWins() {
        var config = GForceConfig()
        config.maxG = 2.0
        var t = GForceTrack()
        t.samples = [GForceSample(time: 0, lateral: 0.2, longitudinal: 0, vertical: 0)]
        #expect(OverlayComposer.maxG(for: t, config: config) == 2.0)
    }

    // MARK: - Trail

    @Test func theTrailIsThinnedAndBounded() {
        var t = GForceTrack()
        t.samples = (0..<400).map {
            GForceSample(time: Double($0) / 200, lateral: 0, longitudinal: 0, vertical: 0)
        }
        let trail = OverlayComposer.trail(in: t, at: 2.0, seconds: 1.0)
        #expect(!trail.isEmpty)
        #expect(trail.count < 60)                       // thinned from ~200
        #expect(trail.allSatisfy { $0.time >= 1.0 && $0.time <= 2.0 })
    }

    @Test func noTrailWhenItIsTurnedOff() {
        var t = GForceTrack()
        t.samples = [GForceSample(time: 0, lateral: 0, longitudinal: 0, vertical: 0)]
        #expect(OverlayComposer.trail(in: t, at: 0, seconds: 0).isEmpty)
    }

    // MARK: - Settings

    @Test func theMeterIsOffByDefaultAndSavesWithThePreset() throws {
        var settings = OverlaySettings.defaults
        #expect(!settings.showsGForce)
        settings.showsGForce = true
        settings.apply(.hiTech)
        settings.gforce.trailSeconds = 2.5

        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(OverlaySettings.self, from: data)
        #expect(restored == settings)
        #expect(restored.gforce.preset == .hiTech)
        #expect(restored.gforce.trailSeconds == 2.5)
    }

    @Test func aPresetMovesAllThreeOverlays() {
        var settings = OverlaySettings.defaults
        settings.apply(.classic)
        #expect(settings.commonPreset == .classic)
        settings.gforce.apply(.minimal)
        #expect(settings.commonPreset == nil)
    }

    /// The readout needs a strip of its own, so the box is taller than wide.
    @Test func theMeterReservesRoomForItsReading() {
        var config = GForceConfig()
        config.placement = OverlayPlacement(x: 0.5, y: 0.5, scale: 0.2)
        let size = CGSize(width: 1920, height: 1080)

        config.showsReading = true
        let withReading = GForceRenderer.frame(in: size, config: config)
        #expect(withReading.height > withReading.width)

        config.showsReading = false
        let without = GForceRenderer.frame(in: size, config: config)
        #expect(abs(without.height - without.width) < 0.001)
    }
}
