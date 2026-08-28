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
}
