//
//  GoPullTests.swift
//  GoPullTests
//
//  Created by Matthew Grdinic on 8/25/26.
//

import Foundation
import Testing
@testable import GoPull

struct GoPullTests {

    // MARK: - Import error classification
    //
    // Misclassification was the whole bug: a cancelled import reported itself as
    // an unplugged camera, which hid why long clips were failing.

    @Test func cancellationIsNotADisconnect() {
        #expect(ImportError.cancelled.isCancellation)
        #expect(!ImportError.cancelled.isDisconnect)
    }

    @Test func disconnectIsNotACancellation() {
        #expect(ImportError.disconnected.isDisconnect)
        #expect(!ImportError.disconnected.isCancellation)
    }

    @Test func transferFailuresAreNeitherCancelledNorDisconnected() {
        let cases: [ImportError] = [.shortRead("GX010005.MP4"),
                                    .badStatus("GX010005.MP4", 500),
                                    .writeFailed("GX010005.MP4", ENOSPC)]
        for error in cases {
            #expect(!error.isCancellation)
            #expect(!error.isDisconnect)
            #expect(error.errorDescription?.isEmpty == false)
        }
    }

    /// The full-disk case has to name itself, because a silently discarded
    /// `pwrite` result is what used to turn it into a corrupt clip.
    @Test func writeFailureExplainsItself() {
        let message = ImportError.writeFailed("GX010005.MP4", ENOSPC).errorDescription ?? ""
        #expect(message.contains("GX010005.MP4"))
        #expect(message.contains(String(cString: strerror(ENOSPC))))
    }

    // MARK: - Destination layout

    private func file(_ name: String, folder: String = "100GOPRO",
                      modified: Date? = nil) -> MediaFile {
        MediaFile(folder: folder, name: name, size: 1024, modified: modified)
    }

    @MainActor @Test func destinationIsFlatByDefault() {
        let root = URL(fileURLWithPath: "/tmp/dest")
        let url = Importer.destinationURL(for: file("GX010005.MP4"), in: root,
                                          organiseByDate: false, cameraFolder: nil)
        #expect(url.path == "/tmp/dest/GX010005.MP4")
    }

    @MainActor @Test func destinationNestsByCameraThenDate() {
        let root = URL(fileURLWithPath: "/tmp/dest")
        let when = Date(timeIntervalSince1970: 1_787_678_184)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let url = Importer.destinationURL(for: file("GX010005.MP4", modified: when),
                                          in: root, organiseByDate: true,
                                          cameraFolder: "MISSION 1 PRO")
        #expect(url.path == "/tmp/dest/MISSION 1 PRO/\(formatter.string(from: when))/GX010005.MP4")
    }

    /// A clip the camera gave no timestamp for still has to land somewhere.
    @MainActor @Test func undatedClipsGetTheirOwnFolder() {
        let root = URL(fileURLWithPath: "/tmp/dest")
        let url = Importer.destinationURL(for: file("GX010005.MP4"), in: root,
                                          organiseByDate: true, cameraFolder: nil)
        #expect(url.path == "/tmp/dest/undated/GX010005.MP4")
    }

    // MARK: - Preview details

    /// The camera sends every value as a string, and frame rate as a rational.
    @Test func detailsParseTheCamerasStringsAndRational() throws {
        let details = try #require(MediaDetails(json: [
            "w": "7680", "h": "4320", "dur": "384",
            "fps": "30000", "fps_denom": "1001", "ls": "381862591",
        ]))
        #expect(details.width == 7680)
        #expect(details.height == 4320)
        #expect(details.duration == 384)
        #expect(details.summary == "6:24 · 7680×4320 · 29.97 fps")
        #expect(details.proxyBytes == 381_862_591)
    }

    @Test func stillsHaveNoDurationOrFrameRate() throws {
        let details = try #require(MediaDetails(json: ["w": "4096", "h": "3072"]))
        #expect(details.duration == nil)
        #expect(details.summary == "4096×3072")
    }

    @Test func longClipsGetAnHoursComponent() throws {
        let details = try #require(MediaDetails(json: ["w": "1920", "h": "1080", "dur": "3725"]))
        #expect(details.durationLabel == "1:02:05")
    }

    @Test func aPayloadWithNothingUsefulIsRejected() {
        #expect(MediaDetails(json: ["gumi": "abc"]) == nil)
    }

    // MARK: - Proxy matching

    private var card: [MediaFile] {
        ["GX010005.MP4", "GL010005.LRV", "GX020005.MP4", "GL020005.LRV",
         "GP010007.JPG", "GX010005.MP4"].enumerated().map { _, name in
            MediaFile(folder: "100GOPRO", name: name, size: 1, modified: nil)
        }
    }

    @Test func proxyMatchesTheRecordingNotTheLetter() {
        let clip = MediaFile(folder: "100GOPRO", name: "GX010005.MP4", size: 1, modified: nil)
        #expect(MediaPreview.proxy(for: clip, among: card)?.name == "GL010005.LRV")
    }

    /// The chapter number is part of the stem, so chapter 2 must not pick up
    /// chapter 1's proxy.
    @Test func proxyDoesNotCrossChapters() {
        let clip = MediaFile(folder: "100GOPRO", name: "GX020005.MP4", size: 1, modified: nil)
        #expect(MediaPreview.proxy(for: clip, among: card)?.name == "GL020005.LRV")
    }

    @Test func proxyIsScopedToItsFolder() {
        let clip = MediaFile(folder: "101GOPRO", name: "GX010005.MP4", size: 1, modified: nil)
        #expect(MediaPreview.proxy(for: clip, among: card) == nil)
    }

    @Test func stillsAndProxiesHaveNoProxyOfTheirOwn() {
        let photo = MediaFile(folder: "100GOPRO", name: "GP010007.JPG", size: 1, modified: nil)
        let proxy = MediaFile(folder: "100GOPRO", name: "GL010005.LRV", size: 1, modified: nil)
        #expect(MediaPreview.proxy(for: photo, among: card) == nil)
        #expect(MediaPreview.proxy(for: proxy, among: card) == nil)
    }

    /// A clip from another device may not follow GoPro's naming at all.
    @Test func aClipWithNoProxyFallsBackToItself() {
        let clip = MediaFile(folder: "100GOPRO", name: "DJI_0001.MP4", size: 1, modified: nil)
        let source = MediaPreview.source(for: clip, among: card, cameraIP: "172.24.113.51")
        guard case .video(let url, let isProxy)? = source else {
            Issue.record("expected a video source"); return
        }
        #expect(!isProxy)
        #expect(url.absoluteString.hasSuffix("/videos/DCIM/100GOPRO/DJI_0001.MP4"))
    }

    @Test func withoutACameraThereIsNothingToPlay() {
        let clip = MediaFile(folder: "100GOPRO", name: "GX010005.MP4", size: 1, modified: nil)
        #expect(MediaPreview.source(for: clip, among: card, cameraIP: "") == nil)
    }
}
