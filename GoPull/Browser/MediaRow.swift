//
//  MediaRow.swift
//  GoPull
//
//  What the file list actually shows.
//
//  The card is not a flat list of files. Shooting raw writes a .GPR *and* a
//  .JPG for the same photo, which listed separately means every shot appears
//  twice, and the .GPR half has no preview because nothing on macOS can decode
//  one. So a row is a *shot*, not a file: the JPEG carries the row, and the raw
//  rides along as a badge that can be switched off.
//

import Foundation

/// One line in the list: a clip, or a photo and its raw sibling.
struct MediaRow: Identifiable, Hashable {
    /// The file the row is named and previewed by.
    var primary: MediaFile
    /// The raw file shot at the same moment, when there is one.
    var raw: MediaFile?

    var id: String { primary.id }
    var name: String { primary.name }
    var folder: String { primary.folder }
    var modified: Date? { primary.modified }

    /// Everything this row would import.
    func files(includingRaw: Bool) -> [MediaFile] {
        guard let raw, includingRaw else { return [primary] }
        return [primary, raw]
    }

    /// Bytes this row would copy.
    func size(includingRaw: Bool) -> Int64 {
        files(includingRaw: includingRaw).reduce(0) { $0 + $1.size }
    }

    var hasRaw: Bool { raw != nil }
    /// A raw file with no JPEG beside it still gets a row of its own.
    var isRawOnly: Bool { raw == nil && MediaRow.isRaw(primary) }

    var isVideo: Bool { MediaPreview.isVideo(primary) }
    var isPhoto: Bool { MediaPreview.isStill(primary) || isRawOnly }

    static func isRaw(_ file: MediaFile) -> Bool {
        file.name.lowercased().hasSuffix(".gpr")
    }

    /// "GP010015" — what a raw and its JPEG have in common.
    static func stem(_ name: String) -> String {
        (name as NSString).deletingPathExtension
    }
}

enum MediaFilter: String, CaseIterable, Identifiable, Codable {
    case all, video, photos

    var id: String { rawValue }
    var label: String {
        switch self {
        case .all:    return "All"
        case .video:  return "Video"
        case .photos: return "Photos"
        }
    }

    func matches(_ row: MediaRow) -> Bool {
        switch self {
        case .all:    return true
        case .video:  return row.isVideo
        case .photos: return row.isPhoto
        }
    }
}

enum MediaSort: String, CaseIterable, Identifiable, Codable {
    case newest, oldest, name, largest

    var id: String { rawValue }
    var label: String {
        switch self {
        case .newest:  return "Newest first"
        case .oldest:  return "Oldest first"
        case .name:    return "Name"
        case .largest: return "Largest first"
        }
    }
}

/// A day's worth of shots, for the date headers.
struct MediaSection: Identifiable {
    var id: String
    var title: String
    var rows: [MediaRow]

    var totalBytes: Int64 { rows.reduce(0) { $0 + $1.size(includingRaw: true) } }
}

enum MediaBrowser {

    /// Collapses a card's files into rows.
    ///
    /// Pairing is by folder and stem, which is exactly how the camera names
    /// them: `GP010015.GPR` and `GP010015.JPG` are one photo. A raw with no
    /// JPEG keeps its own row rather than disappearing.
    static func rows(from files: [MediaFile]) -> [MediaRow] {
        var raws: [String: MediaFile] = [:]
        for file in files where isRaw(file) {
            raws["\(file.folder)/\(MediaRow.stem(file.name))"] = file
        }

        var result: [MediaRow] = []
        var pairedRaws: Set<String> = []

        for file in files where !isRaw(file) {
            let key = "\(file.folder)/\(MediaRow.stem(file.name))"
            // Only a still pairs with a raw; a clip that happens to share a
            // stem with one is a coincidence, not the same shot.
            if MediaPreview.isStill(file), let raw = raws[key] {
                pairedRaws.insert(raw.id)
                result.append(MediaRow(primary: file, raw: raw))
            } else {
                result.append(MediaRow(primary: file, raw: nil))
            }
        }
        for file in files where isRaw(file) && !pairedRaws.contains(file.id) {
            result.append(MediaRow(primary: file, raw: nil))
        }
        return result
    }

    private static func isRaw(_ file: MediaFile) -> Bool { MediaRow.isRaw(file) }

    static func sorted(_ rows: [MediaRow], by sort: MediaSort) -> [MediaRow] {
        switch sort {
        case .name:
            return rows.sorted { $0.name < $1.name }
        case .largest:
            return rows.sorted { $0.size(includingRaw: true) > $1.size(includingRaw: true) }
        case .newest, .oldest:
            let ascending = sort == .oldest
            return rows.sorted {
                // Undated files sort last either way rather than jumping to the
                // top of a newest-first list.
                switch ($0.modified, $1.modified) {
                case let (a?, b?): return ascending ? a < b : a > b
                case (nil, _?):    return false
                case (_?, nil):    return true
                default:           return $0.name < $1.name
                }
            }
        }
    }

    static func matching(_ rows: [MediaRow], search: String) -> [MediaRow] {
        let term = search.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return rows }
        return rows.filter { $0.name.localizedCaseInsensitiveContains(term) }
    }

    /// Groups rows under a header per calendar day, keeping the order they
    /// arrive in so the chosen sort still decides which day comes first.
    static func sections(_ rows: [MediaRow], calendar: Calendar = .current) -> [MediaSection] {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none

        var order: [String] = []
        var grouped: [String: [MediaRow]] = [:]
        for row in rows {
            let key: String
            if let date = row.modified {
                let day = calendar.startOfDay(for: date)
                key = ISO8601DateFormatter().string(from: day)
            } else {
                key = "undated"
            }
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(row)
        }

        return order.map { key in
            let rows = grouped[key] ?? []
            let title: String
            if key == "undated" {
                title = "No date"
            } else if let date = rows.first?.modified {
                title = formatter.string(from: date)
            } else {
                title = key
            }
            return MediaSection(id: key, title: title, rows: rows)
        }
    }
}
