//
//  WebDAVServer.swift
//  GoPull
//
//  A tiny read-only WebDAV server on localhost that macOS's built-in WebDAV
//  client can mount -- no macFUSE, no kernel extension, no sudo.
//
//  It answers OPTIONS and PROPFIND itself. For GET and HEAD it replies with a
//  302 pointing at the camera's own file server: macOS follows the redirect and
//  re-sends its Range header, so video data flows straight from the camera to
//  the kernel and never passes through this process. That keeps seeking fast
//  and means a 500 MB clip is never buffered in the app.
//

import Foundation
import Network

/// What the server should currently expose. Swapped out wholesale as the card changes.
struct CardSnapshot {
    var cameraIP: String = ""
    var tree: [String: [MediaFile]] = [:]
    var usedBytes: Int64 = 0
    var freeBytes: Int64 = 0
}

/// Guarantees a continuation is resumed exactly once, even though the state
/// handler can be invoked repeatedly from another thread.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

final class WebDAVServer {

    /// Served as an empty file so Spotlight won't drag every clip over USB to index it.
    private static let spotlightMarker = "/.metadata_never_index"

    private let queue = DispatchQueue(label: "com.nicsoft.gopro.webdav")
    private var listener: NWListener?
    private let lock = NSLock()
    private var snapshot = CardSnapshot()
    private(set) var port: UInt16 = 0

    func update(_ newValue: CardSnapshot) {
        lock.lock(); snapshot = newValue; lock.unlock()
    }

    private var current: CardSnapshot {
        lock.lock(); defer { lock.unlock() }; return snapshot
    }

    var isRunning: Bool { listener != nil }

    // MARK: - Lifecycle

    func start() async throws -> UInt16 {
        if let existing = listener, existing.state == .ready { return port }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)

        let listener = try NWListener(using: parameters)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Peer(connection: connection, server: self, queue: self.queue).start()
        }

        let once = OnceFlag()
        let assigned: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.fire() {
                        continuation.resume(returning: listener.port?.rawValue ?? 0)
                    }
                case .failed(let error), .waiting(let error):
                    if once.fire() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: self.queue)
        }

        port = assigned
        return assigned
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
    }

    // MARK: - Routing

    fileprivate enum Resource {
        case root
        case directory(String)
        case file(folder: String, file: MediaFile)
        case marker
        case missing
    }

    fileprivate func resolve(_ path: String) -> Resource {
        if path == Self.spotlightMarker { return .marker }
        let parts = path.split(separator: "/").map(String.init)
        let tree = current.tree
        switch parts.count {
        case 0:
            return .root
        case 1:
            return tree[parts[0]] != nil ? .directory(parts[0]) : .missing
        case 2:
            guard let file = tree[parts[0]]?.first(where: { $0.name == parts[1] }) else {
                return .missing
            }
            return .file(folder: parts[0], file: file)
        default:
            return .missing
        }
    }

    fileprivate func propfindBody(for path: String, depth: String) -> Data? {
        let snapshot = current
        var entries: [String] = []

        switch resolve(path) {
        case .missing:
            return nil
        case .marker:
            entries.append(Self.fileEntry(href: Self.spotlightMarker,
                                          name: ".metadata_never_index",
                                          size: 0, modified: nil))
        case .root:
            entries.append(Self.collectionEntry(href: "/", name: "GoPro",
                                                used: snapshot.usedBytes,
                                                free: snapshot.freeBytes))
            if depth != "0" {
                for folder in snapshot.tree.keys.sorted() {
                    entries.append(Self.collectionEntry(href: "/\(folder)/", name: folder,
                                                        used: snapshot.usedBytes,
                                                        free: snapshot.freeBytes))
                }
                entries.append(Self.fileEntry(href: Self.spotlightMarker,
                                              name: ".metadata_never_index",
                                              size: 0, modified: nil))
            }
        case .directory(let folder):
            entries.append(Self.collectionEntry(href: "/\(folder)/", name: folder,
                                                used: snapshot.usedBytes,
                                                free: snapshot.freeBytes))
            if depth != "0" {
                for file in snapshot.tree[folder] ?? [] {
                    entries.append(Self.fileEntry(href: "/\(folder)/\(file.name)",
                                                  name: file.name,
                                                  size: file.size,
                                                  modified: file.modified))
                }
            }
        case .file(let folder, let file):
            entries.append(Self.fileEntry(href: "/\(folder)/\(file.name)",
                                          name: file.name,
                                          size: file.size,
                                          modified: file.modified))
        }

        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
        \(entries.joined())</D:multistatus>

        """
        return Data(xml.utf8)
    }

    fileprivate func redirectTarget(folder: String, name: String) -> String {
        let encoded = "\(folder)/\(name)"
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "\(folder)/\(name)"
        return "http://\(current.cameraIP):8080/videos/DCIM/\(encoded)"
    }

    // MARK: - XML

    private static func collectionEntry(href: String, name: String,
                                        used: Int64, free: Int64) -> String {
        """
        <D:response><D:href>\(escapeHref(href))</D:href><D:propstat><D:prop>\
        <D:displayname>\(escapeXML(name))</D:displayname>\
        <D:resourcetype><D:collection/></D:resourcetype>\
        <D:getcontenttype>httpd/unix-directory</D:getcontenttype>\
        <D:getlastmodified>\(rfc1123(Date()))</D:getlastmodified>\
        <D:creationdate>\(iso8601(Date()))</D:creationdate>\
        <D:quota-used-bytes>\(used)</D:quota-used-bytes>\
        <D:quota-available-bytes>\(free)</D:quota-available-bytes>\
        </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>

        """
    }

    private static func fileEntry(href: String, name: String,
                                  size: Int64, modified: Date?) -> String {
        let stamp = modified ?? Date()
        return """
        <D:response><D:href>\(escapeHref(href))</D:href><D:propstat><D:prop>\
        <D:displayname>\(escapeXML(name))</D:displayname>\
        <D:resourcetype/>\
        <D:getcontentlength>\(size)</D:getcontentlength>\
        <D:getcontenttype>\(contentType(for: name))</D:getcontenttype>\
        <D:getlastmodified>\(rfc1123(stamp))</D:getlastmodified>\
        <D:creationdate>\(iso8601(stamp))</D:creationdate>\
        <D:getetag>"\(escapeXML(name))-\(size)"</D:getetag>\
        </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>

        """
    }

    private static func escapeXML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
             .replacingOccurrences(of: "<", with: "&lt;")
             .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeHref(_ path: String) -> String {
        escapeXML(path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)
    }

    private static let rfc1123Formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    private static let iso8601Formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter
    }()

    private static func rfc1123(_ date: Date) -> String { rfc1123Formatter.string(from: date) }
    private static func iso8601(_ date: Date) -> String { iso8601Formatter.string(from: date) }

    static func contentType(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "mp4", "lrv", "360": return "video/mp4"
        case "jpg", "jpeg", "thm": return "image/jpeg"
        case "png": return "image/png"
        case "gpr": return "image/x-adobe-dng"
        case "wav": return "audio/wav"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - One client connection

/// Parses HTTP/1.1 requests from macOS's WebDAV client and answers them.
/// Retains itself for the life of the connection via its receive loop.
private final class Peer {

    private let connection: NWConnection
    private let server: WebDAVServer
    private let queue: DispatchQueue
    private var buffer = Data()

    init(connection: NWConnection, server: WebDAVServer, queue: DispatchQueue) {
        self.connection = connection
        self.server = server
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.teardown()
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    private func teardown() {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                self.buffer.append(data)
                if !self.drain() { return }
            }
            if isComplete || error != nil {
                self.teardown()
                return
            }
            self.receive()   // strong self here is deliberate: it keeps the peer alive
        }
    }

    /// Handle every complete request sitting in the buffer.
    /// Returns false if the connection was closed and the receive loop should stop.
    private func drain() -> Bool {
        while true {
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return true }

            let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
            guard let headerText = String(data: headerData, encoding: .utf8) else {
                teardown(); return false
            }

            var lines = headerText.components(separatedBy: "\r\n")
            guard let requestLine = lines.first, !requestLine.isEmpty else {
                teardown(); return false
            }
            lines.removeFirst()

            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[line.startIndex..<colon].lowercased()
                let value = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }

            // Wait until the whole body has arrived (PROPFIND sends one).
            let bodyLength = Int(headers["content-length"] ?? "") ?? 0
            let available = buffer.distance(from: headerEnd.upperBound, to: buffer.endIndex)
            if available < bodyLength { return true }

            let bodyEnd = buffer.index(headerEnd.upperBound, offsetBy: bodyLength)
            buffer.removeSubrange(buffer.startIndex..<bodyEnd)

            let fields = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
            guard fields.count >= 2 else { teardown(); return false }

            let keepAlive = (headers["connection"]?.lowercased() != "close")
            handle(method: fields[0], target: fields[1], headers: headers, keepAlive: keepAlive)
            if !keepAlive { return false }
        }
    }

    private func handle(method: String, target: String,
                        headers: [String: String], keepAlive: Bool) {
        let rawPath = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        let path = rawPath.removingPercentEncoding ?? rawPath

        switch method {
        case "OPTIONS":
            // Advertising DAV class 1 only (no locking) is what makes macOS
            // mount the volume read-only.
            send(status: 200, reason: "OK", keepAlive: keepAlive, headers: [
                ("DAV", "1"),
                ("MS-Author-Via", "DAV"),
                ("Allow", "OPTIONS, GET, HEAD, PROPFIND"),
            ])

        case "PROPFIND":
            let depth = headers["depth"] ?? "1"
            guard let body = server.propfindBody(for: path, depth: depth) else {
                send(status: 404, reason: "Not Found", keepAlive: keepAlive)
                return
            }
            send(status: 207, reason: "Multi-Status", keepAlive: keepAlive,
                 headers: [("Content-Type", "text/xml; charset=\"utf-8\"")],
                 body: body)

        case "GET", "HEAD":
            switch server.resolve(path) {
            case .marker:
                send(status: 200, reason: "OK", keepAlive: keepAlive,
                     headers: [("Content-Type", "application/octet-stream")],
                     body: Data(), includeBody: method == "GET")
            case .file(let folder, let file):
                // Hand the client straight to the camera; it re-sends its Range header.
                send(status: 302, reason: "Found", keepAlive: keepAlive,
                     headers: [("Location", server.redirectTarget(folder: folder,
                                                                 name: file.name))])
            case .root, .directory:
                send(status: 403, reason: "Forbidden", keepAlive: keepAlive)
            case .missing:
                send(status: 404, reason: "Not Found", keepAlive: keepAlive)
            }

        default:
            // PUT/DELETE/MKCOL/MOVE/COPY/PROPPATCH/LOCK: refuse, stay read-only.
            send(status: 403, reason: "Forbidden", keepAlive: keepAlive)
        }
    }

    private func send(status: Int, reason: String, keepAlive: Bool,
                      headers: [(String, String)] = [], body: Data = Data(),
                      includeBody: Bool = true) {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        for (key, value) in headers { head += "\(key): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"

        var payload = Data(head.utf8)
        if includeBody { payload.append(body) }

        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            if !keepAlive { self?.teardown() }
        })
    }
}
