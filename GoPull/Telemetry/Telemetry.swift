//
//  Telemetry.swift
//  GoPull
//
//  The GPS track a GoPro records alongside the video.
//
//  A MISSION 1 PRO emits `GPS9` at 10 Hz: latitude, longitude, altitude, 2D and
//  3D speed, the date as days since 2000 and seconds into the day, dilution of
//  precision, and the fix. Older bodies emit `GPS5` (no per-sample time or fix,
//  those come from sibling `GPSU`/`GPSF`/`GPSP` items), so both are read.
//
//  Every value arrives as an integer that must be divided by the matching entry
//  in the stream's `SCAL`, which is why the scales are read per stream rather
//  than assumed.
//

import CoreLocation
import Foundation

struct GPSSample {
    var latitude: Double
    var longitude: Double
    /// Metres.
    var altitude: Double
    /// Metres per second, over the ground.
    var speed2D: Double
    /// Metres per second, including vertical movement.
    var speed3D: Double
    /// Seconds from the start of the clip.
    var time: Double
    /// When the fix was taken, when the camera reported it.
    var timestamp: Date?
    /// Dilution of precision. Lower is better; 9999 means "no idea".
    var dop: Double
    /// 0 none, 2 a 2D fix, 3 a 3D fix.
    var fix: Int

    /// Whether this sample is worth plotting.
    ///
    /// The camera emits samples from the moment recording starts, including
    /// while it is still searching — those carry fix 0, DOP 99.99 and a stale
    /// position, and drawing them puts a false point on the map.
    var isUsable: Bool { fix >= 2 && dop < 50 }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Everything read from one clip's telemetry.
struct TelemetryTrack {
    var samples: [GPSSample] = []

    var usable: [GPSSample] { samples.filter(\.isUsable) }
    var hasFix: Bool { usable.count >= 2 }

    var duration: Double { samples.last.map { $0.time } ?? 0 }
    var topSpeed: Double { usable.map(\.speed2D).max() ?? 0 }

    /// Metres climbed.
    ///
    /// Summing every positive step between 10 Hz samples measures GPS noise,
    /// not climbing; applying a threshold to steps that small instead discards
    /// the climb entirely (a real 3.5 km ride reported 1 m). So altitude is
    /// averaged into one-second buckets first, and the threshold applied to
    /// those.
    var ascent: Double {
        let seconds = altitudePerSecond
        guard seconds.count > 1 else { return 0 }
        return zip(seconds, seconds.dropFirst()).reduce(0) { total, pair in
            let gain = pair.1 - pair.0
            return gain > 0.5 ? total + gain : total
        }
    }

    /// Altitude averaged per second, which is also what an elevation plot wants.
    var altitudePerSecond: [Double] {
        var buckets: [Int: (sum: Double, count: Int)] = [:]
        for sample in usable {
            let second = Int(sample.time)
            let entry = buckets[second] ?? (0, 0)
            buckets[second] = (entry.sum + sample.altitude, entry.count + 1)
        }
        return buckets.keys.sorted().compactMap { key in
            guard let entry = buckets[key], entry.count > 0 else { return nil }
            return entry.sum / Double(entry.count)
        }
    }

    /// The corners of the track, for framing a map.
    var bounds: (southWest: CLLocationCoordinate2D, northEast: CLLocationCoordinate2D)? {
        let points = usable
        guard let first = points.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for point in points.dropFirst() {
            minLat = min(minLat, point.latitude); maxLat = max(maxLat, point.latitude)
            minLon = min(minLon, point.longitude); maxLon = max(maxLon, point.longitude)
        }
        return (CLLocationCoordinate2D(latitude: minLat, longitude: minLon),
                CLLocationCoordinate2D(latitude: maxLat, longitude: maxLon))
    }

    /// The path to draw on a map.
    var route: [CLLocationCoordinate2D] { usable.map(\.coordinate) }

    /// Ground distance in metres, from the fixes themselves.
    var distance: Double {
        let points = usable
        guard points.count > 1 else { return 0 }
        return zip(points, points.dropFirst()).reduce(0) { sum, pair in
            sum + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
        }
    }

    /// The reading at a moment in the clip, interpolated, for driving an overlay.
    ///
    /// Returns nil outside the window where the camera actually had a fix
    /// rather than clamping to the nearest one -- a speed gauge must read
    /// "no GPS" over the opening seconds, not repeat the first fix it ever got.
    /// Between samples the values are interpolated, because a gauge is drawn
    /// far more often than 10 Hz and stepping is visible.
    func sample(at time: Double) -> GPSSample? {
        let points = usable
        guard points.count > 1,
              time >= points[0].time, time <= points[points.count - 1].time
        else { return nil }

        var low = 0, high = points.count - 1
        while low + 1 < high {
            let mid = (low + high) / 2
            if points[mid].time <= time { low = mid } else { high = mid }
        }
        let a = points[low], b = points[low + 1]
        let span = b.time - a.time
        guard span > 0 else { return a }
        let t = (time - a.time) / span

        func lerp(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        var result = a
        result.latitude = lerp(a.latitude, b.latitude)
        result.longitude = lerp(a.longitude, b.longitude)
        result.altitude = lerp(a.altitude, b.altitude)
        result.speed2D = lerp(a.speed2D, b.speed2D)
        result.speed3D = lerp(a.speed3D, b.speed3D)
        result.time = time
        return result
    }

    /// The window in which the camera had a usable fix.
    var fixWindow: ClosedRange<Double>? {
        let points = usable
        guard let first = points.first, let last = points.last, first.time < last.time
        else { return nil }
        return first.time ... last.time
    }
}

enum TelemetryReader {

    /// Reads the GPS track from a GoPro MP4 — an imported clip, or the small
    /// MP4 the camera serves from `/gopro/media/telemetry`.
    static func read(_ url: URL) throws -> TelemetryTrack {
        let payloads = try GPMFTrack.payloads(of: url)
        var track = TelemetryTrack()
        for payload in payloads {
            track.samples += samples(in: payload)
        }
        return track
    }

    /// GPS samples from one payload, with times spread across its duration.
    static func samples(in payload: GPMFPayload) -> [GPSSample] {
        var result: [GPSSample] = []
        for device in GPMF.parse(payload.data) where device.key == "DEVC" {
            for stream in device.all("STRM") {
                let found = gps(in: stream, payload: payload)
                if !found.isEmpty { result += found }
            }
        }
        return result
    }

    private static func gps(in stream: GPMFItem, payload: GPMFPayload) -> [GPSSample] {
        guard let scal = stream.first("SCAL") else { return [] }
        // SCAL is int32 on GPS9 streams and int16 on some older ones.
        let scales: [Double] = scal.type == UInt8(ascii: "s")
            ? scal.int16s.map { Double($0) }
            : scal.int32s.map { Double($0) }
        guard !scales.isEmpty else { return [] }

        func scale(_ index: Int) -> Double {
            let value = index < scales.count ? scales[index] : scales[scales.count - 1]
            return value == 0 ? 1 : value
        }

        if let gps9 = stream.first("GPS9"), gps9.structSize >= 32, gps9.count > 0 {
            return (0..<gps9.count).compactMap { i in
                let base = i * gps9.structSize
                guard base + 32 <= gps9.payload.count else { return nil }
                func i32(_ at: Int) -> Double {
                    Double(Int32(bitPattern: gps9.payload.uint32(at: base + at)))
                }
                func u16(_ at: Int) -> Double { Double(gps9.payload.uint16(at: base + at)) }

                let days = i32(20), secs = i32(24) / scale(6)
                let stamp = Self.date(days: days / scale(5), seconds: secs)
                let fraction = gps9.count > 1 ? Double(i) / Double(gps9.count) : 0
                return GPSSample(latitude: i32(0) / scale(0),
                                 longitude: i32(4) / scale(1),
                                 altitude: i32(8) / scale(2),
                                 speed2D: i32(12) / scale(3),
                                 speed3D: i32(16) / scale(4),
                                 time: payload.time + payload.duration * fraction,
                                 timestamp: stamp,
                                 dop: u16(28) / scale(7),
                                 fix: Int(u16(30) / scale(8)))
            }
        }

        // GPS5: five int32s per sample, with fix, precision and time alongside.
        if let gps5 = stream.first("GPS5"), gps5.structSize >= 20, gps5.count > 0 {
            let fix = stream.first("GPSF").map { Int($0.payload.uint32(at: 0)) } ?? 3
            let dop = stream.first("GPSP").map { Double($0.payload.uint16(at: 0)) / 100 } ?? 0
            let stamp = stream.first("GPSU").flatMap { Self.gpsuDate($0.string) }
            return (0..<gps5.count).compactMap { i in
                let base = i * gps5.structSize
                guard base + 20 <= gps5.payload.count else { return nil }
                func i32(_ at: Int) -> Double {
                    Double(Int32(bitPattern: gps5.payload.uint32(at: base + at)))
                }
                let fraction = gps5.count > 1 ? Double(i) / Double(gps5.count) : 0
                return GPSSample(latitude: i32(0) / scale(0),
                                 longitude: i32(4) / scale(1),
                                 altitude: i32(8) / scale(2),
                                 speed2D: i32(12) / scale(3),
                                 speed3D: i32(16) / scale(4),
                                 time: payload.time + payload.duration * fraction,
                                 timestamp: stamp,
                                 dop: dop,
                                 fix: fix)
            }
        }
        return []
    }

    /// GPS9 dates count days from 2000-01-01 and seconds into that day.
    private static func date(days: Double, seconds: Double) -> Date? {
        guard days > 0 else { return nil }
        var components = DateComponents()
        components.year = 2000; components.month = 1; components.day = 1
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let epoch = calendar.date(from: components) else { return nil }
        return epoch.addingTimeInterval(days * 86_400 + seconds)
    }

    /// GPS5 cameras write "yymmddhhmmss.sss".
    private static func gpsuDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyMMddHHmmss.SSS"
        return formatter.date(from: text)
    }
}

extension GPSSample {
    /// Ground speed in miles per hour, which is what the gauge shows.
    var mph: Double { speed2D * 2.236936 }
    /// Ground speed in kilometres per hour.
    var kph: Double { speed2D * 3.6 }
}
