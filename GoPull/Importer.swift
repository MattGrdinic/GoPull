//
//  Importer.swift
//  GoPull
//
//  Copies clips off the camera using several parallel range requests, which
//  measurably beats a single stream over the USB-Ethernet link.
//

import Combine
import Foundation

struct ImportProgress {
    var fileName: String = ""
    var fileIndex: Int = 0
    var fileCount: Int = 0
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var bytesPerSecond: Double = 0

    var fraction: Double {
        bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : 0
    }
}

enum ImportError: LocalizedError {
    case shortRead(String)
    case badStatus(String, Int)
    case writeFailed(String, Int32)
    case cancelled
    case disconnected

    var errorDescription: String? {
        switch self {
        case .shortRead(let name):     return "\(name): the camera sent fewer bytes than expected."
        case .badStatus(let name, let code): return "\(name): camera returned HTTP \(code)."
        case .writeFailed(let name, let code):
            return "\(name): could not be written to disk (\(String(cString: strerror(code))))."
        case .cancelled:               return "Import cancelled."
        case .disconnected:            return "The camera was disconnected."
        }
    }

    var isDisconnect: Bool {
        if case .disconnected = self { return true }
        return false
    }

    var isCancellation: Bool {
        if case .cancelled = self { return true }
        return false
    }
}

/// URLSession reports a cancelled task as `URLError.cancelled`, *not* as
/// `CancellationError`, so a bare `is CancellationError` check misses it and
/// the retry loop burns its attempts on a task that is already going away.
private nonisolated func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled { return true }
    return false
}

/// 8 MB pieces: small enough to bound memory, big enough to keep the link busy.
private let chunkSize: Int64 = 8 * 1024 * 1024
private let parallelism = 4
private nonisolated let retries = 5

/// Tight timeouts matter here: these requests go to a device on the end of a
/// USB cable that can be pulled at any moment, and URLSession.shared's default
/// resource timeout is seven days.
///
/// `timeoutIntervalForRequest` is the one that guards against a pulled cable:
/// it fires after 15s with no data at all. `timeoutIntervalForResource` caps a
/// whole chunk, and at 60s it was killing chunks that were still making
/// progress -- four streams plus a poll can drag an 8 MB chunk out well past a
/// minute. The inactivity timeout still catches a dead link first, so this can
/// afford to be generous.
///
/// This lives at file scope rather than on `Importer` so the fetch and write
/// paths can stay off the main actor.
private let importSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 15
    config.timeoutIntervalForResource = 300
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.httpMaximumConnectionsPerHost = 8
    return URLSession(configuration: config)
}()

/// Tracks bytes transferred so the UI can show a rate without hammering @Published.
private actor ByteCounter {
    private(set) var total: Int64 = 0
    func add(_ count: Int64) -> Int64 { total += count; return total }
}

@MainActor
final class Importer: ObservableObject {

    @Published private(set) var progress = ImportProgress()
    @Published private(set) var isRunning = false

    /// Returns the files that failed, if any.
    func run(camera: GoProCamera,
             targets: [(file: MediaFile, url: URL)]) async -> [(MediaFile, Error)] {

        guard !targets.isEmpty else { return [] }
        let files = targets.map(\.file)

        isRunning = true
        defer { isRunning = false }

        progress = ImportProgress(fileCount: files.count,
                                  bytesTotal: files.reduce(0) { $0 + $1.size })

        var failures: [(MediaFile, Error)] = []
        var completedBytes: Int64 = 0
        let started = Date()

        for (index, file) in files.enumerated() {
            if Task.isCancelled { break }
            progress.fileName = file.name
            progress.fileIndex = index + 1

            do {
                let target = targets[index].url
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true)

                let base = completedBytes
                try await download(camera: camera, file: file, to: target) { [weak self] done in
                    guard let self else { return }
                    let elapsed = max(Date().timeIntervalSince(started), 0.001)
                    self.progress.bytesDone = base + done
                    self.progress.bytesPerSecond = Double(base + done) / elapsed
                }
                completedBytes += file.size
                progress.bytesDone = completedBytes
            } catch {
                // `keepAlive` would be asked on a cancelled task, where every
                // await throws instantly -- which reads as a disconnect and is
                // how a plain Cancel used to be reported as an unplugged camera.
                if Task.isCancelled || isCancellation(error) {
                    failures.append((file, ImportError.cancelled))
                    break
                }
                let stillThere = await camera.keepAlive()
                failures.append((file, stillThere ? error : ImportError.disconnected))
                completedBytes += file.size
                progress.bytesDone = completedBytes
                if !stillThere { break }
            }
        }

        return failures
    }

    static func destinationURL(for file: MediaFile, in root: URL,
                               organiseByDate: Bool,
                               cameraFolder: String?) -> URL {
        var url = root
        if let cameraFolder, !cameraFolder.isEmpty {
            url.appendPathComponent(cameraFolder)
        }
        if organiseByDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            url.appendPathComponent(file.modified.map(formatter.string(from:)) ?? "undated")
        }
        return url.appendingPathComponent(file.name)
    }

    // MARK: - One file

    private func download(camera: GoProCamera,
                          file: MediaFile,
                          to target: URL,
                          onProgress: @escaping @MainActor (Int64) -> Void) async throws {

        let partial = target.appendingPathExtension("part")
        let path = partial.path

        FileManager.default.createFile(atPath: path, contents: nil)
        let descriptor = open(path, O_WRONLY)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        ftruncate(descriptor, off_t(file.size))

        let url = camera.downloadURL(folder: file.folder, name: file.name)
        let counter = ByteCounter()

        var ranges: [(Int64, Int64)] = []
        var offset: Int64 = 0
        while offset < file.size {
            let end = min(offset + chunkSize, file.size) - 1
            ranges.append((offset, end))
            offset = end + 1
        }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                var next = 0
                let inFlight = min(parallelism, ranges.count)

                func schedule(_ index: Int) {
                    let (start, end) = ranges[index]
                    group.addTask {
                        let data = try await Self.fetch(url: url, name: file.name,
                                                        start: start, end: end)
                        try Self.writeFully(descriptor, data, at: start, name: file.name)
                        let done = await counter.add(Int64(data.count))
                        await onProgress(done)
                    }
                }

                for _ in 0..<inFlight { schedule(next); next += 1 }
                while try await group.next() != nil {
                    if Task.isCancelled { group.cancelAll(); throw ImportError.cancelled }
                    if next < ranges.count { schedule(next); next += 1 }
                }
            }
        } catch {
            close(descriptor)
            try? FileManager.default.removeItem(at: partial)
            throw error
        }

        close(descriptor)

        // Against `ftruncate`'s preallocated length this check was vacuous;
        // the bytes the chunks actually delivered are what matters.
        let received = await counter.total
        guard received == file.size else {
            try? FileManager.default.removeItem(at: partial)
            throw ImportError.shortRead(file.name)
        }

        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.moveItem(at: partial, to: target)

        if let modified = file.modified {
            try? FileManager.default.setAttributes([.modificationDate: modified],
                                                   ofItemAtPath: target.path)
        }
    }

    /// `pwrite` may legitimately write less than asked, and returns -1 on a
    /// full disk. Both were being discarded.
    private nonisolated static func writeFully(_ descriptor: Int32, _ data: Data,
                                               at offset: Int64, name: String) throws {
        try data.withUnsafeBytes { raw in
            guard var base = raw.baseAddress else { return }
            var remaining = raw.count
            var position = off_t(offset)
            while remaining > 0 {
                let written = pwrite(descriptor, base, remaining, position)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw ImportError.writeFailed(name, errno)
                }
                if written == 0 { throw ImportError.writeFailed(name, ENOSPC) }
                remaining -= written
                position += off_t(written)
                base = base.advanced(by: written)
            }
        }
    }

    private nonisolated static func fetch(url: URL, name: String,
                                          start: Int64, end: Int64) async throws -> Data {
        var lastError: Error = ImportError.shortRead(name)

        for attempt in 0..<retries {
            if Task.isCancelled { throw CancellationError() }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
                request.cachePolicy = .reloadIgnoringLocalCacheData

                let (data, response) = try await importSession.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200 || code == 206 else {
                    throw ImportError.badStatus(name, code)
                }
                guard data.count == Int(end - start + 1) else {
                    throw ImportError.shortRead(name)
                }
                return data
            } catch {
                if isCancellation(error) || Task.isCancelled { throw CancellationError() }
                lastError = error
                // A camera serving four streams can stall for seconds at a
                // time; linear 200ms steps gave up while it was still there.
                let backoff = min(4.0, 0.3 * pow(3.0, Double(attempt)))
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            }
        }
        throw lastError
    }
}
