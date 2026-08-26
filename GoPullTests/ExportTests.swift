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
