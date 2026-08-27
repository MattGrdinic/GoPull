//
//  BatchOverlayTests.swift
//  GoPullTests
//

import AVFoundation
import Foundation
import Testing
@testable import GoPull

@MainActor
struct BatchOverlayTests {

    private func file(_ name: String, folder: String = "100GOPRO") -> MediaFile {
        MediaFile(folder: folder, name: name, size: 1024, modified: nil)
    }

    // MARK: - Which clips are candidates

    @Test func stillsAndProxiesCannotTakeAnOverlay() {
        let model = AppModel()
        #expect(model.canOverlay(file("GX010005.MP4")))
        #expect(!model.canOverlay(file("GP010007.JPG")))
        #expect(!model.canOverlay(file("GL010005.LRV")))
    }

    /// Stored as exceptions, so a card of one kind of footage needs no
    /// attention at all.
    @Test func clipsAreIncludedUntilTurnedOff() {
        let model = AppModel()
        let clip = file("GX010005.MP4")
        #expect(model.overlaysEnabled(for: clip))

        model.setOverlaysEnabled(false, for: clip)
        #expect(!model.overlaysEnabled(for: clip))

        model.setOverlaysEnabled(true, for: clip)
        #expect(model.overlaysEnabled(for: clip))
    }

    /// Mixed footage is the case this exists for: turn one kind off, leave the
    /// rest alone.
    @Test func turningOneOffLeavesTheOthers() {
        let model = AppModel()
        let ride = file("GX010005.MP4")
        let pickleball = file("GX010009.MP4")
        model.setOverlaysEnabled(false, for: pickleball)
        #expect(model.overlaysEnabled(for: ride))
        #expect(!model.overlaysEnabled(for: pickleball))
    }

    @Test func aClipThatCannotTakeAnOverlayIsNeverEnabled() {
        let model = AppModel()
        let photo = file("GP010007.JPG")
        model.setOverlaysEnabled(true, for: photo)
        #expect(!model.overlaysEnabled(for: photo))
    }

    // MARK: - Where batch output lands

    private var burnedIn: OverlaySettings {
        var settings = OverlaySettings.defaults
        settings.export.content = .burnedIn
        return settings
    }

    private var alpha: OverlaySettings {
        var settings = OverlaySettings.defaults
        settings.export.content = .overlayOnly
        return settings
    }

    @Test func batchNamesMatchWhatTheEditorWrites() {
        let clip = URL(fileURLWithPath: "/clips/GX010005.MP4")
        #expect(AppModel.overlayDestination(for: clip, settings: burnedIn).lastPathComponent
                == "GX010005 — overlay.mp4")
        #expect(AppModel.overlayDestination(for: clip, settings: alpha).lastPathComponent
                == "GX010005 — overlay-alpha.mov")
    }

    @Test func batchWritesBesideTheClip() {
        let clip = URL(fileURLWithPath: "/clips/2026-08-25/GX010005.MP4")
        let out = AppModel.overlayDestination(for: clip, settings: alpha)
        #expect(out.deletingLastPathComponent() == clip.deletingLastPathComponent())
    }

    /// Replacing is only meaningful for a burned-in export; a batch of
    /// transparent overlays must never overwrite the footage.
    @Test func alphaBatchNeverReplacesTheOriginal() {
        var settings = alpha
        settings.export.destination = .replaceOriginal
        let clip = URL(fileURLWithPath: "/clips/GX010005.MP4")
        #expect(AppModel.overlayDestination(for: clip, settings: settings) != clip)
    }

    @Test func burnedInBatchCanReplaceWhenAsked() {
        var settings = burnedIn
        settings.export.destination = .replaceOriginal
        let clip = URL(fileURLWithPath: "/clips/GX010005.MP4")
        #expect(AppModel.overlayDestination(for: clip, settings: settings) == clip)
    }

    // MARK: - The preset

    /// Export choices travel with the look: "my preset" means burned-in-at-4K
    /// as much as it means Hi-Tech.
    @Test func theExportIsPartOfThePreset() throws {
        var settings = OverlaySettings.defaults
        settings.apply(.hiTech)
        settings.export.content = .overlayOnly
        settings.export.size = .uhd4K
        settings.export.codec = .proRes4444

        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(OverlaySettings.self, from: data)
        #expect(restored == settings)
        #expect(restored.export.content == .overlayOnly)
        #expect(restored.export.size == .uhd4K)
        #expect(restored.export.codec == .proRes4444)
    }

    @Test func thePresetDescribesItself() {
        var settings = OverlaySettings.defaults
        settings.apply(.classic)
        settings.export.content = .overlayOnly
        settings.export.size = .hd1080
        let summary = settings.summary
        #expect(summary.contains("Classic"))
        #expect(summary.contains("alpha"))
        #expect(summary.contains("1080p"))
    }

    @Test func aBurnedInPresetSaysSo() {
        var settings = OverlaySettings.defaults
        settings.export.content = .burnedIn
        #expect(settings.summary.contains("burned in"))
    }
}
