//
//  GoProCamera.swift
//  GoPull
//
//  Discovery and HTTP client for a USB-tethered GoPro.
//
//  A modern GoPro does not appear as a USB disk. Plugged in, it raises a USB
//  Ethernet interface and serves HTTP on port 8080: a control API under
//  /gopro/..., and the camera's card under /videos/DCIM/... GoPro Connect hands
//  the Mac x.x.x.55 and keeps x.x.x.51 for the camera, which is how we find it.
//

import Foundation

/// The camera exposes its card here, as a plain HTTP file server.
private let dcimRoot = "/videos/DCIM"

private let httpDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    return formatter
}()

struct MediaFile: Identifiable, Hashable {
    let folder: String
    let name: String
    let size: Int64
    let modified: Date?
    /// Which device shot this, worked out per folder -- a card in a GoPro may
    /// well have been written by something else entirely.
    var device: DeviceIdentity = DeviceIdentity(brand: "GoPro", model: nil)

    var id: String { "\(folder)/\(name)" }
    var isSidecar: Bool { DeviceCatalog.isSidecar(name) }
}

/// One row of the camera's HTML directory index.
private struct IndexEntry {
    let name: String
    let isDirectory: Bool
    /// Rounded, e.g. "77.0M" -- only good enough to use as a cache key.
    let displayedSize: String
    let displayedDate: String
}

struct CameraInfo: Equatable {
    var model: String
    var serial: String
    var firmware: String
}

enum CameraError: LocalizedError {
    case notFound
    case http(String, Int)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "No GoPro found. Connect it by USB, switch it on, and make sure "
                 + "it is in GoPro Connect mode rather than MTP."
        case .http(let path, let code):
            return "Camera returned HTTP \(code) for \(path)."
        case .malformed(let what):
            return "Could not read \(what) from the camera."
        }
    }
}

actor GoProCamera {

    let ip: String
    let info: CameraInfo

    private let session: URLSession

    private init(ip: String, info: CameraInfo) {
        self.ip = ip
        self.info = info
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 8
        self.session = URLSession(configuration: config)
    }

    // MARK: - Discovery

    /// Every plausible camera address, derived from our own GoPro Connect interfaces.
    static func candidateAddresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var seen = Set<String>()
        var result: [String] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                              &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let parts = String(cString: host).split(separator: ".")
            // GoPro Connect always lands somewhere in 172.16.0.0/12
            guard parts.count == 4, parts[0] == "172",
                  let second = Int(parts[1]), (16...31).contains(second) else { continue }
            let guess = "\(parts[0]).\(parts[1]).\(parts[2]).51"
            if seen.insert(guess).inserted { result.append(guess) }
        }
        return result
    }

    static func discover() async throws -> GoProCamera {
        for candidate in candidateAddresses() {
            if let info = try? await probe(candidate) {
                let camera = GoProCamera(ip: candidate, info: info)
                await camera.enableWiredControl()
                await camera.readClockOffset()
                return camera
            }
        }
        throw CameraError.notFound
    }

    // MARK: - The camera's clock

    /// Seconds the camera's clock runs ahead of UTC.
    ///
    /// Every timestamp the camera reports is local wall-clock time wearing a
    /// UTC label, and nothing in either response says so. `/gopro/media/list`
    /// gives `mod` and `cre` as seconds since the epoch computed from the local
    /// clock, and the file server puts the same local time in `Last-Modified`
    /// with `GMT` after it. In Arizona a photo taken at 12:02 came back as
    /// `Fri, 28 Aug 2026 12:02:32 GMT` and was shown as 05:02 -- out by the
    /// seven hours of the offset, in the wrong direction.
    private(set) var clockOffset: TimeInterval = 0

    /// A camera timestamp, corrected to a real instant.
    func instant(fromCameraEpoch epoch: TimeInterval) -> Date {
        Date(timeIntervalSince1970: epoch - clockOffset)
    }

    /// Works the offset out from what the camera says the time is.
    ///
    /// Deliberately not from the `tzone` and `dst` fields it also returns: it is
    /// not documented whether `tzone` already includes daylight saving or
    /// whether `dst` has to be added to it, and guessing wrong is an hour's
    /// error for half the year in most of the world. Reading the camera's own
    /// wall clock as UTC and comparing it with now needs no such interpretation.
    ///
    /// Rounded to a quarter hour, because every real zone is a multiple of one
    /// and this way a camera clock a few minutes out does not skew it.
    func readClockOffset() async {
        guard let data = try? await get("/gopro/camera/get_date_time"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let date = json["date"] as? String, let time = json["time"] as? String,
              let offset = Self.offsetFromCameraClock(date: date, time: time)
        else { return }
        clockOffset = offset
    }

    /// The offset implied by the camera saying it is `date` at `time`.
    ///
    /// Returns nil when the reading cannot be parsed, or is far enough from now
    /// that it is a wrong clock rather than another time zone -- baking a wrong
    /// clock in as an offset would move every timestamp by the same error.
    /// Named apart from the `clockOffset` property on purpose: with both called
    /// `clockOffset`, `GoProCamera.clockOffset(...)` is ambiguous against the
    /// property's unapplied member reference, and the compiler gives up rather
    /// than saying so.
    static func offsetFromCameraClock(date cameraDate: String, time cameraTime: String,
                                      now: Date = Date()) -> TimeInterval? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy_MM_dd HH_mm_ss"
        guard let asIfUTC = formatter.date(from: "\(cameraDate) \(cameraTime)") else { return nil }

        let difference = asIfUTC.timeIntervalSince(now)
        guard abs(difference) <= 15 * 3600 else { return nil }
        // Every real zone is a multiple of a quarter hour, so rounding to one
        // keeps a camera clock a few minutes out from skewing the offset.
        let quarter: TimeInterval = 15 * 60
        return (difference / quarter).rounded() * quarter
    }

    private static func probe(_ ip: String) async throws -> CameraInfo {
        let url = URL(string: "http://\(ip):8080/gopro/camera/info")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = json["model_name"] as? String else {
            throw CameraError.malformed("camera info")
        }
        return CameraInfo(model: model,
                          serial: json["serial_number"] as? String ?? "",
                          firmware: json["firmware_version"] as? String ?? "")
    }

    // MARK: - Requests

    private func get(_ path: String) async throws -> Data {
        let url = URL(string: "http://\(ip):8080\(path)")!
        let (data, response) = try await session.data(from: url)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw CameraError.http(path, code) }
        return data
    }

    @discardableResult
    func keepAlive() async -> Bool {
        ((try? await get("/gopro/camera/keep_alive")) != nil)
    }

    /// Deletes one file from the card. Returns false if the camera refused.
    ///
    /// There is no undo on the camera side and no trash — the file is gone from
    /// the card the moment this succeeds.
    func delete(folder: String, name: String) async -> Bool {
        let path = "\(folder)/\(name)"
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return false }
        return (try? await get("/gopro/media/delete/file?path=\(encoded)")) != nil
    }

    @discardableResult
    func enableWiredControl() async -> Bool {
        ((try? await get("/gopro/camera/control/wired_usb?p=1")) != nil)
    }

    /// Free space on the card. Camera status key 54 reports it in kilobytes.
    func freeBytes() async -> Int64 {
        guard let data = try? await get("/gopro/camera/state"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? [String: Any] else { return 0 }
        if let kb = status["54"] as? NSNumber { return kb.int64Value * 1024 }
        if let kb = status["54"] as? String, let value = Int64(kb) { return value * 1024 }
        return 0
    }

    func mediaList() async throws -> [String: [MediaFile]] {
        let data = try await get("/gopro/media/list")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let media = json["media"] as? [[String: Any]] else {
            throw CameraError.malformed("media list")
        }

        var tree: [String: [MediaFile]] = [:]
        for directory in media {
            guard let folder = directory["d"] as? String,
                  let entries = directory["fs"] as? [[String: Any]] else { continue }
            var files: [MediaFile] = []
            for entry in entries {
                guard let name = entry["n"] as? String, !name.hasPrefix("._") else { continue }
                let size = Self.int64(entry["s"]) ?? 0
                let stamp = Self.int64(entry["mod"]) ?? Self.int64(entry["cre"])
                let modified = stamp.map { instant(fromCameraEpoch: TimeInterval($0)) }
                for expanded in Self.expand(name: name, entry: entry) {
                    files.append(MediaFile(folder: folder, name: expanded,
                                           size: size, modified: modified))
                }
            }
            if !files.isEmpty {
                tree[folder] = files.sorted { $0.name < $1.name }
            }
        }
        return tree
    }

    /// Burst and time-lapse groups arrive as one entry spanning a numeric range.
    private static func expand(name: String, entry: [String: Any]) -> [String] {
        guard entry["g"] != nil,
              let first = int64(entry["b"]), let last = int64(entry["l"]),
              last >= first, last - first <= 10_000 else { return [name] }

        // Split "GOPR0042.JPG" into prefix "GOPR", digits "0042" and ext ".JPG"
        // without a regex, so this compiles cleanly in Swift 5 language mode.
        guard let dot = name.lastIndex(of: ".") else { return [name] }
        let ext = String(name[dot...])
        let stem = name[name.startIndex..<dot]
        let digits = stem.reversed().prefix { $0.isNumber }.reversed()
        guard !digits.isEmpty else { return [name] }
        let prefix = String(stem.dropLast(digits.count))
        let width = digits.count

        return (first...last).map { number in
            prefix + String(format: "%0\(width)d", number) + ext
        }
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) }
        return nil
    }

    // MARK: - Whole-card scan

    /// Exact sizes keyed by "folder/name|roundedSize|date" so a re-scan only
    /// issues HEAD requests for entries that actually changed.
    private var sizeCache: [String: (size: Int64, modified: Date?)] = [:]

    /// Everything on the card, not just what the camera claims as its own media.
    ///
    /// `/gopro/media/list` only reports GoPro-native clips: it misses proxies
    /// (`.LRV`) and anything written by another device. The plain file server
    /// underneath shows the lot, so that's what we walk. It only reports rounded
    /// sizes ("77.0M"), which is useless for a mount, so exact lengths come from
    /// a HEAD per file -- cached, because this runs on every poll.
    func cardTree() async throws -> [String: [MediaFile]] {
        let native = (try? await mediaList()) ?? [:]

        let rootHTML = try await getString(dcimRoot + "/")
        let folders = Self.parseIndex(rootHTML)
            .filter { $0.isDirectory }
            .map { $0.name.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }

        var tree: [String: [MediaFile]] = [:]

        for folder in folders {
            guard let html = try? await getString("\(dcimRoot)/\(folder)/") else { continue }
            let entries = Self.parseIndex(html).filter { entry in
                !entry.isDirectory
                    && !entry.name.hasPrefix(".")        // AppleDouble and dotfiles
                    && !entry.name.hasPrefix("..")
            }
            guard !entries.isEmpty else { continue }

            let nativeFiles = native[folder] ?? []
            let identity = DeviceCatalog.identify(folder: folder,
                                                  fileNames: entries.map { $0.name },
                                                  attached: info,
                                                  isNative: !nativeFiles.isEmpty)

            // Anything the camera already described exactly needs no HEAD.
            var known: [String: MediaFile] = [:]
            for file in nativeFiles { known[file.name] = file }

            var needLookup: [IndexEntry] = []
            var files: [MediaFile] = []

            for entry in entries {
                if let exact = known[entry.name] {
                    files.append(MediaFile(folder: folder, name: entry.name,
                                           size: exact.size, modified: exact.modified,
                                           device: identity))
                } else if let cached = sizeCache[Self.cacheKey(folder, entry)] {
                    files.append(MediaFile(folder: folder, name: entry.name,
                                           size: cached.size, modified: cached.modified,
                                           device: identity))
                } else {
                    needLookup.append(entry)
                }
            }

            if !needLookup.isEmpty {
                let ip = self.ip
                // Captured here: the tasks below run outside the actor.
                let offset = self.clockOffset
                let measured = await withTaskGroup(of: (IndexEntry, Int64, Date?)?.self) { group in
                    var pending = needLookup.makeIterator()
                    var inFlight = 0
                    var results: [(IndexEntry, Int64, Date?)] = []

                    func schedule() {
                        guard let entry = pending.next() else { return }
                        inFlight += 1
                        group.addTask {
                            guard let head = await Self.head(ip: ip, folder: folder,
                                                             name: entry.name, offset: offset)
                            else { return nil }
                            return (entry, head.0, head.1)
                        }
                    }
                    for _ in 0..<min(8, needLookup.count) { schedule() }
                    while inFlight > 0, let result = await group.next() {
                        inFlight -= 1
                        if let result { results.append(result) }
                        schedule()
                    }
                    return results
                }

                for (entry, size, modified) in measured {
                    sizeCache[Self.cacheKey(folder, entry)] = (size, modified)
                    files.append(MediaFile(folder: folder, name: entry.name,
                                           size: size, modified: modified,
                                           device: identity))
                }
            }

            if !files.isEmpty {
                tree[folder] = files.sorted { $0.name < $1.name }
            }
        }

        return tree
    }

    private func getString(_ path: String) async throws -> String {
        String(decoding: try await get(path), as: UTF8.self)
    }

    private static func cacheKey(_ folder: String, _ entry: IndexEntry) -> String {
        "\(folder)/\(entry.name)|\(entry.displayedSize)|\(entry.displayedDate)"
    }

    /// Exact length and timestamp for one file.
    private static func head(ip: String, folder: String, name: String,
                             offset: TimeInterval) async -> (Int64, Date?)? {
        let encoded = "\(folder)/\(name)"
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "\(folder)/\(name)"
        guard let url = URL(string: "http://\(ip):8080\(dcimRoot)/\(encoded)") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

        let size = http.expectedContentLength
        guard size >= 0 else { return nil }

        var modified: Date?
        if let header = http.value(forHTTPHeaderField: "Last-Modified") {
            // The camera writes its local wall clock here and calls it GMT, so
            // this needs the same correction as the media list.
            modified = httpDateFormatter.date(from: header)?.addingTimeInterval(-offset)
        }
        return (size, modified)
    }

    /// Rows look like:
    /// `<tr><td><a href="…">NAME</a></td><td>&nbsp;DATE</td><td>&nbsp;&nbsp;SIZE</td></tr>`
    private static func parseIndex(_ html: String) -> [IndexEntry] {
        var entries: [IndexEntry] = []
        for row in html.components(separatedBy: "<tr>").dropFirst() {
            let cells = row.components(separatedBy: "<td>")
            guard cells.count >= 4 else { continue }

            guard let nameOpen = cells[1].range(of: "\">"),
                  let nameClose = cells[1].range(of: "</a>") else { continue }
            let rawName = String(cells[1][nameOpen.upperBound..<nameClose.lowerBound])
            let name = rawName.removingPercentEncoding ?? rawName
            guard !name.isEmpty, name != "Parent directory" else { continue }

            func text(_ cell: String) -> String {
                cell.replacingOccurrences(of: "&nbsp;", with: "")
                    .replacingOccurrences(of: "</td>", with: "")
                    .replacingOccurrences(of: "</tr>", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let date = text(cells[2])
            let size = text(cells[3])

            entries.append(IndexEntry(name: name.hasSuffix("/") ? String(name.dropLast()) : name,
                                      isDirectory: size.contains("DIRECTORY") || name.hasSuffix("/"),
                                      displayedSize: size,
                                      displayedDate: date))
        }
        return entries
    }

    nonisolated func downloadURL(folder: String, name: String) -> URL {
        URL(string: "http://\(ip):8080\(dcimRoot)/\(folder)/\(name)")!
    }
}
