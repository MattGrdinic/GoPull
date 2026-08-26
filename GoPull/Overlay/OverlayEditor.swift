//
//  OverlayEditor.swift
//  GoPull
//
//  Tunes the overlays against the footage they will sit on.
//
//  Everything up to here was tuned by rendering PNGs and looking at them, which
//  works for finding bugs and not at all for taste. This puts a real frame from
//  the clip behind real overlays and lets them be dragged.
//

import AVFoundation
import Combine
import CoreGraphics
import SwiftUI

@MainActor
final class OverlayEditorModel: ObservableObject {

    @Published var settings: OverlaySettings {
        didSet { settings.save(); compose() }
    }
    /// The composited preview.
    @Published private(set) var preview: CGImage?
    @Published private(set) var status: String?
    /// Where in the clip the preview is taken from.
    @Published var time: Double = 0 {
        didSet { loadFrame() }
    }
    @Published private(set) var duration: Double = 0
    @Published private(set) var track = TelemetryTrack()

    /// Which overlay a drag is moving.
    enum Handle { case gauge, map }
    @Published var dragging: Handle?

    private let url: URL
    private var raw = TelemetryTrack()
    private var maxSpeed: Double = 60
    private var frame: CGImage?
    private var generator: AVAssetImageGenerator?
    private var frameTask: Task<Void, Never>?
    private var frameSize = CGSize(width: 1920, height: 1080)

    init(url: URL) {
        self.url = url
        self.settings = .load()
    }

    var videoSize: CGSize { frameSize }

    func start() async {
        // Telemetry first: without it there is nothing to configure, and the
        // message should say so rather than showing an empty dial.
        do {
            raw = try TelemetryReader.read(url)
        } catch {
            status = error.localizedDescription
            return
        }
        guard raw.hasFix else {
            status = "This clip has no usable GPS fixes, so there is nothing to overlay."
            return
        }
        applySmoothing()

        let asset = AVURLAsset(url: url)
        if let seconds = try? await asset.load(.duration).seconds, seconds.isFinite {
            duration = seconds
        }
        if let video = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await video.load(.naturalSize) {
            frameSize = CGSize(width: abs(size.width), height: abs(size.height))
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Scrubbing wants speed, not exactness: a frame within half a second is
        // indistinguishable for placing an overlay and far quicker to fetch.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        self.generator = generator

        // Open on the first moment with a fix, so the gauge is not blank.
        time = track.fixWindow?.lowerBound ?? 0
        loadFrame()
    }

    private func applySmoothing() {
        track = raw.smoothed(settings.gauge.smoothing)
        maxSpeed = OverlayComposer.maxSpeed(for: raw, unit: settings.gauge.unit)
    }

    /// Re-smoothing is only needed when the window or the unit changes; doing it
    /// on every drag would re-walk thousands of samples per frame.
    func settingsChangedRequiringResample() {
        applySmoothing()
        compose()
    }

    private func loadFrame() {
        guard let generator else { return }
        frameTask?.cancel()
        let at = CMTime(seconds: time, preferredTimescale: 600)
        frameTask = Task { [weak self] in
            let image = try? await generator.image(at: at).image
            guard !Task.isCancelled, let self else { return }
            self.frame = image
            self.compose()
        }
    }

    func compose() {
        guard let frame else { return }
        let width = frame.width, height = frame.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        let size = CGSize(width: width, height: height)
        context.draw(frame, in: CGRect(origin: .zero, size: size))
        OverlayComposer.draw(in: context, frameSize: size, track: track, at: time,
                             settings: settings, maxSpeed: maxSpeed)
        preview = context.makeImage()
    }

    /// Moves whichever overlay is under the point, in normalised coordinates.
    func beginDrag(at point: CGPoint) {
        // Test the smaller one first, so an overlap does not always grab the map.
        let gaugeRect = GaugeRenderer.frame(in: unitSize, config: settings.gauge)
        let mapRect = MapRenderer.frame(in: unitSize, config: settings.map)
        let flipped = CGPoint(x: point.x, y: 1 - point.y)
        if settings.showsGauge, gaugeRect.insetBy(dx: -0.02, dy: -0.02).contains(flipped) {
            dragging = .gauge
        } else if settings.showsMap, mapRect.insetBy(dx: -0.02, dy: -0.02).contains(flipped) {
            dragging = .map
        } else {
            dragging = nil
        }
    }

    /// A 1x1 space, so hit-testing works in the same normalised units the
    /// placement is stored in and never depends on the preview's pixel size.
    private var unitSize: CGSize { CGSize(width: 1, height: 1) }

    func drag(to point: CGPoint) {
        guard let dragging else { return }
        let clampSize = CGSize(width: 1, height: 1 / max(aspect, 0.0001))
        switch dragging {
        case .gauge:
            settings.gauge.placement.x = point.x
            settings.gauge.placement.y = point.y
            settings.gauge.placement = settings.gauge.placement
                .clamped(in: clampSize, heightRatio: settings.gauge.kind == .bar ? 0.34 : 1)
        case .map:
            settings.map.placement.x = point.x
            settings.map.placement.y = point.y
            settings.map.placement = settings.map.placement.clamped(in: clampSize)
        }
    }

    func endDrag() { dragging = nil }

    var aspect: Double { frameSize.height > 0 ? frameSize.width / frameSize.height : 16.0 / 9.0 }

    var summary: String {
        guard raw.hasFix else { return "" }
        let unit = settings.gauge.unit
        return String(format: "%.1f km · top %.0f %@ · %d fixes",
                      raw.distance / 1000,
                      unit.value(fromMetresPerSecond: raw.topSpeed), unit.label,
                      raw.usable.count)
    }
}
