//
//  ExportTests.swift
//  GoPullTests
//

import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import GoPull

struct ExportTests {

    private let uhd8K = CGSize(width: 7680, height: 4320)
    private let uhd4K = CGSize(width: 3840, height: 2160)

    @Test func sourceSizeIsLeftAlone() {
        #expect(ExportOptions.Size.source.output(for: uhd8K) == uhd8K)
    }

    @Test func downscalingCapsTheLongEdge() {
        #expect(ExportOptions.Size.uhd4K.output(for: uhd8K) == uhd4K)
        #expect(ExportOptions.Size.hd1080.output(for: uhd8K)
                == CGSize(width: 1920, height: 1080))
    }

    /// Encoders reject odd dimensions, and 4:3 or anamorphic sources round to
    /// them easily.
    @Test func outputDimensionsAreAlwaysEven() {
        let awkward = [CGSize(width: 4096, height: 3072),
                       CGSize(width: 5312, height: 2988),
                       CGSize(width: 2704, height: 1520),
                       CGSize(width: 1919, height: 1079)]
        for source in awkward {
            for size in ExportOptions.Size.allCases {
                let output = size.output(for: source)
                #expect(Int(output.width) % 2 == 0, "\(source) \(size.rawValue) width")
                #expect(Int(output.height) % 2 == 0, "\(source) \(size.rawValue) height")
            }
        }
    }

    @Test func aspectRatioSurvivesDownscaling() {
        let source = CGSize(width: 5312, height: 2988)     // 16:9-ish
        let output = ExportOptions.Size.hd1080.output(for: source)
        #expect(abs(output.width / output.height - source.width / source.height) < 0.01)
    }

    /// Asking for 4K from a 1080p clip must not upscale it.
    @Test func smallerSourcesAreNotBlownUp() {
        let small = CGSize(width: 1280, height: 720)
        #expect(ExportOptions.Size.uhd4K.output(for: small) == small)
        #expect(ExportOptions.Size.hd1080.output(for: small) == small)
    }

    @Test func portraitSourcesCapTheLongEdgeToo() {
        let portrait = CGSize(width: 2160, height: 3840)
        let output = ExportOptions.Size.hd1080.output(for: portrait)
        #expect(max(output.width, output.height) == 1920)
        #expect(output.width < output.height)
    }

    @Test func defaultsAreHEVCWithAudio() {
        let options = ExportOptions()
        #expect(options.codec == .hevc)
        #expect(options.includesAudio)
        #expect(options.size == .source)
    }
}

struct ExportDestinationTests {

    /// New file is the default, because replacing is the one that cannot be
    /// undone.
    @Test func newFileIsTheDefault() {
        #expect(ExportOptions().destination == .newFile)
    }

    @Test func bothDestinationsAreOffered() {
        #expect(ExportOptions.Destination.allCases.count == 2)
        #expect(ExportOptions.Destination.allCases.contains(.replaceOriginal))
    }

    @Test func destinationSurvivesEncoding() throws {
        var settings = OverlaySettings.defaults
        settings.gauge.kind = .digital
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(OverlaySettings.self, from: data) == settings)

        // The destination is a choice per export, not part of the saved look,
        // so it is deliberately not in OverlaySettings.
        for destination in ExportOptions.Destination.allCases {
            let encoded = try JSONEncoder().encode(destination)
            #expect(try JSONDecoder().decode(ExportOptions.Destination.self,
                                             from: encoded) == destination)
        }
    }

    /// A file with no telemetry loses nothing by being replaced, so the warning
    /// must not appear for one.
    @Test func replacingAFileWithoutTelemetryLosesNothing() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gopull-test-\(UUID().uuidString).mp4")
        try Data("not an mp4".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(!OverlayExporter.replacingLosesTelemetry(url))
    }

    @Test func replacingAMissingFileIsNotClaimedToLoseTelemetry() {
        let missing = URL(fileURLWithPath: "/nowhere/at/all.mp4")
        #expect(!OverlayExporter.replacingLosesTelemetry(missing))
    }
}

struct AlphaExportTests {

    /// Alpha needs a codec that carries it; HEVC's support is patchy across
    /// editors, ProRes 4444 is read everywhere.
    @Test func overlayOnlyForcesProRes4444() {
        var options = ExportOptions()
        options.codec = .hevc
        options.content = .overlayOnly
        #expect(options.effectiveCodec == .proRes4444)

        options.content = .burnedIn
        #expect(options.effectiveCodec == .hevc)
    }

    /// ProRes belongs in QuickTime -- AVAssetWriter refuses to add it to MP4.
    @Test func overlayOnlyWritesQuickTime() {
        var options = ExportOptions()
        options.content = .overlayOnly
        #expect(options.fileType == .mov)
        #expect(options.fileExtension == "mov")

        options.content = .burnedIn
        #expect(options.fileType == .mp4)
        #expect(options.fileExtension == "mp4")
    }

    /// The overlay is laid over the original, which still has its own sound.
    @Test func overlayOnlyWritesNoAudio() {
        var options = ExportOptions()
        options.includesAudio = true
        options.content = .overlayOnly
        #expect(!options.writesAudio)

        options.content = .burnedIn
        #expect(options.writesAudio)
    }

    @Test func burnedInIsStillTheDefault() {
        #expect(ExportOptions().content == .burnedIn)
    }

    @Test func bothContentsAreOffered() {
        #expect(ExportOptions.Content.allCases.count == 2)
    }

    @Test func contentSurvivesEncoding() throws {
        for content in ExportOptions.Content.allCases {
            let data = try JSONEncoder().encode(content)
            #expect(try JSONDecoder().decode(ExportOptions.Content.self, from: data) == content)
        }
    }
}
