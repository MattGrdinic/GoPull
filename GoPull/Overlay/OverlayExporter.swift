//
//  OverlayExporter.swift
//  GoPull
//
//  Burns the overlays into a copy of the clip.
//
//  A reader/writer pipeline rather than AVAssetExportSession with a custom
//  compositor: this needs an explicit output size, an explicit codec, real
//  progress and real cancellation, and the export session gives up control of
//  all four. Frames go decoded -> CGContext -> encoded, and the overlays are
//  drawn by `OverlayComposer`, the same code the editor previews with.
//

import Accelerate
import AVFoundation
import Combine
import CoreGraphics
import Foundation

struct ExportOptions: Equatable, Codable {
    enum Size: String, CaseIterable, Identifiable, Codable {
        case source, uhd4K, hd1080

        var id: String { rawValue }
        var label: String {
            switch self {
            case .source: return "Source"
            case .uhd4K:  return "4K"
            case .hd1080: return "1080p"
            }
        }

        /// Keeps the source's aspect; only the long edge is capped.
        ///
        /// Every path rounds to even dimensions, including the one that keeps
        /// the source size: encoders reject odd ones, and an odd-sized source
        /// would otherwise be handed straight through.
        func output(for source: CGSize) -> CGSize {
            func even(_ size: CGSize) -> CGSize {
                CGSize(width: max((size.width / 2).rounded() * 2, 2),
                       height: max((size.height / 2).rounded() * 2, 2))
            }
            let cap: CGFloat
            switch self {
            case .source: return even(source)
            case .uhd4K:  cap = 3840
            case .hd1080: cap = 1920
            }
            let longest = max(source.width, source.height)
            guard longest > cap else { return even(source) }
            let factor = cap / longest
            return even(CGSize(width: source.width * factor,
                               height: source.height * factor))
        }
    }

    /// Where the burned-in copy goes.
    enum Destination: String, CaseIterable, Identifiable, Codable {
        /// Beside the original, as "<name> — overlay.mp4". The default, and the
        /// only one that keeps the source intact.
        case newFile
        /// In place of the original.
        case replaceOriginal

        var id: String { rawValue }
        var label: String {
            self == .newFile ? "New file" : "Replace original"
        }
    }

    /// What the export contains.
    enum Content: String, CaseIterable, Identifiable, Codable {
        /// The footage with the overlays drawn onto it.
        case burnedIn
        /// The overlays alone on transparency, to lay over the original in an
        /// editor. Nothing of the source is decoded, so it is far quicker.
        case overlayOnly

        var id: String { rawValue }
        var label: String {
            self == .burnedIn ? "Burned in" : "Overlay only (alpha)"
        }
    }

    var content: Content = .burnedIn
    var size: Size = .source
    /// Stored as its raw value: `AVVideoCodecType` is a RawRepresentable
    /// struct, and Swift only synthesises Codable for RawRepresentable *enums*.
    var codecRawValue: String = AVVideoCodecType.hevc.rawValue
    var includesAudio = true
    var destination: Destination = .newFile

    var codec: AVVideoCodecType {
        get { AVVideoCodecType(rawValue: codecRawValue) }
        set { codecRawValue = newValue.rawValue }
    }

    /// Alpha needs a codec that carries it. ProRes 4444 is the one every
    /// editor reads; HEVC's alpha support is far patchier.
    var effectiveCodec: AVVideoCodecType {
        content == .overlayOnly ? .proRes4444 : codec
    }

    /// An overlay track is laid over the original, which already has the sound.
    var writesAudio: Bool { includesAudio && content == .burnedIn }

    /// ProRes belongs in QuickTime; MP4 is not a container for it.
    var fileType: AVFileType { content == .overlayOnly ? .mov : .mp4 }
    var fileExtension: String { content == .overlayOnly ? "mov" : "mp4" }
}

/// AVFoundation's `localizedDescription` is often just "The operation could not
/// be completed"; the reason it fails is in the underlying error.
private func detail(_ error: Error?) -> String {
    guard let error = error as NSError? else { return "unknown" }
    var parts = [error.localizedDescription]
    if let reason = error.localizedFailureReason { parts.append(reason) }
    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
        parts.append("(\(underlying.domain) \(underlying.code): \(underlying.localizedDescription))")
    }
    parts.append("[\(error.domain) \(error.code)]")
    return parts.joined(separator: " ")
}

enum ExportError: LocalizedError {
    case noVideoTrack
    case cannotWrite(String)
    case failed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:        return "That clip has no video track."
        case .cannotWrite(let why): return "Could not write the export: \(why)"
        case .failed(let why):     return "The export failed: \(why)"
        case .cancelled:           return "Export cancelled."
        }
    }

    var isCancellation: Bool {
        if case .cancelled = self { return true }
        return false
    }
}

struct ExportProgress {
    var fraction: Double = 0
    var framesWritten: Int = 0
    var framesPerSecond: Double = 0
}

@MainActor
final class OverlayExporter: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var progress = ExportProgress()
    /// What is being exported, for showing progress outside the editor.
    @Published private(set) var clipName: String?

    /// Set from `cancel()`.
    ///
    /// `Task.isCancelled` was being read inside the writer's callback, which
    /// runs on a dispatch queue with no task context, so it was always false and
    /// Cancel did nothing.
    private let cancelled = Cancellation()

    final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
        func reset() { lock.lock(); value = false; lock.unlock() }
    }

    func cancel() { cancelled.set() }

    /// Writes `clip` with overlays burned in to `destination`.
    func export(clip: URL, to destination: URL, track: TelemetryTrack,
                settings: OverlaySettings, options: ExportOptions,
                gforce: GForceTrack = GForceTrack(),
                runs: [AccelerationRun] = []) async throws {
        isRunning = true
        cancelled.reset()
        clipName = clip.lastPathComponent
        progress = ExportProgress()
        defer { isRunning = false; clipName = nil }

        let asset = AVURLAsset(url: clip)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }
        let naturalSize = try await video.load(.naturalSize)
        let transform = try await video.load(.preferredTransform)
        // A rotated track reports its size unrotated; what gets written is the
        // displayed rectangle, so the overlays land where the editor showed them.
        let displayed = naturalSize.applying(transform)
        let sourceSize = CGSize(width: abs(displayed.width), height: abs(displayed.height))
        let outputSize = options.size.output(for: sourceSize)

        let duration = try await asset.load(.duration).seconds
        let nominalRate = Double(try await video.load(.nominalFrameRate))
        let totalFrames = max(Int((duration * max(nominalRate, 1)).rounded()), 1)
        let maxSpeed = OverlayComposer.maxSpeed(for: track, unit: settings.gauge.unit)
        // Built once for the whole export rather than per frame.
        let projection = RouteProjection(track.usable.map(\.coordinate))
        let maxG = OverlayComposer.maxG(for: gforce, config: settings.gforce)
        let peaks = gforce.runningExtremes

        // Always write somewhere hidden and move it into place at the end,
        // whether or not the original is being replaced.
        //
        // An MP4's `moov` atom is written last, so a partly-written file has no
        // index and will not open. Writing it at the destination name means an
        // export in progress is indistinguishable from a finished export that is
        // broken -- which is exactly how it was read.
        let replacing = destination == clip
        let writeTo = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).gopull-export")
        try? FileManager.default.removeItem(at: writeTo)

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: writeTo, fileType: options.fileType)

        // An overlay-only export never touches the source's pixels, so it does
        // not read the video track at all -- it generates frames on the track's
        // own cadence.
        //
        // Reading the track in passthrough to borrow its timestamps looked
        // cheaper and is not usable: the first two samples of these clips both
        // report a presentation time of 0.000, and a writer rejects a repeated
        // timestamp (AVFoundation -11800 / OSStatus -16364, which says none of
        // that).
        let overlayOnly = options.content == .overlayOnly
        let frameDuration = try await video.load(.minFrameDuration)
        let step = frameDuration.isValid && frameDuration.seconds > 0
            ? frameDuration
            : CMTime(value: 1001, timescale: 30000)

        var videoOutput: AVAssetReaderTrackOutput?
        if !overlayOnly {
            let output = AVAssetReaderTrackOutput(
                track: video,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:
                                    kCVPixelFormatType_32BGRA])
            output.alwaysCopiesSampleData = false
            reader.add(output)
            videoOutput = output
        }

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: options.effectiveCodec,
            AVVideoWidthKey: Int(outputSize.width),
            AVVideoHeightKey: Int(outputSize.height),
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(outputSize.width),
                kCVPixelBufferHeightKey as String: Int(outputSize.height),
                kCVPixelBufferCGImageCompatibilityKey as String: true,
            ])
        writer.add(videoInput)

        // Audio is copied, not re-encoded: nothing here touches it.
        var audioOutput: AVAssetReaderTrackOutput?
        var audioInput: AVAssetWriterInput?
        if options.writesAudio,
           let audio = try await asset.loadTracks(withMediaType: .audio).first {
            let output = AVAssetReaderTrackOutput(track: audio, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            // Passing through to MP4 needs the source format up front, or
            // AVAssetWriter raises rather than returning an error.
            let hint = try await audio.load(.formatDescriptions).first
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil,
                                           sourceFormatHint: hint)
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioOutput = output
            audioInput = input
        }

        // The reader is only needed when something is being read from the clip.
        if (!overlayOnly || options.writesAudio), !reader.startReading() {
            throw ExportError.failed(detail(reader.error))
        }
        guard writer.startWriting() else {
            throw ExportError.cannotWrite(detail(writer.error))
        }
        writer.startSession(atSourceTime: .zero)

        let started = Date()
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let overlayFrames = max(Int((duration / step.seconds).rounded()), 1)

        // The two tracks are pumped on their own queues; video is what takes the
        // time, and audio must not be blocked behind it.
        async let audioDone: Void = Self.pump(audioOutput, into: audioInput)

        let videoQueue = DispatchQueue(label: "GoPull.export.video")
        var written = 0
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            videoInput.requestMediaDataWhenReady(on: videoQueue) {
                while videoInput.isReadyForMoreMediaData {
                    if self.cancelled.isSet || Task.isCancelled {
                        reader.cancelReading(); videoInput.markAsFinished()
                        continuation.resume(throwing: ExportError.cancelled)
                        return
                    }
                    var source: CVPixelBuffer?
                    let time: CMTime
                    if overlayOnly {
                        guard written < overlayFrames else {
                            videoInput.markAsFinished()
                            continuation.resume()
                            return
                        }
                        time = CMTimeMultiply(step, multiplier: Int32(written))
                    } else {
                        guard let sample = videoOutput?.copyNextSampleBuffer() else {
                            videoInput.markAsFinished()
                            continuation.resume()
                            return
                        }
                        guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
                        source = image
                        time = CMSampleBufferGetPresentationTimeStamp(sample)
                    }
                    guard let pool = adaptor.pixelBufferPool else {
                        continuation.resume(throwing: ExportError.cannotWrite("no buffer pool"))
                        return
                    }
                    var target: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &target)
                    guard let target else {
                        continuation.resume(throwing: ExportError.cannotWrite("no pixel buffer"))
                        return
                    }

                    Self.compose(source: source, into: target, size: outputSize,
                                 colorSpace: space, track: track,
                                 at: time.seconds, settings: settings,
                                 maxSpeed: maxSpeed, projection: projection,
                                 gforce: gforce, maxG: maxG,
                                 peaks: peaks, runs: runs)

                    if !adaptor.append(target, withPresentationTime: time) {
                        continuation.resume(throwing: ExportError.cannotWrite(
                            detail(writer.error)))
                        return
                    }
                    written += 1
                    let count = written
                    let elapsed = Date().timeIntervalSince(started)
                    Task { @MainActor [weak self] in
                        self?.progress = ExportProgress(
                            fraction: min(Double(count) / Double(totalFrames), 1),
                            framesWritten: count,
                            framesPerSecond: elapsed > 0 ? Double(count) / elapsed : 0)
                    }
                }
            }
        }
        await audioDone
        await writer.finishWriting()

        if writer.status == .failed {
            try? FileManager.default.removeItem(at: writeTo)
            throw ExportError.cannotWrite(detail(writer.error))
        }

        do {
            if replacing || FileManager.default.fileExists(atPath: destination.path) {
                // Atomic, so an interrupted replace cannot destroy the original:
                // either the old file or the new one is there, never half.
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: writeTo)
            } else {
                try FileManager.default.moveItem(at: writeTo, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: writeTo)
            throw ExportError.cannotWrite(error.localizedDescription)
        }
        progress.fraction = 1
    }

    /// Whether replacing this clip would throw away telemetry that is not
    /// anywhere else.
    ///
    /// The writer produces video and audio only; a GoPro's `gpmd` track is not
    /// something AVFoundation can even see, let alone pass through. Overwriting
    /// therefore destroys the GPS data, and with it any chance of adjusting the
    /// overlays later.
    nonisolated static func replacingLosesTelemetry(_ clip: URL) -> Bool {
        (try? GPMFTrack.payloads(of: clip).isEmpty == false) ?? false
    }

    /// Copies a track through untouched.
    private nonisolated static func pump(_ output: AVAssetReaderTrackOutput?,
                                         into input: AVAssetWriterInput?) async {
        guard let output, let input else { return }
        let queue = DispatchQueue(label: "GoPull.export.audio")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    if !input.append(sample) {
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }
    }

    /// Draws one frame, scaled if needed, with the overlays on top.
    private nonisolated static func compose(source: CVPixelBuffer?, into target: CVPixelBuffer,
                                            size: CGSize, colorSpace: CGColorSpace,
                                            track: TelemetryTrack, at time: Double,
                                            settings: OverlaySettings, maxSpeed: Double,
                                            projection: RouteProjection,
                                            gforce: GForceTrack, maxG: Double,
                                            peaks: GForceTrack.RunningExtremes,
                                            runs: [AccelerationRun]) {
        CVPixelBufferLockBaseAddress(target, [])
        defer { CVPixelBufferUnlockBaseAddress(target, []) }
        if let source { CVPixelBufferLockBaseAddress(source, .readOnly) }
        defer { if let source { CVPixelBufferUnlockBaseAddress(source, .readOnly) } }

        guard let base = CVPixelBufferGetBaseAddress(target),
              let context = CGContext(
                data: base,
                width: CVPixelBufferGetWidth(target),
                height: CVPixelBufferGetHeight(target),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(target),
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                          | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }

        // One `draw` for both paths, deliberately. There used to be two -- an
        // early return for the overlay-only case and another at the end for the
        // burn-in -- and the second one was missing `extremes:` and `runs:`.
        // Both have defaults, so it compiled and silently dropped the g-force
        // peak marks and the whole launch badge from every burned-in export
        // while the editor preview, which passes them, looked right.
        if let source {
            copy(source, into: base, target: target, size: size)
        } else {
            // Overlay only: start from transparency. Pool buffers are recycled,
            // so the previous frame is still in them and must be cleared, or the
            // overlay smears across the whole export.
            memset(base, 0, CVPixelBufferGetBytesPerRow(target) * CVPixelBufferGetHeight(target))
        }

        OverlayComposer.draw(in: context, frameSize: size, track: track, at: time,
                             settings: settings, maxSpeed: maxSpeed,
                             projection: projection, gforce: gforce, maxG: maxG,
                             peaks: peaks, runs: runs)
    }

    /// Puts the source frame into the target buffer, scaling if the export is
    /// smaller than the clip.
    private nonisolated static func copy(_ source: CVPixelBuffer,
                                         into base: UnsafeMutableRawPointer,
                                         target: CVPixelBuffer, size: CGSize) {
        let sourceWidth = CVPixelBufferGetWidth(source)
        let sourceHeight = CVPixelBufferGetHeight(source)
        let scaling = sourceWidth != Int(size.width) || sourceHeight != Int(size.height)

        if !scaling, let sourceBase = CVPixelBufferGetBaseAddress(source) {
            // Same size: copy the rows straight across. Going through
            // makeImage() and draw() instead cost a full CGImage allocation per
            // frame and held 4K export to 15 fps.
            let sourceStride = CVPixelBufferGetBytesPerRow(source)
            let targetStride = CVPixelBufferGetBytesPerRow(target)
            if sourceStride == targetStride {
                memcpy(base, sourceBase, sourceStride * sourceHeight)
            } else {
                let width = min(sourceStride, targetStride)
                for row in 0..<sourceHeight {
                    memcpy(base.advanced(by: row * targetStride),
                           sourceBase.advanced(by: row * sourceStride), width)
                }
            }
        } else if let sourceBase = CVPixelBufferGetBaseAddress(source) {
            // vImage, not makeImage() plus draw(). Going through Core Graphics
            // made downscaling *slower* than not scaling at all -- 8K to 4K ran
            // at 18 fps against 21 fps for 8K untouched, which is backwards.
            var input = vImage_Buffer(data: sourceBase,
                                      height: vImagePixelCount(sourceHeight),
                                      width: vImagePixelCount(sourceWidth),
                                      rowBytes: CVPixelBufferGetBytesPerRow(source))
            var output = vImage_Buffer(data: base,
                                       height: vImagePixelCount(CVPixelBufferGetHeight(target)),
                                       width: vImagePixelCount(CVPixelBufferGetWidth(target)),
                                       rowBytes: CVPixelBufferGetBytesPerRow(target))
            vImageScale_ARGB8888(&input, &output, nil,
                                 vImage_Flags(kvImageNoFlags))
        }
    }
}
