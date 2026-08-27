//
//  AccelerationTests.swift
//  GoPullTests
//

import CoreGraphics
import Foundation
import Testing
@testable import GoPull

struct AccelerationTests {

    /// A track from a speed profile in mph, sampled at 10 Hz like the camera.
    private func track(_ mph: [Double], rate: Double = 10) -> TelemetryTrack {
        var track = TelemetryTrack()
        track.samples = mph.enumerated().map { index, v in
            GPSSample(latitude: 32, longitude: -111, altitude: 700,
                      speed2D: v / 2.236936, speed3D: v / 2.236936,
                      time: Double(index) / rate, timestamp: nil, dop: 2, fix: 3)
        }
        return track
    }

    /// Stationary, then a clean pull to `top` over `seconds`.
    private func launch(rest: Double, seconds: Double, top: Double) -> [Double] {
        var values = [Double](repeating: 0, count: Int(rest * 10))
        let steps = Int(seconds * 10)
        for i in 0...steps { values.append(top * Double(i) / Double(steps)) }
        values += [Double](repeating: top, count: 30)
        return values
    }

    // MARK: - Detection

    @Test func aCleanLaunchIsFound() throws {
        let runs = AccelerationDetector.runs(in: track(launch(rest: 3, seconds: 10, top: 60)),
                                             settings: .init())
        #expect(runs.count == 1)
        let run = try #require(runs.first)
        #expect(run.splits[30] != nil)
        #expect(run.splits[60] != nil)
        // Linear ramp to 60 in 10s: 30 mph lands at half of it.
        #expect(abs(run.splits[30]! - 5) < 0.4)
        #expect(abs(run.splits[60]! - 10) < 0.4)
    }

    /// Speed hovers around zero, and one noisy sample above the threshold is
    /// not a launch — that made a whole clip look like a single 45-second run.
    @Test func aSingleNoisySampleIsNotALaunch() {
        var values = [Double](repeating: 0.2, count: 100)
        values[40] = 4.0                                    // one spike
        values += [Double](repeating: 0.2, count: 100)
        #expect(AccelerationDetector.runs(in: track(values), settings: .init()).isEmpty)
    }

    /// Pulling away gently and reaching 10 mph twenty seconds later is not a
    /// standing start; reporting it as one buries the real runs.
    @Test func aPotterIsNotALaunch() {
        var settings = AccelerationSettings()
        settings.targets = [10]
        let potter = launch(rest: 3, seconds: 22, top: 12)
        #expect(AccelerationDetector.runs(in: track(potter), settings: settings).isEmpty)

        let real = launch(rest: 3, seconds: 4, top: 12)
        #expect(AccelerationDetector.runs(in: track(real), settings: settings).count == 1)
    }

    @Test func aClipThatNeverStopsHasNoLaunches() {
        let cruising = [Double](repeating: 30, count: 300)
        #expect(AccelerationDetector.runs(in: track(cruising), settings: .init()).isEmpty)
    }

    @Test func twoLaunchesAreFoundSeparately() {
        var settings = AccelerationSettings()
        settings.targets = [30]
        let values = launch(rest: 3, seconds: 5, top: 40)
            + [Double](repeating: 0, count: 40)
            + launch(rest: 2, seconds: 4, top: 40)
        let runs = AccelerationDetector.runs(in: track(values), settings: settings)
        #expect(runs.count == 2)
        #expect(runs[0].start < runs[1].start)
    }

    /// A target the run never reached must not appear at all.
    @Test func unreachedTargetsAreAbsent() throws {
        var settings = AccelerationSettings()
        settings.targets = [30, 60, 100]
        let runs = AccelerationDetector.runs(in: track(launch(rest: 3, seconds: 6, top: 45)),
                                             settings: settings)
        let run = try #require(runs.first)
        #expect(run.splits[30] != nil)
        #expect(run.splits[60] == nil)
        #expect(run.splits[100] == nil)
        #expect(run.reached == [30])
    }

    // MARK: - The accelerometer start

    /// GPS speed leaves zero slowly; the accelerometer sees the push at 200 Hz.
    @Test func theAccelerometerMovesTheStartEarlier() throws {
        let speeds = launch(rest: 3, seconds: 8, top: 60)
        var gforce = GForceTrack()
        // A push beginning slightly before GPS speed clears the rest threshold.
        gforce.samples = (0..<(200 * 12)).map { i in
            let t = Double(i) / 200
            return GForceSample(time: t, lateral: 0,
                                longitudinal: t >= 2.8 ? 0.25 : 0, vertical: 0)
        }
        let withAccel = AccelerationDetector.runs(in: track(speeds), gforce: gforce,
                                                  settings: .init())
        let without = AccelerationDetector.runs(in: track(speeds), gforce: nil,
                                                settings: .init())
        let a = try #require(withAccel.first), b = try #require(without.first)
        #expect(a.start <= b.start)
        #expect(a.splits[30]! >= b.splits[30]!)     // an earlier start means a longer time
    }

    // MARK: - Comparison

    @Test func theBestRunToATargetIsFound() {
        var slow = AccelerationRun(start: 0); slow.splits = [60: 5.2]
        var quick = AccelerationRun(start: 100); quick.splits = [60: 4.4]
        var short = AccelerationRun(start: 200); short.splits = [30: 2.0]
        let runs = [slow, quick, short]
        #expect(runs.best(to: 60)?.start == 100)
        #expect(runs.best(to: 30)?.start == 200)
        #expect(runs.best(to: 100) == nil)
    }

    @Test func theRunCoveringAMomentIsFound() {
        var first = AccelerationRun(start: 10); first.end = 20
        var second = AccelerationRun(start: 100); second.end = 110
        let runs = [first, second]
        #expect(runs.run(at: 15)?.start == 10)
        #expect(runs.run(at: 105)?.start == 100)
        #expect(runs.run(at: 60) == nil)
        // The result stays up for a few seconds after the run ends.
        #expect(runs.run(at: 22)?.start == 10)
    }

    // MARK: - Settings

    @Test func settingsSurviveEncoding() throws {
        var settings = OverlaySettings.defaults
        settings.showsAcceleration = true
        settings.acceleration.detection = .porsche
        settings.acceleration.holdSeconds = 9
        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(OverlaySettings.self, from: data)
        #expect(restored == settings)
        #expect(restored.acceleration.detection.targets == [30, 60, 100])
    }

    @Test func aPresetMovesAllFourOverlays() {
        var settings = OverlaySettings.defaults
        settings.apply(.hiTech)
        #expect(settings.commonPreset == .hiTech)
        settings.acceleration.apply(.classic)
        #expect(settings.commonPreset == nil)
    }

    @Test func theBadgeGrowsWithItsTargets() {
        var config = AccelerationConfig()
        config.placement = OverlayPlacement(x: 0.5, y: 0.5, scale: 0.2)
        let size = CGSize(width: 1920, height: 1080)
        config.detection.targets = [30]
        let two = AccelerationRenderer.frame(in: size, config: config)
        config.detection.targets = [30, 60, 100]
        let four = AccelerationRenderer.frame(in: size, config: config)
        #expect(four.height > two.height)
    }
}

struct GForceExtremesTests {

    private func track(_ pairs: [(Double, Double)]) -> GForceTrack {
        var track = GForceTrack()
        track.samples = pairs.enumerated().map { index, v in
            GForceSample(time: Double(index) / 200, lateral: v.0,
                         longitudinal: v.1, vertical: 0)
        }
        return track
    }

    /// Per direction, not per axis: "0.51 right, 0.42 left" says something that
    /// "0.51 lateral" does not.
    @Test func peaksAreKeptPerDirection() {
        let extremes = track([(0.5, 0.3), (-0.2, -0.9), (0.1, 0.1)]).extremes
        #expect(abs(extremes.right - 0.5) < 0.0001)
        #expect(abs(extremes.left - 0.2) < 0.0001)
        #expect(abs(extremes.accelerating - 0.3) < 0.0001)
        #expect(abs(extremes.braking - 0.9) < 0.0001)
    }

    @Test func anEmptyTrackHasNoPeaks() {
        #expect(GForceTrack().extremes.isEmpty)
    }

    @Test func aOneSidedTrackReportsOnlyThatSide() {
        let extremes = track([(0.4, 0.2), (0.3, 0.1)]).extremes
        #expect(extremes.left == 0)
        #expect(extremes.braking == 0)
        #expect(!extremes.isEmpty)
    }
}
