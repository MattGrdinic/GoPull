//
//  TelemetrySummary.swift
//  GoPull
//
//  What a clip's telemetry holds, known before the clip is copied.
//
//  Importing an 11 GB clip to discover it has no GPS fix is a slow way to find
//  out. The camera will hand over the telemetry on its own — `/gopro/media/
//  telemetry` returns just the GPMF as a small MP4, about 1.3 MB per minute of
//  footage, or 8.6 MB and two thirds of a second for a six-minute clip. That is
//  cheap enough to do for a whole card in the background.
//

import Foundation

struct TelemetrySummary: Equatable {
    /// Whether there is any usable fix at all.
    var hasFix = false
    /// Fraction of the clip's fixes that were usable, so a clip that only found
    /// the sky halfway through can say so.
    var coverage: Double = 0
    var distance: Double = 0
    var topSpeed: Double = 0
    /// Standing starts the acceleration overlay would find.
    var launches = 0
    /// Whether an accelerometer track is present for the g-meter.
    var hasGForce = false
    var peakG: Double = 0

    var isEmpty: Bool { !hasFix && !hasGForce }

    func caption(unit: SpeedUnit) -> String {
        guard !isEmpty else { return "No telemetry in this clip." }
        var parts: [String] = []
        if hasFix {
            parts.append(String(format: "GPS %.0f%%", coverage * 100))
            if distance > 0 { parts.append(String(format: "%.1f km", distance / 1000)) }
            if topSpeed > 0 {
                parts.append(String(format: "top %.0f %@",
                                    unit.value(fromMetresPerSecond: topSpeed), unit.label))
            }
        } else {
            parts.append("no GPS fix")
        }
        if launches > 0 { parts.append("\(launches) standing start\(launches == 1 ? "" : "s")") }
        if hasGForce, peakG > 0 { parts.append(String(format: "peak %.2f g", peakG)) }
        return parts.joined(separator: " · ")
    }
}

enum TelemetryProbe {

    /// Reads a summary from a telemetry-only MP4, as the camera serves it.
    static func summarise(_ url: URL,
                          detection: AccelerationSettings = .init()) -> TelemetrySummary {
        var summary = TelemetrySummary()
        guard let track = try? TelemetryReader.read(url) else { return summary }

        let usable = track.usable
        summary.hasFix = track.hasFix
        summary.coverage = track.samples.isEmpty ? 0
            : Double(usable.count) / Double(track.samples.count)
        summary.distance = track.distance
        summary.topSpeed = track.topSpeed

        let gforce = (try? GForceReader.read(url)) ?? GForceTrack()
        summary.hasGForce = !gforce.isEmpty
        let smoothed = gforce.smoothed(.default)
        summary.peakG = smoothed.peakPlanar

        if track.hasFix {
            summary.launches = AccelerationDetector.runs(in: track, gforce: smoothed,
                                                         settings: detection).count
        }
        return summary
    }
}
