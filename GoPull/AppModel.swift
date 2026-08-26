//
//  AppModel.swift
//  GoPull
//
//  Ties together camera discovery, the WebDAV bridge, the mount and imports.
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {

    @Published private(set) var info: CameraInfo?
    @Published private(set) var cameraIP: String = ""
    @Published private(set) var files: [MediaFile] = []
    @Published private(set) var freeBytes: Int64 = 0
    @Published private(set) var isMounted = false
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?
    @Published var selection: Set<String> = []
    @Published var organiseByDate: Bool {
        didSet { UserDefaults.standard.set(organiseByDate, forKey: "organiseByDate") }
    }
    /// Put each camera's clips in their own folder, so several cameras can share
    /// one destination without their clips interleaving.
    @Published var separateByCamera: Bool {
        didSet { UserDefaults.standard.set(separateByCamera, forKey: "separateByCamera") }
    }
    /// Proxies and thumbnails (.LRV/.LRF/.THM) are always on the mount, but are
    /// hidden from the import list unless asked for.
    @Published var includeSidecars: Bool {
        didSet { UserDefaults.standard.set(includeSidecars, forKey: "includeSidecars") }
    }
    /// Distinguishes two bodies of the same model. Stored per serial number.
    @Published private(set) var cameraNumber: Int = 1
    /// Set when the camera vanishes, so the UI can explain itself without an alert.
    @Published private(set) var statusNote: String?
    @Published var destination: URL {
        didSet { UserDefaults.standard.set(destination.path, forKey: "destination") }
    }

    static let shared = AppModel()

    let importer = Importer()
    let previews = PreviewStore()
    let mountPoint = MountController.defaultMountPoint

    private let server = WebDAVServer()
    private var poller: Task<Void, Never>?
    private var camera: GoProCamera?
    private var missedPolls = 0
    private var isEjecting = false
    private var importTask: Task<Void, Never>?

    var isConnected: Bool { info != nil }

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    init() {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "destination") {
            destination = URL(fileURLWithPath: saved)
        } else {
            destination = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Movies/GoPro")
        }
        organiseByDate = defaults.object(forKey: "organiseByDate") as? Bool ?? true
        separateByCamera = defaults.object(forKey: "separateByCamera") as? Bool ?? false
        includeSidecars = defaults.object(forKey: "includeSidecars") as? Bool ?? false
        isMounted = MountController.isMounted(at: mountPoint)
    }

    // MARK: - Camera identity

    private static let cameraNumbersKey = "cameraNumbers"

    private var cameraNumbers: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: Self.cameraNumbersKey) as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.cameraNumbersKey) }
    }

    func setCameraNumber(_ number: Int) {
        let clamped = max(1, min(99, number))
        cameraNumber = clamped
        guard let serial = info?.serial, !serial.isEmpty else { return }
        var all = cameraNumbers
        all[serial] = clamped
        cameraNumbers = all
    }

    /// Folder name for a given clip's device, or nil when the option is off.
    ///
    /// The number only applies to the camera that's actually attached -- it
    /// exists to tell two identical bodies apart, and means nothing for a card
    /// that was written by a drone. Number 1 is left off so one camera reads
    /// cleanly and adding a second body never renames the first one's folder.
    func deviceFolder(for file: MediaFile) -> String? {
        guard separateByCamera else { return nil }
        let base = file.device.folderName
        guard file.device.isAttachedCamera, cameraNumber > 1 else { return base }
        return "\(base) \(cameraNumber)"
    }

    /// Devices represented on the card right now, for display.
    var devicesOnCard: [DeviceIdentity] {
        var seen: [DeviceIdentity] = []
        for file in files where !seen.contains(file.device) { seen.append(file.device) }
        return seen
    }

    /// Where the next import would land, for display under the destination.
    var examplePath: String {
        var url = destination
        if separateByCamera {
            let sample = files.first.map { deviceFolder(for: $0) ?? "" }
                ?? (info.map { cameraNumber > 1 ? "\($0.model) \(cameraNumber)" : $0.model } ?? "")
            if !sample.isEmpty { url.appendPathComponent(sample) }
        }
        if organiseByDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            url.appendPathComponent(formatter.string(from: Date()))
        }
        return url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    // MARK: - Polling

    func startPolling() {
        guard poller == nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func stopPolling() {
        poller?.cancel()
        poller = nil
    }

    /// `statfs` and `umount` can block on a WebDAV volume whose server has gone,
    /// so they are always run off the main actor.
    private static func mountedOffMain(_ point: URL) async -> Bool {
        await Task.detached { MountController.isMounted(at: point) }.value
    }

    func refresh() async {
        // Called from a cancelled task (e.g. an import the user just cancelled)
        // every await fails, which must not be mistaken for a missing camera.
        guard !Task.isCancelled else { return }
        isMounted = await Self.mountedOffMain(mountPoint)

        // Nothing may touch the camera's control API while an import is
        // running. Measured on a MISSION 1 PRO: with the importer's four range
        // streams in flight, /gopro/media/list, /videos/DCIM/ and even
        // /gopro/camera/keep_alive all take the full 15s timeout and fail. That
        // made three consecutive polls "miss", which cancelled the import and
        // reported it as an unplugged camera -- so any clip long enough to span
        // ~50s of transfer could never finish, while short ones always did.
        //
        // The import is its own liveness check: if the camera really goes away
        // its chunk requests fail, and `Importer` reports that directly.
        if importer.isRunning { return }

        if camera == nil {
            camera = try? await GoProCamera.discover()
        }
        guard let camera else {
            if info != nil {
                info = nil
                files = []
                cameraIP = ""
                freeBytes = 0
            }
            await handleMissedPoll()
            return
        }

        do {
            let tree = try await camera.cardTree()
            let free = await camera.freeBytes()
            await camera.keepAlive()

            missedPolls = 0
            statusNote = nil
            if camera.info.serial != info?.serial {
                cameraNumber = cameraNumbers[camera.info.serial] ?? 1
            }
            info = camera.info
            cameraIP = camera.ip
            files = tree.keys.sorted().flatMap { tree[$0] ?? [] }
            freeBytes = free
            previews.update(cameraIP: camera.ip)
            selection = selection.filter { id in files.contains { $0.id == id } }

            server.update(CardSnapshot(cameraIP: camera.ip,
                                       tree: tree,
                                       usedBytes: files.reduce(0) { $0 + $1.size },
                                       freeBytes: free))
        } catch is CancellationError {
            return                       // not a disconnect; leave state alone
        } catch {
            // Two very different situations look the same here, so tell them
            // apart: a camera that has gone, versus a camera that is present
            // but has no readable card in it.
            if await camera.keepAlive() {
                // The camera answered, so it is present. Only a clean refusal
                // from the card endpoints means there is no card -- a timeout
                // or a dropped connection just means the link was busy, and
                // throwing away the file list over one of those made the whole
                // window flicker between "no card" and normal.
                guard error is CameraError else { return }
                info = camera.info
                cameraIP = camera.ip
                files = []
                freeBytes = 0
                statusNote = "No SD card detected in the camera."
            } else {
                self.camera = nil
                info = nil
                files = []
                cameraIP = ""
            }
            // Either way a mounted volume is now useless, so let it be ejected.
            await handleMissedPoll()
        }
    }

    /// A mounted volume whose camera has gone is worse than no volume at all --
    /// Finder blocks on it. Tear it down, but only once the camera has really
    /// gone rather than on a single dropped poll.
    private func handleMissedPoll() async {
        missedPolls += 1
        guard missedPolls >= 3 else { return }

        // An import against a camera that has gone is just going to time out.
        cancelImport()

        guard isMounted, !isEjecting else { return }
        isEjecting = true
        statusNote = "The camera disconnected -- ejecting the volume…"
        let point = mountPoint
        await Task.detached { try? MountController.unmount(at: point) }.value

        isMounted = await Self.mountedOffMain(point)
        if !isMounted { server.stop() }
        statusNote = isMounted
            ? "The camera disconnected, but the volume could not be ejected — it may still be in use."
            : "The camera disconnected, so the volume was ejected."
        isEjecting = false
    }

    // MARK: - Mounting

    func mount() async {
        guard let camera, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let port = try await server.start()
            let tree = (try? await camera.mediaList()) ?? [:]
            let free = await camera.freeBytes()
            server.update(CardSnapshot(cameraIP: camera.ip,
                                       tree: tree,
                                       usedBytes: tree.values.flatMap { $0 }.reduce(0) { $0 + $1.size },
                                       freeBytes: free))

            let point = mountPoint
            try await Task.detached(priority: .userInitiated) {
                try MountController.mount(port: port, at: point)
            }.value
            isMounted = await Self.mountedOffMain(point)
            missedPolls = 0
            statusNote = nil
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unmount() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        let point = mountPoint
        do {
            try await Task.detached(priority: .userInitiated) {
                try MountController.unmount(at: point)
            }.value
            isMounted = await Self.mountedOffMain(point)
            if !isMounted { server.stop() }
            errorMessage = nil
            statusNote = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Called on quit -- the mount depends on this process, so leaving it behind
    /// would strand a dead volume in Finder.
    func unmountForShutdown() {
        if MountController.isMounted(at: mountPoint) {
            try? MountController.unmount(at: mountPoint)
        }
        server.stop()
    }

    func revealMount() {
        NSWorkspace.shared.open(mountPoint)
    }

    func revealDestination() {
        try? FileManager.default.createDirectory(at: destination,
                                                 withIntermediateDirectories: true)
        NSWorkspace.shared.open(destination)
    }

    // MARK: - Importing

    func destinationURL(for file: MediaFile) -> URL {
        Importer.destinationURL(for: file, in: destination,
                                organiseByDate: organiseByDate,
                                cameraFolder: deviceFolder(for: file))
    }

    /// What a preview would show for this clip: the low-resolution proxy when
    /// the card has one, otherwise the clip itself.
    func previewSource(for file: MediaFile) -> PreviewSource? {
        MediaPreview.source(for: file, among: files, cameraIP: cameraIP)
    }

    /// The imported copy of a clip, when there is one.
    ///
    /// Overlays are edited against the pulled-down file rather than the camera:
    /// the telemetry and the video have to come from the same place, and the
    /// camera cannot be scrubbed frame by frame over USB.
    func importedURL(for file: MediaFile) -> URL? {
        let url = destinationURL(for: file)
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int64, size == file.size
        else { return nil }
        return url
    }

    /// True when this clip is already sitting in the destination at full size.
    func alreadyImported(_ file: MediaFile) -> Bool {
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: destinationURL(for: file).path)[.size] as? Int64
        else { return false }
        return size == file.size
    }

    /// What the import list shows: sidecars are hidden unless asked for.
    var visibleFiles: [MediaFile] {
        includeSidecars ? files : files.filter { !$0.isSidecar }
    }

    var newFiles: [MediaFile] { visibleFiles.filter { !alreadyImported($0) } }

    func selectNew() {
        selection = Set(newFiles.map(\.id))
    }

    func importSelected() {
        startImport(visibleFiles.filter { selection.contains($0.id) })
    }

    func importNew() {
        startImport(newFiles)
    }

    func cancelImport() {
        importTask?.cancel()
    }

    /// Held so the Cancel button and a disconnect can actually stop the work --
    /// awaiting `run` directly left nothing to cancel.
    private func startImport(_ chosen: [MediaFile]) {
        guard importTask == nil else { return }
        // Sweep before the empty check: "nothing new to import" is exactly the
        // state a leftover .part leaves behind, so it must still be cleaned.
        removeOrphanedParts()
        guard !chosen.isEmpty else { return }
        // Thumbnail requests go to the same control API that stops answering
        // under an import's range streams, so they stand down too.
        previews.suspend()
        importTask = Task { [weak self] in
            await self?.importFiles(chosen)
            self?.previews.resume()
            self?.importTask = nil
        }
    }

    /// A `.part` left by an import that died before it could clean up -- for
    /// instance if the app was quit while the camera was being unplugged.
    ///
    /// This scans the destination rather than matching against the clips
    /// currently on the camera: the card may since have been formatted or
    /// swapped, and those orphans still need clearing. Only names that could
    /// have come from us are touched.
    private func removeOrphanedParts() {
        let mediaExtensions: Set<String> = ["mp4", "lrv", "360", "jpg", "jpeg",
                                            "gpr", "png", "wav", "thm"]
        guard let walker = FileManager.default.enumerator(
            at: destination,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return }

        for case let url as URL in walker where url.pathExtension == "part" {
            let base = url.deletingPathExtension()
            guard mediaExtensions.contains(base.pathExtension.lowercased()) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func importFiles(_ chosen: [MediaFile]) async {
        guard let camera, !chosen.isEmpty else { return }
        let targets = chosen.map { (file: $0, url: destinationURL(for: $0)) }
        let failures = await importer.run(camera: camera, targets: targets)
        if failures.isEmpty {
            errorMessage = nil
            selection.removeAll()
        } else if failures.allSatisfy({ ($0.1 as? ImportError)?.isCancellation == true }) {
            // Either the user pressed Cancel or a real disconnect cancelled us,
            // and that path posts its own note. Neither warrants an alert.
            errorMessage = nil
        } else if failures.contains(where: { ($0.1 as? ImportError)?.isDisconnect == true }) {
            errorMessage = "The camera was disconnected — the import stopped after "
                         + "\(chosen.count - failures.count) of \(chosen.count) clip(s). "
                         + "Nothing partial was left behind."
        } else {
            let names = failures.map(\.0.name).joined(separator: ", ")
            errorMessage = "\(failures.count) file(s) failed: \(names)"
        }
        if !Task.isCancelled { await refresh() }
    }
}

extension Int64 {
    var byteLabel: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
