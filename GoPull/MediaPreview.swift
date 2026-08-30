//
//  MediaPreview.swift
//  GoPull
//
//  Thumbnails and clip details, so a clip can be identified before it is
//  transferred rather than after.
//
//  The camera has all of this already: /gopro/media/thumbnail returns a JPEG in
//  about 30ms, /gopro/media/info returns duration and dimensions, and every
//  clip has a low-resolution .LRV proxy beside it on the card that plays over
//  HTTP. None of it requires copying the original.
//

import AppKit
import Combine
import Foundation

/// What the camera knows about one clip. Every value arrives as a string.
struct MediaDetails: Equatable {
    var width: Int = 0
    var height: Int = 0
    /// Whole seconds. Absent for stills.
    var duration: Int?
    var fps: Double?
    /// The `.LRV` proxy's length. Zero or absent when the clip has no proxy.
    var proxyBytes: Int64 = 0

    var resolutionLabel: String? {
        guard width > 0, height > 0 else { return nil }
        return "\(width)×\(height)"
    }

    var durationLabel: String? {
        guard let duration, duration > 0 else { return nil }
        let (h, m, s) = (duration / 3600, (duration % 3600) / 60, duration % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    var fpsLabel: String? {
        guard let fps, fps > 0 else { return nil }
        return fps.rounded() == fps ? "\(Int(fps)) fps" : String(format: "%.2f fps", fps)
    }

    /// The one-line summary under a clip's name.
    var summary: String {
        [durationLabel, resolutionLabel, fpsLabel].compactMap { $0 }.joined(separator: " · ")
    }

    init() {}

    init?(json: [String: Any]) {
        func number(_ key: String) -> Double? {
            if let value = json[key] as? NSNumber { return value.doubleValue }
            if let value = json[key] as? String { return Double(value) }
            return nil
        }
        width = Int(number("w") ?? 0)
        height = Int(number("h") ?? 0)
        if let seconds = number("dur"), seconds > 0 { duration = Int(seconds) }
        // Frame rate arrives as a rational, e.g. 30000/1001 for 29.97.
        if let numerator = number("fps"), numerator > 0 {
            let denominator = number("fps_denom") ?? 1
            fps = denominator > 0 ? numerator / denominator : numerator
        }
        proxyBytes = Int64(number("ls") ?? 0)
        guard width > 0 || duration != nil else { return nil }
    }
}

/// Thumbnails and details for the clips on the card, fetched once and kept.
///
/// Requests are issued **one at a time**, and stop entirely while an import is
/// running. Both matter: the camera's control API stops answering under the
/// importer's four range streams, which is what used to make long imports fail
/// (see DECISIONS #21). Preview traffic must never be what re-creates that.
@MainActor
final class PreviewStore: ObservableObject {

    @Published private(set) var thumbnails: [String: NSImage] = [:]
    @Published private(set) var details: [String: MediaDetails] = [:]
    /// What each clip's telemetry holds, so the list can say before a copy.
    @Published private(set) var summaries: [String: TelemetrySummary] = [:]

    private var cameraIP = ""
    private var queue: [MediaFile] = []
    private var queued: Set<String> = []
    /// Clips the camera has no preview for -- proxies and sidecars 404 -- so
    /// they are asked for once and then left alone.
    private var unavailable: Set<String> = []
    private var worker: Task<Void, Never>?
    private var isSuspended = false

    /// Its own session, so preview traffic can never be delayed behind, or
    /// delay, the polling and import sessions.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// A different camera means a different card, so nothing carries over.
    /// A camera that serves none of this -- a HERO8 has no thumbnail, media
    /// info or telemetry endpoint at all -- is recorded here rather than
    /// discovered one 404 at a time. `request` then does nothing, which is what
    /// makes the rows fall back to their icon and the badges stay away.
    @Published private(set) var servesPreviews = true

    func update(cameraIP: String, servesPreviews: Bool = true) {
        self.servesPreviews = servesPreviews
        guard cameraIP != self.cameraIP else { return }
        self.cameraIP = cameraIP
        thumbnails.removeAll()
        details.removeAll()
        summaries.removeAll()
        unavailable.removeAll()
        queue.removeAll()
        queued.removeAll()
    }

    /// Drops what is known about files that have gone from the card.
    ///
    /// Only these entries are stale: deleting one clip says nothing about any
    /// other clip's thumbnail. Clearing the whole store instead left every row
    /// blank, because a row only asks for its preview from `.task` and that
    /// does not run again for rows that stayed on screen.
    func forget(_ files: [MediaFile]) {
        for file in files {
            thumbnails[file.id] = nil
            details[file.id] = nil
            summaries[file.id] = nil
            unavailable.remove(file.id)
            queued.remove(file.id)
        }
        queue.removeAll { file in files.contains { $0.id == file.id } }
    }

    /// Called when an import starts. In-flight work is dropped, not awaited.
    func suspend() {
        isSuspended = true
        worker?.cancel()
        worker = nil
        queue.removeAll()
        queued.removeAll()
    }

    func resume() {
        isSuspended = false
    }

    /// Ask for a clip's preview. Cheap to call repeatedly -- from `.task`, on
    /// every redraw -- because everything already known or already asked for is
    /// filtered out here.
    func request(_ file: MediaFile) {
        guard !isSuspended, !cameraIP.isEmpty, servesPreviews else { return }
        guard thumbnails[file.id] == nil || details[file.id] == nil
                || (MediaPreview.isVideo(file) && summaries[file.id] == nil)
        else { return }
        guard !queued.contains(file.id), !unavailable.contains(file.id) else { return }
        // Positively, rather than by excluding sidecars: raw audio is not a
        // sidecar any more, and there is no thumbnail for a WAV either.
        guard MediaPreview.isVideo(file) || MediaPreview.isStill(file) else { return }

        queued.insert(file.id)
        queue.append(file)
        startWorker()
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let next = self?.takeNext() {
                await self?.fetch(next)
                if Task.isCancelled { break }
            }
            self?.worker = nil
        }
    }

    private func takeNext() -> MediaFile? {
        guard !isSuspended, !queue.isEmpty else { return nil }
        return queue.removeFirst()
    }

    private func fetch(_ file: MediaFile) async {
        let ip = cameraIP
        let id = file.id

        if details[id] == nil,
           let data = await Self.get("/gopro/media/info", ip: ip, file: file),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let parsed = MediaDetails(json: json) {
            details[id] = parsed
        }

        if thumbnails[id] == nil {
            if let data = await Self.get("/gopro/media/thumbnail", ip: ip, file: file),
               let image = NSImage(data: data) {
                thumbnails[id] = image
            } else {
                unavailable.insert(id)
            }
        }

        // Telemetry last and only for video: it is the heavy one, about 1.3 MB
        // per minute of footage against 60 KB for a thumbnail, and the point of
        // it is to answer "is there anything in this clip" before an 11 GB copy.
        if MediaPreview.isVideo(file), summaries[id] == nil,
           let data = await Self.get("/gopro/media/telemetry", ip: ip, file: file) {
            let summary = await Task.detached(priority: .utility) { () -> TelemetrySummary in
                let scratch = FileManager.default.temporaryDirectory
                    .appendingPathComponent("gopull-telemetry-\(UUID().uuidString).mp4")
                defer { try? FileManager.default.removeItem(at: scratch) }
                guard (try? data.write(to: scratch)) != nil else { return TelemetrySummary() }
                return TelemetryProbe.summarise(scratch)
            }.value
            summaries[id] = summary
        }
        queued.remove(id)
    }

    private static func get(_ path: String, ip: String, file: MediaFile) async -> Data? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = ip
        components.port = 8080
        components.path = path
        components.queryItems = [URLQueryItem(name: "path", value: "\(file.folder)/\(file.name)")]
        guard let url = components.url else { return nil }

        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              !data.isEmpty else { return nil }
        return data
    }
}

// MARK: - What to play

/// What a preview should show for one clip.
enum PreviewSource {
    /// A video the camera will stream over HTTP, and whether it is the
    /// low-resolution proxy rather than the original.
    case video(URL, isProxy: Bool)
    case still(URL)

    var url: URL {
        switch self {
        case .video(let url, _): return url
        case .still(let url):    return url
        }
    }
}

enum MediaPreview {

    private static let stillExtensions: Set<String> = ["jpg", "jpeg", "png", "heic"]
    private static let videoExtensions: Set<String> = ["mp4", "360", "mov", "lrv"]

    static func isStill(_ file: MediaFile) -> Bool {
        stillExtensions.contains((file.name as NSString).pathExtension.lowercased())
    }

    static func isVideo(_ file: MediaFile) -> Bool {
        videoExtensions.contains((file.name as NSString).pathExtension.lowercased())
    }

    /// The `.LRV` beside a clip, if the card has one.
    ///
    /// GoPro names a clip `GX010005.MP4` and its proxy `GL010005.LRV` -- same
    /// digits, second letter swapped. Rather than reconstruct that name and
    /// hope, this matches against the files actually on the card, which also
    /// covers the `GH`/`GS` prefixes older bodies use.
    static func proxy(for file: MediaFile, among files: [MediaFile]) -> MediaFile? {
        guard isVideo(file), !file.isSidecar else { return nil }
        let stem = numericStem(file.name)
        guard !stem.isEmpty else { return nil }
        return files.first { candidate in
            candidate.folder == file.folder
                && (candidate.name as NSString).pathExtension.lowercased() == "lrv"
                && numericStem(candidate.name) == stem
        }
    }

    /// "GX010005.MP4" -> "010005": the part that identifies the recording
    /// regardless of which stream of it we are looking at.
    private static func numericStem(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        guard base.count > 2 else { return "" }
        let tail = String(base.dropFirst(2))
        return tail.allSatisfy(\.isNumber) ? tail : ""
    }

    /// Prefers the proxy: it is ~30x smaller than an 8K original and decodes
    /// without stuttering over the USB link.
    static func source(for file: MediaFile, among files: [MediaFile],
                       cameraIP: String) -> PreviewSource? {
        guard !cameraIP.isEmpty else { return nil }
        func url(_ target: MediaFile) -> URL? {
            let path = "/videos/DCIM/\(target.folder)/\(target.name)"
            guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            else { return nil }
            return URL(string: "http://\(cameraIP):8080\(encoded)")
        }

        if isStill(file) {
            return url(file).map { .still($0) }
        }
        guard isVideo(file) else { return nil }
        if let proxy = proxy(for: file, among: files), let proxyURL = url(proxy) {
            return .video(proxyURL, isProxy: true)
        }
        return url(file).map { .video($0, isProxy: false) }
    }
}
