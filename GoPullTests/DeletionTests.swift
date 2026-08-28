//
//  DeletionTests.swift
//  GoPullTests
//
//  Deleting from the card is the one irreversible thing this app does, so what
//  the confirmation claims has to be right.
//

import Foundation
import Testing
@testable import GoPull

private func file(_ name: String, size: Int64 = 1_000_000) -> MediaFile {
    MediaFile(folder: "100GOPRO", name: name, size: size, modified: nil)
}

private func rows(_ files: [MediaFile]) -> [MediaRow] {
    MediaBrowser.rows(from: files)
}

@Test func aShotWithALocalCopyCountsAsBacked() {
    let plan = DeletionPlan(rows: rows([file("GX010001.MP4")]), isBacked: { _ in true })
    #expect(plan.allBacked)
    #expect(plan.backed.count == 1)
    #expect(plan.unbacked.isEmpty)
    #expect(plan.bytes == 1_000_000)
}

@Test func aShotWithNoLocalCopyIsFlagged() {
    let plan = DeletionPlan(rows: rows([file("GX010001.MP4")]), isBacked: { _ in false })
    #expect(!plan.allBacked)
    #expect(plan.unbacked.count == 1)
}

/// A paired GPR that never came across still makes the shot the only copy of
/// that raw, even though the JPEG is safely on disk.
@Test func aRowIsOnlyBackedWhenItsRawIsToo() {
    let shot = rows([file("GP010007.JPG"), file("GP010007.GPR", size: 20_000_000)])
    #expect(shot.count == 1)
    let plan = DeletionPlan(rows: shot, isBacked: { $0.name.hasSuffix(".JPG") })
    #expect(plan.unbacked.count == 1)
    #expect(plan.backed.isEmpty)
    // Both files go, and both are counted in what would be freed.
    #expect(plan.files.count == 2)
    #expect(plan.bytes == 21_000_000)
}

@Test func theSplitIsReportedPerShot() {
    let all = rows([file("GX010001.MP4"), file("GX010002.MP4"), file("GX010003.MP4")])
    let plan = DeletionPlan(rows: all, isBacked: { $0.name != "GX010002.MP4" })
    #expect(plan.rows.count == 3)
    #expect(plan.backed.count == 2)
    #expect(plan.unbacked.count == 1)
    #expect(plan.unbacked.first?.name == "GX010002.MP4")
    #expect(!plan.allBacked)
}

@Test func anEmptyPlanIsEmpty() {
    let plan = DeletionPlan(rows: [], isBacked: { _ in true })
    #expect(plan.isEmpty)
    #expect(plan.bytes == 0)
}
