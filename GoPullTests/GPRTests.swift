//
//  GPRTests.swift
//  GoPullTests
//

import Foundation
import Testing
@testable import GoPull

struct GPRTests {

    @Test func recognisesGPRByExtension() {
        #expect(GPRConverter.isGPR(URL(fileURLWithPath: "/x/GP010012.GPR")))
        #expect(GPRConverter.isGPR(URL(fileURLWithPath: "/x/GP010012.gpr")))
        #expect(!GPRConverter.isGPR(URL(fileURLWithPath: "/x/GX010005.MP4")))
        #expect(!GPRConverter.isGPR(URL(fileURLWithPath: "/x/GP010007.JPG")))
    }

    @Test func theDNGSitsBesideTheGPR() {
        let gpr = URL(fileURLWithPath: "/clips/2026-08-25/GP010012.GPR")
        let dng = GPRConverter.dngURL(for: gpr)
        #expect(dng.lastPathComponent == "GP010012.dng")
        #expect(dng.deletingLastPathComponent() == gpr.deletingLastPathComponent())
    }

    @Test func rubbishIsRejectedRatherThanCrashing() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gopull-\(UUID().uuidString).GPR")
        try? Data("not a tiff at all".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: (any Error).self) { try GPRConverter.convert(url) }
    }

    @Test func aTruncatedFileIsRejected() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gopull-\(UUID().uuidString).GPR")
        // A valid little-endian TIFF header pointing at an IFD that is not there.
        var data = Data("II".utf8)
        data.append(contentsOf: [42, 0, 0x40, 0x00, 0x00, 0x00])
        try? data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: (any Error).self) { try GPRConverter.convert(url) }
    }

    // MARK: - The container

    /// Round-tripping has to preserve every tag, because the colour matrices,
    /// black and white levels and lens opcodes are what make the DNG usable.
    @Test func rewritingKeepsEveryTag() throws {
        var data = Data("II".utf8)
        data.append(contentsOf: [42, 0])
        data.append(contentsOf: [8, 0, 0, 0])          // IFD at 8

        // Three entries: width, tile offsets, tile byte counts.
        func entry(_ tag: UInt16, _ type: UInt16, _ count: UInt32, _ value: [UInt8]) -> [UInt8] {
            var out: [UInt8] = [UInt8(tag & 0xFF), UInt8(tag >> 8),
                                UInt8(type & 0xFF), UInt8(type >> 8)]
            out += [UInt8(count & 0xFF), UInt8(count >> 8 & 0xFF),
                    UInt8(count >> 16 & 0xFF), UInt8(count >> 24 & 0xFF)]
            out += value
            return out
        }
        var ifd: [UInt8] = [3, 0]
        ifd += entry(256, 4, 1, [0, 16, 0, 0])          // width 4096
        ifd += entry(324, 4, 1, [80, 0, 0, 0])          // tile at 80
        ifd += entry(325, 4, 1, [4, 0, 0, 0])           // 4 bytes
        ifd += [0, 0, 0, 0]
        data.append(contentsOf: ifd)
        data.append(contentsOf: [UInt8](repeating: 0, count: 80 - data.count))
        data.append(contentsOf: [1, 2, 3, 4])

        let container = try TIFFContainer(data)
        #expect(container.entries.count == 3)
        #expect(container.entry(256)?.scalar(littleEndian: true) == 4096)
        #expect(try container.tile(in: data) == Data([1, 2, 3, 4]))

        let bigger = Data([9, 9, 9, 9, 9, 9, 9, 9])
        let rewritten = container.rewritten(tile: bigger)
        let reread = try TIFFContainer(rewritten)
        #expect(reread.entries.count == 3)
        #expect(reread.entry(256)?.scalar(littleEndian: true) == 4096)
        #expect(reread.entry(TIFFTag.compression) == nil)   // absent in, absent out
        #expect(try reread.tile(in: rewritten) == bigger)
    }

    /// The point of the rewrite: compression 9 becomes 1.
    @Test func rewritingMarksTheTileUncompressed() throws {
        var data = Data("II".utf8)
        data.append(contentsOf: [42, 0, 8, 0, 0, 0])
        func entry(_ tag: UInt16, _ type: UInt16, _ value: [UInt8]) -> [UInt8] {
            [UInt8(tag & 0xFF), UInt8(tag >> 8), UInt8(type & 0xFF), UInt8(type >> 8),
             1, 0, 0, 0] + value
        }
        var ifd: [UInt8] = [3, 0]
        ifd += entry(259, 3, [9, 0, 0, 0])              // compression = VC-5
        ifd += entry(324, 4, [80, 0, 0, 0])
        ifd += entry(325, 4, [4, 0, 0, 0])
        ifd += [0, 0, 0, 0]
        data.append(contentsOf: ifd)
        data.append(contentsOf: [UInt8](repeating: 0, count: 80 - data.count))
        data.append(contentsOf: [1, 2, 3, 4])

        let container = try TIFFContainer(data)
        #expect(container.entry(TIFFTag.compression)?.scalar(littleEndian: true) == 9)

        let out = try TIFFContainer(container.rewritten(tile: Data([5, 5, 5, 5])))
        #expect(out.entry(TIFFTag.compression)?.scalar(littleEndian: true) == 1)
        #expect(out.entry(TIFFTag.tileByteCounts)?.scalar(littleEndian: true) == 4)
    }

    @Test func aNonTIFFIsRejected() {
        #expect(throws: (any Error).self) { try TIFFContainer(Data("hello world!".utf8)) }
    }
}
