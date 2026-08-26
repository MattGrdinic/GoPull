//
//  PreviewWindow.swift
//  GoPull
//
//  The sheet that plays a clip straight off the camera.
//
//  Nothing is copied to do this. The camera serves its files over HTTP with
//  `Accept-Ranges: bytes` and `Content-Type: video/mp4`, so AVPlayer streams
//  and seeks against them directly -- including the `.LRV` proxy, which is what
//  actually gets played: 364 MB and 960x540 instead of 10.7 GB of 8K.
//

import AVFoundation
import AVKit
import Combine
import SwiftUI

struct ClipPreviewSheet: View {
    let file: MediaFile
    let source: PreviewSource
    let details: MediaDetails?

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var still: NSImage?
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            heading
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
            Divider()
            footer
        }
        .frame(width: 720, height: 520)
        .onAppear(perform: start)
        .onDisappear { player?.pause() }
    }

    private var heading: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var subtitle: String {
        var parts = [file.folder]
        if let summary = details?.summary, !summary.isEmpty { parts.append(summary) }
        parts.append(file.size.byteLabel)
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        if let failure {
            VStack(spacing: 8) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        } else if let player {
            PlayerView(player: player)
        } else if let still {
            Image(nsImage: still)
                .resizable()
                .scaledToFit()
        } else {
            ProgressView()
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            switch source {
            case .video(_, let isProxy):
                Image(systemName: isProxy ? "bolt.fill" : "exclamationmark.triangle")
                    .foregroundStyle(isProxy ? Color.accentColor : .orange)
                Text(isProxy
                     ? "Playing the camera's low-resolution proxy — nothing is being copied."
                     : "No proxy on the card, so this is the full-resolution file. "
                       + "It still streams rather than copying, but may stutter.")
            case .still:
                Image(systemName: "photo")
                    .foregroundStyle(Color.accentColor)
                Text("Loaded straight from the camera — nothing is being copied.")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func start() {
        switch source {
        case .video(let url, _):
            // The proxy is served as video/mp4 but named .LRV, and AVFoundation
            // otherwise has to sniff the type -- measured at 0.29s versus 0.03s
            // with the hint.
            let asset = AVURLAsset(url: url,
                                   options: ["AVURLAssetOutOfBandMIMETypeKey": "video/mp4"])
            let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            self.player = player
            player.play()

        case .still(let url):
            Task {
                var request = URLRequest(url: url)
                request.timeoutInterval = 20
                guard let (data, response) = try? await URLSession.shared.data(for: request),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let image = NSImage(data: data) else {
                    failure = "The camera would not send this photo."
                    return
                }
                still = image
            }
        }
    }
}

/// AVKit's player, wrapped by hand rather than using SwiftUI's `VideoPlayer`.
///
/// Two reasons, and the first is not optional. `import AVKit` autolinks the
/// `_AVKit_SwiftUI` shim but *not* `AVKit.framework` itself, so `VideoPlayer`
/// resolved its shim and then died in `getSuperclassMetadata` looking for
/// `AVPlayerView` -- an immediate SIGABRT the moment the sheet opened. Naming
/// `AVPlayerView` here is a hard symbol reference, so the linker brings AVKit
/// along. Using it directly also gets the real transport bar: scrubbing,
/// volume, and a full-screen button, none of which have to be rebuilt.
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// The thumbnail shown against a clip in the list.
struct ClipThumbnail: View {
    let file: MediaFile
    @EnvironmentObject private var model: AppModel

    private static let size = CGSize(width: 64, height: 36)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(.quaternary)
            if let image = model.previews.thumbnails[file.id] {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                // Says "this plays" without needing to be discovered.
                if MediaPreview.isVideo(file), !file.isSidecar {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.white.opacity(0.9), .black.opacity(0.35))
                        .shadow(radius: 1)
                }
            } else {
                Image(systemName: file.isSidecar ? "square.stack.3d.down.right"
                                                 : (MediaPreview.isStill(file) ? "photo" : "film"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .task(id: file.id) { model.previews.request(file) }
    }
}
