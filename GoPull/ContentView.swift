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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if model.isConnected {
                if model.visibleFiles.isEmpty {
                    emptyCard
                } else {
                    fileList
                }
                Divider()
                footer
            } else {
                disconnected
            }
        }
        .frame(minWidth: 620, minHeight: 460)
        .alert("Something went wrong",
               isPresented: Binding(get: { model.errorMessage != nil },
                                    set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
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
                    Text("\(model.cameraIP) · \(model.visibleFiles.count) file\(model.visibleFiles.count == 1 ? "" : "s") · \(model.totalBytes.byteLabel) used · \(model.freeBytes.byteLabel) free"
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

    private var fileList: some View {
        List(model.visibleFiles, selection: $selection) { file in
            HStack(spacing: 10) {
                Image(systemName: model.alreadyImported(file)
                      ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(model.alreadyImported(file) ? .green : .secondary)
                    .help(model.alreadyImported(file) ? "Already imported" : "Not imported yet")

                // Which clips want a speedometer on them. On by default, so a
                // card of one kind of footage needs no attention; the point is
                // turning it off for the few that do not.
                Toggle("", isOn: Binding(
                    get: { model.overlaysEnabled(for: file) },
                    set: { model.setOverlaysEnabled($0, for: file) }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(!model.canOverlay(file))
                    .opacity(model.canOverlay(file) ? 1 : 0.25)
                    .help(model.canOverlay(file)
                          ? "Give this clip an overlay when overlays are generated"
                          : "Overlays only apply to video")

                Button { preview(file) } label: { ClipThumbnail(file: file) }
                    .buttonStyle(.plain)
                    .disabled(model.importer.isRunning
                              || model.previewSource(for: file) == nil)
                    .help("Play a preview straight from the camera, without copying it")

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(file.name)
                        if file.isSidecar {
                            Text("proxy")
                                .font(.caption2)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    Text(rowSubtitle(for: file))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if let modified = file.modified {
                    Text(modified.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(file.size.byteLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .trailing)
            }
            .padding(.vertical, 2)
            // No tap gesture on the row, deliberately. Every spelling of
            // double-click-to-preview cost something, and the last one was the
            // subtlest: a gesture's hit area is the row's *content*, so clicks
            // on the name and thumbnail went through gesture arbitration while
            // clicks on the empty space beside them went straight to the List.
            // Half the row selected crisply and half did not.
            //
            //   .onTapGesture(count: 2)       rows stop selecting at all
            //   .contentShape + simultaneous  rows stop selecting at all
            //   .simultaneousGesture alone    selection works, but only the
            //                                 white space feels responsive
            //
            // Preview has three affordances that cost the row nothing: the
            // thumbnail is a real Button, plus the Preview button and the
            // context menu item. So the row itself does exactly one thing.
            .contextMenu {
                Button("Preview") { preview(file) }
                    .disabled(model.importer.isRunning || model.previewSource(for: file) == nil)
                Button("Overlays…") { editingOverlays = file }
                    .disabled(model.importer.isRunning || model.importedURL(for: file) == nil)
                Divider()
                Button("Tick All for Overlays") { model.setOverlaysEnabledForAll(true) }
                Button("Untick All") { model.setOverlaysEnabledForAll(false) }
                Divider()
                Button("Generate Overlays for Selection") {
                    model.queueOverlays(for: model.visibleFiles.filter { selection.contains($0.id) })
                }
                .disabled(model.isRunningOverlayQueue || model.overlayExporter.isRunning
                          || selection.isEmpty)
            }
            .tag(file.id)
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
        .sheet(item: $editingOverlays) { file in
            if let url = model.importedURL(for: file) {
                OverlayEditorView(file: file, url: url)
            }
        }
    }

    /// Duration and resolution once the camera has told us, folder until then.
    private func rowSubtitle(for file: MediaFile) -> String {
        var parts: [String] = []
        if model.devicesOnCard.count > 1 { parts.append(file.device.label) }
        parts.append(file.folder)
        if let summary = model.previews.details[file.id]?.summary, !summary.isEmpty {
            parts.append(summary)
        }
        return parts.joined(separator: " · ")
    }

    /// Previewing opens a fifth stream against a camera that is already
    /// serving four, and an import is the operation worth protecting. Playback
    /// waits until it finishes.
    private func preview(_ file: MediaFile) {
        guard !model.importer.isRunning, model.previewSource(for: file) != nil else { return }
        previewing = file
    }

    /// The clip a Preview button would act on: the selection when it is a
    /// single clip, so the button matches what the list is showing as chosen.
    private var previewTarget: MediaFile? {
        guard !model.importer.isRunning else { return nil }
        guard selection.count == 1, let id = selection.first else { return nil }
        return model.visibleFiles.first { $0.id == id && model.previewSource(for: $0) != nil }
    }

    /// Overlays are edited against the imported copy, so this stays nil until a
    /// clip is actually on disk.
    private var overlayTarget: MediaFile? {
        guard !model.importer.isRunning else { return nil }
        guard selection.count == 1, let id = selection.first else { return nil }
        return model.visibleFiles.first { $0.id == id && model.importedURL(for: $0) != nil }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 10) {
            if model.importer.isRunning {
                importProgress
            }
            // A burn-in outlives the editor sheet, so it reports here too --
            // otherwise closing that sheet leaves it running with nothing to
            // show for it, and a part-written file that looks like a failure.
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

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import to")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        choosingDestination = true
                    } label: {
                        Text(model.destination.path.replacingOccurrences(
                            of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .buttonStyle(.link)
                    Text(model.examplePath + "/")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help("Where the next import will land")
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Date folders", isOn: $model.organiseByDate)
                        .toggleStyle(.checkbox)
                        .help("Sort clips into YYYY-MM-DD folders as they are copied")

                    Toggle("Show proxies", isOn: $model.includeSidecars)
                        .toggleStyle(.checkbox)
                        .help("Include .LRV/.LRF proxies and thumbnails in the list. "
                              + "They are always visible on the mounted drive.")

                    // Only offered when the card actually has raw stills on it.
                    if model.hasGPRFiles {
                        HStack(spacing: 6) {
                            Toggle("GPR → DNG", isOn: $model.convertGPRToDNG)
                                .toggleStyle(.checkbox)
                                .help("GoPro's raw stills use VC-5 compression, which "
                                      + "nothing on macOS can open. Converting writes a "
                                      + "DNG beside each one, with all its colour data intact.")
                            if model.convertGPRToDNG {
                                Toggle("replace", isOn: $model.replaceGPRWithDNG)
                                    .toggleStyle(.checkbox)
                                    .help("Delete each .GPR once its .DNG has been written.")
                            }
                        }
                    }

                    HStack(spacing: 6) {
                        Toggle("Overlays after import", isOn: $model.overlaysAfterImport)
                            .toggleStyle(.checkbox)
                            .help("Run the saved overlay preset over each ticked clip "
                                  + "once it has copied across.")
                        if model.overlaysAfterImport {
                            Text("\(model.overlayEligibleCount) ticked · \(model.overlayPresetSummary)")
                                .font(.caption2).foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }

                    HStack(spacing: 6) {
                        Toggle("Device folders", isOn: $model.separateByCamera)
                            .toggleStyle(.checkbox)
                            .help("Give each device its own folder, named after the model "
                                  + "when the camera knows it")

                        if model.separateByCamera && model.isConnected
                            && model.devicesOnCard.contains(where: { $0.isAttachedCamera }) {
                            Stepper(value: Binding(get: { model.cameraNumber },
                                                   set: { model.setCameraNumber($0) }),
                                    in: 1...99) {
                                Text("#\(model.cameraNumber)")
                                    .font(.caption.monospacedDigit())
                            }
                            .help("Distinguishes two bodies of the same model. "
                                  + "Remembered per camera; #1 is left out of the folder name.")
                        }
                    }
                }

                Spacer()

                if model.importer.isRunning {
                    Button("Cancel") { model.cancelImport() }
                } else {
                    Button {
                        if let target = previewTarget { preview(target) }
                    } label: {
                        Label("Preview", systemImage: "play.rectangle")
                    }
                    .disabled(previewTarget == nil)
                    .help("Play the camera's low-resolution proxy without copying anything. "
                          + "Double-clicking a clip does the same.")

                    Button {
                        if let target = overlayTarget { editingOverlays = target }
                    } label: {
                        Label("Overlays", systemImage: "speedometer")
                    }
                    .disabled(overlayTarget == nil)
                    .help(overlayTarget == nil
                          ? "Import a clip first — overlays are edited against the copy on disk."
                          : "Position the speed gauge and route map on this clip.")

                    Button("Import Selected") { model.importSelected() }
                    .disabled(selection.isEmpty)

                    Button {
                        model.importNew()
                    } label: {
                        Label("Import \(model.newFiles.count) New",
                              systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.newFiles.isEmpty)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .fileImporter(isPresented: $choosingDestination,
                      allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.destination = url }
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
