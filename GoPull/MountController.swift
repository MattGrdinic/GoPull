//
//  MountController.swift
//  GoPull
//
//  Drives macOS's own WebDAV client. Nothing here needs sudo, as long as the
//  mount point is a directory the user owns.
//

import Foundation

enum MountError: LocalizedError {
    case commandFailed(String, Int32, String)
    case notMounted

    var errorDescription: String? {
        switch self {
        case .commandFailed(let tool, let code, let output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "\(tool) failed with status \(code)."
                : "\(tool) failed: \(detail)"
        case .notMounted:
            return "The camera volume is not mounted."
        }
    }
}

enum MountController {

    static var defaultMountPoint: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("GoPro-Camera")
    }

    /// True when `path` sits on a WebDAV filesystem. Nothing else on a Mac
    /// normally is, so this is a reliable check for our own mount.
    static func isMounted(at path: URL) -> Bool {
        var info = statfs()
        guard statfs(path.path, &info) == 0 else { return false }
        let type = withUnsafeBytes(of: &info.f_fstypename) { raw -> String in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
        return type == "webdav"
    }

    static func mount(port: UInt16, at path: URL, volumeName: String = "GoPro") throws {
        if isMounted(at: path) { return }

        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)

        let result = try run("/sbin/mount_webdav",
                             ["-S", "-v", volumeName,
                              "http://127.0.0.1:\(port)/", path.path])
        guard result.status == 0 else {
            throw MountError.commandFailed("mount_webdav", result.status, result.output)
        }
    }

    static func unmount(at path: URL) throws {
        guard isMounted(at: path) else { throw MountError.notMounted }
        var result = try run("/sbin/umount", [path.path])
        if result.status != 0 {
            // Finder or a preview can hold the volume briefly after a read.
            result = try run("/sbin/umount", ["-f", path.path])
        }
        guard result.status == 0 else {
            throw MountError.commandFailed("umount", result.status, result.output)
        }
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws
        -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
