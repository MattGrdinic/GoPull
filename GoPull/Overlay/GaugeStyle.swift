//
//  GaugeStyle.swift
//  GoPull
//
//  What a speed gauge looks like, separated from how it is drawn.
//
//  A preset is a starting point, not a lock: every value it sets can be
//  overridden, so "Classic, but in kilometres, bigger, and without the bezel"
//  needs no new preset.
//

import CoreGraphics
import Foundation

/// The shape of the readout.
enum GaugeKind: String, CaseIterable, Identifiable, Codable {
    /// A round dial with a swept scale and a needle.
    case dial
    /// Numerals only.
    case digital
    /// A horizontal bar that fills as speed rises.
    case bar

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dial:    return "Dial"
        case .digital: return "Digital"
        case .bar:     return "Bar"
        }
    }
}

enum SpeedUnit: String, CaseIterable, Identifiable, Codable {
    case mph, kph

    var id: String { rawValue }
    var label: String { self == .mph ? "mph" : "km/h" }

    func value(fromMetresPerSecond speed: Double) -> Double {
        self == .mph ? speed * 2.236936 : speed * 3.6
    }
}

/// A colour, stored so a style can be written to disk later.
struct RGBA: Codable, Equatable {
    var r: Double, g: Double, b: Double, a: Double

    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    var cgColor: CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    func opacity(_ value: Double) -> RGBA { RGBA(r, g, b, a * value) }
}

enum GaugePreset: String, CaseIterable, Identifiable, Codable {
    case modern, classic, hiTech, minimal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .modern:  return "Modern"
        case .classic: return "Classic"
        case .hiTech:  return "Hi-Tech"
        case .minimal: return "Minimal"
        }
    }
}

struct GaugeStyle: Equatable, Codable {
    /// Behind the dial. Translucent so footage reads through it.
    var face: RGBA
    /// The rim.
    var bezel: RGBA
    var bezelWidth: Double
    /// Ticks and their numbers.
    var ticks: RGBA
    var majorTickWidth: Double
    var minorTickWidth: Double
    /// The needle, or the filled part of a bar.
    var needle: RGBA
    /// The arc that tracks the current value.
    var arc: RGBA
    var arcWidth: Double
    /// The big number and the unit caption.
    var text: RGBA
    var caption: RGBA
    /// Font names, resolved at draw time so a missing face falls back cleanly.
    var numberFont: String
    var captionFont: String
    /// Drop shadow, which is what keeps a gauge legible over bright footage.
    var shadow: Double
    /// How many minor ticks sit between major ones.
    var minorTicksPerMajor: Int

    static func preset(_ preset: GaugePreset) -> GaugeStyle {
        switch preset {
        case .modern:
            // Clean and neutral: a translucent dark disc, white marks, one
            // accent colour on the needle.
            return GaugeStyle(face: RGBA(0.06, 0.07, 0.09, 0.55),
                              bezel: RGBA(1, 1, 1, 0.25), bezelWidth: 2,
                              ticks: RGBA(1, 1, 1, 0.85),
                              majorTickWidth: 3, minorTickWidth: 1.5,
                              needle: RGBA(1, 0.27, 0.23),
                              arc: RGBA(0.20, 0.65, 1.0, 0.95), arcWidth: 7,
                              text: RGBA(1, 1, 1), caption: RGBA(1, 1, 1, 0.65),
                              numberFont: "HelveticaNeue-Bold",
                              captionFont: "HelveticaNeue-Medium",
                              shadow: 0.55, minorTicksPerMajor: 4)
        case .classic:
            // A cream instrument face, black numerals, a red needle and a
            // chrome rim -- what sits on a motorcycle tank.
            return GaugeStyle(face: RGBA(0.94, 0.91, 0.83, 0.92),
                              bezel: RGBA(0.30, 0.30, 0.32, 0.95), bezelWidth: 6,
                              ticks: RGBA(0.10, 0.09, 0.08, 0.95),
                              majorTickWidth: 3.5, minorTickWidth: 1.5,
                              needle: RGBA(0.78, 0.10, 0.09),
                              arc: RGBA(0.78, 0.10, 0.09, 0), arcWidth: 0,
                              text: RGBA(0.10, 0.09, 0.08),
                              caption: RGBA(0.32, 0.29, 0.25),
                              numberFont: "Times-Bold",
                              captionFont: "Times-Roman",
                              shadow: 0.35, minorTicksPerMajor: 4)
        case .hiTech:
            // Instrument-cluster: near-black face, cyan arc, monospaced digits.
            return GaugeStyle(face: RGBA(0.02, 0.04, 0.06, 0.72),
                              bezel: RGBA(0.0, 0.85, 0.95, 0.55), bezelWidth: 1.5,
                              ticks: RGBA(0.0, 0.85, 0.95, 0.7),
                              majorTickWidth: 2.5, minorTickWidth: 1,
                              needle: RGBA(0.0, 0.95, 0.85),
                              arc: RGBA(0.0, 0.85, 0.95, 1), arcWidth: 9,
                              text: RGBA(0.85, 1.0, 1.0),
                              caption: RGBA(0.0, 0.85, 0.95, 0.8),
                              numberFont: "Menlo-Bold",
                              captionFont: "Menlo-Regular",
                              shadow: 0.7, minorTicksPerMajor: 4)
        case .minimal:
            // No face and no ticks: numerals and a thin arc, for footage that
            // should not be covered up.
            return GaugeStyle(face: RGBA(0, 0, 0, 0),
                              bezel: RGBA(1, 1, 1, 0.18), bezelWidth: 1,
                              ticks: RGBA(1, 1, 1, 0),
                              majorTickWidth: 0, minorTickWidth: 0,
                              needle: RGBA(1, 1, 1, 0.9),
                              arc: RGBA(1, 1, 1, 0.9), arcWidth: 4,
                              text: RGBA(1, 1, 1), caption: RGBA(1, 1, 1, 0.6),
                              numberFont: "HelveticaNeue-Thin",
                              captionFont: "HelveticaNeue",
                              shadow: 0.8, minorTicksPerMajor: 0)
        }
    }
}

/// Where the gauge sits on the frame.
enum OverlayCorner: String, CaseIterable, Identifiable, Codable {
    case topLeft, topRight, bottomLeft, bottomRight

    var id: String { rawValue }
    var label: String {
        switch self {
        case .topLeft:     return "Top Left"
        case .topRight:    return "Top Right"
        case .bottomLeft:  return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }
}

/// Everything needed to draw one gauge.
struct GaugeConfig: Equatable, Codable {
    var kind: GaugeKind = .dial
    var preset: GaugePreset = .modern
    var style: GaugeStyle = .preset(.modern)
    var unit: SpeedUnit = .mph
    /// Top of the dial's scale. Nil means "fit the clip", worked out from the
    /// fastest reading it contains.
    var maxSpeed: Double?
    var corner: OverlayCorner = .bottomLeft
    /// Gauge width as a fraction of the frame's shorter side.
    var scale: Double = 0.28
    /// Inset from the frame edge, also as a fraction of the shorter side.
    var margin: Double = 0.035
    var smoothingSeconds: Double = Smoothing.default.seconds
    /// Show the reading when the camera has no fix, rather than hiding.
    var showsWhenNoFix: Bool = true

    var smoothing: Smoothing { Smoothing(seconds: smoothingSeconds) }

    /// Applying a preset replaces the look but keeps placement and units.
    mutating func apply(_ preset: GaugePreset) {
        self.preset = preset
        self.style = .preset(preset)
    }

    /// A round number above the clip's top speed, so the needle has headroom.
    static func niceMaximum(above speed: Double) -> Double {
        let candidates: [Double] = [20, 30, 40, 60, 80, 100, 120, 160, 200, 240]
        return candidates.first { $0 >= speed * 1.15 } ?? max(20, (speed * 1.2).rounded(.up))
    }
}
