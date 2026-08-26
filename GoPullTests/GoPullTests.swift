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
}
