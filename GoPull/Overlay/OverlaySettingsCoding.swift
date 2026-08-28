//
//  OverlaySettingsCoding.swift
//  GoPull
//
//  Loading settings that were saved before a field existed.
//
//  Swift's synthesised `Codable` requires every key, so each time an overlay
//  was added — the g-force meter, the launch badge, splitting the peaks in two
//  — previously saved settings stopped decoding and a tuned look silently
//  reverted to the defaults. Nobody reports that as a bug; they just find their
//  overlay has moved.
//
//  Rather than hand-write a lenient `init(from:)` for every nested type — which
//  also means hand-writing `CodingKeys` for each, because declaring the one
//  suppresses synthesis of the other — the stored JSON is merged over the JSON
//  of the defaults. Any key the old data lacks keeps its default value, at any
//  depth, and nothing needs updating when the next field is added.
//

import Foundation

extension OverlaySettings {

    /// Reads saved settings, filling in anything a newer build expects.
    static func loadMerging(_ data: Data) -> OverlaySettings {
        if let decoded = try? JSONDecoder().decode(OverlaySettings.self, from: data) {
            return decoded
        }
        guard let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaultsData = try? JSONEncoder().encode(OverlaySettings.defaults),
              let base = try? JSONSerialization.jsonObject(with: defaultsData) as? [String: Any]
        else { return .defaults }

        let merged = merge(base: base, over: stored)
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              let decoded = try? JSONDecoder().decode(OverlaySettings.self, from: mergedData)
        else { return .defaults }
        return decoded
    }

    /// `over` wins wherever it has a value; `base` fills the gaps.
    private static func merge(base: [String: Any], over: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in over {
            if let nested = value as? [String: Any], let existing = base[key] as? [String: Any] {
                result[key] = merge(base: existing, over: nested)
            } else {
                result[key] = value
            }
        }
        return result
    }
}
