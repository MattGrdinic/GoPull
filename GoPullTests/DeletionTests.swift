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

/// Deleting from the camera once an import has finished. The option is off
/// unless asked for, and it only ever offers — the confirmation is not
/// skippable, because the card has no trash.
struct DeleteAfterImportTests {

    private func file(_ name: String, size: Int64 = 1_000_000) -> MediaFile {
        MediaFile(folder: "100GOPRO", name: name, size: size, modified: nil)
    }

    @Test func offersTheShotsTheImportJustCopied() {
        let card = [file("GX010001.MP4"), file("GX010002.MP4"), file("GX010003.MP4")]
        let imported = [card[0], card[1]]
        let plan = DeletionPlan.afterImport(imported, among: MediaBrowser.rows(from: card),
                                            isBacked: { _ in true })
        #expect(plan.rows.count == 2)
        #expect(plan.allBacked)
        #expect(!plan.rows.contains { $0.name == "GX010003.MP4" })
    }

    /// "The importer reported no failure" is not "the bytes are on disk".
    @Test func aShotThatIsNotActuallyOnDiskIsNotOffered() {
        let card = [file("GX010001.MP4"), file("GX010002.MP4")]
        let plan = DeletionPlan.afterImport(card, among: MediaBrowser.rows(from: card),
                                            isBacked: { $0.name == "GX010001.MP4" })
        #expect(plan.rows.count == 1)
        #expect(plan.rows.first?.name == "GX010001.MP4")
    }

    /// A shot whose raw was left behind by the RAW toggle must not be offered:
    /// deleting it would take the raw with it.
    @Test func aShotWhoseRawStayedBehindIsNotOffered() {
        let card = [file("GP010007.JPG"), file("GP010007.GPR", size: 20_000_000)]
        let rows = MediaBrowser.rows(from: card)
        #expect(rows.count == 1)
        // Only the JPEG came across.
        let plan = DeletionPlan.afterImport([card[0]], among: rows,
                                            isBacked: { $0.name.hasSuffix(".JPG") })
        #expect(plan.isEmpty)
    }

    @Test func bothFilesOfAPairedShotGoTogether() {
        let card = [file("GP010007.JPG"), file("GP010007.GPR", size: 20_000_000)]
        let plan = DeletionPlan.afterImport(card, among: MediaBrowser.rows(from: card),
                                            isBacked: { _ in true })
        #expect(plan.rows.count == 1)
        #expect(plan.files.count == 2)
        #expect(plan.bytes == 21_000_000)
    }

    @Test func animportThatCopiedNothingOffersNothing() {
        let card = [file("GX010001.MP4")]
        #expect(DeletionPlan.afterImport([], among: MediaBrowser.rows(from: card),
                                         isBacked: { _ in true }).isEmpty)
    }

    /// Everything offered is verified, so the prompt never has to warn.
    @Test func whatIsOfferedIsAlwaysFullyBacked() {
        let card = (1...6).map { file(String(format: "GX01000%d.MP4", $0)) }
        let plan = DeletionPlan.afterImport(card, among: MediaBrowser.rows(from: card),
                                            isBacked: { $0.name != "GX010004.MP4" })
        #expect(plan.unbacked.isEmpty)
        #expect(plan.allBacked)
        #expect(plan.rows.count == 5)
    }
}
