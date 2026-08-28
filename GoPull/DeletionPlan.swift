//
//  DeletionPlan.swift
//  GoPull
//
//  What deleting a set of rows would actually do.
//
//  The distinction that matters is whether a copy exists on this Mac. A clip
//  that has been imported can be deleted and pulled back from that copy; one
//  that has not is the only copy there is, and the card has no trash and no
//  undo. Everything the confirmation shows is built from that split, so it is
//  worked out here -- away from the singleton -- where it can be tested.
//

import Foundation

struct DeletionPlan {
    var rows: [MediaRow] = []
    var files: [MediaFile] = []
    /// Rows with a verified, full-size copy in the destination.
    var backed: [MediaRow] = []
    /// Rows with no copy, or an incomplete one.
    var unbacked: [MediaRow] = []
    var bytes: Int64 = 0

    var isEmpty: Bool { rows.isEmpty }
    var allBacked: Bool { unbacked.isEmpty }

    init() {}

    /// - Parameter isBacked: whether one file is on disk at its full size.
    init(rows: [MediaRow], isBacked: (MediaFile) -> Bool) {
        for row in rows {
            // Deleting a shot takes its raw with it: leaving an orphaned GPR
            // behind after removing the JPEG is not what "delete this" means.
            let files = row.files(includingRaw: true)
            self.rows.append(row)
            self.files += files
            bytes += files.reduce(0) { $0 + $1.size }
            // A shot only counts as backed when *every* one of its files is,
            // so a paired GPR that never came across still counts as the only
            // copy of that raw.
            if files.allSatisfy(isBacked) {
                backed.append(row)
            } else {
                unbacked.append(row)
            }
        }
    }

    /// What an import may offer to delete once it has finished.
    ///
    /// Whole shots that the import touched, narrowed to the ones every file of
    /// which is verified on this Mac. The importer reporting no failure is not
    /// the same as the bytes being on disk, and a shot whose raw was left behind
    /// by the RAW toggle must not be offered at all -- deleting it would take
    /// the raw with it. The result is all-backed by construction, which is what
    /// lets the post-import prompt be a plain confirmation instead of the sheet.
    static func afterImport(_ imported: [MediaFile], among rows: [MediaRow],
                            isBacked: (MediaFile) -> Bool) -> DeletionPlan {
        let justImported = Set(imported.map(\.id))
        let touched = rows.filter { row in
            row.files(includingRaw: true).contains { justImported.contains($0.id) }
        }
        let considered = DeletionPlan(rows: touched, isBacked: isBacked)
        return DeletionPlan(rows: considered.backed, isBacked: isBacked)
    }
}
