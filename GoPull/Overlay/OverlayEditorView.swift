//
//  OverlayEditorView.swift
//  GoPull
//

import Combine
import SwiftUI

struct OverlayEditorView: View {
    let file: MediaFile
    @StateObject private var model: OverlayEditorModel
    @Environment(\.dismiss) private var dismiss

    init(file: MediaFile, url: URL) {
        self.file = file
        _model = StateObject(wrappedValue: OverlayEditorModel(url: url))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                preview
                Divider()
                VStack(spacing: 0) {
                    controls
                    Divider()
                    // Pinned, not at the bottom of the scroll view: it was below
                    // the fold with no visible scrollbar, so it read as missing.
                    exportSection
                        .padding(16)
                }
                .frame(width: 300)
            }
        }
        .frame(width: 1080, height: 700)
        .task { await model.start() }
        .alert("Replace \(file.name)?", isPresented: $model.confirmingReplace) {
            Button("Replace", role: .destructive) { model.export() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The overlays will be burned into the clip itself, and its GPS "
                 + "track will not survive — the overlays could not be moved, "
                 + "restyled or removed afterwards. Re-importing from the camera "
                 + "would be the only way back.")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Overlays — \(file.name)").font(.headline)
                Text(model.summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: - Preview

    private var preview: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                ZStack {
                    Color.black
                    if let image = model.preview {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else if let status = model.status {
                        VStack(spacing: 8) {
                            Image(systemName: "location.slash")
                                .font(.system(size: 30)).foregroundStyle(.tertiary)
                            Text(status).font(.callout).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center).frame(maxWidth: 320)
                        }
                    } else {
                        ProgressView()
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard let rect = videoRect(in: geometry.size) else { return }
                            let point = CGPoint(
                                x: (value.location.x - rect.minX) / rect.width,
                                y: (value.location.y - rect.minY) / rect.height)
                            if model.dragging == nil { model.beginDrag(at: point) }
                            model.drag(to: point)
                        }
                        .onEnded { _ in model.endDrag() }
                )
            }
            scrubber
        }
        .padding(12)
    }

    /// Where the letterboxed video actually sits, so a drag maps to the frame
    /// rather than to the black bars around it.
    private func videoRect(in size: CGSize) -> CGRect? {
        let aspect = model.aspect
        guard aspect > 0, size.width > 0, size.height > 0 else { return nil }
        let fitted = size.width / size.height > aspect
            ? CGSize(width: size.height * aspect, height: size.height)
            : CGSize(width: size.width, height: size.width / aspect)
        return CGRect(x: (size.width - fitted.width) / 2,
                      y: (size.height - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
    }

    private var scrubber: some View {
        HStack(spacing: 10) {
            Text(timecode(model.time)).font(.caption.monospacedDigit())
                .foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
            Slider(value: $model.time, in: 0...max(model.duration, 1))
            Text(timecode(model.duration)).font(.caption.monospacedDigit())
                .foregroundStyle(.secondary).frame(width: 52)
        }
        .disabled(model.duration <= 0)
    }

    private func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    // MARK: - Controls

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Look") {
                    Picker("", selection: Binding(
                        get: { model.settings.commonPreset ?? .modern },
                        set: { model.settings.apply($0) })) {
                        ForEach(GaugePreset.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }

                section("Speed") {
                    Toggle("Show gauge", isOn: $model.settings.showsGauge)
                    Picker("Shape", selection: $model.settings.gauge.kind) {
                        ForEach(GaugeKind.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Units", selection: Binding(
                        get: { model.settings.gauge.unit },
                        set: { model.settings.gauge.unit = $0
                               model.settingsChangedRequiringResample() })) {
                        ForEach(SpeedUnit.allCases) { Text($0.label).tag($0) }
                    }
                    slider("Size", value: $model.settings.gauge.placement.scale, in: 0.10...0.50)
                }

                section("Map") {
                    Toggle("Show map", isOn: $model.settings.showsMap)
                    Picker("Mode", selection: $model.settings.map.mode) {
                        ForEach(MapMode.allCases) { Text($0.label).tag($0) }
                    }
                    if model.settings.map.mode == .follow {
                        slider("Span", value: $model.settings.map.followSpan,
                               in: 100...2000, format: "%.0f m")
                    }
                    slider("Size", value: $model.settings.map.placement.scale, in: 0.10...0.50)
                    slider("Feather", value: $model.settings.map.style.feather, in: 0...0.8)
                    slider("Backing", value: $model.settings.map.style.backing.a, in: 0...1)
                    slider("Rim", value: $model.settings.map.style.rim.a, in: 0...1)
                }

                section("Smoothing") {
                    slider("Window", value: Binding(
                        get: { model.settings.gauge.smoothingSeconds },
                        set: { model.settings.gauge.smoothingSeconds = $0 }),
                           in: 0...2, format: "%.1f s")
                    Text(smoothingNote)
                        .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
                .onChange(of: model.settings.gauge.smoothingSeconds) { _, _ in
                    model.settingsChangedRequiringResample()
                }

                Text("Drag the gauge or the map on the preview to move it.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Export").font(.caption).foregroundStyle(.secondary)

            Picker("Contents", selection: $model.settings.export.content) {
                ForEach(ExportOptions.Content.allCases) { Text($0.label).tag($0) }
            }
            if model.exportOptions.content == .overlayOnly {
                Text("The overlays on transparency, to lay over the original in "
                     + "an editor. The footage is never decoded, so this is much "
                     + "quicker.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.exportOptions.content == .burnedIn {
                Picker("Write to", selection: $model.settings.export.destination) {
                    ForEach(ExportOptions.Destination.allCases) { Text($0.label).tag($0) }
                }
            }
            Text(model.exportDestination.lastPathComponent)
                .font(.caption2).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle)

            if model.replaceWouldLoseTelemetry {
                Label("Replacing discards this clip's GPS track — the overlays "
                      + "could not be changed afterwards.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("Size", selection: $model.settings.export.size) {
                ForEach(ExportOptions.Size.allCases) { Text($0.label).tag($0) }
            }
            if model.exportOptions.content == .burnedIn {
                Toggle("Include audio", isOn: $model.settings.export.includesAudio)
            }
            Text(model.exportSummary)
                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            if let estimate = model.exportSizeEstimate {
                Text(estimate).font(.caption2).foregroundStyle(.tertiary)
            }

            if model.isExporting {
                let progress = model.app.overlayExporter.progress
                ProgressView(value: progress.fraction)
                HStack {
                    Text("\(Int(progress.fraction * 100))%")
                    Spacer()
                    Text(String(format: "%.0f fps", progress.framesPerSecond)).monospacedDigit()
                }
                .font(.caption2).foregroundStyle(.secondary)
                Button("Cancel Export") { model.cancelExport() }
                    .frame(maxWidth: .infinity)
            } else {
                Button {
                    model.exportRequested()
                } label: {
                    Label(model.exportOptions.content == .overlayOnly
                          ? "Export Overlay"
                          : (model.exportOptions.destination == .replaceOriginal
                             ? "Burn In and Replace" : "Burn In and Export"),
                          systemImage: "square.and.arrow.down.on.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.track.hasFix)
            }

            if let exported = model.app.overlayExportResult {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Button(exported.lastPathComponent) { model.revealExport() }
                        .buttonStyle(.link).lineLimit(1).truncationMode(.middle)
                }
                .font(.caption2)
            }
            if let error = model.app.overlayExportError {
                Text(error).font(.caption2).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var smoothingNote: String {
        let seconds = model.settings.gauge.smoothingSeconds
        if seconds == 0 { return "Raw fixes. GPS noise is about the size of real acceleration, so the needle will twitch." }
        if seconds <= 0.6 { return "Steadies the needle for about a quarter second of lag." }
        return "Very smooth, with visible lag behind real changes in speed."
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    private func slider(_ title: String, value: Binding<Double>,
                        in range: ClosedRange<Double>, format: String = "%.2f") -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
            Slider(value: value, in: range)
        }
    }
}
