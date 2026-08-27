//
//  TIFFContainer.swift
//  GoPull
//
//  Just enough TIFF to take a GPR apart and put a DNG back together.
//
//  A GPR *is* a DNG: same tags, same colour matrices, same opcode lists. The
//  only thing a standard reader cannot cope with is that its single tile is
//  VC-5 compressed. So rather than build a DNG from scratch -- or vendor
//  Adobe's 104,000-line SDK to do it -- this reads the existing tag set,
//  swaps the compression and the tile, and writes it back out.
//
//  Offsets move when that happens, so every out-of-line value is copied to a
//  new position and any nested IFD is rewritten the same way rather than left
//  pointing at bytes that have shifted.
//

import Foundation

struct TIFFTag {
    static let compression: UInt16 = 259
    static let tileOffsets: UInt16 = 324
    static let tileByteCounts: UInt16 = 325
    static let exifIFD: UInt16 = 34665
    static let imageWidth: UInt16 = 256
    static let imageLength: UInt16 = 257
    static let photometric: UInt16 = 262
    static let bitsPerSample: UInt16 = 258
    static let whiteLevel: UInt16 = 50717
    static let cfaPattern: UInt16 = 33422
    static let dngVersion: UInt16 = 50706
}

/// One IFD entry, with its value already gathered up.
struct TIFFEntry {
    var tag: UInt16
    var type: UInt16
    var count: UInt32
    /// The bytes of the value, wherever they were stored.
    var value: Data

    /// Byte width of one element of this type.
    static func size(of type: UInt16) -> Int {
        switch type {
        case 1, 2, 6, 7: return 1
        case 3, 8:       return 2
        case 4, 9, 11:   return 4
        case 5, 10, 12:  return 8
        default:         return 1
        }
    }

    var byteCount: Int { Int(count) * Self.size(of: type) }

    /// The value read as a single unsigned integer, for the tags that are one.
    func scalar(littleEndian: Bool) -> UInt32? {
        switch type {
        case 3:
            guard value.count >= 2 else { return nil }
            return UInt32(littleEndian ? UInt16(value[value.startIndex])
                                        | UInt16(value[value.startIndex + 1]) << 8
                                       : UInt16(value[value.startIndex]) << 8
                                        | UInt16(value[value.startIndex + 1]))
        case 4:
            guard value.count >= 4 else { return nil }
            let b = [UInt8](value.prefix(4))
            return littleEndian
                ? UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
                : UInt32(b[3]) | UInt32(b[2]) << 8 | UInt32(b[1]) << 16 | UInt32(b[0]) << 24
        default:
            return nil
        }
    }
}

enum TIFFError: LocalizedError {
    case notTIFF
    case truncated
    case noTile

    var errorDescription: String? {
        switch self {
        case .notTIFF:   return "That file is not a TIFF or DNG."
        case .truncated: return "The file ends before its data does."
        case .noTile:    return "No image tile — this is not a GPR."
        }
    }
}

struct TIFFContainer {
    var littleEndian: Bool
    /// The main image directory.
    var entries: [TIFFEntry]
    /// The Exif directory, kept so exposure and ISO survive the rewrite.
    var exif: [TIFFEntry]

    // MARK: - Reading

    init(_ data: Data) throws {
        guard data.count >= 8 else { throw TIFFError.truncated }
        let magic = data.prefix(2)
        guard magic == Data("II".utf8) || magic == Data("MM".utf8) else { throw TIFFError.notTIFF }
        littleEndian = magic == Data("II".utf8)
        guard Self.u16(data, 2, littleEndian) == 42 else { throw TIFFError.notTIFF }

        let first = Int(Self.u32(data, 4, littleEndian))
        entries = try Self.readIFD(data, at: first, littleEndian: littleEndian)
        if let pointer = entries.first(where: { $0.tag == TIFFTag.exifIFD }),
           let offset = pointer.scalar(littleEndian: littleEndian),
           let read = try? Self.readIFD(data, at: Int(offset), littleEndian: littleEndian) {
            exif = read
        } else {
            exif = []
        }
    }

    private static func readIFD(_ data: Data, at offset: Int, littleEndian: Bool) throws -> [TIFFEntry] {
        guard offset > 0, offset + 2 <= data.count else { throw TIFFError.truncated }
        let count = Int(u16(data, offset, littleEndian))
        guard offset + 2 + count * 12 <= data.count else { throw TIFFError.truncated }

        var result: [TIFFEntry] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let at = offset + 2 + i * 12
            let tag = u16(data, at, littleEndian)
            let type = u16(data, at + 2, littleEndian)
            let n = u32(data, at + 4, littleEndian)
            let bytes = Int(n) * TIFFEntry.size(of: type)

            let value: Data
            if bytes <= 4 {
                value = data.subdata(in: data.startIndex + at + 8 ..< data.startIndex + at + 8 + max(bytes, 0))
            } else {
                let where_ = Int(u32(data, at + 8, littleEndian))
                guard where_ >= 0, where_ + bytes <= data.count else { throw TIFFError.truncated }
                value = data.subdata(in: data.startIndex + where_ ..< data.startIndex + where_ + bytes)
            }
            result.append(TIFFEntry(tag: tag, type: type, count: n, value: value))
        }
        return result
    }

    func entry(_ tag: UInt16) -> TIFFEntry? { entries.first { $0.tag == tag } }

    /// Where the compressed image sits, and how big it is.
    func tile(in data: Data) throws -> Data {
        guard let offset = entry(TIFFTag.tileOffsets)?.scalar(littleEndian: littleEndian),
              let length = entry(TIFFTag.tileByteCounts)?.scalar(littleEndian: littleEndian)
        else { throw TIFFError.noTile }
        let start = Int(offset), size = Int(length)
        guard start + size <= data.count else { throw TIFFError.truncated }
        return data.subdata(in: data.startIndex + start ..< data.startIndex + start + size)
    }

    // MARK: - Writing

    /// Rewrites the container with a new, uncompressed tile.
    ///
    /// Layout is header, main IFD, Exif IFD, out-of-line values, then the tile,
    /// so the one huge block is at the end and everything referring to it is
    /// already written by the time its position is known.
    func rewritten(tile: Data, compression: UInt16 = 1) -> Data {
        var main = entries
        for index in main.indices {
            switch main[index].tag {
            case TIFFTag.compression:
                main[index].value = Self.pack16(compression, littleEndian)
            case TIFFTag.tileByteCounts:
                main[index].value = Self.pack32(UInt32(tile.count), littleEndian)
            default:
                break
            }
        }

        func ifdSize(_ entries: [TIFFEntry]) -> Int { 2 + entries.count * 12 + 4 }

        let mainAt = 8
        let exifAt = mainAt + ifdSize(main)
        let valuesAt = exifAt + (exif.isEmpty ? 0 : ifdSize(exif))

        var values = Data()
        func place(_ bytes: Data) -> Data {
            if bytes.count <= 4 {
                var padded = bytes
                padded.append(contentsOf: [UInt8](repeating: 0, count: 4 - bytes.count))
                return padded
            }
            let at = valuesAt + values.count
            values.append(bytes)
            if values.count % 2 != 0 { values.append(0) }
            return Self.pack32(UInt32(at), littleEndian)
        }

        func build(_ entries: [TIFFEntry], exifOffset: Int?) -> Data {
            var body = Self.pack16(UInt16(entries.count), littleEndian)
            for entry in entries {
                let value: Data
                if entry.tag == TIFFTag.exifIFD, let exifOffset {
                    value = Self.pack32(UInt32(exifOffset), littleEndian)
                } else if entry.tag == TIFFTag.tileOffsets {
                    value = Data([0, 0, 0, 0])          // patched once the tile is placed
                } else {
                    value = place(entry.value)
                }
                body.append(Self.pack16(entry.tag, littleEndian))
                body.append(Self.pack16(entry.type, littleEndian))
                body.append(Self.pack32(entry.count, littleEndian))
                body.append(value)
            }
            body.append(Self.pack32(0, littleEndian))   // no next IFD
            return body
        }

        let exifBody = exif.isEmpty ? Data() : build(exif, exifOffset: nil)
        let mainBody = build(main, exifOffset: exif.isEmpty ? nil : exifAt)

        var out = Data(littleEndian ? "II".utf8 : "MM".utf8)
        out.append(Self.pack16(42, littleEndian))
        out.append(Self.pack32(8, littleEndian))
        out.append(mainBody)
        out.append(exifBody)
        out.append(values)
        while out.count % 4 != 0 { out.append(0) }

        let tileAt = out.count
        out.append(tile)

        if let index = main.firstIndex(where: { $0.tag == TIFFTag.tileOffsets }) {
            let at = mainAt + 2 + index * 12 + 8
            out.replaceSubrange(at..<(at + 4), with: Self.pack32(UInt32(tileAt), littleEndian))
        }
        return out
    }

    // MARK: - Bytes

    static func u16(_ d: Data, _ o: Int, _ le: Bool) -> UInt16 {
        let i = d.startIndex + o
        guard i + 1 < d.endIndex else { return 0 }
        return le ? UInt16(d[i]) | UInt16(d[i + 1]) << 8
                  : UInt16(d[i]) << 8 | UInt16(d[i + 1])
    }

    static func u32(_ d: Data, _ o: Int, _ le: Bool) -> UInt32 {
        let i = d.startIndex + o
        guard i + 3 < d.endIndex else { return 0 }
        return le ? UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16 | UInt32(d[i + 3]) << 24
                  : UInt32(d[i]) << 24 | UInt32(d[i + 1]) << 16 | UInt32(d[i + 2]) << 8 | UInt32(d[i + 3])
    }

    static func pack16(_ v: UInt16, _ le: Bool) -> Data {
        Data(le ? [UInt8(v & 0xFF), UInt8(v >> 8)] : [UInt8(v >> 8), UInt8(v & 0xFF)])
    }

    static func pack32(_ v: UInt32, _ le: Bool) -> Data {
        let b = [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)]
        return Data(le ? b : b.reversed())
    }
}
