//
//  GForce.swift
//  GoPull
//
//  The accelerometer track, turned into something a meter can show.
//
//  A GoPro records `ACCL` at 200 Hz in m/s², and it includes gravity: a camera
//  sitting still reads 1 g, not 0. So gravity is estimated by low-passing the
//  signal and subtracted, which also means this does not depend on knowing how
//  the camera was mounted — whichever way is down, the average points at it.
//
//  Which of the remaining axes is lateral and which is fore-and-aft *is*
//  mount-dependent, and was established from the data rather than from the
//  stream's ORIN field, which does not agree with the gravity stream's. On a
//  forward-facing mount, across 311 moving samples of a motorcycle ride:
//
//      axis 0   vertical        9.76 m/s² average, i.e. gravity
//      axis 1   lateral         r = -0.542 against v · dHeading/dt
//      axis 2   longitudinal    r = -0.431 against GPS d(speed)/dt
//
//  Each axis correlates with one thing and not the others, and the signs are
//  inverted relative to "right is positive, accelerating is positive", so they
//  are flipped here.
//

import Foundation

struct GForceSample {
    /// Seconds from the start of the clip.
    var time: Double
    /// Positive to the right of travel.
    var lateral: Double
    /// Positive under acceleration, negative under braking.
    var longitudinal: Double
    /// Positive upward — bumps and landings.
    var vertical: Double

    /// What the meter's needle or ball is at, ignoring the vertical axis.
    var planar: Double { (lateral * lateral + longitudinal * longitudinal).squareRoot() }
    /// Everything, including vertical.
    var total: Double {
        (lateral * lateral + longitudinal * longitudinal + vertical * vertical).squareRoot()
    }
}

struct GForceTrack {
    var samples: [GForceSample] = []

    var isEmpty: Bool { samples.isEmpty }
    var duration: Double { samples.last?.time ?? 0 }

    /// The hardest cornering or braking in the clip, for scaling the meter.
    var peakPlanar: Double { samples.map(\.planar).max() ?? 0 }

    /// The furthest the clip went each way, as positive magnitudes.
    ///
    /// Kept per direction rather than per axis: "0.51 right, 0.42 left" says
    /// something about a ride that "0.51 lateral" does not, and braking and
    /// acceleration are not the same achievement either.
    struct Extremes: Equatable {
        var left = 0.0, right = 0.0, accelerating = 0.0, braking = 0.0
        var vertical = 0.0

        var isEmpty: Bool {
            left == 0 && right == 0 && accelerating == 0 && braking == 0
        }
    }

    var extremes: Extremes {
        var result = Extremes()
        for sample in samples {
            if sample.lateral > 0 { result.right = Swift.max(result.right, sample.lateral) }
            else { result.left = Swift.max(result.left, -sample.lateral) }
            if sample.longitudinal > 0 {
                result.accelerating = Swift.max(result.accelerating, sample.longitudinal)
            } else {
                result.braking = Swift.max(result.braking, -sample.longitudinal)
            }
            result.vertical = Swift.max(result.vertical, abs(sample.vertical))
        }
        return result
    }

    /// The extremes as they stood at each moment, rather than for the whole clip.
    ///
    /// A peak is something that happened, so it should appear when it happens
    /// and then stay put until it is beaten. Showing the clip's biggest hit from
    /// the first frame gives away a corner that is still a minute away, and made
    /// the marks look like fixed decoration rather than a record.
    ///
    /// Bucketed at 20 Hz: the values only ever climb, so a bucket costs at most
    /// 50 ms of freshness, which is under two frames and invisible. Per sample
    /// instead, a ten-minute clip at 200 Hz would hold 120,000 of these.
    struct RunningExtremes {
        private var times: [Double] = []
        private var values: [Extremes] = []

        /// The whole clip, for anything that wants the final figures.
        var final: Extremes { values.last ?? Extremes() }
        var isEmpty: Bool { values.isEmpty }

        init() {}

        init(_ track: GForceTrack, bucket: Double = 0.05) {
            var running = Extremes()
            var nextBucket = -Double.infinity
            for sample in track.samples {
                if sample.lateral > 0 { running.right = Swift.max(running.right, sample.lateral) }
                else { running.left = Swift.max(running.left, -sample.lateral) }
                if sample.longitudinal > 0 {
                    running.accelerating = Swift.max(running.accelerating, sample.longitudinal)
                } else {
                    running.braking = Swift.max(running.braking, -sample.longitudinal)
                }
                running.vertical = Swift.max(running.vertical, abs(sample.vertical))

                if sample.time >= nextBucket {
                    times.append(sample.time)
                    values.append(running)
                    nextBucket = sample.time + bucket
                } else {
                    values[values.count - 1] = running
                }
            }
        }

        /// What had been reached by `time`. Nothing, before the track starts.
        func at(_ time: Double) -> Extremes {
            guard let first = times.first, time >= first else { return Extremes() }
            var low = 0, high = times.count - 1
            while low + 1 < high {
                let mid = (low + high) / 2
                if times[mid] <= time { low = mid } else { high = mid }
            }
            return times[high] <= time ? values[high] : values[low]
        }
    }

    var runningExtremes: RunningExtremes { RunningExtremes(self) }

    /// The reading at a moment, interpolated so the ball moves smoothly.
    func sample(at time: Double) -> GForceSample? {
        guard samples.count > 1,
              time >= samples[0].time, time <= samples[samples.count - 1].time
        else { return samples.count == 1 ? samples[0] : nil }

        var low = 0, high = samples.count - 1
        while low + 1 < high {
            let mid = (low + high) / 2
            if samples[mid].time <= time { low = mid } else { high = mid }
        }
        let a = samples[low], b = samples[low + 1]
        let span = b.time - a.time
        guard span > 0 else { return a }
        let t = (time - a.time) / span
        func lerp(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        return GForceSample(time: time,
                            lateral: lerp(a.lateral, b.lateral),
                            longitudinal: lerp(a.longitudinal, b.longitudinal),
                            vertical: lerp(a.vertical, b.vertical))
    }

    /// A trailing average, the same idea as the speed smoothing: raw 200 Hz
    /// accelerometer is far too lively to read.
    func smoothed(_ smoothing: Smoothing) -> GForceTrack {
        guard smoothing.isEnabled, samples.count > 1 else { return self }
        var result = self
        var start = 0
        for index in samples.indices {
            let now = samples[index].time
            while start < index, now - samples[start].time > smoothing.seconds { start += 1 }
            let slice = samples[start...index]
            let count = Double(slice.count)
            result.samples[index].lateral = slice.reduce(0) { $0 + $1.lateral } / count
            result.samples[index].longitudinal = slice.reduce(0) { $0 + $1.longitudinal } / count
            result.samples[index].vertical = slice.reduce(0) { $0 + $1.vertical } / count
        }
        return result
    }
}

enum GForceReader {

    /// Standard gravity, m/s². Named in full so a `gravity:` parameter cannot
    /// quietly shadow it.
    private static let standardGravity = 9.80665

    /// Reads the accelerometer track from a clip.
    ///
    /// Prefers the camera's own `GRAV` stream for gravity. Low-passing ACCL
    /// instead cannot tell gravity from a sustained acceleration, and a launch
    /// is exactly that: measured on GX010053, a 2.2-second 0-30 that really
    /// pulled 0.63 g came back as 0.02 g, because a one-second average of a
    /// two-second pull *is* the pull.
    static func read(_ url: URL) throws -> GForceTrack {
        let payloads = try GPMFTrack.payloads(of: url)
        var raw: [(time: Double, x: Double, y: Double, z: Double)] = []
        var gravity: [(time: Double, x: Double, y: Double, z: Double)] = []
        for payload in payloads {
            raw += readings(in: payload)
            gravity += readings(in: payload, key: "GRAV")
        }
        return gravity.isEmpty ? track(from: raw) : track(from: raw, gravity: gravity)
    }

    /// The raw triples in one payload, timed across its duration.
    ///
    /// `ACCL` is m/s²; `GRAV` is a unit vector pointing along gravity.
    static func readings(in payload: GPMFPayload, key: String = "ACCL")
        -> [(time: Double, x: Double, y: Double, z: Double)] {
        var result: [(time: Double, x: Double, y: Double, z: Double)] = []
        for device in GPMF.parse(payload.data) where device.key == "DEVC" {
            for stream in device.all("STRM") {
                guard let accl = stream.first(key), accl.structSize >= 6, accl.count > 0,
                      let scal = stream.first("SCAL")
                else { continue }
                let scale = Double(scal.int16s.first ?? 1)
                guard scale != 0 else { continue }

                for i in 0..<accl.count {
                    let base = i * accl.structSize
                    guard base + 6 <= accl.payload.count else { break }
                    func value(_ at: Int) -> Double {
                        Double(Int16(bitPattern: accl.payload.uint16(at: base + at))) / scale
                    }
                    let fraction = accl.count > 1 ? Double(i) / Double(accl.count) : 0
                    result.append((payload.time + payload.duration * fraction,
                                   value(0), value(2), value(4)))
                }
            }
        }
        return result
    }

    /// Removes gravity using the camera's `GRAV` stream, and converts to g.
    ///
    /// `GRAV` does not use ACCL's axis order. Established on GX010053 by
    /// pairing every axis with every other and taking the clip-average
    /// residual: the vehicle averages no acceleration over four minutes, so the
    /// right pairing is the one that leaves nothing behind. `ACCL0-GRAV1`
    /// leaves +0.034 g, `ACCL1-GRAV0` +0.022 g and `ACCL2-GRAV2` +0.011 g,
    /// while every other pairing leaves about a whole g. So ACCL's first two
    /// axes are swapped relative to GRAV's, and nothing is sign-flipped.
    ///
    /// Against GPS the longitudinal channel then correlates at r = -0.86 over
    /// the whole clip and reports 87% of the true mean across six launches
    /// (76-94%), against 4% for the low-pass it replaces. The shortfall is
    /// expected: GPS "truth" averages the whole 0-30 including the roll-out,
    /// and the chassis pitches under power while the wheels do not.
    static func track(from raw: [(time: Double, x: Double, y: Double, z: Double)],
                      gravity: [(time: Double, x: Double, y: Double, z: Double)])
        -> GForceTrack {
        guard raw.count > 1, !gravity.isEmpty else { return GForceTrack() }
        var track = GForceTrack()
        track.samples.reserveCapacity(raw.count)

        // GRAV runs at 30 Hz against ACCL's 200 Hz, so walk it alongside.
        var index = 0
        for sample in raw {
            while index + 1 < gravity.count, gravity[index + 1].time <= sample.time { index += 1 }
            let g = gravity[index]
            // Swapped: ACCL x pairs with GRAV y, ACCL y with GRAV x.
            let dx = sample.x / standardGravity - g.y
            let dy = sample.y / standardGravity - g.x
            let dz = sample.z / standardGravity - g.z
            track.samples.append(GForceSample(time: sample.time,
                                              lateral: -dy,
                                              longitudinal: -dz,
                                              vertical: dx))
        }
        return track
    }

    /// Removes gravity by low-passing, for clips with no `GRAV` stream.
    ///
    /// Gravity is whatever the signal averages out to over a second, which is
    /// true for any mounting and any orientation — a vehicle does not sustain
    /// a real acceleration for a whole second often enough to matter, and when
    /// it does the error is small next to the 1 g being removed.
    ///
    /// The window is long deliberately. It cannot separate gravity from a
    /// sustained acceleration at all, so the only choice is how much of a real
    /// pull it eats: at one second a 2.2-second launch kept 4% of its true
    /// 0.63 g, at five seconds 27%, at twenty 40%. Prefer `GRAV`.
    static func track(from raw: [(time: Double, x: Double, y: Double, z: Double)],
                      window: Double = 10.0) -> GForceTrack {
        guard raw.count > 1 else { return GForceTrack() }

        var track = GForceTrack()
        track.samples.reserveCapacity(raw.count)
        var start = 0
        var sumX = 0.0, sumY = 0.0, sumZ = 0.0
        var end = 0

        for index in raw.indices {
            let now = raw[index].time
            // Centred window where there is one, so the estimate does not lag.
            while end < raw.count, raw[end].time <= now + window / 2 {
                sumX += raw[end].x; sumY += raw[end].y; sumZ += raw[end].z
                end += 1
            }
            while start < end, raw[start].time < now - window / 2 {
                sumX -= raw[start].x; sumY -= raw[start].y; sumZ -= raw[start].z
                start += 1
            }
            let n = Double(max(end - start, 1))
            let gx = sumX / n, gy = sumY / n, gz = sumZ / n

            // What is left after gravity, in g.
            let dx = (raw[index].x - gx) / standardGravity
            let dy = (raw[index].y - gy) / standardGravity
            let dz = (raw[index].z - gz) / standardGravity

            track.samples.append(GForceSample(time: raw[index].time,
                                              lateral: -dy,
                                              longitudinal: -dz,
                                              vertical: dx))
        }
        return track
    }
}
