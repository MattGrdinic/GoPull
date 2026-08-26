//
//  GPMFTrack.swift
//  GoPull
//
//  Pulls the GPMF payloads out of a GoPro MP4.
//
//  This exists because **AVFoundation cannot see the track**. A GoPro clip
//  carries its telemetry in a fourth track whose handler is `mhlr/meta` named
//  "GoPro MET", and `AVAsset.load(.tracks)` reports only three — video, audio
//  and timecode. Verified against an 11.5 GB MISSION 1 PRO clip whose `moov`
//  plainly contains the track. So the sample table is walked by hand.
//
//  Only what is needed to find one track's samples is implemented: the box
//  tree down to `stbl`, then `stsd`/`stsz`/`stsc`/`stco`/`co64`/`stts`.
//

import Foundation

/// One GPMF payload and when it starts, in seconds from the beginning.
struct GPMFPayload {
    let time: Double
    let duration: Double
    let data: Data
}

enum GPMFTrackError: LocalizedError {
    case notAnMP4
    case noTelemetryTrack

    var errorDescription: String? {
        switch self {
        case .notAnMP4:         return "That file is not an MP4."
        case .noTelemetryTrack: return "This clip carries no GoPro telemetry track."
        }
    }
}

enum GPMFTrack {

    /// Reads every GPMF payload from a GoPro MP4 without loading the file.
    ///
    /// Clips run to double-digit gigabytes, so this seeks: the sample table is
    /// read from `moov`, then each payload is read from `mdat` by offset. Total
    /// read is the size of the telemetry, typically a few hundred KB.
    static func payloads(of url: URL) throws -> [GPMFPayload] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let size = try handle.seekToEnd()
        guard size > 8 else { throw GPMFTrackError.notAnMP4 }

        guard let moov = try box(named: "moov", in: handle, from: 0, to: size) else {
            throw GPMFTrackError.notAnMP4
        }
        guard let table = try telemetryTable(in: handle, moov: moov) else {
            throw GPMFTrackError.noTelemetryTrack
        }

        var payloads: [GPMFPayload] = []
        payloads.reserveCapacity(table.offsets.count)
        for (index, offset) in table.offsets.enumerated() {
            let length = table.sizes[index]
            guard length > 0 else { continue }
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: length), data.count == length else { continue }
            let (start, duration) = table.timing(of: index)
            payloads.append(GPMFPayload(time: start, duration: duration, data: data))
        }
        return payloads
    }

    // MARK: - Box walking

    private struct Box {
        let type: String
        let start: UInt64      // first byte of the box
        let bodyStart: UInt64  // first byte after the header
        let end: UInt64
    }

    private static func boxes(in handle: FileHandle,
                              from start: UInt64, to end: UInt64) throws -> [Box] {
        var result: [Box] = []
        var offset = start
        while offset + 8 <= end {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 8), header.count == 8 else { break }
            var size = UInt64(header.uint32(at: 0))
            let type = String(decoding: header[header.startIndex + 4 ..< header.startIndex + 8], as: UTF8.self)
            var headerSize: UInt64 = 8
            if size == 1 {
                guard let large = try handle.read(upToCount: 8), large.count == 8 else { break }
                size = large.uint64(at: 0)
                headerSize = 16
            } else if size == 0 {
                size = end - offset
            }
            guard size >= headerSize, offset + size <= end else { break }
            result.append(Box(type: type, start: offset,
                              bodyStart: offset + headerSize, end: offset + size))
            offset += size
        }
        return result
    }

    private static func box(named name: String, in handle: FileHandle,
                            from start: UInt64, to end: UInt64) throws -> Box? {
        try boxes(in: handle, from: start, to: end).first { $0.type == name }
    }

    // MARK: - The sample table

    private struct SampleTable {
        var offsets: [UInt64] = []
        var sizes: [Int] = []
        /// `stts` run-length pairs: (sample count, duration in timescale units).
        var deltas: [(count: UInt32, delta: UInt32)] = []
        var timescale: Double = 1

        /// Start and duration in seconds for one sample.
        func timing(of index: Int) -> (Double, Double) {
            var seen = 0
            var ticks: UInt64 = 0
            for run in deltas {
                if index < seen + Int(run.count) {
                    ticks += UInt64(index - seen) * UInt64(run.delta)
                    return (Double(ticks) / timescale, Double(run.delta) / timescale)
                }
                seen += Int(run.count)
                ticks += UInt64(run.count) * UInt64(run.delta)
            }
            return (Double(ticks) / timescale, 0)
        }
    }

    /// The GoPro telemetry track is the one whose handler is `meta` and whose
    /// sample description is `gpmd`.
    private static func telemetryTable(in handle: FileHandle, moov: Box) throws -> SampleTable? {
        for trak in try boxes(in: handle, from: moov.bodyStart, to: moov.end)
                        where trak.type == "trak" {
            guard let mdia = try box(named: "mdia", in: handle, from: trak.bodyStart, to: trak.end),
                  let hdlr = try box(named: "hdlr", in: handle, from: mdia.bodyStart, to: mdia.end),
                  let minf = try box(named: "minf", in: handle, from: mdia.bodyStart, to: mdia.end),
                  let stbl = try box(named: "stbl", in: handle, from: minf.bodyStart, to: minf.end)
            else { continue }

            try handle.seek(toOffset: hdlr.bodyStart)
            guard let hdlrData = try handle.read(upToCount: 24), hdlrData.count >= 12 else { continue }
            // handler type sits 8 bytes in, after version/flags and a reserved word
            let handlerType = String(decoding: hdlrData[hdlrData.startIndex + 8 ..< hdlrData.startIndex + 12],
                                     as: UTF8.self)
            guard handlerType == "meta" else { continue }

            guard let stsd = try box(named: "stsd", in: handle, from: stbl.bodyStart, to: stbl.end) else { continue }
            try handle.seek(toOffset: stsd.bodyStart)
            let stsdLength = Int(stsd.end - stsd.bodyStart)
            guard let stsdData = try handle.read(upToCount: min(stsdLength, 64)),
                  stsdData.count >= 16 else { continue }
            // version/flags (4) + entry count (4) + entry size (4) + format (4)
            let format = String(decoding: stsdData[stsdData.startIndex + 12 ..< stsdData.startIndex + 16],
                                as: UTF8.self)
            guard format == "gpmd" else { continue }

            return try sampleTable(in: handle, mdia: mdia, stbl: stbl)
        }
        return nil
    }

    private static func sampleTable(in handle: FileHandle, mdia: Box, stbl: Box) throws -> SampleTable {
        var table = SampleTable()

        if let mdhd = try box(named: "mdhd", in: handle, from: mdia.bodyStart, to: mdia.end) {
            try handle.seek(toOffset: mdhd.bodyStart)
            if let d = try handle.read(upToCount: 20), d.count >= 20 {
                // version 0: creation(4) modification(4) timescale(4) duration(4)
                let scale = d[d.startIndex] == 0 ? d.uint32(at: 12) : d.uint32(at: 20)
                if scale > 0 { table.timescale = Double(scale) }
            }
        }

        func body(_ name: String) throws -> Data? {
            guard let b = try box(named: name, in: handle, from: stbl.bodyStart, to: stbl.end)
            else { return nil }
            try handle.seek(toOffset: b.bodyStart)
            return try handle.read(upToCount: Int(b.end - b.bodyStart))
        }

        if let stsz = try body("stsz"), stsz.count >= 12 {
            let uniform = Int(stsz.uint32(at: 4))
            let count = Int(stsz.uint32(at: 8))
            if uniform > 0 {
                table.sizes = Array(repeating: uniform, count: count)
            } else {
                table.sizes = (0..<count).compactMap {
                    let at = 12 + $0 * 4
                    return at + 4 <= stsz.count ? Int(stsz.uint32(at: at)) : nil
                }
            }
        }

        if let co64 = try body("co64"), co64.count >= 8 {
            let count = Int(co64.uint32(at: 4))
            table.offsets = (0..<count).compactMap {
                let at = 8 + $0 * 8
                return at + 8 <= co64.count ? co64.uint64(at: at) : nil
            }
        } else if let stco = try body("stco"), stco.count >= 8 {
            let count = Int(stco.uint32(at: 4))
            table.offsets = (0..<count).compactMap {
                let at = 8 + $0 * 4
                return at + 4 <= stco.count ? UInt64(stco.uint32(at: at)) : nil
            }
        }

        if let stts = try body("stts"), stts.count >= 8 {
            let count = Int(stts.uint32(at: 4))
            table.deltas = (0..<count).compactMap {
                let at = 8 + $0 * 8
                guard at + 8 <= stts.count else { return nil }
                return (stts.uint32(at: at), stts.uint32(at: at + 4))
            }
        }

        // GoPro writes one telemetry sample per chunk, so offsets and sizes line
        // up 1:1 and `stsc` needs no interpreting. Guard rather than assume.
        let usable = min(table.offsets.count, table.sizes.count)
        table.offsets = Array(table.offsets.prefix(usable))
        table.sizes = Array(table.sizes.prefix(usable))
        return table
    }
}
