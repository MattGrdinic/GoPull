//
//  GPRConverter.swift
//  GoPull
//
//  Turns a GoPro GPR into a DNG anything can open.
//
//  GPR is a DNG whose single tile is compressed with VC-5, which no ordinary
//  reader implements -- macOS included. ImageIO will happily read a GPR's
//  metadata and report it as `com.adobe.raw-image`, then fail to decode a
//  single pixel and produce no thumbnail. That is the whole problem.
//
//  So: decode the tile with GoPro's own decoder, and write the same tag set
//  back out with the tile uncompressed. Every colour tag survives -- the
//  matrices, the as-shot neutral, black and white levels, the lens opcodes --
//  because they are copied rather than reconstructed.
//

import Foundation

enum GPRError: LocalizedError {
    case decodeFailed(Int32)
    case unexpectedSize(expected: Int, got: Int)

    var errorDescription: String? {
        switch self {
        case .decodeFailed(let code):
            return "The GPR image could not be decoded (VC-5 error \(code))."
        case .unexpectedSize(let expected, let got):
            return "The decoded image is \(got) bytes, expected \(expected)."
        }
    }
}

enum GPRConverter {

    /// True for files this can convert.
    static func isGPR(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "gpr"
    }

    /// The DNG that `convert` would write for a GPR.
    static func dngURL(for gpr: URL) -> URL {
        gpr.deletingPathExtension().appendingPathExtension("dng")
    }

    /// Reads a GPR and writes the equivalent DNG. Returns where it went.
    @discardableResult
    static func convert(_ gpr: URL, to destination: URL? = nil) throws -> URL {
        let data = try Data(contentsOf: gpr, options: .mappedIfSafe)
        let container = try TIFFContainer(data)
        let tile = try container.tile(in: data)

        let width = Int(container.entry(TIFFTag.imageWidth)?
            .scalar(littleEndian: container.littleEndian) ?? 0)
        let height = Int(container.entry(TIFFTag.imageLength)?
            .scalar(littleEndian: container.littleEndian) ?? 0)

        let bayer = try decode(tile, whiteLevel: container.entry(TIFFTag.whiteLevel)?
            .scalar(littleEndian: container.littleEndian) ?? 16383,
                               cfa: container.entry(TIFFTag.cfaPattern)?.value)

        if width > 0, height > 0 {
            let expected = width * height * 2
            guard bayer.count == expected else {
                throw GPRError.unexpectedSize(expected: expected, got: bayer.count)
            }
        }

        let out = destination ?? dngURL(for: gpr)
        let dng = container.rewritten(tile: bayer)
        try dng.write(to: out, options: .atomic)
        return out
    }

    // MARK: - VC-5

    /// Decodes the tile to 16-bit Bayer samples.
    private static func decode(_ tile: Data, whiteLevel: UInt32, cfa: Data?) throws -> Data {
        var parameters = vc5_decoder_parameters()
        vc5_decoder_parameters_set_default(&parameters)
        // set_default leaves the allocator callbacks alone, and the decoder
        // segfaults on the first allocation without them.
        parameters.mem_alloc = { size in malloc(size) }
        parameters.mem_free = { pointer in free(pointer) }
        parameters.pixel_format = Self.pixelFormat(whiteLevel: whiteLevel, cfa: cfa)

        var input = gpr_buffer()
        var output = gpr_buffer()

        return try tile.withUnsafeBytes { raw -> Data in
            input.buffer = UnsafeMutableRawPointer(mutating: raw.baseAddress)
            input.size = raw.count

            let error = vc5_decoder_process(&parameters, &input, &output, nil)
            guard error.rawValue == 0, let produced = output.buffer, output.size > 0 else {
                if let buffer = output.buffer { free(buffer) }
                throw GPRError.decodeFailed(Int32(error.rawValue))
            }
            defer { free(produced) }
            return Data(bytes: produced, count: output.size)
        }
    }

    /// Bit depth comes from the white level, Bayer order from the CFA pattern.
    ///
    /// Both are read from the file rather than assumed: a MISSION 1 PRO writes
    /// 14-bit RGGB, but the format allows others and guessing would silently
    /// swap the colour channels.
    private static func pixelFormat(whiteLevel: UInt32, cfa: Data?) -> VC5_DECODER_PIXEL_FORMAT {
        let is14Bit = whiteLevel > 4095
        // CFA pattern bytes: 0 red, 1 green, 2 blue.
        let isGBRG = (cfa?.count ?? 0) >= 4 && cfa?.first == 1
        switch (isGBRG, is14Bit) {
        case (false, true):  return VC5_DECODER_PIXEL_FORMAT_RGGB_14
        case (false, false): return VC5_DECODER_PIXEL_FORMAT_RGGB_12
        case (true, true):   return VC5_DECODER_PIXEL_FORMAT_GBRG_14
        case (true, false):  return VC5_DECODER_PIXEL_FORMAT_GBRG_12
        }
    }
}
