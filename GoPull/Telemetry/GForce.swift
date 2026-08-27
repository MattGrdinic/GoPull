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

    private static let gravity = 9.80665

    /// Reads the accelerometer track from a clip.
    static func read(_ url: URL) throws -> GForceTrack {
        let payloads = try GPMFTrack.payloads(of: url)
        var raw: [(time: Double, x: Double, y: Double, z: Double)] = []
        for payload in payloads {
            raw += readings(in: payload)
        }
        return track(from: raw)
    }

    /// The raw m/s² triples in one payload, timed across its duration.
    static func readings(in payload: GPMFPayload)
        -> [(time: Double, x: Double, y: Double, z: Double)] {
        var result: [(time: Double, x: Double, y: Double, z: Double)] = []
        for device in GPMF.parse(payload.data) where device.key == "DEVC" {
            for stream in device.all("STRM") {
                guard let accl = stream.first("ACCL"), accl.structSize >= 6, accl.count > 0,
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

    /// Removes gravity and converts to g.
    ///
    /// Gravity is whatever the signal averages out to over a second, which is
    /// true for any mounting and any orientation — a vehicle does not sustain
    /// a real acceleration for a whole second often enough to matter, and when
    /// it does the error is small next to the 1 g being removed.
    static func track(from raw: [(time: Double, x: Double, y: Double, z: Double)],
                      window: Double = 1.0) -> GForceTrack {
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
            let dx = (raw[index].x - gx) / gravity
            let dy = (raw[index].y - gy) / gravity
            let dz = (raw[index].z - gz) / gravity

            track.samples.append(GForceSample(time: raw[index].time,
                                              lateral: -dy,
                                              longitudinal: -dz,
                                              vertical: dx))
        }
        return track
    }
}
