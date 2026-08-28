//
//  TelemetrySummaryTests.swift
//  GoPullTests
//

import Foundation
import Testing
@testable import GoPull

struct TelemetrySummaryTests {

    /// The point of the summary: knowing before an 11 GB copy.
    @Test func aClipWithNothingSaysSo() {
        let summary = TelemetrySummary()
        #expect(summary.isEmpty)
        #expect(summary.caption(unit: .mph) == "No telemetry in this clip.")
    }

    @Test func aClipWithFixesDescribesItself() {
        var summary = TelemetrySummary()
        summary.hasFix = true
        summary.coverage = 0.82
        summary.distance = 3_480
        summary.topSpeed = 22.3
        let caption = summary.caption(unit: .mph)
        #expect(caption.contains("GPS 82%"))
        #expect(caption.contains("3.5 km"))
        #expect(caption.contains("50 mph"))
    }

    /// A clip that only found the sky halfway through should say so rather than
    /// claiming a clean track.
    @Test func partialCoverageIsReported() {
        var summary = TelemetrySummary()
        summary.hasFix = true
        summary.coverage = 0.41
        #expect(summary.caption(unit: .mph).contains("GPS 41%"))
    }

    @Test func accelerometerWithoutGPSStillCounts() {
        var summary = TelemetrySummary()
        summary.hasGForce = true
        summary.peakG = 0.45
        #expect(!summary.isEmpty)
        let caption = summary.caption(unit: .mph)
        #expect(caption.contains("no GPS fix"))
        #expect(caption.contains("0.45 g"))
    }

    @Test func launchesArePluralisedProperly() {
        var one = TelemetrySummary(); one.hasFix = true; one.launches = 1
        var two = TelemetrySummary(); two.hasFix = true; two.launches = 2
        #expect(one.caption(unit: .mph).contains("1 standing start"))
        #expect(two.caption(unit: .mph).contains("2 standing starts"))
    }

    @Test func theUnitIsHonoured() {
        var summary = TelemetrySummary()
        summary.hasFix = true
        summary.topSpeed = 27.78          // 100 km/h
        #expect(summary.caption(unit: .kph).contains("100 km/h"))
        #expect(summary.caption(unit: .mph).contains("62 mph"))
    }

    /// Rubbish in must not crash the probe — it runs over whatever the camera
    /// hands back.
    @Test func probingSomethingThatIsNotTelemetryIsSafe() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gopull-\(UUID().uuidString).mp4")
        try? Data("not an mp4".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(TelemetryProbe.summarise(url).isEmpty)
    }

    @Test func probingAMissingFileIsSafe() {
        #expect(TelemetryProbe.summarise(URL(fileURLWithPath: "/nowhere.mp4")).isEmpty)
    }
}
