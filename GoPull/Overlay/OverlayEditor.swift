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
import AppKit
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
    @Published private(set) var gforce = GForceTrack()
    @Published private(set) var runs: [AccelerationRun] = []

    /// Which overlay a drag is moving.
    enum Handle { case gauge, map, gforce }
    @Published var dragging: Handle?

    /// Export itself lives on AppModel so it outlives this sheet.
    let app = AppModel.shared

    /// Part of the preset, not a separate choice: what is set here is what a
    /// batch run over a whole card will produce.
    var exportOptions: ExportOptions {
        get { settings.export }
        set { settings.export = newValue }
    }

    private let url: URL
    private var raw = TelemetryTrack()
    private var rawGForce = GForceTrack()
    private var maxSpeed: Double = 60
    private var maxG: Double = 1
    private var extremes = GForceTrack.Extremes()
    private var peaks = GForceTrack.RunningExtremes()
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
        // The accelerometer is optional: a clip can have GPS and no usable
        // accelerometer, and that should cost the meter, not the whole editor.
        rawGForce = (try? GForceReader.read(url)) ?? GForceTrack()
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
        gforce = rawGForce.smoothed(settings.gforce.smoothing)
        extremes = gforce.extremes
        peaks = gforce.runningExtremes
        // Timed on the *raw* track. A trailing average is a drawing tool: it
        // delays every threshold crossing by about half its window, and it
        // fills in the dip between two back-to-back launches well enough that
        // the second one stops looking like a standing start at all -- 0.5s
        // smoothing turned the two runs in GX010050 into one.
        runs = AccelerationDetector.runs(in: raw, gforce: rawGForce,
                                         settings: settings.acceleration.detection)
        // Scaled from the smoothed track, which is what gets drawn: the raw
        // peak on this ride is 2.82 g against 1.01 g smoothed, and scaling to
        // the former leaves the ball parked in the middle all day.
        maxG = OverlayComposer.maxG(for: gforce, config: settings.gforce)
    }

    var hasGForce: Bool { !rawGForce.isEmpty }

    /// What the clip pulled each way, for the editor to show.
    var gForcePeaks: String {
        let e = extremes
        guard !e.isEmpty else { return "" }
        return String(format: "left %.2f · right %.2f · accel %.2f · brake %.2f g",
                      e.left, e.right, e.accelerating, e.braking)
    }

    /// One line per standing start, for comparing runs.
    var runSummaries: [String] {
        runs.map { run in
            let splits = run.reached.map { String(format: "0–%d %.2fs", $0, run.splits[$0]!) }
            return String(format: "%d:%02d  %@", Int(run.start) / 60, Int(run.start) % 60,
                          splits.joined(separator: "   "))
        }
    }

    /// Why there are no launches, in terms of what the clip actually contains.
    var launchExplanation: String {
        AccelerationDetector.diagnose(in: raw, settings: settings.acceleration.detection)
            .explanation(settings.acceleration.detection)
    }

    /// Add or drop a target speed, keeping at least one.
    func toggleTarget(_ target: Int) {
        var targets = settings.acceleration.detection.targets
        if let index = targets.firstIndex(of: target) {
            guard targets.count > 1 else { return }
            targets.remove(at: index)
        } else {
            targets.append(target)
        }
        settings.acceleration.detection.targets = targets.sorted()
        settingsChangedRequiringResample()
    }

    /// Jump the preview to a run, so a time can be checked against the footage.
    func scrub(toRun index: Int) {
        guard runs.indices.contains(index) else { return }
        time = Swift.max(runs[index].start - 1, 0)
    }
    var gForceSummary: String {
        guard hasGForce else { return "No accelerometer data in this clip." }
        return String(format: "peak %.2f g · full scale %.1f g", gforce.peakPlanar, maxG)
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
                             settings: settings, maxSpeed: maxSpeed,
                             gforce: gforce, maxG: maxG,
                             peaks: peaks, runs: runs)
        preview = context.makeImage()
    }

    /// Moves whichever overlay is under the point, in normalised coordinates.
    func beginDrag(at point: CGPoint) {
        // Test the smaller one first, so an overlap does not always grab the map.
        let gaugeRect = GaugeRenderer.frame(in: unitSize, config: settings.gauge)
        let mapRect = MapRenderer.frame(in: unitSize, config: settings.map)
        let flipped = CGPoint(x: point.x, y: 1 - point.y)
        let gRect = GForceRenderer.frame(in: unitSize, config: settings.gforce)
        if settings.showsGForce, gRect.insetBy(dx: -0.02, dy: -0.02).contains(flipped) {
            dragging = .gforce
        } else if settings.showsGauge, gaugeRect.insetBy(dx: -0.02, dy: -0.02).contains(flipped) {
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
        case .gforce:
            settings.gforce.placement.x = point.x
            settings.gforce.placement.y = point.y
            settings.gforce.placement = settings.gforce.placement
                .clamped(in: clampSize,
                         heightRatio: settings.gforce.showsReading
                             ? 1 + GForceRenderer.readoutStrip : 1)
        }
    }

    func endDrag() { dragging = nil }

    var aspect: Double { frameSize.height > 0 ? frameSize.width / frameSize.height : 16.0 / 9.0 }

    // MARK: - Export

    var isExporting: Bool { app.isExportingOverlay }

    /// Where a burned-in copy goes.
    var exportDestination: URL {
        switch exportOptions.destination {
        case .replaceOriginal where exportOptions.content == .burnedIn:
            return url
        case .replaceOriginal:
            fallthrough
        case .newFile:
            let base = url.deletingPathExtension().lastPathComponent
            let suffix = exportOptions.content == .overlayOnly ? "overlay-alpha" : "overlay"
            return url.deletingLastPathComponent()
                .appendingPathComponent("\(base) — \(suffix).\(exportOptions.fileExtension)")
        }
    }

    /// True when the chosen destination would throw away the clip's telemetry.
    var replaceWouldLoseTelemetry: Bool {
        exportOptions.destination == .replaceOriginal && track.hasFix
    }

    /// Set when Replace is chosen, so the sheet can insist before overwriting.
    @Published var confirmingReplace = false

    func exportRequested() {
        if replaceWouldLoseTelemetry {
            confirmingReplace = true
        } else {
            export()
        }
    }

    func export() {
        confirmingReplace = false
        guard !app.isExportingOverlay, track.hasFix else { return }
        app.startOverlayExport(clip: url, to: exportDestination, track: track,
                               settings: settings, options: exportOptions,
                               gforce: gforce, runs: runs)
    }

    func cancelExport() { app.cancelOverlayExport() }
    func revealExport() { app.revealOverlayExport() }

    /// What the export will produce, so the size is known before it starts.
    var exportSummary: String {
        let output = exportOptions.size.output(for: frameSize)
        let codec = exportOptions.content == .overlayOnly
            ? "ProRes 4444 · alpha"
            : (exportOptions.codec == .hevc ? "HEVC" : "H.264")
        return "\(Int(output.width))×\(Int(output.height)) · \(codec)"
    }

    /// ProRes is not a small format, and an overlay is mostly empty frame -- it
    /// still costs what the resolution costs, so it is worth saying up front.
    var exportSizeEstimate: String? {
        guard exportOptions.content == .overlayOnly, duration > 0 else { return nil }
        let output = exportOptions.size.output(for: frameSize)
        // Measured: 1920x1080 ProRes 4444 lands near 7.2 MB per second.
        let perSecond = 7.2e6 * (output.width * output.height) / (1920 * 1080)
        let bytes = perSecond * duration
        return "about \(Int64(bytes).byteLabel)"
    }

    var summary: String {
        guard raw.hasFix else { return "" }
        let unit = settings.gauge.unit
        return String(format: "%.1f km · top %.0f %@ · %d fixes",
                      raw.distance / 1000,
                      unit.value(fromMetresPerSecond: raw.topSpeed), unit.label,
                      raw.usable.count)
    }
}
