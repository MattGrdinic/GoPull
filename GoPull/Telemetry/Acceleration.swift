//
//  Acceleration.swift
//  GoPull
//
//  Standing-start times — 0-30, 0-60 and so on.
//
//  What the hardware allows, measured on a real card:
//
//    GPS speed        10 Hz, so 100 ms between samples and about 50 ms once
//                     the crossing is interpolated between the two either side
//    Speed noise      0.30 mph median from sample to sample
//    Accelerometer    200 Hz, and it moves before GPS speed does
//
//  So the error is set by how hard the launch is: at 15 mph/s a 0.30 mph wobble
//  is 20 ms, and at a trail-riding 2.5 mph/s it is 120 ms. The start is pinned
//  with the accelerometer rather than the GPS, because that is where most of
//  the error would otherwise sit — speed hovers around zero for a while before
//  it convincingly leaves it, while the push is unmistakable at 200 Hz.
//

import Foundation

/// One launch from rest, and the targets it reached.
struct AccelerationRun: Identifiable, Equatable {
    /// Seconds into the clip where the car or bike started moving.
    var start: Double
    /// Target speed (in the run's unit) to seconds taken.
    var splits: [Int: Double] = [:]
    /// The fastest it got before the run ended.
    var peak: Double = 0
    /// Where the run stopped being one.
    var end: Double = 0

    var id: Double { start }

    func time(to target: Int) -> Double? { splits[target] }
    var reached: [Int] { splits.keys.sorted() }
    var best: Int? { reached.last }
}

struct AccelerationSettings: Equatable, Codable {
    /// Targets to time, in the chosen unit.
    var targets: [Int] = [30, 60]
    var unit: SpeedUnit = .mph
    /// At or below this the vehicle counts as stopped.
    var restSpeed: Double = 1.0
    /// It has to stay above this for `departureHold` to count as having left.
    var movingSpeed: Double = 3.0
    var departureHold: Double = 0.6
    /// A run ends if speed falls back to this fraction of its peak.
    var giveUpFraction: Double = 0.6
    /// Longest a run may take before it is not a launch any more.
    var maxDuration: Double = 40
    /// Average rate to the first target, below which it was not a launch.
    ///
    /// Pulling away gently and reaching 10 mph twenty seconds later is not a
    /// standing start, and reporting it as one makes the good runs harder to
    /// find. Measured on a trail ride: a real launch managed 2.3 mph/s to its
    /// first target, a potter 0.45.
    var minimumRate: Double = 1.5

    static let porsche = AccelerationSettings(targets: [30, 60, 100])
    static let motorcycle = AccelerationSettings(targets: [30, 60])
}

enum AccelerationDetector {

    /// Finds every standing start in a clip.
    ///
    /// `gforce` is optional; with it the start time is pinned from the
    /// accelerometer, which is both earlier and far more precise than the
    /// moment GPS speed convincingly leaves zero.
    static func runs(in track: TelemetryTrack,
                     gforce: GForceTrack? = nil,
                     settings: AccelerationSettings = .init()) -> [AccelerationRun] {
        let points = track.usable
        guard points.count > 2, !settings.targets.isEmpty else { return [] }
        let unit = settings.unit
        func speed(_ index: Int) -> Double {
            unit.value(fromMetresPerSecond: points[index].speed2D)
        }

        var result: [AccelerationRun] = []
        var index = 0

        while index < points.count - 1 {
            // Find a stretch at rest.
            guard speed(index) <= settings.restSpeed else { index += 1; continue }
            var lastAtRest = index
            while lastAtRest + 1 < points.count, speed(lastAtRest + 1) <= settings.restSpeed {
                lastAtRest += 1
            }

            // It has to *stay* moving. Speed hovers around zero and a single
            // noisy sample above the threshold is not a launch -- that is what
            // made a whole clip look like one 45-second run.
            guard let departure = departureIndex(after: lastAtRest, points: points,
                                                 speed: speed, settings: settings)
            else { index = lastAtRest + 1; continue }

            var run = AccelerationRun(start: points[lastAtRest].time)
            if let gforce {
                run.start = refinedStart(near: points[lastAtRest].time,
                                         until: points[departure].time, in: gforce)
            }

            var peak = 0.0
            var cursor = departure
            while cursor < points.count {
                let now = speed(cursor)
                peak = max(peak, now)
                run.end = points[cursor].time

                if points[cursor].time - run.start > settings.maxDuration { break }
                if now < peak * settings.giveUpFraction, now < Double(settings.targets.min() ?? 0) {
                    break
                }
                for target in settings.targets where run.splits[target] == nil && now >= Double(target) {
                    // Interpolate across the pair either side of the crossing;
                    // at 10 Hz that is the difference between 100 ms and 50 ms
                    // of quantisation.
                    let previous = points[max(cursor - 1, 0)]
                    let before = speed(max(cursor - 1, 0))
                    let crossing: Double
                    if now != before {
                        let fraction = (Double(target) - before) / (now - before)
                        crossing = previous.time + (points[cursor].time - previous.time) * fraction
                    } else {
                        crossing = points[cursor].time
                    }
                    run.splits[target] = crossing - run.start
                }
                if run.splits.count == settings.targets.count { break }
                cursor += 1
            }
            run.peak = peak
            if let first = settings.targets.min(), let taken = run.splits[first],
               taken > 0, Double(first) / taken >= settings.minimumRate {
                result.append(run)
            }
            index = max(cursor, lastAtRest + 1)
        }
        return result
    }

    /// The first index after rest where the speed stays above `movingSpeed`.
    private static func departureIndex(after lastAtRest: Int, points: [GPSSample],
                                       speed: (Int) -> Double,
                                       settings: AccelerationSettings) -> Int? {
        var index = lastAtRest + 1
        while index < points.count {
            guard speed(index) > settings.movingSpeed else { index += 1; continue }
            // Does it hold?
            var check = index
            var held = true
            while check < points.count,
                  points[check].time - points[index].time < settings.departureHold {
                if speed(check) <= settings.restSpeed { held = false; break }
                check += 1
            }
            if held { return index }
            index = check + 1
        }
        return nil
    }

    /// The moment the push actually starts, from the accelerometer.
    ///
    /// GPS speed leaves zero slowly and noisily; a 200 Hz accelerometer sees
    /// the launch immediately, which is worth about a tenth of a second on a
    /// gentle start and rather more on a hard one.
    private static func refinedStart(near restEnd: Double, until departure: Double,
                                     in gforce: GForceTrack) -> Double {
        let window = gforce.samples.filter { $0.time >= restEnd - 1.0 && $0.time <= departure }
        guard !window.isEmpty else { return restEnd }
        // The first sustained forward push, rather than one noisy sample.
        for (offset, sample) in window.enumerated() where sample.longitudinal > 0.05 {
            let ahead = window[offset..<min(offset + 20, window.count)]
            if ahead.allSatisfy({ $0.longitudinal > 0.02 }) { return sample.time }
        }
        return restEnd
    }
}

extension Array where Element == AccelerationRun {
    /// The quickest time anything in this clip managed to a target.
    func best(to target: Int) -> AccelerationRun? {
        filter { $0.splits[target] != nil }
            .min { ($0.splits[target] ?? .infinity) < ($1.splits[target] ?? .infinity) }
    }

    /// The run covering a moment, for driving a live readout.
    func run(at time: Double) -> AccelerationRun? {
        // `max` inside an Array extension resolves to the sequence method.
        last { time >= $0.start && time <= Swift.max($0.end, $0.start) + 3 }
    }
}
