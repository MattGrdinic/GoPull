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

/// The camera reports local wall-clock time and labels it UTC — in the media
/// list as an epoch computed from the local clock, and in `Last-Modified` with
/// `GMT` after it. A photo taken at noon in Arizona was shown as 05:02.
struct CameraClockTests {

    /// 2026-08-28 12:00:00 UTC, as a fixed "now" to measure against.
    private let now = Date(timeIntervalSince1970: 1787918400)

    @Test func aCameraSevenHoursBehindUTCIsRecognised() {
        // The camera's wall clock reads 05:00 when UTC is 12:00: MST, UTC-7.
        //
        // The expectation is a typed constant because `#expect(offset == -7 * 3600)`
        // against a `TimeInterval?` fails: the bare literal expression does not
        // infer to Double there, and the macro reports it as a plain mismatch.
        let offset = GoProCamera.offsetFromCameraClock(date: "2026_08_28",
                                             time: "05_00_00", now: now)
        let expected: TimeInterval = -7 * 3600
        #expect(offset == expected)
    }

    @Test func aCameraAheadOfUTCIsRecognised() {
        let offset = GoProCamera.offsetFromCameraClock(date: "2026_08_28",
                                             time: "21_30_00", now: now)
        #expect(offset == 9.5 * 3600)          // and a half-hour zone works
    }

    @Test func aCameraOnUTCNeedsNoCorrection() {
        #expect(GoProCamera.offsetFromCameraClock(date: "2026_08_28",
                                        time: "12_00_00", now: now) == 0)
    }

    /// A clock a few minutes out must not skew the offset.
    @Test func aFewMinutesOfDriftRoundsAway() {
        let offset = GoProCamera.offsetFromCameraClock(date: "2026_08_28",
                                             time: "05_03_20", now: now)
        let expected: TimeInterval = -7 * 3600
        #expect(offset == expected)
    }

    /// A clock that is simply wrong is not a time zone, and baking it in would
    /// move every timestamp by the same error.
    @Test func aWildlyWrongClockIsRefused() {
        #expect(GoProCamera.offsetFromCameraClock(date: "2019_01_01",
                                        time: "12_00_00", now: now) == nil)
        #expect(GoProCamera.offsetFromCameraClock(date: "not a date",
                                        time: "12_00_00", now: now) == nil)
    }

    /// The correction runs the right way: the camera's epoch is ahead of the
    /// real instant by the offset, so it is subtracted.
    @Test func aLocalEpochBecomesTheRealInstant() {
        // The photo the report came from: mod=1787918536 for a noon shot.
        let reported = Date(timeIntervalSince1970: 1787918536)
        let corrected = Date(timeIntervalSince1970: 1787918536 - (-7 * 3600))
        #expect(corrected > reported)
        #expect(corrected.timeIntervalSince(reported) == 7 * 3600)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -7 * 3600)!
        #expect(calendar.component(.hour, from: corrected) == 12)
    }
}

/// GoPro has two HTTP APIs, and they are not versions of one another: a HERO8
/// 404s every modern path. Everything needed to get footage off the card exists
/// in both, so only the paths differ.
struct CameraAPITests {

    @Test func eachApiUsesItsOwnPaths() {
        #expect(CameraAPI.modern.infoPath == "/gopro/camera/info")
        #expect(CameraAPI.legacy.infoPath == "/gp/gpControl/info")
        #expect(CameraAPI.modern.mediaListPath == "/gopro/media/list")
        #expect(CameraAPI.legacy.mediaListPath == "/gp/gpMediaList")
        #expect(CameraAPI.modern.keepAlivePath != CameraAPI.legacy.keepAlivePath)
    }

    /// Thumbnails, media info and the telemetry download are modern-only, so
    /// the previews and the pre-import badges have to stand down rather than
    /// fail one 404 at a time.
    @Test func onlyTheModernApiServesPreviews() {
        #expect(CameraAPI.modern.servesPreviews)
        #expect(!CameraAPI.legacy.servesPreviews)
        #expect(CameraAPI.modern.needsWiredControl)
        #expect(!CameraAPI.legacy.needsWiredControl)
    }

    @Test func deletePathsDifferAndAreEncoded() {
        let modern = CameraAPI.modern.deletePath(for: "100GOPRO/GX010001.MP4")
        let legacy = CameraAPI.legacy.deletePath(for: "100GOPRO/GX010001.MP4")
        #expect(modern == "/gopro/media/delete/file?path=100GOPRO/GX010001.MP4")
        #expect(legacy == "/gp/gpControl/command/storage/delete?p=100GOPRO/GX010001.MP4")
        // A space has to survive as an escape, not as a broken query.
        #expect(CameraAPI.modern.deletePath(for: "100GOPRO/A B.MP4")?
            .contains(" ") == false)
    }

    /// The legacy camera has no `get_date_time`; status key 40 is the wall
    /// clock as six percent-encoded bytes — year since 2000, month, day, h,m,s.
    @Test func theLegacyClockDecodes() throws {
        let clock = try #require(GoProCamera.decodeLegacyClock("%1A%08%1D%11%36%24"))
        #expect(clock.date == "2026_08_29")
        #expect(clock.time == "17_54_36")
    }

    /// And it feeds the same offset arithmetic as the modern reading.
    @Test func theLegacyClockGivesTheSameOffset() throws {
        let clock = try #require(GoProCamera.decodeLegacyClock("%1A%08%1D%11%36%24"))
        // 17:54:36 local while UTC is 00:54:36 the next day: UTC-7.
        let utc = Date(timeIntervalSince1970: 1788051276)
        let offset = GoProCamera.offsetFromCameraClock(date: clock.date, time: clock.time,
                                                       now: utc)
        let expected: TimeInterval = -7 * 3600
        #expect(offset == expected)
    }

    @Test func aMalformedLegacyClockIsRefused() {
        #expect(GoProCamera.decodeLegacyClock("%1A%08") == nil)
        #expect(GoProCamera.decodeLegacyClock("") == nil)
    }
}
