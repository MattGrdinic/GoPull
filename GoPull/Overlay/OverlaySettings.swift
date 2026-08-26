//
//  OverlaySettings.swift
//  GoPull
//
//  Everything the overlays are configured to do, in one value.
//
//  Kept `Codable` and stored whole, so a look someone has tuned survives a
//  restart and can later be exported as a preset file.
//

import CoreGraphics
import Foundation

struct OverlaySettings: Equatable, Codable {
    var showsGauge = true
    var gauge = GaugeConfig()
    var showsMap = true
    var map = MapConfig()

    /// Applying a preset moves both overlays together, which is what the
    /// preset names mean -- "Classic" is a look for the whole overlay, not for
    /// the dial alone.
    mutating func apply(_ preset: GaugePreset) {
        gauge.apply(preset)
        map.apply(preset)
    }

    /// True when both overlays already agree on a preset, so the picker can
    /// show it as selected rather than guessing.
    var commonPreset: GaugePreset? {
        gauge.preset == map.preset ? gauge.preset : nil
    }

    static let defaults: OverlaySettings = {
        var settings = OverlaySettings()
        settings.gauge.placement = .corner(.bottomLeft, scale: 0.24)
        settings.map.placement = .corner(.bottomRight, scale: 0.26)
        return settings
    }()

    // MARK: - Persistence

    private static let key = "overlaySettings"

    static func load() -> OverlaySettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(OverlaySettings.self, from: data)
        else { return .defaults }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
