//
//  Smoothing.swift
//  GoPull
//
//  Takes the jitter out of GPS readings before they drive a gauge.
//
//  Measured on a motorcycle ride (GX010005, 3160 usable fixes at 10 Hz):
//  consecutive speed samples differ by a median of 0.30 mph and a 99th
//  percentile of 2.13 mph, with a worst case of 4.81 mph. The hardest real
//  acceleration in that clip -- 16.7 to 30.2 mph in two seconds -- is only
//  0.68 mph per sample. Noise and signal are the same size, which is why an
//  unsmoothed needle looks broken even though the data is fine.
//
//  A half-second window drops the 99th percentile step to 0.88 mph and costs a
//  quarter second of lag, which is not visible against footage. That is the
//  default; it is a knob because a drone and a mountain bike want different
//  answers.
//

import Foundation

struct Smoothing {
    /// Width of the averaging window, in seconds. Zero passes values through.
    var seconds: Double

    /// Half a second: enough to settle the needle, too little lag to notice.
    static let `default` = Smoothing(seconds: 0.5)
    static let none = Smoothing(seconds: 0)
    /// For very jittery mounts, at the cost of a visible lag.
    static let heavy = Smoothing(seconds: 2.0)

    var isEnabled: Bool { seconds > 0 }
}

extension TelemetryTrack {

    /// A copy whose speeds and altitudes are averaged over the window.
    ///
    /// Positions are deliberately left alone: a map trace is drawn from the
    /// whole route at once, where averaging would round off real corners, and
    /// the fix-to-fix scatter is far smaller relative to the distances a map
    /// shows than it is on a speed dial.
    func smoothed(_ smoothing: Smoothing) -> TelemetryTrack {
        guard smoothing.isEnabled, samples.count > 1 else { return self }

        var result = self
        let window = smoothing.seconds
        var start = 0

        for index in samples.indices {
            let now = samples[index].time
            // Trailing window: a gauge cannot average over readings that have
            // not happened yet without lagging by the whole window.
            while start < index, now - samples[start].time > window { start += 1 }
            let slice = samples[start...index]
            let count = Double(slice.count)
            result.samples[index].speed2D = slice.reduce(0) { $0 + $1.speed2D } / count
            result.samples[index].speed3D = slice.reduce(0) { $0 + $1.speed3D } / count
            result.samples[index].altitude = slice.reduce(0) { $0 + $1.altitude } / count
        }
        return result
    }
}
