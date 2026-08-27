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
    /// Owned here, not by the editor, so a burn-in keeps running and keeps
    /// reporting when the editor sheet is closed. Closing that sheet used to
    /// leave an export running with nothing anywhere saying so.
    let overlayExporter = OverlayExporter()
    let previews = PreviewStore()
    let mountPoint = MountController.defaultMountPoint

    private let server = WebDAVServer()
    private var poller: Task<Void, Never>?
    private var camera: GoProCamera?
    private var missedPolls = 0
    private var isEjecting = false
    private var importTask: Task<Void, Never>?
    private var overlayExportTask: Task<Void, Never>?
    @Published private(set) var overlayExportResult: URL?
    @Published var overlayExportError: String?

    // MARK: - Browsing

    @Published var filter: MediaFilter = .all {
        didSet { UserDefaults.standard.set(filter.rawValue, forKey: "browseFilter") }
    }
    @Published var sort: MediaSort = .newest {
        didSet { UserDefaults.standard.set(sort.rawValue, forKey: "browseSort") }
    }
    @Published var groupsByDate: Bool {
        didSet { UserDefaults.standard.set(groupsByDate, forKey: "groupsByDate") }
    }
    /// Thumbnail height in points.
    @Published var thumbnailSize: Double {
        didSet { UserDefaults.standard.set(thumbnailSize, forKey: "thumbnailSize") }
    }
    @Published var search: String = ""
    /// Shots whose raw file the user does not want copied.
    @Published private(set) var rawExcluded: Set<String> = []

    /// Convert each imported .GPR into a .DNG.
    @Published var convertGPRToDNG: Bool {
        didSet { UserDefaults.standard.set(convertGPRToDNG, forKey: "convertGPRToDNG") }
    }
    /// Delete the .GPR once a .DNG has been written from it.
    @Published var replaceGPRWithDNG: Bool {
        didSet { UserDefaults.standard.set(replaceGPRWithDNG, forKey: "replaceGPRWithDNG") }
    }
    @Published private(set) var convertingGPR: String?
    @Published private(set) var gprConverted = 0
    @Published var gprError: String?

    /// Run the saved overlay preset over each clip as it finishes importing.
    @Published var overlaysAfterImport: Bool {
        didSet { UserDefaults.standard.set(overlaysAfterImport, forKey: "overlaysAfterImport") }
    }
    /// Clips the user has turned overlays off for.
    ///
    /// Stored as the exceptions rather than the inclusions so a clip that has
    /// never been considered is included by default -- the common case is a
    /// card of one kind of footage, and the point of this is picking the few
    /// that do not want a speedometer on them.
    @Published private(set) var overlaysExcluded: Set<String> = []
    @Published private(set) var overlayQueue: [MediaFile] = []
    @Published private(set) var overlayQueueDone = 0
    @Published private(set) var overlaySkipped: [String] = []

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
        overlaysAfterImport = defaults.object(forKey: "overlaysAfterImport") as? Bool ?? false
        groupsByDate = defaults.object(forKey: "groupsByDate") as? Bool ?? true
        thumbnailSize = defaults.object(forKey: "thumbnailSize") as? Double ?? 36
        convertGPRToDNG = defaults.object(forKey: "convertGPRToDNG") as? Bool ?? false
        replaceGPRWithDNG = defaults.object(forKey: "replaceGPRWithDNG") as? Bool ?? false
        organiseByDate = defaults.object(forKey: "organiseByDate") as? Bool ?? true
        separateByCamera = defaults.object(forKey: "separateByCamera") as? Bool ?? false
        includeSidecars = defaults.object(forKey: "includeSidecars") as? Bool ?? false
        isMounted = MountController.isMounted(at: mountPoint)

        if let raw = defaults.string(forKey: "browseFilter"),
           let value = MediaFilter(rawValue: raw) { filter = value }
        if let raw = defaults.string(forKey: "browseSort"),
           let value = MediaSort(rawValue: raw) { sort = value }
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

    // MARK: - GPR

    var hasGPRFiles: Bool { visibleFiles.contains { GPRConverter.isGPR(URL(fileURLWithPath: $0.name)) } }

    /// Converts the GPRs among these clips, one at a time.
    ///
    /// A GPR is a DNG whose tile is VC-5 compressed, which nothing on macOS can
    /// decode -- ImageIO reads the metadata and then produces no pixels at all.
    /// The conversion is what makes the file openable anywhere else.
    func convertGPRs(_ files: [MediaFile]) async {
        let gprs = files.compactMap { file -> URL? in
            guard GPRConverter.isGPR(URL(fileURLWithPath: file.name)) else { return nil }
            let url = destinationURL(for: file)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        guard !gprs.isEmpty else { return }

        for gpr in gprs {
            convertingGPR = gpr.lastPathComponent
            let replace = replaceGPRWithDNG
            let result = await Task.detached(priority: .utility) { () -> Result<URL, Error> in
                do { return .success(try GPRConverter.convert(gpr)) }
                catch { return .failure(error) }
            }.value
            switch result {
            case .success:
                gprConverted += 1
                // Only after the DNG is safely written, and only if asked.
                if replace { try? FileManager.default.removeItem(at: gpr) }
            case .failure(let error):
                gprError = "\(gpr.lastPathComponent): \(error.localizedDescription)"
            }
        }
        convertingGPR = nil
    }

    // MARK: - Overlay export

    var isExportingOverlay: Bool { overlayExportTask != nil }

    /// Whether a clip is a candidate for an overlay at all.
    ///
    /// Stills and proxies have nothing to put one on; whether a clip actually
    /// carries GPS is only knowable once it is on disk, so that is checked when
    /// its turn comes rather than here.
    func canOverlay(_ file: MediaFile) -> Bool {
        !file.isSidecar && MediaPreview.isVideo(file)
    }

    func overlaysEnabled(for file: MediaFile) -> Bool {
        canOverlay(file) && !overlaysExcluded.contains(file.id)
    }

    func setOverlaysEnabled(_ enabled: Bool, for file: MediaFile) {
        if enabled { overlaysExcluded.remove(file.id) }
        else { overlaysExcluded.insert(file.id) }
    }

    /// Turn overlays on or off for everything currently listed.
    func setOverlaysEnabledForAll(_ enabled: Bool) {
        for file in visibleFiles where canOverlay(file) {
            setOverlaysEnabled(enabled, for: file)
        }
    }

    var overlayEligibleCount: Int { visibleFiles.filter { overlaysEnabled(for: $0) }.count }

    /// What the saved preset would produce, so the checkbox is not a leap of
    /// faith about settings last touched days ago.
    var overlayPresetSummary: String { OverlaySettings.load().summary }

    // MARK: - Batch

    var isRunningOverlayQueue: Bool { !overlayQueue.isEmpty }

    /// Queues the saved preset against each clip that is on disk and not opted
    /// out of.
    func queueOverlays(for files: [MediaFile]) {
        let wanted = files.filter { overlaysEnabled(for: $0) && importedURL(for: $0) != nil }
        guard !wanted.isEmpty else { return }
        overlaySkipped = []
        overlayQueueDone = 0
        overlayQueue = wanted
        runNextOverlay()
    }

    func cancelOverlayQueue() {
        overlayQueue = []
        cancelOverlayExport()
    }

    private func runNextOverlay() {
        guard !overlayQueue.isEmpty else { return }
        guard overlayExportTask == nil else { return }
        let file = overlayQueue[0]
        guard let clip = importedURL(for: file) else {
            overlayQueue.removeFirst()
            runNextOverlay()
            return
        }

        let settings = OverlaySettings.load()
        Task { [weak self] in
            guard let self else { return }
            // Telemetry is only knowable from the file, so a clip with no fixes
            // is skipped here rather than failing the whole run.
            let raw = try? TelemetryReader.read(clip)
            guard let raw, raw.hasFix else {
                self.overlaySkipped.append(file.name)
                self.overlayQueue.removeFirst()
                self.overlayQueueDone += 1
                self.runNextOverlay()
                return
            }
            let track = raw.smoothed(settings.gauge.smoothing)
            let gforce = ((try? GForceReader.read(clip)) ?? GForceTrack())
                .smoothed(settings.gforce.smoothing)
            let destination = Self.overlayDestination(for: clip, settings: settings)
            let runs = AccelerationDetector.runs(in: track, gforce: gforce,
                                                 settings: settings.acceleration.detection)
            self.startOverlayExport(clip: clip, to: destination, track: track,
                                    settings: settings, options: settings.export,
                                    gforce: gforce, runs: runs)
            await self.overlayExportTask?.value
            if !self.overlayQueue.isEmpty { self.overlayQueue.removeFirst() }
            self.overlayQueueDone += 1
            self.runNextOverlay()
        }
    }

    /// Where a batch overlay is written. Matches what the editor does.
    static func overlayDestination(for clip: URL, settings: OverlaySettings) -> URL {
        if settings.export.content == .burnedIn,
           settings.export.destination == .replaceOriginal {
            return clip
        }
        let base = clip.deletingPathExtension().lastPathComponent
        let suffix = settings.export.content == .overlayOnly ? "overlay-alpha" : "overlay"
        return clip.deletingLastPathComponent()
            .appendingPathComponent("\(base) — \(suffix).\(settings.export.fileExtension)")
    }

    func startOverlayExport(clip: URL, to destination: URL, track: TelemetryTrack,
                            settings: OverlaySettings, options: ExportOptions,
                            gforce: GForceTrack = GForceTrack(),
                            runs: [AccelerationRun] = []) {
        guard overlayExportTask == nil else { return }
        overlayExportError = nil
        overlayExportResult = nil
        overlayExportTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.overlayExporter.export(clip: clip, to: destination,
                                                      track: track, settings: settings,
                                                      options: options, gforce: gforce,
                                                      runs: runs)
                self.overlayExportResult = destination
            } catch is CancellationError {
                // Cancelling is not a failure worth an alert.
            } catch let error as ExportError where error.isCancellation {
            } catch {
                self.overlayExportError = error.localizedDescription
            }
            self.overlayExportTask = nil
        }
    }

    func cancelOverlayExport() {
        overlayExporter.cancel()
        overlayExportTask?.cancel()
    }

    func revealOverlayExport() {
        guard let url = overlayExportResult else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
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

    // MARK: - Rows

    /// The card as shots rather than files, filtered, searched and sorted.
    var rows: [MediaRow] {
        let all = MediaBrowser.rows(from: visibleFiles).filter { filter.matches($0) }
        return MediaBrowser.sorted(MediaBrowser.matching(all, search: search), by: sort)
    }

    var sections: [MediaSection] {
        groupsByDate ? MediaBrowser.sections(rows) : [MediaSection(id: "all", title: "", rows: rows)]
    }

    /// Whether this shot's raw file gets copied. On unless switched off.
    func includesRaw(_ row: MediaRow) -> Bool {
        row.hasRaw && !rawExcluded.contains(row.id)
    }

    func setIncludesRaw(_ include: Bool, for row: MediaRow) {
        if include { rawExcluded.remove(row.id) } else { rawExcluded.insert(row.id) }
    }

    /// The files a row would import, honouring its raw toggle.
    func files(for row: MediaRow) -> [MediaFile] {
        row.files(includingRaw: includesRaw(row))
    }

    func rows(withIDs ids: Set<String>) -> [MediaRow] {
        rows.filter { ids.contains($0.id) }
    }

    /// A row counts as imported only when everything it would copy is there.
    func alreadyImported(_ row: MediaRow) -> Bool {
        files(for: row).allSatisfy { alreadyImported($0) }
    }

    var newRows: [MediaRow] { rows.filter { !alreadyImported($0) } }

    /// A section's size, honouring each row's raw toggle.
    ///
    /// `MediaSection.totalBytes` counts the raw every time because it knows
    /// nothing about the toggles; using it in the header made a date say 254.6
    /// MB while the strip above said 249.5 MB.
    func bytes(of section: MediaSection) -> Int64 {
        section.rows.reduce(0) { $0 + $1.size(includingRaw: includesRaw($1)) }
    }

    /// What Import Selected would copy, for the footer.
    func selectionSummary(_ ids: Set<String>) -> (count: Int, bytes: Int64) {
        let chosen = rows(withIDs: ids)
        return (chosen.count, chosen.reduce(0) { $0 + $1.size(includingRaw: includesRaw($1)) })
    }

    func importRows(_ chosen: [MediaRow]) {
        startImport(chosen.flatMap { files(for: $0) })
    }

    /// Opens the folder the next import would land in, making it whether or not
    /// anything has been copied there yet.
    func revealImportDestination() {
        let target = files.first.map { destinationURL(for: $0).deletingLastPathComponent() }
            ?? destination
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    var newFiles: [MediaFile] { visibleFiles.filter { !alreadyImported($0) } }

    func selectNew() {
        selection = Set(newFiles.map(\.id))
    }

    func importSelected() {
        importRows(rows(withIDs: selection))
    }

    func importNew() {
        importRows(newRows)
    }

    func cancelImport() {
        importTask?.cancel()
    }

    /// Held so the Cancel button and a disconnect can actually stop the work --
    /// awaiting `run` directly left nothing to cancel.
    func startImport(_ chosen: [MediaFile]) {
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

        let done = chosen.filter { file in !failures.contains { $0.0.id == file.id } }

        if convertGPRToDNG, !Task.isCancelled {
            await convertGPRs(done)
        }

        // Overlays run after the copy, not during it: both want the disk and
        // the CPU, and an import that is already the long pole should not be
        // made longer.
        if overlaysAfterImport, !Task.isCancelled {
            queueOverlays(for: done)
        }
    }
}

extension Int64 {
    var byteLabel: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
