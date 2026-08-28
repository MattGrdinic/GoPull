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

/// Why a clip produced no launches, so the answer is not just "none found".
///
/// A clip can be full of standing starts and still report nothing, because a
/// run has to reach the lowest target *and* average a real rate getting there.
/// On a trail ride that is usually the whole story: eight stops, and the best
/// of them took ninety seconds to reach 31 mph.
struct AccelerationDiagnosis: Equatable {
    var stops = 0
    /// Best speed reached after any stop, in the settings' unit.
    var bestSpeed = 0.0
    /// Best average rate *to the lowest target*, among the stretches that
    /// actually got there.
    ///
    /// Measured over the whole moving stretch instead, a 0.4-second wobble that
    /// touched 1.1 mph reported 2.8 mph/s and made the explanation nonsense.
    var bestRate = 0.0

    func explanation(_ settings: AccelerationSettings) -> String {
        let unit = settings.unit.label
        guard stops > 0 else {
            return "No standing start in this clip — it never comes to a stop with a GPS fix."
        }
        guard let target = settings.targets.min() else { return "No targets set." }
        if bestSpeed < Double(target) {
            return String(format: "%d stop%@, but the fastest reached only %.0f %@ — under the "
                          + "%d %@ target. Try a lower one.",
                          stops, stops == 1 ? "" : "s", bestSpeed, unit, target, unit)
        }
        return String(format: "%d stop%@, but none picked up quickly enough — the best averaged "
                      + "%.1f %@ per second to %d %@. Pulling away gently is not a launch.",
                      stops, stops == 1 ? "" : "s", bestRate, unit, target, unit)
    }
}

enum AccelerationDetector {

    /// What the clip contains, when it contains no launches.
    static func diagnose(in track: TelemetryTrack,
                         settings: AccelerationSettings = .init()) -> AccelerationDiagnosis {
        let points = track.usable
        var result = AccelerationDiagnosis()
        guard points.count > 2 else { return result }
        func speed(_ index: Int) -> Double {
            settings.unit.value(fromMetresPerSecond: points[index].speed2D)
        }

        var index = 0
        while index < points.count - 1 {
            guard speed(index) <= settings.restSpeed else { index += 1; continue }
            var lastAtRest = index
            while lastAtRest + 1 < points.count, speed(lastAtRest + 1) <= settings.restSpeed {
                lastAtRest += 1
            }
            var cursor = lastAtRest + 1
            var best = 0.0
            var reachedTargetAt: Double?
            let target = Double(settings.targets.min() ?? 0)
            while cursor < points.count, speed(cursor) > settings.restSpeed {
                let now = speed(cursor)
                best = Swift.max(best, now)
                if reachedTargetAt == nil, target > 0, now >= target {
                    reachedTargetAt = points[cursor].time
                }
                cursor += 1
            }
            if cursor > lastAtRest + 1 {
                result.stops += 1
                result.bestSpeed = Swift.max(result.bestSpeed, best)
                // Only stretches that got to the target say anything about the
                // rate needed to get there.
                if let reached = reachedTargetAt {
                    let elapsed = reached - points[lastAtRest].time
                    if elapsed > 0 {
                        result.bestRate = Swift.max(result.bestRate, target / elapsed)
                    }
                }
            }
            index = Swift.max(cursor, lastAtRest + 1)
        }
        return result
    }

    /// Finds every standing start in a clip.
    ///
    /// `gforce` is optional; with it the start time is pinned from the
    /// accelerometer, which is both earlier and far more precise than the
    /// moment GPS speed convincingly leaves zero. Pass the *raw* tracks: this
    /// smooths the accelerometer itself, by a fixed amount, so a reported 0-60
    /// does not move when the display smoothing slider does.
    static func runs(in track: TelemetryTrack,
                     gforce: GForceTrack? = nil,
                     settings: AccelerationSettings = .init()) -> [AccelerationRun] {
        let points = track.usable
        guard points.count > 2, !settings.targets.isEmpty else { return [] }
        let unit = settings.unit
        func speed(_ index: Int) -> Double {
            unit.value(fromMetresPerSecond: points[index].speed2D)
        }

        // Enough to clear the 200 Hz noise floor without blunting the onset:
        // raw, the noise alone can hold 0.02 g for the 20 samples the sustained
        // check asks for, which pins the start early.
        let onset = gforce?.smoothed(Smoothing(seconds: 0.1))

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

            // Re-anchor to the rest immediately before *this* departure.
            //
            // The search above stops at the first sample above `restSpeed`, but
            // `departureIndex` will happily scan past a creep and any amount of
            // rest after it. Measured on GX010050: two stationary samples of GPS
            // noise at 0.1s ended the "rest", the bike then sat still until 6.8s,
            // and the run was timed from 0.1s -- reporting a 3.5-second 0-30 as
            // 10.05s. The start is the last moment at rest before the departure,
            // not before the first stretch of rest in the clip.
            var anchor = departure - 1
            while anchor > lastAtRest, speed(anchor) > settings.restSpeed { anchor -= 1 }
            lastAtRest = anchor

            var run = AccelerationRun(start: points[lastAtRest].time)
            if let onset {
                run.start = refinedStart(near: points[lastAtRest].time,
                                         until: points[departure].time, in: onset)
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
