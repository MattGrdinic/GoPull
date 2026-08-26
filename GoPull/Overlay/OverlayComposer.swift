//
//  OverlayComposer.swift
//  GoPull
//
//  Puts the overlays onto one frame.
//
//  The editor's preview and the eventual burn-in both go through here, so what
//  is seen while tuning is what gets rendered. Anything that draws differently
//  between the two is a bug waiting to be found at export time.
//

import CoreGraphics
import Foundation

enum OverlayComposer {

    /// Draws the overlays for a moment in the clip, over whatever is already in
    /// the context.
    ///
    /// `track` should already be smoothed; smoothing the whole track once is far
    /// cheaper than doing it per frame, and export renders thousands of frames.
    static func draw(in context: CGContext, frameSize: CGSize,
                     track: TelemetryTrack, at time: Double,
                     settings: OverlaySettings, maxSpeed: Double) {

        let sample = track.sample(at: time)

        if settings.showsGauge {
            let speed = sample.map { settings.gauge.unit.value(fromMetresPerSecond: $0.speed2D) }
            if speed != nil || settings.gauge.showsWhenNoFix {
                GaugeRenderer.draw(GaugeReading(speed: speed, altitude: sample?.altitude),
                                   in: context, frameSize: frameSize,
                                   config: settings.gauge, maxSpeed: maxSpeed)
            }
        }

        if settings.showsMap {
            let points = track.usable
            if points.count > 1 {
                MapRenderer.draw(route: points.map(\.coordinate),
                                 progress: progress(in: points, at: time),
                                 in: context, frameSize: frameSize, config: settings.map)
            }
        }
    }

    /// How far along the route the rider is, as a fractional index.
    ///
    /// Fractional on purpose: at 10 Hz a whole-number index makes the marker
    /// hop between fixes, which is visible at 30 fps.
    static func progress(in points: [GPSSample], at time: Double) -> Double {
        guard points.count > 1 else { return 0 }
        if time <= points[0].time { return 0 }
        if time >= points[points.count - 1].time { return Double(points.count - 1) }
        var low = 0, high = points.count - 1
        while low + 1 < high {
            let mid = (low + high) / 2
            if points[mid].time <= time { low = mid } else { high = mid }
        }
        let span = points[low + 1].time - points[low].time
        let fraction = span > 0 ? (time - points[low].time) / span : 0
        return Double(low) + fraction
    }

    /// The dial's top, chosen once from the clip so the needle has headroom.
    static func maxSpeed(for track: TelemetryTrack, unit: SpeedUnit) -> Double {
        GaugeConfig.niceMaximum(above: unit.value(fromMetresPerSecond: track.topSpeed))
    }
}
