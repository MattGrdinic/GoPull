# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

**GoPull** is a macOS app that makes a USB-tethered GoPro (a **MISSION 1 PRO**) usable as if
it were an external drive, plus a set of Python CLI tools that do the same thing without the
app. The app target, module and product are all `GoPull`; the type `GoProCamera` and the many
"GoPro" strings refer to the camera itself and are correct as they stand.

The problem it solves: modern GoPros do **not** present as USB mass storage. Plugging one
in raises a *USB Ethernet (NCM)* interface and the camera serves HTTP on port 8080. So the
card can only be reached over the network, not through the filesystem — until you put a
WebDAV server in front of it, which is what this project does.

Deep documentation lives in [docs/](docs/): [ARCHITECTURE.md](docs/ARCHITECTURE.md) for how
it works, [DECISIONS.md](docs/DECISIONS.md) for why it's built this way, and
[TESTING.md](docs/TESTING.md) for how to verify changes against real hardware.

## Commands

```bash
# Build
xcodebuild -project GoPull.xcodeproj -scheme GoPull -configuration Debug -destination 'platform=macOS' build

# Test (unit tests only; the UI test target launches the app)
xcodebuild test -project GoPull.xcodeproj -scheme GoPull -destination 'platform=macOS' -only-testing:GoPullTests

# A single test
xcodebuild test -project GoPull.xcodeproj -scheme GoPull -destination 'platform=macOS' -only-testing:GoPullTests/GoPullTests/example

# Release build + install
xcodebuild -project GoPull.xcodeproj -scheme GoPull -configuration Release -destination 'platform=macOS' -derivedDataPath /tmp/gopull-dd build
rm -rf /Applications/GoPull.app && cp -R /tmp/gopull-dd/Build/Products/Release/GoPull.app /Applications/
```

`GoPullTests` uses **Swift Testing** (`@Test`); `GoPullUITests` uses XCTest.

The Python CLI equivalents live in [tools/](tools/) and need no build step — see
[tools/README.md](tools/README.md).

## Architecture

Understanding this codebase means understanding one unusual data path.

**Discovery.** GoPro Connect assigns the Mac `x.x.x.55` and keeps `x.x.x.51` for the camera,
always inside `172.16.0.0/12`. `GoProCamera.candidateAddresses()` walks `getifaddrs`, derives
every plausible `.51`, and probes `/gopro/camera/info`. Nothing is hardcoded, so it survives
reconnects and other GoPro models.

**The mount.** `WebDAVServer` is a small HTTP server on `127.0.0.1` (an `NWListener` from
Network.framework). `MountController` then runs `/sbin/mount_webdav` against it. macOS's
*built-in* WebDAV client does the actual mounting — there is no macFUSE, no kernel extension
and no `sudo` anywhere.

**The redirect, which is the key design point.** The server answers `OPTIONS` and `PROPFIND`
itself, but answers `GET`/`HEAD` with a **302 to the camera's own file server**. macOS follows
the redirect *and re-sends its `Range` header*, so clip data flows straight from camera to
kernel and never passes through this process. That is why a 500 MB clip is never buffered and
why seeking stays as fast as reading the camera directly. Do not "fix" this into a proxy.

**Read-only is deliberate.** The server advertises `DAV: 1` only (no class 2 / locking) and
returns 403 for every mutating method. That combination is what makes macOS mount the volume
read-only, which in turn means footage can't be deleted by accident and macOS won't try to
write `.DS_Store` to the card.

**Importing is a separate, faster path.** `Importer` downloads via parallel HTTP range
requests (8 MB chunks, 4 in flight) — about 51 MB/s versus ~40 MB/s for a single stream. It
writes through `pwrite` at offsets into a preallocated `.part` file, so a failure never leaves
a corrupt clip in place.

### Files

| file | role |
|---|---|
| `GoPull/GoProCamera.swift` | `actor` — discovery, media list, camera state. The only thing that talks to the camera's API. |
| `GoPull/WebDAVServer.swift` | The WebDAV server and its HTTP connection handling (`Peer`, at the bottom of the file). |
| `GoPull/MountController.swift` | `mount_webdav` / `umount`, and mount detection via `statfs` (`f_fstypename == "webdav"`). |
| `GoPull/Importer.swift` | `@MainActor ObservableObject` — the parallel range downloader and its progress. |
| `GoPull/AppModel.swift` | `@MainActor` singleton (`AppModel.shared`) wiring polling, mounting and importing together. |
| `GoPull/GoPullApp.swift` | App entry, `MenuBarExtra`, and the `AppDelegate` that starts polling and unmounts on quit. |

`Peer` is `fileprivate`-coupled to `WebDAVServer`, so it has to stay in the same file.

## Versioning and branching

**Semver, and `MARKETING_VERSION` is the only copy of it.** `tools/version` is the only thing that
writes it — never hand-edit the version in the pbxproj, and never add a second copy anywhere.
`AppVersion` reads it back from the bundle, so the app, the bundle and the tag stay in step.

```bash
tools/version              # show    tools/version minor    # bump
tools/version set 1.4.2    # exact   tools/version tag      # print the tag command
```

**Work happens on a release branch, in pieces.** `main` is always releasable.

* `feature/X.Y.Z` — one release's worth of work, branched off `main`.
* `feature/X.Y.Z-<thing>` — one feature or fix, branched off *that*, merged back with `--no-ff`.
  A **hyphen**, never a slash: git cannot hold both `feature/1.2.0` and `feature/1.2.0/thing`,
  because the first is a ref file and the second needs it to be a directory.
* Bump the version on the release branch as its own commit when the work is done.
* PR the release branch into `main`; its description is the release notes.
* After merge, tag `main` with `vX.Y.Z` and cut the GitHub release.

Pick the bump by what changed: **minor** for a new capability, **patch** for fixes, **major** for
something that breaks existing use. Full detail in [docs/RELEASING.md](docs/RELEASING.md).

**Tagging and releasing are the user's to run**, not something to do unprompted — pushing a tag is
outward-facing. Prepare the version bump and the PR description; let them press the button.

## Project-specific gotchas

**App Sandbox must stay off.** A sandboxed child process cannot mount a filesystem, so
`mount_webdav` fails outright. `ENABLE_APP_SANDBOX = NO` in the project is load-bearing.
Hardened Runtime is on and is fine — verified that a Hardened-Runtime-signed binary can still
bind the listener and mount.

**`import Combine` explicitly.** The project enables
`SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY`, so SwiftUI's re-export of Combine is *not*
enough. Any file declaring `ObservableObject` must import Combine or you get a confusing
"does not conform to protocol 'ObservableObject'" error at the *use* site, not the declaration.

**`Info.plist` lives at the repo root, not in `GoPro/`.** The project uses Xcode 16+
file-system-synchronized groups (`objectVersion = 77`), so *everything* in `GoPro/` is added
to the target automatically. That's convenient for new `.swift` files — just create them, never
hand-edit the pbxproj — but a plist in there lands in Copy Bundle Resources and warns. The
plist only carries the ATS exception (the camera is plain HTTP); Xcode still generates and
merges the rest.

**The mount belongs to the process.** The WebDAV server runs inside the app, so quitting
unmounts the volume — `applicationWillTerminate` does this on purpose rather than stranding a
dead volume in Finder. Any change that could kill the app mid-session breaks a live mount.

**`df` reports the volume as 0 bytes and that is not a bug.** macOS's WebDAV client only ever
requests `getlastmodified`, `getcontentlength`, `creationdate` and `resourcetype` — it never
asks for the RFC 4331 quota properties. The server serves them correctly anyway for other
clients. Confirmed by instrumenting the request stream; don't re-investigate.

**Never call `statfs` or `umount` on the main actor.** Both can block on a WebDAV volume whose
server has gone — exactly the unplugged-camera case — and blocking the main actor beachballs
the UI. `AppModel` routes them through `Task.detached` and only mutates published state back on
the main actor. `unmountForShutdown()` is the one deliberate exception, because blocking during
`applicationWillTerminate` is both acceptable and necessary.

**Don't use `URLSession.shared` for camera traffic.** Its resource timeout defaults to seven
days, which means requests survive the cable being pulled. `Importer` has its own session with
15s request / 60s resource timeouts; `GoProCamera` likewise.

**`AppModel` owns the import `Task`, not `Importer`.** Cancellation needs something to cancel:
an earlier version stored the task on `Importer` but never assigned it, which made both the
Cancel button and disconnect-cancellation silently do nothing. If you move import orchestration
around, keep the task where it can actually be cancelled.

**Cancellation makes every `await` throw, including inside `refresh()`.** `refresh()` bails on
`Task.isCancelled` and swallows `CancellationError` for exactly this reason: without it,
cancelling an import made the app conclude the camera had vanished, which also fed the
auto-eject path. Any handler that infers *state of the world* from a failed await must rule out
cancellation first.

**Never touch the camera's control API during an import.** With the importer's four range
streams in flight, `/gopro/media/list`, `/videos/DCIM/` *and* `/gopro/camera/keep_alive` all take
the full 15s timeout and fail. Three of those in a row used to trip `handleMissedPoll()`, which
cancelled the import and reported it as an unplugged camera — so every clip longer than ~50s of
transfer failed while short ones worked. `refresh()` now returns early on `importer.isRunning`;
the import is its own liveness check. A cheap `keepAlive()` ping is *not* a safe substitute.

**`import AVKit` does not link `AVKit.framework`.** It autolinks the `_AVKit_SwiftUI` shim only,
so SwiftUI's `VideoPlayer` crashes on first render with `SIGABRT` in `getSuperclassMetadata`.
`PreviewWindow.swift` wraps `AVPlayerView` directly, which is a hard symbol reference and pulls
AVKit in. Check `otool -L` before suspecting SwiftUI.

**Never bind a `@Published` property to `List(selection:)`.** The List writes the new value back
*while it is updating rows*, so `objectWillChange` fires mid-update: "Publishing changes from
within view updates is not allowed" — 14 times per click on a 12-row list, and SwiftUI then
re-runs the update, which is what made clicking a second row feel slow or not highlight at all.
`ContentView` keeps selection in `@State` and mirrors it to `AppModel.selection` in `onChange`,
which runs after the update. Measure it: `log show --predicate 'eventMessage CONTAINS "Publishing
changes"'` — it must be 0.

**No gestures on a `List` row — put clickable things in a `Button`.** Selecting clips and
double-clicking one to preview compete for the same click. `.onTapGesture(count: 2)` stops
selection entirely (it outranks the gesture `List(selection:)` uses), and so does
`.contentShape(Rectangle())`. `.simultaneousGesture` alone keeps selection working but only over
the row's *content*, so the name and thumbnail arbitrate the click while the white space beside
them does not — half the row feels responsive and half does not. The row now carries no gesture;
the thumbnail is a real `Button`, which handles its own click and leaves selection alone. All of
this breaks silently, and none of it reproduces under synthesised clicks — check by clicking every
region of a row by hand.

**Preview traffic is import traffic.** Thumbnails and `/gopro/media/info` use the same control
API that must stay untouched during an import, and playback would be a fifth stream. `PreviewStore`
suspends and `ContentView` disables preview while `importer.isRunning`.

**The exporter composes in one place on purpose.** `composite` used to have two
`OverlayComposer.draw` calls, and the burn-in one was missing `extremes:` and `runs:`. Both
have defaults, so it compiled and silently dropped the g-force peak marks and the whole launch
badge from every burned-in export while the editor preview looked right. Both paths now share
one call. If you add overlay state, it flows to preview and export together or not at all.

**Time launches on the raw track, and anchor to the rest *before the departure*.** Smoothing is
a drawing tool: a trailing average delays every threshold crossing by about half its window and
fills in the dip between two back-to-back launches, so at the default 0.5s the two runs in
`GX010050` came back as one. Separately, `runs()` used to time from the first stretch of rest it
found rather than the one the launch actually left — two samples of GPS noise reported a
3.3-second 0-30 as 10.05s. The accelerometer is smoothed *inside* the detector, by a fixed
0.1s, so a reported 0-60 doesn't move when the display slider does. Detail in DECISIONS #27.

**Deleting is irreversible and the card has no trash.** The confirmation names the shots and
splits them into backed (a verified full-size copy in the destination) and unbacked; a shot is
only backed when every file of it is, so an unimported GPR keeps its JPEG's row in the warning.
`DeletionPlan` sits outside `AppModel` and takes an `isBacked` closure so it can be tested
without the singleton. Delete is a context-menu item, the destructive button is not the default
action, and it is disabled during an import.

**Camera present with no card looks like no camera.** `/gopro/media/list` fails either way.
`refresh()` disambiguates with `keepAlive()`; don't collapse those branches.

**The camera will hand over telemetry without the clip.** `/gopro/media/telemetry?path=` returns
the GPMF alone as a small MP4 — about 1.3 MB per minute of footage, 8.6 MB and 0.66s for a
six-minute clip — so the list can say whether a clip has GPS before an 11 GB copy. It is on the
control API, so it queues behind thumbnails in `PreviewStore` and stands down during an import
like everything else there.

**Adding a field to `OverlaySettings` used to reset everyone's saved look.** Swift's synthesised
`Codable` requires every key, so previously saved settings failed to decode and fell back to the
defaults with nothing said. `OverlaySettings.load()` merges the stored JSON over the JSON of the
defaults instead, so a missing key at any depth keeps its default. Nothing needs updating when the
next overlay is added — but if you hand-write `init(from:)` for one of these types, you take that
protection away.

**Two filters decide what counts as a launch, and they surprise people.** A run must reach the
*lowest* target — 30 mph by default, so a clip that never exceeds 25 reports nothing — and must
average `minimumRate` getting there. A trail ride with eight stops produced zero launches for both
reasons at once. `AccelerationDetector.diagnose` exists so the UI can say which of the two it was
rather than "none found".

**A standing start is not just "speed left zero".** Speed hovers around zero and one noisy sample
above the threshold made an entire clip read as a single 45-second run. Departure has to *hold*,
and a run that averages under ~1.5 mph/s to its first target is someone pulling away gently, not a
launch. Both thresholds are in `AccelerationSettings`.

**Time launches from the accelerometer, not the GPS.** GPS speed leaves zero slowly and noisily at
10 Hz; the 200 Hz accelerometer sees the push immediately. On a real launch that moved the start
0.22s earlier — 5% of a 4.35s time. Crossings are still GPS, interpolated between the bracketing
pair, which halves the 100 ms quantisation.

**ACCL includes gravity, and its axes are not what ORIN says.** A still camera reads 1 g, so
gravity is estimated by low-passing the signal and subtracted — which also makes it independent of
how the camera is mounted. The stream's `ORIN` is `ZXY` while the gravity stream carries none, and
their dominant axes disagree, so neither is trusted. The mapping was established from a real ride
instead: axis 0 is vertical (9.76 m/s² average), axis 1 is lateral (r = −0.542 against
v·dHeading/dt) and axis 2 is longitudinal (r = −0.431 against GPS d(speed)/dt), all sign-flipped.
Re-derive it the same way before assuming it holds for a different mount.

**Scale the g-meter from the smoothed track, not the raw one.** A single bump put the raw peak at
2.82 g against 1.01 g smoothed, and full scale at 4 g left the ball in the middle for a whole ride.

**GPR is a DNG that macOS cannot decode.** ImageIO reports a `.GPR` as
`com.adobe.raw-image`, reads every DNG tag out of it, and then fails to produce a single pixel or
a thumbnail — the tile is VC-5 compressed. `GPRConverter` decodes it with GoPro's decoder,
vendored in `GoPull/VC5/`, and rewrites the same tag set with an uncompressed tile. Adobe's DNG
SDK (104k lines, also in that repo) is deliberately *not* vendored; the container is rewritten by
hand instead.

**Two vendored files are renamed on purpose.** `vc5_common/syntax.c` and `vc5_common/wavelet.c`
became `vc5_common_syntax.c` and `vc5_common_wavelet.c`, because Xcode derives object names from
the basename and `vc5_decoder` has files of the same name. The directory layout is otherwise kept
so `#include "syntax.h"` still resolves to the right header.

**`vc5_decoder_parameters_set_default` does not set the allocator.** `mem_alloc` and `mem_free`
are left as whatever was on the stack, so the decoder segfaults on its first allocation. Set them.

**Camera must be in "GoPro Connect" USB mode**, not MTP, or nothing is discoverable.

## Testing against real hardware

The interesting code paths need a camera attached, and the app's buttons can't be clicked from
automation. The established approach is to compile the non-UI sources into a throwaway CLI
harness with `swiftc` and drive them directly — see [docs/TESTING.md](docs/TESTING.md) for the
exact invocation and the pitfalls (notably: a harness `main.swift` must call `dispatchMain()`,
because blocking the main thread deadlocks all `@MainActor` work).

Note that plain `swiftc -swift-version 5` does **not** enable bare-slash regex literals, while
the Xcode build does pass `-enable-bare-slash-regex`. Code shared with the harness should avoid
regex literals.
