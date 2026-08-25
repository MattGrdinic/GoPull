//
//  DeviceCatalog.swift
//  GoPull
//
//  Works out which device shot the footage in a DCIM folder.
//
//  The camera is always a GoPro -- that's what serves the API this app talks to
//  -- but the card inside it need not be a GoPro card. Using the camera as a
//  card reader for a drone or a mirrorless body is a perfectly good reason to
//  plug it in, so folders are identified individually.
//

import Foundation

struct DeviceIdentity: Hashable {
    /// Manufacturer, e.g. "GoPro", "DJI", "Sony".
    var brand: String
    /// Specific model when the camera itself told us, e.g. "MISSION 1 PRO".
    var model: String?
    /// True when this folder was recorded by the camera currently attached.
    var isAttachedCamera: Bool = false

    /// Folder name for imports: the model when we genuinely know it, else the brand.
    var folderName: String {
        (model ?? brand)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    var label: String {
        guard let model, model != brand else { return brand }
        return "\(brand) \(model)"
    }
}

enum DeviceCatalog {

    /// DCF names folders `NNNXXXXX` (100GOPRO, 100MSDCF…), but plenty of devices
    /// ignore that and use their own (DJI_001, Insta360). Match on a contained
    /// token so both styles work.
    private static let folderTokens: [(token: String, brand: String)] = [
        ("GOPRO", "GoPro"),
        ("DJI", "DJI"),
        ("MSDCF", "Sony"),      // Sony's DCF signature
        ("SONY", "Sony"),
        ("CANON", "Canon"),
        ("EOS", "Canon"),
        ("NIKON", "Nikon"),
        ("NCD", "Nikon"),
        ("OLYMP", "Olympus"),
        ("PENTX", "Pentax"),
        ("FUJI", "Fujifilm"),
        ("LUMIX", "Panasonic"),
        ("PANA", "Panasonic"),
        ("APPLE", "Apple"),
        ("ANDRO", "Android"),
        ("PXL", "Android"),
        ("INSTA", "Insta360"),
        ("SIGMA", "Sigma"),
        ("LEICA", "Leica"),
        ("RICOH", "Ricoh"),
        ("CASIO", "Casio"),
        ("SAMSG", "Samsung"),
        ("SAMSUNG", "Samsung"),
        ("GARMIN", "Garmin"),
    ]

    /// Filename prefixes, used when the folder name gives nothing away
    /// (100MEDIA and friends). Deliberately excludes ambiguous ones such as
    /// `IMG_`, which both Apple and Canon use.
    private static let filePrefixes: [(prefix: String, brand: String)] = [
        ("GX", "GoPro"), ("GH", "GoPro"), ("GOPR", "GoPro"),
        ("GL", "GoPro"), ("GP", "GoPro"), ("GS", "GoPro"),
        ("DJI_", "DJI"),
        ("MVI_", "Canon"), ("_MG_", "Canon"),
        ("DSCF", "Fujifilm"),
        ("DSC", "Sony"),
        ("PXL_", "Android"), ("VID_", "Android"),
        ("LRM_", "Insta360"), ("IMG_E", "Apple"),
    ]

    /// - Parameters:
    ///   - folder: the DCIM subfolder name, e.g. "100GOPRO" or "DJI_001".
    ///   - fileNames: what's inside it, used only when the folder name is generic.
    ///   - attached: the connected camera, used only for folders it recorded itself.
    ///   - isNative: true when the camera's own media list claims this folder.
    static func identify(folder: String,
                         fileNames: [String],
                         attached: CameraInfo?,
                         isNative: Bool) -> DeviceIdentity {

        // The camera can name its own footage precisely; nothing else can.
        // Only trust it for folders the camera itself reports, so a card written
        // by a different body isn't relabelled with this one's model.
        if isNative, let attached {
            return DeviceIdentity(brand: "GoPro", model: attached.model, isAttachedCamera: true)
        }

        let haystack = folder.uppercased()
        for entry in folderTokens where haystack.contains(entry.token) {
            return DeviceIdentity(brand: entry.brand, model: nil)
        }

        // Fall back to what the files are called.
        var tally: [String: Int] = [:]
        for name in fileNames {
            let upper = name.uppercased()
            for entry in filePrefixes where upper.hasPrefix(entry.prefix) {
                tally[entry.brand, default: 0] += 1
                break
            }
        }
        if let winner = tally.max(by: { $0.value < $1.value })?.key {
            return DeviceIdentity(brand: winner, model: nil)
        }

        // Nothing recognisable: the folder name is still more useful than "Unknown".
        return DeviceIdentity(brand: folder, model: nil)
    }

    /// Proxies, thumbnails and sidecars -- worth showing on the mount, but not
    /// usually worth copying alongside the real footage.
    static let sidecarExtensions: Set<String> = ["lrv", "lrf", "thm", "wav", "sav", "trinf"]

    static func isSidecar(_ name: String) -> Bool {
        sidecarExtensions.contains((name as NSString).pathExtension.lowercased())
    }
}
