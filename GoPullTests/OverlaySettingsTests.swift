//
//  OverlaySettingsTests.swift
//  GoPullTests
//

import CoreGraphics
import Foundation
import Testing
@testable import GoPull

struct OverlaySettingsTests {

    /// A tuned look has to survive a restart, so the whole thing round-trips.
    @Test func settingsSurviveEncoding() throws {
        var settings = OverlaySettings.defaults
        settings.apply(.hiTech)
        settings.gauge.kind = .bar
        settings.gauge.unit = .kph
        settings.gauge.placement = OverlayPlacement(x: 0.31, y: 0.72, scale: 0.19)
        settings.gauge.smoothingSeconds = 1.25
        settings.map.mode = .follow
        settings.map.followSpan = 750
        settings.map.style.feather = 0.55
        settings.showsMap = false

        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(OverlaySettings.self, from: data)
        #expect(restored == settings)
    }

    /// A preset names a look for the whole overlay, not for the dial alone.
    @Test func aPresetMovesBothOverlaysTogether() {
        var settings = OverlaySettings.defaults
        settings.apply(.classic)
        #expect(settings.gauge.preset == .classic)
        #expect(settings.map.preset == .classic)
        #expect(settings.commonPreset == .classic)
    }

    /// Mixing them is allowed; the picker just has nothing to highlight.
    @Test func aMixedLookHasNoCommonPreset() {
        var settings = OverlaySettings.defaults
        settings.gauge.apply(.classic)
        settings.map.apply(.hiTech)
        #expect(settings.commonPreset == nil)
    }

    @Test func defaultsPutTheTwoOverlaysInDifferentCorners() {
        let settings = OverlaySettings.defaults
        let size = CGSize(width: 1920, height: 1080)
        let gauge = GaugeRenderer.frame(in: size, config: settings.gauge)
        let map = MapRenderer.frame(in: size, config: settings.map)
        #expect(!gauge.intersects(map))
    }

    // MARK: - Progress along the route

    private func points(_ times: [Double]) -> [GPSSample] {
        times.map {
            GPSSample(latitude: 32, longitude: -111, altitude: 700, speed2D: 10,
                      speed3D: 10, time: $0, timestamp: nil, dop: 2, fix: 3)
        }
    }

    /// Fractional on purpose: a whole-number index makes the marker hop between
    /// 10 Hz fixes, which is visible at 30 fps.
    @Test func progressIsFractionalBetweenFixes() {
        let route = points([0, 1, 2, 3])
        #expect(abs(OverlayComposer.progress(in: route, at: 1.5) - 1.5) < 0.0001)
        #expect(abs(OverlayComposer.progress(in: route, at: 2.25) - 2.25) < 0.0001)
    }

    @Test func progressClampsToTheEnds() {
        let route = points([10, 11, 12])
        #expect(OverlayComposer.progress(in: route, at: 0) == 0)
        #expect(OverlayComposer.progress(in: route, at: 99) == 2)
    }

    @Test func progressHandlesADegenerateRoute() {
        #expect(OverlayComposer.progress(in: [], at: 5) == 0)
        #expect(OverlayComposer.progress(in: points([1]), at: 5) == 0)
    }

    /// Uneven gaps happen when fixes drop out; the marker must still be placed
    /// proportionally rather than jumping a whole segment.
    @Test func progressRespectsUnevenGaps() {
        let route = points([0, 1, 11])
        #expect(abs(OverlayComposer.progress(in: route, at: 6) - 1.5) < 0.0001)
    }

    // MARK: - Composing

    @Test func composingWithNoFixDrawsNothingAndDoesNotCrash() {
        let ctx = CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        OverlayComposer.draw(in: ctx, frameSize: CGSize(width: 320, height: 180),
                             track: TelemetryTrack(), at: 5,
                             settings: .defaults, maxSpeed: 60)
    }

    @Test func theDialTopComesFromTheClip() {
        var track = TelemetryTrack()
        track.samples = points([0, 1]).enumerated().map { index, sample in
            var copy = sample
            copy.speed2D = index == 0 ? 10 : 22.3   // ~50 mph
            return copy
        }
        #expect(OverlayComposer.maxSpeed(for: track, unit: .mph) == 60)
        #expect(OverlayComposer.maxSpeed(for: track, unit: .kph) == 100)
    }
}

struct SettingsMigrationTests {

    /// Adding an overlay used to make every previously saved look fail to
    /// decode and revert to the defaults, silently.
    @Test func settingsSavedBeforeAFieldExistedStillLoad() throws {
        var full = OverlaySettings.defaults
        full.apply(.classic)
        full.gauge.unit = .kph
        full.gauge.placement = OverlayPlacement(x: 0.2, y: 0.8, scale: 0.3)
        full.gauge.smoothingSeconds = 1.25

        // Strip the newest sections, as older data would not have them.
        let data = try JSONEncoder().encode(full)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["showsGForce", "gforce", "showsAcceleration", "acceleration"] {
            object.removeValue(forKey: key)
        }
        let older = try JSONSerialization.data(withJSONObject: object)

        let loaded = OverlaySettings.loadMerging(older)
        // What was saved survives…
        #expect(loaded.gauge.preset == .classic)
        #expect(loaded.gauge.unit == .kph)
        #expect(loaded.gauge.smoothingSeconds == 1.25)
        #expect(loaded.gauge.placement.x == 0.2)
        // …and what is new arrives at its default rather than failing.
        #expect(loaded.showsGForce == OverlaySettings.defaults.showsGForce)
        #expect(loaded.acceleration.detection.targets
                == OverlaySettings.defaults.acceleration.detection.targets)
    }

    /// A field missing from deep inside a nested value is filled in too.
    @Test func aMissingNestedFieldIsFilledIn() throws {
        var full = OverlaySettings.defaults
        full.gforce.trailSeconds = 3.0
        let data = try JSONEncoder().encode(full)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        if var gforce = object["gforce"] as? [String: Any] {
            gforce.removeValue(forKey: "showsPeakMarks")
            gforce.removeValue(forKey: "showsPeakFigures")
            object["gforce"] = gforce
        }
        let older = try JSONSerialization.data(withJSONObject: object)

        let loaded = OverlaySettings.loadMerging(older)
        #expect(loaded.gforce.trailSeconds == 3.0)          // kept
        #expect(!loaded.gforce.showsPeakMarks)              // defaulted
    }

    @Test func currentSettingsRoundTripUnchanged() throws {
        var settings = OverlaySettings.defaults
        settings.apply(.hiTech)
        settings.showsGForce = true
        settings.gforce.showsPeakMarks = true
        let data = try JSONEncoder().encode(settings)
        #expect(OverlaySettings.loadMerging(data) == settings)
    }

    @Test func rubbishFallsBackToTheDefaults() {
        #expect(OverlaySettings.loadMerging(Data("not json".utf8)) == .defaults)
        #expect(OverlaySettings.loadMerging(Data()) == .defaults)
    }
}
