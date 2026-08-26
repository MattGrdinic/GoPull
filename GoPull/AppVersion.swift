//
//  AppVersion.swift
//  GoPull
//
//  The version the app is running, read from the bundle.
//
//  There is one source of truth for this -- MARKETING_VERSION in the Xcode
//  project, managed by `tools/version`. GENERATE_INFOPLIST_FILE turns it into
//  CFBundleShortVersionString, and this reads it back, so what the app reports
//  and what the release is tagged as cannot drift apart.
//

import Foundation

enum AppVersion {

    /// e.g. "1.1.0"
    static var short: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// The build number, which rises on every version bump.
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// What the menu bar shows: "1.1.0 (2)".
    static var display: String { "\(short) (\(build))" }

    /// The tag a release of this build should carry.
    static var tag: String { "v\(short)" }
}
