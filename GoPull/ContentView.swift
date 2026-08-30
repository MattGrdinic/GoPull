//
//  ContentView.swift
//  GoPull
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var choosingDestination = false
    @State private var previewing: MediaFile?
    @State private var editingOverlays: MediaFile?
    /// Set when Overlays is asked for on a clip that is not on disk yet.
    @State private var overlayNeedsImport: MediaFile?
    /// Selection is owned by SwiftUI here, not read straight off the model.
    ///
    /// `List(selection:)` writes the new value back *while it is updating the
    /// rows*. Pointed at a `@Published` property that means `objectWillChange`
    /// fires mid-update -- "Publishing changes from within view updates is not
    /// allowed, this will cause undefined behavior", 14 times per click on a
    /// 12-row list. SwiftUI then re-runs the update, which is what made
    /// clicking a second row feel slow or fail to highlight at all.
    ///
    /// The model is still the source of truth for everything else; the two are
    /// mirrored below, in `onChange`, which runs *after* the update completes.
    @State private var selection: Set<String> = []

    /// Which deletion prompt is up, mirrored from the model.
    ///
    /// SwiftUI calls a presentation binding's setter *while it is updating*, so
    /// a setter that writes `@Published` state fires `objectWillChange` inside
    /// the update pass -- "Publishing changes from within view updates is not
    /// allowed". Same mechanism as the selection binding in DECISIONS #26, and
    /// the same fix: the binding only ever touches `@State`, and the model is
    /// brought into line from `onChange`, which runs after the update.
    ///
    /// It was loudest here because clearing `pendingDeletion` dismisses the
    /// alert *and* the sheet, so both setters ran, and `cancelDeletion()`
    /// writes two published properties each time.
    private enum DeletePrompt: Equatable { case none, alert, sheet }
    @State private var deletePrompt: DeletePrompt = .none
    @State private var showsError = false

    private var modelDeletePrompt: DeletePrompt {
        guard model.pendingDeletion != nil else { return .none }
        return model.deletionFollowsImport ? .alert : .sheet
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if model.isConnected {
                if model.visibleFiles.isEmpty {
                    emptyCard
                } else {
                    controlStrip
                    Divider()
                    fileList
                }
                Divider()
                footer
            } else {
                disconnected
            }
        }
        .frame(minWidth: 620, minHeight: 460)
        .alert("Something went wrong", isPresented: $showsError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onChange(of: model.errorMessage == nil) { _, cleared in
            showsError = !cleared
        }
        .onChange(of: showsError) { _, showing in
            if !showing, model.errorMessage != nil { model.errorMessage = nil }
        }
        .onChange(of: modelDeletePrompt) { _, prompt in
            deletePrompt = prompt
        }
        .onChange(of: deletePrompt) { _, prompt in
            // Dismissed by Escape or a click outside, rather than by a button.
            if prompt == .none, model.pendingDeletion != nil { model.cancelDeletion() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: model.isConnected ? "camera.fill" : "camera")
                .font(.system(size: 26))
                .foregroundStyle(model.isConnected ? Color.accentColor : .secondary)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.info?.model ?? "No camera connected")
                    .font(.headline)
                if model.isConnected {
                    // Counts live in the control strip, which knows about
                    // filtering; two different totals on one screen only ever
                    // disagreed.
                    Text("\(model.cameraIP) · \(model.totalBytes.byteLabel) used · \(model.freeBytes.byteLabel) free"
                         + (model.devicesOnCard.count > 1
                            ? " · " + model.devicesOnCard.map(\.brand).joined(separator: ", ")
                            : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Connect by USB and switch the camera on")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if model.isConnected {
                mountControls
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var mountControls: some View {
        HStack(spacing: 8) {
            if model.isMounted {
                Button("Open in Finder") { model.revealMount() }
                Button("Eject") { Task { await model.unmount() } }
                    .disabled(model.isBusy)
            } else {
                Button {
                    Task { await model.mount() }
                } label: {
                    Label("Mount as Drive", systemImage: "externaldrive.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy)
            }
        }
    }

    // MARK: - Empty state

    private var disconnected: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "cable.connector")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Looking for a GoPro…")
                .font(.title3)
            Text("The camera must be powered on and set to GoPro Connect mode rather than MTP. If it is, try unplugging and replugging the USB cable.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if let note = model.statusNote {
                Label(note, systemImage: "eject.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .padding(.top, 4)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyCard: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: model.statusNote == nil ? "film.stack" : "sdcard")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(model.statusNote ?? "No clips on the card.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Files

    /// Filter, search, sort and size, above the list rather than crowded into
    /// the footer with the import options.
    private var controlStrip: some View {
        HStack(spacing: 12) {
            Picker("", selection: $model.filter) {
                ForEach(MediaFilter.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary).font(.caption)
                TextField("Search", text: $model.search)
                    .textFieldStyle(.plain)
                    .font(.callout)
                if !model.search.isEmpty {
                    Button {
                        model.search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: 220)

            Spacer()

            Text(countLabel)
                .font(.caption).foregroundStyle(.secondary)
                .monospacedDigit()

            Menu {
                Picker("Sort", selection: $model.sort) {
                    ForEach(MediaSort.allCases) { Text($0.label).tag($0) }
                }
                Divider()
                Toggle("Group by date", isOn: $model.groupsByDate)
                Divider()
                Picker("Preview size", selection: $model.thumbnailSize) {
                    Text("Small").tag(28.0)
                    Text("Medium").tag(36.0)
                    Text("Large").tag(56.0)
                    Text("Huge").tag(84.0)
                }
            } label: {
                Label("View", systemImage: "slider.horizontal.3")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    private var countLabel: String {
        let rows = model.rows
        let bytes = rows.reduce(Int64(0)) { $0 + $1.size(includingRaw: model.includesRaw($1)) }
        let noun = rows.count == 1 ? "item" : "items"
        return "\(rows.count) \(noun) · \(bytes.byteLabel)"
    }

    private var fileList: some View {
        List(selection: $selection) {
            ForEach(model.sections) { section in
                if model.groupsByDate {
                    Section {
                        ForEach(section.rows) { row(for: $0) }
                    } header: {
                        HStack {
                            Text(section.title)
                            Spacer()
                            Text("\(section.rows.count) · \(model.bytes(of: section).byteLabel)")
                                .foregroundStyle(.tertiary).monospacedDigit()
                        }
                        .font(.caption)
                    }
                } else {
                    ForEach(section.rows) { row(for: $0) }
                }
            }
        }
        .listStyle(.inset)
        .onChange(of: selection) { _, new in
            if model.selection != new { model.selection = new }
        }
        .onChange(of: model.selection) { _, new in
            if selection != new { selection = new }
        }
        .sheet(item: $previewing) { file in
            if let source = model.previewSource(for: file) {
                ClipPreviewSheet(file: file, source: source,
                                 details: model.previews.details[file.id])
            }
        }
        .alert("Delete \(model.pendingDeletion?.rows.count ?? 0) item(s) from the camera?",
               isPresented: Binding(get: { deletePrompt == .alert },
                                    set: { if !$0 { deletePrompt = .none } })) {
            Button("Keep on Camera", role: .cancel) { model.cancelDeletion() }
            Button("Delete", role: .destructive) { model.confirmDeletion() }
        } message: {
            if let plan = model.pendingDeletion {
                Text("\(plan.bytes.byteLabel) copied to "
                     + "\(model.destination.lastPathComponent) and verified at full size. "
                     + "The camera has no trash — this cannot be undone.")
            }
        }
        .sheet(isPresented: Binding(get: { deletePrompt == .sheet },
                                    set: { if !$0 { deletePrompt = .none } })) {
            if let plan = model.pendingDeletion {
                DeleteConfirmationView(plan: plan, destination: model.destination,
                                       onDelete: { model.confirmDeletion() },
                                       onCancel: { model.cancelDeletion() })
            }
        }
        .sheet(item: $editingOverlays) { file in
            if let url = model.importedURL(for: file) {
                OverlayEditorView(file: file, url: url)
            }
        }
        // A dead button explains nothing; this offers the way forward.
        .alert("Import \(overlayNeedsImport?.name ?? "this clip") first?",
               isPresented: Binding(get: { overlayNeedsImport != nil },
                                    set: { if !$0 { overlayNeedsImport = nil } })) {
            Button("Import Now") {
                if let file = overlayNeedsImport { model.startImport([file]) }
                overlayNeedsImport = nil
            }
            Button("Cancel", role: .cancel) { overlayNeedsImport = nil }
        } message: {
            Text("Overlays are positioned against the copy on disk, because the "
                 + "telemetry and the video have to come from the same file and "
                 + "the camera cannot be scrubbed over USB.")
        }
    }

    @ViewBuilder
    private func row(for row: MediaRow) -> some View {
        let file = row.primary
        HStack(spacing: 10) {
            Image(systemName: model.alreadyImported(row)
                  ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(model.alreadyImported(row) ? .green : .secondary)
                .help(model.alreadyImported(row) ? "Already imported" : "Not imported yet")

            Button { preview(file) } label: { ClipThumbnail(file: file, height: model.thumbnailSize) }
                .buttonStyle(.plain)
                .disabled(model.importer.isRunning || model.previewSource(for: file) == nil)
                .help("Play a preview straight from the camera, without copying it")

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(file.name)
                    if row.hasRaw { rawBadge(row) }
                    if let audio = row.audio {
                        badge("WAV", filled: true)
                            .help("Uncompressed audio, \(audio.size.byteLabel) — "
                                  + "imported with the clip")
                    }
                    if row.isVideo { overlayBadge(file) }
                    if row.isVideo { telemetryBadges(file) }
                    if row.isRawOnly {
                        badge("RAW", filled: true)
                            .help("A raw photo with no JPEG beside it")
                    }
                    if row.isAudioOnly {
                        badge("WAV", filled: true)
                            .help("Uncompressed audio with no clip beside it")
                    }
                    if file.isSidecar {
                        badge("proxy", filled: false)
                    }
                }
                Text(rowSubtitle(for: row))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if let modified = file.modified {
                Text(modified.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(row.size(includingRaw: model.includesRaw(row)).byteLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
        }
        .padding(.vertical, 2)
        // No gestures on the row: they take the click List(selection:) needs.
        // See DECISIONS #25.
        .contextMenu {
            Button("Preview") { preview(file) }
                .disabled(model.importer.isRunning || model.previewSource(for: file) == nil)
            Button("Overlays…") { openOverlays(file) }
                .disabled(model.importer.isRunning || !row.isVideo)
            if row.hasRaw {
                Divider()
                Button(model.includesRaw(row) ? "Skip the RAW file" : "Include the RAW file") {
                    model.setIncludesRaw(!model.includesRaw(row), for: row)
                }
            }
            Divider()
            Button("Delete from Camera…") {
                let chosen = selection.contains(row.id)
                    ? model.rows(withIDs: selection) : [row]
                model.requestDeletion(of: chosen)
            }
            .disabled(model.importer.isRunning || model.isDeleting)
            Divider()
            Button("Tick All for Overlays") { model.setOverlaysEnabledForAll(true) }
            Button("Untick All") { model.setOverlaysEnabledForAll(false) }
            Divider()
            Button("Generate Overlays for Selection") {
                model.queueOverlays(for: model.rows(withIDs: selection).map(\.primary))
            }
            .disabled(model.isRunningOverlayQueue || model.overlayExporter.isRunning
                      || selection.isEmpty)
        }
        .tag(row.id)
    }

    /// The raw file's badge, which is also its switch.
    private func rawBadge(_ row: MediaRow) -> some View {
        Button {
            model.setIncludesRaw(!model.includesRaw(row), for: row)
        } label: {
            badge("RAW", filled: model.includesRaw(row))
        }
        .buttonStyle(.plain)
        .help(model.includesRaw(row)
              ? "The .GPR will be imported with this photo — click to skip it"
              : "The .GPR will be skipped — click to include it")
    }

    /// What the camera says is in this clip, before it is copied.
    ///
    /// Importing an 11 GB clip to find out it has no GPS is a slow way to learn
    /// it, so the telemetry is fetched from the camera in the background and
    /// the answer shown here.
    @ViewBuilder
    private func telemetryBadges(_ file: MediaFile) -> some View {
        if let summary = model.previews.summaries[file.id] {
            HStack(spacing: 3) {
                Image(systemName: summary.hasFix ? "location.fill" : "location.slash")
                    .font(.caption2)
                    .foregroundStyle(summary.hasFix ? Color.accentColor : Color.secondary)
                if summary.launches > 0 {
                    Image(systemName: "stopwatch")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .help(summary.caption(unit: .mph))
        }
    }

    /// Whether this clip gets an overlay when overlays are generated.
    private func overlayBadge(_ file: MediaFile) -> some View {
        Button {
            model.setOverlaysEnabled(!model.overlaysEnabled(for: file), for: file)
        } label: {
            Image(systemName: "speedometer")
                .font(.caption2)
                .foregroundStyle(model.overlaysEnabled(for: file)
                                 ? Color.white : Color.secondary)
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(model.overlaysEnabled(for: file)
                            ? AnyShapeStyle(Color.accentColor)
                            : AnyShapeStyle(.quaternary),
                            in: Capsule())
        }
        .buttonStyle(.plain)
        .help(model.overlaysEnabled(for: file)
              ? "This clip gets an overlay — click to skip it"
              : "This clip is skipped when overlays are generated — click to include it")
    }

    private func badge(_ text: String, filled: Bool) -> some View {
        Text(text)
            .font(.caption2.weight(filled ? .semibold : .regular))
            .foregroundStyle(filled ? Color.white : Color.secondary)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(filled ? AnyShapeStyle(Color.accentColor)
                               : AnyShapeStyle(.quaternary),
                        in: Capsule())
    }

    private func rowSubtitle(for row: MediaRow) -> String {
        var parts: [String] = []
        if model.devicesOnCard.count > 1 { parts.append(row.primary.device.label) }
        parts.append(row.folder)
        if let summary = model.previews.details[row.primary.id]?.summary, !summary.isEmpty {
            parts.append(summary)
        }
        if row.isVideo, let telemetry = model.previews.summaries[row.primary.id] {
            parts.append(telemetry.caption(unit: .mph))
        }
        if row.hasRaw, !model.includesRaw(row) { parts.append("RAW skipped") }
        return parts.joined(separator: " · ")
    }

    private func preview(_ file: MediaFile) {
        guard !model.importer.isRunning, model.previewSource(for: file) != nil else { return }
        previewing = file
    }

    private var previewTarget: MediaFile? {
        guard !model.importer.isRunning, selection.count == 1, let id = selection.first
        else { return nil }
        return model.rows.first { $0.id == id && model.previewSource(for: $0.primary) != nil }?
            .primary
    }

    /// The clip the Overlays button acts on: any single selected video.
    ///
    /// Deliberately *not* filtered by whether it has been imported. It used to
    /// be, and the button then went dead with no explanation for three separate
    /// reasons -- a photo selected, more than one row, or a clip not yet copied
    /// -- which is indistinguishable from the feature being broken. It stays
    /// live now and says what is in the way.
    private var overlayTarget: MediaFile? {
        guard !model.importer.isRunning, selection.count == 1, let id = selection.first
        else { return nil }
        return model.rows.first { $0.id == id && $0.isVideo }?.primary
    }

    /// Why the Overlays button cannot act, if it cannot.
    private var overlayBlocker: String? {
        if model.importer.isRunning { return "Not while an import is running." }
        if selection.isEmpty { return "Select a clip first." }
        if selection.count > 1 { return "Select a single clip." }
        guard let id = selection.first, let row = model.rows.first(where: { $0.id == id })
        else { return "Select a clip first." }
        if !row.isVideo { return "Overlays need a video — this is a photo." }
        return nil
    }

    private func openOverlays(_ file: MediaFile) {
        if model.importedURL(for: file) == nil {
            overlayNeedsImport = file
        } else {
            editingOverlays = file
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 10) {
            if model.importer.isRunning { importProgress }
            if model.isDeleting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Deleting from the camera… \(model.deletedCount)")
                    Spacer()
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            if let converting = model.convertingGPR {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Converting \(converting) to DNG…")
                    Spacer()
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            if model.overlayExporter.isRunning || model.isRunningOverlayQueue {
                overlayExportProgress
            } else if let exported = model.overlayExportResult {
                overlayExportFinished(exported)
            }

            HStack(alignment: .center, spacing: 14) {
                destinationControl
                Spacer()
                optionsButton
                actions
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .fileImporter(isPresented: $choosingDestination,
                      allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.destination = url }
        }
    }

    /// The destination, with the folder itself one click away — it used to be a
    /// path you could read and not open.
    private var destinationControl: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("Import to").font(.caption).foregroundStyle(.secondary)
                Button("Change…") { choosingDestination = true }
                    .buttonStyle(.link).font(.caption)
            }
            Button {
                model.revealImportDestination()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                    Text(model.examplePath + "/")
                        .lineLimit(1).truncationMode(.head)
                }
            }
            .buttonStyle(.link)
            .help("Open this folder in Finder")
        }
    }

    /// Everything that used to be five rows of checkboxes.
    private var optionsButton: some View {
        Menu {
            Toggle("Date folders", isOn: $model.organiseByDate)
            Toggle("Device folders", isOn: $model.separateByCamera)
            if model.separateByCamera, model.isConnected,
               model.devicesOnCard.contains(where: { $0.isAttachedCamera }) {
                Stepper(value: Binding(get: { model.cameraNumber },
                                       set: { model.setCameraNumber($0) }), in: 1...99) {
                    Text("Camera #\(model.cameraNumber)")
                }
            }
            Divider()
            Toggle("Show proxies", isOn: $model.includeSidecars)
            if model.hasGPRFiles {
                Divider()
                Toggle("Convert GPR to DNG", isOn: $model.convertGPRToDNG)
                if model.convertGPRToDNG {
                    Toggle("Delete the GPR afterwards", isOn: $model.replaceGPRWithDNG)
                }
            }
            Divider()
            Toggle("Overlays after import", isOn: $model.overlaysAfterImport)
            if model.overlaysAfterImport {
                Text("\(model.overlayEligibleCount) ticked · \(model.overlayPresetSummary)")
            }
            Divider()
            Toggle("Delete from camera after importing", isOn: $model.deleteAfterImport)
            if model.deleteAfterImport {
                Text("Asks first, every time")
            }
        } label: {
            Label("Options", systemImage: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if model.importer.isRunning {
                Button("Cancel") { model.cancelImport() }
            } else {
                if !selection.isEmpty {
                    let summary = model.selectionSummary(selection)
                    Text("\(summary.count) selected · \(summary.bytes.byteLabel)")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }

                Button {
                    if let target = previewTarget { preview(target) }
                } label: {
                    Label("Preview", systemImage: "play.rectangle")
                }
                .disabled(previewTarget == nil)
                .help("Play the camera's low-resolution proxy without copying anything")

                Button {
                    if let target = overlayTarget { openOverlays(target) }
                } label: {
                    Label("Overlays", systemImage: "speedometer")
                }
                .disabled(overlayTarget == nil)
                .help(overlayBlocker ?? "Position the overlays on this clip.")

                Button("Import Selected") { model.importSelected() }
                    .disabled(selection.isEmpty)

                Button {
                    model.importNew()
                } label: {
                    Label("Import \(model.newRows.count) New", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.newRows.isEmpty)
            }
        }
    }

    private var overlayExportProgress: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: model.overlayExporter.progress.fraction)
            HStack {
                Label(queueLabel, systemImage: "speedometer")
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(String(format: "%.0f fps", model.overlayExporter.progress.framesPerSecond))
                    .monospacedDigit()
                Button("Cancel") {
                    model.isRunningOverlayQueue ? model.cancelOverlayQueue()
                                                : model.cancelOverlayExport()
                }
                .buttonStyle(.link)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var queueLabel: String {
        let name = model.overlayExporter.clipName ?? ""
        guard model.isRunningOverlayQueue else { return "Overlay — \(name)" }
        let total = model.overlayQueueDone + model.overlayQueue.count
        return "Overlay \(model.overlayQueueDone + 1) of \(total) — \(name)"
    }

    private func overlayExportFinished(_ url: URL) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("Exported")
            Button(url.lastPathComponent) { model.revealOverlayExport() }
                .buttonStyle(.link).lineLimit(1).truncationMode(.middle)
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var importProgress: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: model.importer.progress.fraction)
            HStack {
                Text("\(model.importer.progress.fileName) "
                     + "(\(model.importer.progress.fileIndex) of \(model.importer.progress.fileCount))")
                Spacer()
                Text("\(Int64(model.importer.progress.bytesPerSecond).byteLabel)/s")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ContentView().environmentObject(AppModel())
}
