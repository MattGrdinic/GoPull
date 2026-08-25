//
//  GoPullApp.swift
//  GoPull
//

import SwiftUI

@main
struct GoPullApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
        .windowResizability(.contentMinSize)

        // The mount lives inside this process, so keep a menu bar presence:
        // the window can be closed without tearing the volume down.
        MenuBarExtra("GoPull", systemImage: "camera") {
            if model.isConnected {
                Text(model.info?.model ?? "GoPro")
                Divider()
                if model.isMounted {
                    Button("Open in Finder") { model.revealMount() }
                    Button("Eject") { Task { await model.unmount() } }
                } else {
                    Button("Mount as Drive") { Task { await model.mount() } }
                }
                Button("Import \(model.newFiles.count) New Clips") {
                    model.importNew()
                }
                .disabled(model.newFiles.isEmpty || model.importer.isRunning)
            } else {
                Text("No camera connected")
            }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Not tied to a window appearing: the menu bar item stays useful after
        // the window is closed.
        MainActor.assumeIsolated { AppModel.shared.startPolling() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The mount is served by this process, so leaving it behind would
        // strand a dead volume in Finder.
        MainActor.assumeIsolated { AppModel.shared.unmountForShutdown() }
    }
}
