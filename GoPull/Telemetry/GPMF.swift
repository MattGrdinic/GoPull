//
//  GPMF.swift
//  GoPull
//
//  Reader for GoPro's GPMF telemetry format.
//
//  GPMF is KLV: a 4-byte FourCC key, a 1-byte type, a 1-byte structure size, a
//  2-byte big-endian repeat count, then that many bytes of payload padded up to
//  a 4-byte boundary. A type of 0 means the payload is itself GPMF, which is
//  how streams nest inside devices.
//

import Foundation

/// One key/length/value item, and its children when it is a container.
struct GPMFItem {
    let key: String
    /// The GPMF type character: 'l' int32, 'f' float, 'c' char, 0 for nested…
    let type: UInt8
    /// Bytes per element.
    let structSize: Int
    /// How many elements the payload holds.
    let count: Int
    let payload: Data
    let children: [GPMFItem]

    var isContainer: Bool { type == 0 }

    /// The payload read as text, up to the first NUL.
    var string: String {
        let bytes = payload.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every child with this key, at this level only.
    func all(_ key: String) -> [GPMFItem] { children.filter { $0.key == key } }

    /// The first child with this key.
    func first(_ key: String) -> GPMFItem? { children.first { $0.key == key } }

    /// Big-endian signed 32-bit values, for `SCAL` and the like.
    var int32s: [Int32] {
        stride(from: 0, to: payload.count - 3, by: 4).map {
            Int32(bitPattern: payload.uint32(at: $0))
        }
    }

    var int16s: [Int16] {
        stride(from: 0, to: payload.count - 1, by: 2).map {
            Int16(bitPattern: payload.uint16(at: $0))
        }
    }
}

enum GPMF {

    /// Parses a GPMF payload into its items. Malformed input yields whatever
    /// was readable rather than throwing: telemetry is best-effort, and one bad
    /// stream should not cost the GPS track.
    static func parse(_ data: Data) -> [GPMFItem] {
        parse(data, from: 0, to: data.count)
    }

    private static func parse(_ data: Data, from start: Int, to end: Int) -> [GPMFItem] {
        var items: [GPMFItem] = []
        var offset = start

        while offset + 8 <= end {
            let key = String(decoding: data[data.startIndex + offset ..< data.startIndex + offset + 4],
                             as: UTF8.self)
            let type = data[data.startIndex + offset + 4]
            let structSize = Int(data[data.startIndex + offset + 5])
            let count = Int(data.uint16(at: offset + 6))
            let length = structSize * count
            let bodyStart = offset + 8

            // A length running past the buffer means the stream is damaged;
            // keep what was parsed rather than reading out of bounds.
            guard length >= 0, bodyStart + length <= end else { break }

            let body = data.subdata(in: data.startIndex + bodyStart ..< data.startIndex + bodyStart + length)
            let children = type == 0 ? parse(data, from: bodyStart, to: bodyStart + length) : []

            items.append(GPMFItem(key: key, type: type, structSize: structSize,
                                  count: count, payload: body, children: children))

            // Payloads are padded to a 4-byte boundary.
            offset = bodyStart + ((length + 3) / 4) * 4
        }
        return items
    }
}

extension Data {
    func uint16(at offset: Int) -> UInt16 {
        let i = startIndex + offset
        guard i + 1 < endIndex else { return 0 }
        return UInt16(self[i]) << 8 | UInt16(self[i + 1])
    }

    func uint32(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        guard i + 3 < endIndex else { return 0 }
        return UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16
             | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }

    func uint64(at offset: Int) -> UInt64 {
        UInt64(uint32(at: offset)) << 32 | UInt64(uint32(at: offset + 4))
    }
}
