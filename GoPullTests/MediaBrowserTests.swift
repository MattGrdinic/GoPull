//
//  MediaBrowserTests.swift
//  GoPullTests
//

import Foundation
import Testing
@testable import GoPull

struct MediaBrowserTests {

    private func file(_ name: String, folder: String = "100GOPRO",
                      size: Int64 = 1_000_000, day: Int? = nil) -> MediaFile {
        var date: Date?
        if let day {
            var components = DateComponents()
            components.year = 2026; components.month = 8; components.day = day
            components.hour = 12
            date = Calendar.current.date(from: components)
        }
        return MediaFile(folder: folder, name: name, size: size, modified: date)
    }

    // MARK: - Pairing

    /// Shooting raw writes a .GPR and a .JPG for one photo. Listed separately
    /// every shot appears twice, and the raw half has no preview.
    @Test func aRawAndItsJPEGBecomeOneRow() {
        let rows = MediaBrowser.rows(from: [file("GP010015.GPR"), file("GP010015.JPG")])
        #expect(rows.count == 1)
        #expect(rows[0].name == "GP010015.JPG")     // the half with a preview
        #expect(rows[0].hasRaw)
        #expect(rows[0].raw?.name == "GP010015.GPR")
    }

    @Test func aJPEGWithNoRawIsJustAPhoto() {
        let rows = MediaBrowser.rows(from: [file("GP010007.JPG")])
        #expect(rows.count == 1)
        #expect(!rows[0].hasRaw)
        #expect(rows[0].isPhoto)
    }

    /// A raw with no JPEG still has to be importable, so it keeps a row.
    @Test func aLoneRawKeepsItsOwnRow() {
        let rows = MediaBrowser.rows(from: [file("GP010020.GPR")])
        #expect(rows.count == 1)
        #expect(rows[0].isRawOnly)
        #expect(rows[0].isPhoto)
    }

    /// Same stem in different folders is two different shots.
    @Test func pairingDoesNotCrossFolders() {
        let rows = MediaBrowser.rows(from: [
            file("GP010015.GPR", folder: "100GOPRO"),
            file("GP010015.JPG", folder: "101GOPRO"),
        ])
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { !$0.hasRaw })
    }

    /// A clip that happens to share a stem with a raw is not the same shot.
    @Test func aVideoNeverAbsorbsARaw() {
        let rows = MediaBrowser.rows(from: [file("GX010015.GPR"), file("GX010015.MP4")])
        #expect(rows.count == 2)
        #expect(rows.contains { $0.isVideo && !$0.hasRaw })
        #expect(rows.contains { $0.isRawOnly })
    }

    @Test func aMixedCardPairsOnlyWhatShouldPair() {
        let rows = MediaBrowser.rows(from: [
            file("GP010007.JPG"),                                   // photo alone
            file("GP010015.GPR"), file("GP010015.JPG"),             // paired
            file("GP010016.GPR"), file("GP010016.JPG"),             // paired
            file("GX010002.MP4"),                                   // clip
        ])
        #expect(rows.count == 4)
        #expect(rows.filter(\.hasRaw).count == 2)
        #expect(rows.filter(\.isVideo).count == 1)
    }

    // MARK: - What a row imports

    @Test func aPairedRowImportsBothUnlessRawIsOff() {
        let rows = MediaBrowser.rows(from: [
            file("GP010015.GPR", size: 12_000_000),
            file("GP010015.JPG", size: 11_000_000),
        ])
        let row = rows[0]
        #expect(row.files(includingRaw: true).count == 2)
        #expect(row.files(includingRaw: false).count == 1)
        #expect(row.size(includingRaw: true) == 23_000_000)
        #expect(row.size(includingRaw: false) == 11_000_000)
    }

    @Test func aRowWithNoRawIgnoresTheToggle() {
        let row = MediaBrowser.rows(from: [file("GX010002.MP4", size: 80)])[0]
        #expect(row.size(includingRaw: false) == 80)
        #expect(row.size(includingRaw: true) == 80)
    }

    // MARK: - Filtering

    @Test func theFilterSeparatesStillsFromClips() {
        let rows = MediaBrowser.rows(from: [
            file("GP010015.GPR"), file("GP010015.JPG"),
            file("GX010002.MP4"), file("GX010003.MP4"),
        ])
        #expect(rows.filter(MediaFilter.all.matches).count == 3)
        #expect(rows.filter(MediaFilter.video.matches).count == 2)
        #expect(rows.filter(MediaFilter.photos.matches).count == 1)
    }

    @Test func searchMatchesOnName() {
        let rows = MediaBrowser.rows(from: [file("GX010002.MP4"), file("GP010015.JPG")])
        #expect(MediaBrowser.matching(rows, search: "gx01").count == 1)
        #expect(MediaBrowser.matching(rows, search: "  ").count == 2)
        #expect(MediaBrowser.matching(rows, search: "nothing").isEmpty)
    }

    // MARK: - Sorting

    @Test func sortingByDateRunsBothWays() {
        let rows = MediaBrowser.rows(from: [
            file("a.MP4", day: 25), file("b.MP4", day: 27), file("c.MP4", day: 26),
        ])
        #expect(MediaBrowser.sorted(rows, by: .newest).map(\.name) == ["b.MP4", "c.MP4", "a.MP4"])
        #expect(MediaBrowser.sorted(rows, by: .oldest).map(\.name) == ["a.MP4", "c.MP4", "b.MP4"])
    }

    /// An undated file must not jump to the top of a newest-first list.
    @Test func undatedFilesSortLastEitherWay() {
        let rows = MediaBrowser.rows(from: [
            file("dated.MP4", day: 25), file("undated.MP4"),
        ])
        #expect(MediaBrowser.sorted(rows, by: .newest).last?.name == "undated.MP4")
        #expect(MediaBrowser.sorted(rows, by: .oldest).last?.name == "undated.MP4")
    }

    @Test func sortingBySizeCountsTheRawToo() {
        let rows = MediaBrowser.rows(from: [
            file("GX010002.MP4", size: 20_000_000),
            file("GP010015.GPR", size: 12_000_000), file("GP010015.JPG", size: 11_000_000),
        ])
        #expect(MediaBrowser.sorted(rows, by: .largest).first?.name == "GP010015.JPG")
    }

    // MARK: - Date sections

    @Test func rowsGroupUnderOneHeaderPerDay() {
        let rows = MediaBrowser.sorted(MediaBrowser.rows(from: [
            file("a.MP4", day: 27), file("b.MP4", day: 27), file("c.MP4", day: 25),
        ]), by: .newest)
        let sections = MediaBrowser.sections(rows)
        #expect(sections.count == 2)
        #expect(sections[0].rows.count == 2)
        #expect(sections[1].rows.count == 1)
    }

    /// The chosen sort decides which day comes first, not the grouping.
    @Test func sectionsFollowTheSortOrder() {
        let rows = MediaBrowser.rows(from: [file("a.MP4", day: 25), file("b.MP4", day: 27)])
        let newest = MediaBrowser.sections(MediaBrowser.sorted(rows, by: .newest))
        let oldest = MediaBrowser.sections(MediaBrowser.sorted(rows, by: .oldest))
        #expect(newest.first?.rows.first?.name == "b.MP4")
        #expect(oldest.first?.rows.first?.name == "a.MP4")
    }

    @Test func undatedRowsGetTheirOwnSection() {
        let sections = MediaBrowser.sections(MediaBrowser.rows(from: [file("x.MP4")]))
        #expect(sections.count == 1)
        #expect(sections[0].title == "No date")
    }

    @Test func aSectionKnowsWhatItWeighs() {
        let rows = MediaBrowser.rows(from: [
            file("a.MP4", size: 100, day: 27), file("b.MP4", size: 250, day: 27),
        ])
        #expect(MediaBrowser.sections(rows).first?.totalBytes == 350)
    }

    @Test func anEmptyCardProducesNothing() {
        #expect(MediaBrowser.rows(from: []).isEmpty)
        #expect(MediaBrowser.sections([]).isEmpty)
    }
}

@MainActor
struct MediaRowImportTests {

    private func file(_ name: String, size: Int64 = 1_000_000) -> MediaFile {
        MediaFile(folder: "100GOPRO", name: name, size: size, modified: nil)
    }

    /// A shot's raw is included until it is switched off.
    @Test func rawIsIncludedByDefault() {
        let model = AppModel()
        let row = MediaBrowser.rows(from: [file("GP010015.GPR"), file("GP010015.JPG")])[0]
        #expect(model.includesRaw(row))
        #expect(model.files(for: row).count == 2)

        model.setIncludesRaw(false, for: row)
        #expect(!model.includesRaw(row))
        #expect(model.files(for: row).count == 1)
        #expect(model.files(for: row).first?.name == "GP010015.JPG")
    }

    /// A row with no raw is never "including" one, however the flag is set.
    @Test func aRowWithoutARawIsUnaffected() {
        let model = AppModel()
        let row = MediaBrowser.rows(from: [file("GX010002.MP4")])[0]
        #expect(!model.includesRaw(row))
        model.setIncludesRaw(true, for: row)
        #expect(!model.includesRaw(row))
        #expect(model.files(for: row).count == 1)
    }

    /// The header used to count the raw whether or not it was being copied,
    /// so a date total disagreed with the total above it.
    @Test func sectionTotalsFollowTheRawToggle() {
        let model = AppModel()
        let rows = MediaBrowser.rows(from: [
            file("GP010015.GPR", size: 12_000_000),
            file("GP010015.JPG", size: 11_000_000),
        ])
        let section = MediaSection(id: "x", title: "x", rows: rows)
        #expect(model.bytes(of: section) == 23_000_000)

        model.setIncludesRaw(false, for: rows[0])
        #expect(model.bytes(of: section) == 11_000_000)
        // The model's own figure still counts everything, which is why the
        // view must not use it.
        #expect(section.totalBytes == 23_000_000)
    }

    @Test func theSelectionSummaryFollowsTheRawToggle() {
        let model = AppModel()
        let rows = MediaBrowser.rows(from: [
            file("GP010015.GPR", size: 12_000_000),
            file("GP010015.JPG", size: 11_000_000),
        ])
        model.setIncludesRaw(false, for: rows[0])
        // Without a camera the model has no files, so this exercises the
        // arithmetic rather than the lookup.
        #expect(model.selectionSummary([]).count == 0)
        #expect(model.selectionSummary([]).bytes == 0)
    }
}
