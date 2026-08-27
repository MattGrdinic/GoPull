//
//  OverlayPlacementTests.swift
//  GoPullTests
//

import CoreGraphics
import CoreLocation
import Foundation
import Testing
@testable import GoPull

struct OverlayPlacementTests {

    private let hd = CGSize(width: 1920, height: 1080)

    /// Placement stores y from the top, because that is what a drag reports;
    /// Core Graphics counts from the bottom. The flip happens once, here.
    @Test func yIsStoredFromTheTopAndFlippedForDrawing() {
        let top = OverlayPlacement(x: 0.5, y: 0.1, scale: 0.2)
        let bottom = OverlayPlacement(x: 0.5, y: 0.9, scale: 0.2)
        #expect(top.rect(in: hd).midY > bottom.rect(in: hd).midY)
    }

    @Test func cornersLandInTheRightCorners() {
        let aspect = 1920.0 / 1080.0
        let tl = OverlayPlacement.corner(.topLeft, aspect: aspect).rect(in: hd)
        let br = OverlayPlacement.corner(.bottomRight, aspect: aspect).rect(in: hd)
        #expect(tl.minX < hd.width / 2 && tl.midY > hd.height / 2)   // CG: top is high y
        #expect(br.midX > hd.width / 2 && br.midY < hd.height / 2)
    }

    @Test func everyCornerStaysInsideTheFrame() {
        for corner in OverlayCorner.allCases {
            let rect = OverlayPlacement.corner(corner, aspect: 1920.0 / 1080.0).rect(in: hd)
            #expect(rect.minX >= 0 && rect.minY >= 0)
            #expect(rect.maxX <= hd.width && rect.maxY <= hd.height)
        }
    }

    /// Dragging must not be able to push an overlay off the frame.
    @Test func clampingKeepsAnOverlayOnScreen() {
        let offLeft = OverlayPlacement(x: -0.5, y: 0.5, scale: 0.3).clamped(in: hd)
        let offBottom = OverlayPlacement(x: 0.5, y: 2.0, scale: 0.3).clamped(in: hd)
        for rect in [offLeft.rect(in: hd), offBottom.rect(in: hd)] {
            #expect(rect.minX >= -0.5 && rect.minY >= -0.5)
            #expect(rect.maxX <= hd.width + 0.5 && rect.maxY <= hd.height + 0.5)
        }
    }

    @Test func aPlacementInTheMiddleIsLeftAlone() {
        let middle = OverlayPlacement(x: 0.5, y: 0.5, scale: 0.2)
        #expect(middle.clamped(in: hd) == middle)
    }

    /// Sizes are fractions of the shorter side, so an overlay is the same
    /// relative size on 1080p as on the 8K these clips are.
    @Test func sizingScalesWithTheFrame() {
        let placement = OverlayPlacement(x: 0.5, y: 0.5, scale: 0.25)
        let small = placement.rect(in: hd)
        let big = placement.rect(in: CGSize(width: 7680, height: 4320))
        #expect(abs(big.width / small.width - 4) < 0.0001)
    }

    @Test func aWideOverlayKeepsItsShape() {
        let placement = OverlayPlacement(x: 0.5, y: 0.5, scale: 0.3)
        let rect = placement.rect(in: hd, heightRatio: 0.34)
        #expect(abs(rect.height / rect.width - 0.34) < 0.0001)
    }

    // MARK: - Map

    private var route: [CLLocationCoordinate2D] {
        (0..<50).map { CLLocationCoordinate2D(latitude: 32 + Double($0) / 5000,
                                              longitude: -111 + Double($0) / 4000) }
    }

    @Test func theMapDrawsWithoutATrack() {
        // One point, or none, must not crash or draw nonsense.
        let ctx = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        MapRenderer.draw(route: [], progress: 0, in: ctx,
                         frameSize: CGSize(width: 200, height: 200), config: MapConfig())
        MapRenderer.draw(route: Array(route.prefix(1)), progress: 0, in: ctx,
                         frameSize: CGSize(width: 200, height: 200), config: MapConfig())
    }

    @Test func progressBeyondTheRouteIsClamped() {
        let ctx = CGContext(data: nil, width: 300, height: 300, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var config = MapConfig()
        config.placement = OverlayPlacement(x: 0.5, y: 0.5, scale: 0.9)
        for progress in [-100.0, 0, 25, 1_000_000] {
            MapRenderer.draw(route: route, progress: progress, in: ctx,
                             frameSize: CGSize(width: 300, height: 300), config: config)
        }
    }

    @Test func mapPresetsTrackTheGaugePresets() {
        for preset in GaugePreset.allCases {
            var config = MapConfig()
            config.apply(preset)
            #expect(config.preset == preset)
            #expect(config.style == .matching(preset))
        }
    }

    /// A dark disc vanishes against dark footage; the rim is what gives it an
    /// edge, so every preset must have one.
    @Test func everyMapPresetHasAVisibleRim() {
        for preset in GaugePreset.allCases {
            let style = MapStyle.matching(preset)
            #expect(style.rim.a > 0, "\(preset.rawValue) has no rim")
            #expect(style.rimWidth > 0)
            #expect(style.feather > 0, "\(preset.rawValue) does not feather")
        }
    }
}
