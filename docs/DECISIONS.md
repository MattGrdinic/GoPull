# Decisions

Why the project is built the way it is, including the options that were tried and rejected.

---

## 1. Mount the camera rather than only copying from it

**Decision.** Make the card appear as a mounted volume, with copying as a second, separate path.

**Why.** The goal was editing in DaVinci Resolve straight off the camera, the same way an
external drive is used. Measurement showed this is realistic: the USB link sustains ~40 MB/s
(≈320 Mbit/s) on a single stream, comfortably above the bitrate of a single GoPro stream, and
seeks resolve in ~0.12s.

**Caveat kept in the docs.** A mount is excellent for browsing and quick edits, but a
multi-hour grade shouldn't depend on a USB cable staying seated. Bulk ingest still copies.

---

## 2. macOS's built-in WebDAV client, not macFUSE

**Decision.** Serve WebDAV on loopback and mount it with `/sbin/mount_webdav`.

**Alternatives rejected:**

* **macFUSE + `rclone mount`.** Works, but needs a kernel extension, which on Apple Silicon
  means reduced-security boot and a reboot. Far too heavy for "read my camera".
* **MTP / Image Capture.** The camera exposes GoPro Connect, not mass storage, and macOS has
  no native MTP filesystem. Image Capture gives no mountable volume.
* **A raw TCP proxy.** Can't work — WebDAV needs synthesised `PROPFIND` responses; there is
  nothing to proxy them from.

**Why this wins.** Zero install: no Homebrew, no kernel extension, no reboot, and no `sudo`
(an unprivileged user can mount as long as they own the mount point). It runs on frameworks
already present on the machine.

---

## 3. Redirect `GET` to the camera instead of proxying it

**Decision.** Answer `OPTIONS` and `PROPFIND` in-process; answer `GET`/`HEAD` with a `302`
pointing at the camera's own file server.

**How it was decided.** This was tested before committing to it, because it hinges on client
behaviour that isn't guaranteed. macOS's WebDAV client *does* follow the redirect, and — the
part that actually matters — it **re-sends its `Range` header** on the redirected request.
Verified byte-for-byte: MD5 through a redirecting mount matches the camera exactly.

**Why it matters.** Video data never enters the app. There is no streaming proxy, no
backpressure handling, and no risk of buffering a 500 MB clip in memory. Reading through the
mount is as fast as reading the camera directly.

**Trade-off accepted.** It depends on redirect-following behaviour in `webdavfs`. If a future
macOS stopped following redirects, the fallback is the proxying implementation that already
exists in `tools/gopro_webdavd.py`.

---

## 4. Read-only, deliberately

**Decision.** Advertise `DAV: 1` only, and return `403` for every mutating method.

**Why.** macOS decides a WebDAV volume's writability by probing for lock support. Advertising
class 1 makes it mount read-only, which gives two things at once: footage cannot be deleted
from the card by accident, and macOS never writes `.DS_Store` or AppleDouble files onto it.
Write support was never a requirement — the camera is a source, not a destination.

---

## 5. Native Swift rather than bundling the Python tools

**Decision.** Reimplement the whole stack in Swift for the app; keep the Python CLI as a
separate, still-working tool.

**Why.** Shipping an app that shells out to `python3` would make it depend on Command Line
Tools being installed and on a Python that Apple has been steadily deprecating. The Swift
version is self-contained.

**Why the Python tools were kept.** They were written and verified first, they're useful for
scripting an ingest, and `gopro_webdavd.py` is a working reference implementation of the
proxying approach should the redirect ever stop working.

---

## 6. App Sandbox off, Hardened Runtime on

**Decision.** `ENABLE_APP_SANDBOX = NO`.

**Why.** A sandboxed child process cannot mount a filesystem, so `mount_webdav` fails. There
is no entitlement that grants this to a sandboxed app; the feature is simply incompatible with
sandboxing. Since this is a personal tool rather than a Mac App Store submission, disabling the
sandbox is the correct trade.

**What was verified.** Hardened Runtime stays enabled. A Hardened-Runtime-signed binary was
tested explicitly and can still bind a local listener and spawn `mount_webdav`, so the
remaining hardening is not just cosmetic.

---

## 7. Parallel range requests for importing

**Decision.** 8 MB chunks, 4 in flight, written with `pwrite` into a preallocated `.part` file.

**Why.** Measured: a single stream gets ~40 MB/s, four parallel streams ~60 MB/s. The real
importer achieves 51 MB/s on a 495 MB clip. Chunking at 8 MB bounds memory at ~32 MB no matter
how large the clip is, and gives natural retry granularity (each chunk retries independently,
3 times). `pwrite` is thread-safe at an offset, so no seek/lock coordination is needed.

**Safety property.** The download lands in `.part` and is only renamed once the final size
matches, so an interrupted or failed import can never leave a corrupt clip in the destination.

---

## 8. Serve `.metadata_never_index`

**Decision.** The server exposes an empty `.metadata_never_index` at the volume root.

**Why.** Instrumenting `webdavfs` showed it probes for this file at mount time. Serving it
stops Spotlight from indexing the volume — otherwise `mds` would pull every clip across the
USB link just to index it. Cheap insurance against a very slow surprise.

---

## 9. Accept that `df` reports 0 bytes

**Decision.** Leave it. Serve the RFC 4331 quota properties anyway.

**Why.** Instrumenting the request stream showed macOS's WebDAV client requests exactly four
properties — `getlastmodified`, `getcontentlength`, `creationdate`, `resourcetype` — and never
asks for `quota-available-bytes`. It therefore has no way to learn the card's size. This is a
client limitation with no server-side fix. It is cosmetic: reading files is unaffected. The
properties are still served correctly for other WebDAV clients.

---

## 10. Discover the camera instead of hardcoding its address

**Decision.** Derive candidates from local interfaces and probe them.

**Why.** GoPro Connect assigns the Mac `x.x.x.55` and the camera `x.x.x.51` within
`172.16.0.0/12`, but the specific subnet derives from the camera's serial. Hardcoding
`172.24.113.51` would break on a different camera, and potentially on a reconnect. Walking
`getifaddrs` and probing `/gopro/camera/info` costs one round trip and keeps the tool generic
across GoPro models.

---

## 11. Poll from `applicationDidFinishLaunching`

**Decision.** Start polling at app launch, not from a view's `onAppear`.

**Why.** The app has a `MenuBarExtra` and deliberately survives its window being closed
(`applicationShouldTerminateAfterLastWindowClosed` returns `false`). Tying discovery to a
window appearing would leave the menu bar item dead in exactly the configuration it exists to
serve.

---

## 12. Unmount on quit

**Decision.** `applicationWillTerminate` tears the mount down.

**Why.** The WebDAV server runs inside the app process. If the app exits with the volume still
mounted, Finder is left with a volume pointing at a port nothing is listening on — it hangs on
access and needs a manual `umount -f`. Unmounting deliberately is the lesser evil. The
consequence, documented for users, is that the app must stay running while the volume is in use.

---

## 13. Icon: geometric masking, not colour keying

**Decision.** Locate the artwork by measuring its edges, take the largest centred square, and
mask it with a superellipse (n≈5) fitted to Apple's 824/1024 icon grid.

**Why.** The supplied source was a 1024² render with **no alpha** — a rounded rectangle on a
flat grey field. The first attempt flood-filled the background by colour from the edges, which
failed: the artwork's own lower half fades to near-white and is indistinguishable from the grey
background, so the fill ate into the icon and left a ragged edge. Colour alone cannot separate
them. Measuring the shape and masking it sidesteps the problem entirely and produces the
Apple-style corners as a side effect. The generator is kept so it can be re-run on a new source.

---

## 14. Eject the volume when the camera disappears, after a delay

**Decision.** Three consecutive failed polls (~9s) trigger an automatic unmount.

**Why not immediately.** One dropped poll is not a disconnected camera. Tearing down a working
mount because of a transient blip would be worse than the problem.

**Why not never.** A WebDAV volume whose server can no longer reach the camera is worse than no
volume: Finder blocks on access to it, and clearing it by hand needs `umount -f`. Ejecting is
the kinder failure.

**The subtle part.** `statfs` and `umount` can themselves block on such a volume. Running them
inline on the main actor would beachball the UI in exactly the situation this code exists to
handle, so both are dispatched to a detached task with only the state update back on the main
actor. This was caught while reviewing the first version of the fix, not from a crash.

---

## 15. Stop an import when the camera goes, rather than failing every clip

**Decision.** After any file fails, probe with `keepAlive()`. If the camera is gone, record
`ImportError.disconnected` and break out of the loop.

**Why.** Without the probe, a mid-import disconnect makes every remaining clip fail
individually — each one burning three retries and a backoff — and produces a wall of errors
that hides the actual cause. Stopping immediately reports one accurate message and says how
many clips made it. The `.part` file discipline means nothing partial is left behind either way.

---

## 16. "No card" is not "no camera"

**Decision.** When the media list fails, probe the camera before declaring it absent.

**Why.** Both situations surface as the same failed request, but they are not the same problem
and the fixes are different — one is "plug the camera in", the other is "put a card in". A
camera that answers `/gopro/camera/info` and keep-alive is plainly present, so the app keeps it
identified and says "No SD card detected in the camera."

**How it was found.** By accident: a card was pulled during testing and the app reported the
camera as missing while it was sitting there responding to HTTP. Worth recording because the
misleading state was only obvious with the hardware in front of us.

---

## 17. Per-camera import folders keyed by serial number

**Decision.** An optional "Camera folders" checkbox inserts a folder named after the camera
model, with a user-set number to distinguish two bodies of the same model. The number is stored
against the camera's **serial number**, not its name or address.

**Why serial.** It's the only stable identifier. The IP derives from the serial but could
collide conceptually across setups, and the model name is by definition shared between
identical bodies — which is the exact case this feature exists to solve.

**Why `#1` is omitted from the folder name.** The overwhelmingly common case is one camera.
`~/Movies/GoPro/MISSION 1 PRO/` reads better than `MISSION 1 PRO 1`, and a second body can be
added later without renaming the first one's folder.

**Ordering.** Camera folder is the outer level and date the inner (`<dest>/<camera>/<date>/`),
so each camera's footage stays contiguous — which is the point of separating them at all.

---

## 18. Cancellation lives in `AppModel`, and the camera gets its own URLSession

**Decision.** `AppModel` holds the import `Task`; `Importer` uses a dedicated `URLSession` with
15s request and 60s resource timeouts.

**How this came up.** Yanking the cable mid-import during testing left an orphaned `.part` file
behind, which contradicted the "nothing partial is left behind" claim. Investigating it turned
up three separate bugs rather than one:

1. `Importer` declared `private var task: Task<Void, Never>?` and a `cancel()` that used it —
   but nothing ever assigned it, because `run()` was awaited directly. **The Cancel button had
   never worked.** Nothing failed loudly; it just quietly did nothing.
2. Chunk fetches used `URLSession.shared`, whose resource timeout is **seven days**. Requests
   in flight when the cable came out kept hanging, so the import ground on for a long time
   after the UI had correctly reset to "looking for a GoPro".
3. Nothing connected the two: polling detected the disconnect but never told the importer.

So the import was still alive, holding an open `.part`, when the app was quit — and its cleanup
never ran.

**The fix.** The task moved to `AppModel`, which is what the Cancel button and the disconnect
path both talk to; timeouts became realistic for a device on the end of a pullable cable; and
orphaned `.part` files for known clips are swept before each import, so a process that dies at
the wrong moment heals on the next run instead of leaving litter forever.

**Worth remembering.** The orphan was *sparse* — `ftruncate` preallocates, so it occupied no
real disk space despite reporting 519 MB. The bug was real, but the cost of it was not what the
file listing suggested.

---

## 19. A cancelled task must not be allowed to report a missing camera

**Decision.** `refresh()` returns immediately when its task is cancelled, and treats
`CancellationError` as "nothing to see here" rather than as a disconnect. `importFiles` skips
its trailing refresh when cancelled.

**How this came up.** After wiring up cancellation (see 18), cancelling an import left the app
believing the camera had vanished. The cause: `importFiles` ends with `await refresh()`, and it
ran *inside the very task that had just been cancelled*. In a cancelled task every `await`
fails, so discovery and the media list both failed, and `refresh()` faithfully concluded the
camera was gone.

**Why it mattered more than it looked.** That path also feeds `handleMissedPoll()`, so a few
cancellations in a row could have counted toward the disconnect threshold and **ejected a
perfectly healthy mounted volume**. A cosmetic-looking bug with a genuinely destructive tail.

**The general lesson.** Cancellation makes every `await` throw. Any error handler that infers
*state of the world* from a failed await needs to rule out cancellation first.

---

## 20. The orphan sweep scans the destination, not the card

**Decision.** `removeOrphanedParts()` walks the destination for `*.part` files whose underlying
name has a media extension, rather than deriving paths from the clips currently on the camera.

**Why the first version was wrong, twice over.** It matched `.part` files against the camera's
current clip list, and it sat *behind* the "nothing to import" guard. Both failures shared a
cause — I wrote it for the case I was imagining rather than the case that produces orphans:

* Format or swap the card and the orphan no longer matches anything, so it survives forever.
* "Everything already imported, nothing new" is precisely the state a leftover `.part` leaves
  behind, and that was the one state where the sweep never ran.

**Safety.** Only `<name>.<media-ext>.part` is removed, so an unrelated `notes.txt.part` or
`archive.zip.part` in the same folder is left alone — verified with decoys.

---

## 21. Polling stands down completely while an import runs

**Decision.** `refresh()` returns immediately when `importer.isRunning`. During an import the app
does not call `cardTree()`, `freeBytes()` or even `keepAlive()`. The import is its own liveness
check.

**The bug this fixes.** Any clip that took longer than about 50 seconds to transfer failed, every
time, with *"The camera was disconnected — the import stopped after 0 of 1 clip(s)."* Short clips
always worked. The camera was never disconnected.

**What was actually happening**, measured on a MISSION 1 PRO with an 11.5 GB clip:

```
GET /gopro/media/list      -> URLError -1001 timed out after 15.16s
GET /videos/DCIM/          -> URLError -1001 timed out after 15.00s
GET /gopro/camera/keep_alive -> URLError -1001 timed out after 15.01s   <- camera dropped
handleMissedPoll: missedPolls=1 ... =2 ... =3                           <- cancelImport()
GET /gopro/camera/keep_alive -> URLError -999 cancelled in 0.00s        <- reported as disconnect
```

With the importer's four range streams in flight, the camera's control API stops answering
altogether. Three consecutive 15s timeouts is roughly 50 seconds, which is exactly the threshold
where clips started failing — and why the failure looked size-dependent. `cancelImport()` then
cancelled the import, and the cancelled task made `Importer`'s own `keepAlive()` fail instantly,
which `run()` read as "the camera has gone".

So the app killed its own imports and then blamed the cable.

**Why a cheap ping was not enough.** The first attempt kept polling but reduced it to a single
`keepAlive()`. The trace above shows why that fails too: `keep_alive` takes the full 15s timeout
under load just like the card scan does. Nothing may touch the control API during an import.

**Why giving up liveness detection is safe.** A camera that really is unplugged makes the
importer's own chunk requests fail, and `run()` already distinguishes that case and reports it.
Polling resumes the moment the import ends, so the auto-eject path in
[#14](#14-eject-the-volume-when-the-camera-disappears-after-a-delay) still fires — just from the
next poll rather than during the transfer.

**The general lesson**, and it is the same one as [#19](#19-a-cancelled-task-must-not-be-allowed-to-report-a-missing-camera):
a timeout means *"no answer"*, not *"not there"*. Watchdogs that share a contended resource with
the work they are watching will eventually shoot it.

---

## 22. `pwrite` results are checked

**Decision.** Chunks go through `writeFully()`, which loops on short writes, retries `EINTR` and
throws `ImportError.writeFailed` on error.

**Why.** The write was `_ = pwrite(descriptor, raw.baseAddress, raw.count, off_t(start))` — both
the short-write and the `-1` return were discarded. The completeness check afterwards compared the
file's length against `file.size`, but `ftruncate` had already set that length, so it passed no
matter how many bytes actually landed. A destination that filled up mid-import produced a
full-length, correctly-named, quietly corrupt clip. The check now counts the bytes the chunks
delivered instead.

---

## 23. Preview plays the camera's proxy, and copies nothing

**Decision.** Double-clicking a clip streams it straight off the camera, playing the `.LRV`
proxy that sits beside it on the card rather than the original. Rows also carry a thumbnail and
the camera's own duration, resolution and frame rate.

**Why this is nearly free.** The camera already has everything needed, and none of it is the
clip:

| endpoint | cost, measured |
|---|---|
| `/gopro/media/thumbnail?path=…` | 60 KB JPEG in ~30ms |
| `/gopro/media/info?path=…` | duration, `w`/`h`, `fps`, and `ls` — the proxy's length |
| whole card, 12 clips | 0.6 MB and 1.04s, thumbnails and details together |

And the file server sends `Content-Type: video/mp4` with `Accept-Ranges: bytes`, so AVPlayer
seeks against a file on the card without downloading it. Loading `GL010005.LRV` and decoding a
frame from its midpoint takes 0.03s and 0.01s. The proxy is 364 MB and 960x540 against a 10.7 GB
8K original — playable over USB, where the original would not be.

**Proxies are matched, not constructed.** GoPro names a clip `GX010005.MP4` and its proxy
`GL010005.LRV`. Rather than rebuild that name and hope, `MediaPreview.proxy(for:among:)` matches
the digits against the files actually on the card, which also covers the `GH`/`GS` prefixes older
bodies use and simply finds nothing for a clip written by another device — which then previews at
full resolution instead.

**Preview stands down during an import**, both halves of it: thumbnail requests go to the same
control API that [#21](#21-polling-stands-down-completely-while-an-import-runs) is about, and
playback would open a fifth stream against a camera already serving four. The import wins.

---

## 24. `import AVKit` does not link AVKit

**Decision.** The player is `AVPlayerView` wrapped in an `NSViewRepresentable`, not SwiftUI's
`VideoPlayer`.

**Why, and it is not a preference.** `VideoPlayer` crashed the app with `SIGABRT` the instant the
sheet opened:

```
swift::fatalError
getSuperclassMetadata
_swift_initClassMetadataImpl
_AVKit_SwiftUI  0x1974
```

`import AVKit` autolinks the `_AVKit_SwiftUI` shim but **not `AVKit.framework` itself** —
confirmed with `otool -L`, and confirmed again in the crash report, where `_AVKit_SwiftUI` is
among the loaded images and `AVKit` is not. So `VideoPlayer` resolved its own shim and then died
looking for `AVPlayerView`'s metadata.

Naming `AVPlayerView` in our own code is a hard symbol reference, so the linker brings AVKit
along — `otool -L` now lists it. That also gets the real transport bar (scrubbing, volume,
full-screen) instead of rebuilding one.

**If you ever see `getSuperclassMetadata` in a crash**, check `otool -L` before anything else.
The symptom looks like a SwiftUI bug and is a missing link.

---

## 25. The preview affordance is a Button, not a gesture on the row

**Decision.** The thumbnail is a real `Button`. Double-click via `simultaneousGesture` is kept as
a convenience, but it is not what the feature rests on.

**Why, and this shipped broken once.** Adding preview cost the ability to select clips to import,
which is the app's main job. Three spellings, all tried against the running app:

| on the row | selection | double-click |
|---|---|---|
| `.onTapGesture(count: 2)` | **broken** | works |
| `.contentShape` + `.simultaneousGesture` | **broken** | works |
| `.simultaneousGesture` alone | works, but only evenly on white space | only over real content |
| **nothing** (the shipped answer) | works everywhere | n/a |

A tap gesture on a row outranks the gesture `List(selection:)` relies on, and `contentShape`
loses the click the same way by reshaping the row's hit area.

`simultaneousGesture` alone looked like the answer and was not. A gesture's hit area is the row's
**content**, so clicks on the name and thumbnail went through gesture arbitration while clicks on
the empty space beside them went straight to the List. Half the row felt crisp and half did not —
reported from use as "clicking the labels fails, clicking white areas works", which is exactly the
shape of that hit area. It did not reproduce under synthesised clicks; real mouse input is
arbitrated differently.

So the row carries no gesture at all. Preview has three affordances that cost the row nothing: the
thumbnail is a real `Button`, plus the Preview button and the context menu item.

**It fails silently.** No warning, no crash, no visual difference — rows simply stop highlighting,
or highlight only on part of their area. Anything added to a row has to be checked by clicking
every region of one.

---

## 26. Selection lives in `@State`, mirrored to the model

**Decision.** `ContentView` owns `@State private var selection`, binds *that* to
`List(selection:)`, and mirrors it to `AppModel.selection` in `onChange`. The model stays the
source of truth for importing; it just is not what the List writes into directly.

**The bug.** Clicking a row logged *"Publishing changes from within view updates is not allowed,
this will cause undefined behavior"* — **14 times per click** on a 12-row list. Selecting a second
row was slow, or the row never highlighted.

`List(selection:)` writes the new selection back through the binding *during* its update pass.
Pointed at `@Published var selection`, that fires `objectWillChange` mid-update, SwiftUI discards
and re-runs the update, and the result is the lag.

**It was not the preview feature**, though it surfaced alongside it. Building the commit *before*
preview existed and clicking rows produced the same warnings, which is the check worth doing
before rewriting the thing you touched last.

**Measured, on the same four clicks:**

| | warnings |
|---|---|
| `List(selection: $model.selection)` | 56 |
| `@State` + `onChange` mirror | **0** |

`onChange` runs after the update completes, so the model write is no longer inside it.

**Verifying this needs the log, not the console.** SwiftUI runtime issues go to the unified log,
not stderr:

```bash
log show --last 5m --predicate 'eventMessage CONTAINS "Publishing changes"' --style compact
```

Under Xcode the same warning can pause the app, which is why it looks far worse there than in a
standalone run.

## 27. Launches are timed on the raw track, anchored to the rest before them

Two separate faults, both found on `GX010050` — a clip with two real standing starts that
the app timed as one 7-second run when the rider counted about four.

**The anchor.** `runs()` walked forward to the first sample above `restSpeed`, called that the
end of "rest", and then let `departureIndex` scan on until speed genuinely held above
`movingSpeed`. Those two can be a long way apart. On `GX010050` two samples of GPS noise at
0.1s ended the rest; the bike then sat still until 6.8s and launched; the run was still timed
from 0.1s. A 3.32-second 0-30 was reported as **10.05s**. The clock now starts at the last
sample at rest *before that departure*, found by walking back from it:

```swift
var anchor = departure - 1
while anchor > lastAtRest, speed(anchor) > settings.restSpeed { anchor -= 1 }
lastAtRest = anchor
```

**The smoothing.** Detection ran on the same smoothed track the gauge draws from. A trailing
average is a drawing tool — it exists to settle the needle — and it does two things to a
measurement: it delays every threshold crossing by roughly half its window, and it fills in
the dip between two back-to-back launches. At the default 0.5s, `GX010050`'s two runs came
back as **one**. Detection now takes the raw track at every call site (`OverlayEditor`,
`AppModel`, `TelemetrySummary`); `smoothed()` is only ever applied to what gets rendered.

The accelerometer is the exception, and it is smoothed *inside* the detector by a fixed 0.1s.
Raw at 200 Hz, the noise floor alone can hold 0.02 g for the 20 samples the sustained-push
check asks for, which pins the start early. Doing it in the detector rather than at the call
site also means a reported 0-60 does not move when the display smoothing slider does.

Verified on the card: 0-30 of 3.32s and 4.54s, against interpolated 30 mph crossings at
10.390s and 29.800s and rest ending at 7.07s and 25.26s.

## 28. Deleting names the files, and separates the backed from the unbacked

The camera has no trash. `/gopro/media/delete/file?path=…` is immediate and there is nothing
to undo it with, so the confirmation is a sheet rather than an alert: it lists the shots by
name and splits them into those with a verified full-size copy in the destination and those
without. That split is the only thing that matters — a backed shot can be pulled back from
disk, an unbacked one is the only copy there is — so it drives the warning, the button label
and the ordering.

`DeletionPlan` lives outside `AppModel` and takes an `isBacked` closure, so what the sheet
claims can be tested without the `@MainActor` singleton. A shot counts as backed only when
*every* file of it does, which is what makes a JPEG whose paired GPR never came across still
read as the only copy of that raw.

Delete is on the context menu, not the footer, and the destructive button is not the default
action — it should take a deliberate click, not a stray Return. It is disabled outright while
an import is running, for the same reason nothing else touches the control API then (#12).

Tested against the card: 53 files to 52, the target returning 404 afterwards and every other
file still listed.

Afterwards the store forgets only the files that went, not everything it knows. Clearing it
wholesale — by pushing an empty camera IP through `update(cameraIP:)` — left every remaining
row showing a blank placeholder, because a row asks for its preview from `.task` and that does
not run again for rows that stayed on screen. Deleting one clip says nothing about any other
clip's thumbnail, so there was never a reason to drop them.


## 29. The exporter composes overlays in one place, not two

`composite` had two `OverlayComposer.draw` calls — an early return for the
overlay-only case and another at the end for the burn-in. The second was missing
`extremes:` and `runs:`. Both have defaults (`.init()` and `[]`), so it compiled
and ran, and silently dropped the g-force peak marks and the entire launch badge
from every burned-in export while the editor preview, which passes them, looked
correct. Alpha exports were fine, which made it look like a rendering problem
rather than an argument-passing one.

The two paths now converge on a single `draw`, with the frame copy moved into its
own `copy(_:into:target:size:)`. Adding an overlay that needs new state can no
longer light up in the preview and go missing in the export.

The badge's unreached rows showed the running clock, dimmed. Mid-launch that read
`0-60 mph  2.33s` on a bike that never saw 60 mph in the clip — the dimming is not
enough to say "this has not happened". The clock already ticks on the LAUNCH line,
so unreached targets now show a dash.

`AccelerationConfig.holdSeconds` was declared and never read; a hardcoded `+ 3` in
`run(at:)` decided how long the result stayed up. `run(at:hold:)` takes it now.

Verified by exporting GX010050 and sampling frames: at 12.0s the panel reads
LAUNCH 4.83s / 0-30 mph 3.35s / 0-60 mph —, and the g-meter carries its red ticks
and peak figures.


## 30. G-force peaks are what has happened, not what will

The peak marks were the whole clip's extremes, computed once and drawn on every
frame. That is a spoiler and it is also not a peak: a mark sitting at 1.14 g from
the first frame gives away a corner a minute away, and never moves, so it reads as
decoration rather than a record.

`GForceTrack.RunningExtremes` is a prefix maximum over the track: `at(time)` gives
what had been reached by then, so a mark appears at the moment it is set and holds
until it is beaten. Bucketed at 20 Hz, because the values only ever climb and a
bucket therefore costs at most 50 ms of freshness -- under two frames. Per sample
instead, a ten-minute clip at 200 Hz would carry 120,000 entries; at 20 Hz it is
12,000. Lookup is a binary search, so the per-frame cost is a handful of compares.

The meter's *scale* stays whole-clip. A full scale that grew during playback would
move the ball without the bike doing anything.

Verified on GX010050: the four figures climb through the clip, never fall, and end
exactly equal to `extremes` for the whole track.

## 31. The launch badge can count in

`showsCountdown` brings the panel up for `countdownSeconds` before a detected run
and shows the time remaining, red for the last second.

It earns its place twice. For a viewer it says a run is coming, which a badge that
appears at the same instant as the launch cannot. For us it makes the detected
start *observable*: the count reaching zero while the bike is still stationary is
exactly the smoothing-and-latency error that #27 was about, and now it can be seen
in the footage and measured rather than inferred from numbers in a panel. That is
why the countdown shows tenths rather than whole seconds.

`run(at:hold:lead:)` carries the window; the renderer draws the count-in state when
`elapsed` is negative and returns before the target rows, so a run's splits never
appear before it starts.


## 32. Gravity comes from GRAV, not from a low pass

The g-meter read 0.03 g during a 2.2-second 0-30 that really pulled 0.6 g.

Gravity was estimated by low-passing ACCL over one second and subtracting it.
That cannot work, and not because the window was wrong: a low pass cannot tell
gravity from a sustained acceleration, and a standing start is precisely a
sustained acceleration. A one-second average of a two-second pull *is* the pull.
Measured on GX010053, the fraction of a real 0.63 g that survived was 4% at a
one-second window, 27% at five seconds, 40% at twenty. There is no window that
fixes it.

The camera ships `GRAV`, a gravity unit vector at 30 Hz, which is the right
input. Its axes are ordered differently from ACCL's, which is what the old note
about the two streams disagreeing was seeing. The pairing was established by
taking the clip-average residual for all nine combinations: the bike averages no
acceleration over four minutes, so the correct pairing is the one that leaves
nothing behind.

|         | GRAV0  | GRAV1  | GRAV2  |
|---------|--------|--------|--------|
| ACCL0   | +1.044 | **+0.034** | +0.952 |
| ACCL1   | **+0.022** | -0.988 | -0.071 |
| ACCL2   | +0.104 | -0.906 | **+0.011** |

ACCL's first two axes are swapped relative to GRAV's; nothing is sign-flipped.
The vehicle mapping is unchanged and is confirmed by this: longitudinal is
axis 2 negated, and against GPS it now correlates at r = -0.86 over the whole
clip, against +0.04 before.

Across six launches in GX010053 the reported mean is 89% of what GPS says the
run required (77-95%), and the clip the report came from reads 0.57 g against a
true 0.60. Gentler launches read lower — GX010050's two four-second pulls come
back at 63% — which is expected: GRAV is itself a fused estimate and drifts into
a long, gentle acceleration, and the GPS figure averages the whole 0-30
including the roll-out. The low-pass path is kept for clips with no GRAV stream,
with the window widened to ten seconds as the least-bad option.

One consequence worth knowing: this changes launch *timing* too, because the
start refinement reads the longitudinal channel, which used to be near zero.
The threshold is now measured against the clip's own resting baseline. The
residual carries a small per-clip bias -- how the camera sits, plus GRAV's
fusion -- so an absolute 0.05 g is not the same threshold on every clip: on
GX010053 the bike reads +0.04 g standing still, and the absolute threshold
tripped on that at 211.58s when the push does not begin until 212.0s. Against
the baseline it lands at 211.99s, and the run reads 2.28s where the rider
counted 2.2.


## 33. The ball shows what the rider feels, not what the vehicle does

The meter drew the vehicle's acceleration vector: under power the ball went up.
That is the convention of a racing G-G or friction-circle plot, and it is not the
convention of the g-meter in a car or of a mechanical bubble, both of which move
the way the occupant is thrown. In a first-person shot the second reading is the
obvious one — under power you go back, so the ball goes back. Asked, the rider
picked that one immediately.

Nothing was wrong with the numbers, and this only became visible once #32 made
the longitudinal channel work: with it stuck near zero the ball never moved
vertically, so the direction never came up.

The telemetry stays in the vehicle frame — `longitudinal` positive under power,
`lateral` positive turning right — because that is what the peak names mean and
what the launch detector reads. Only the drawing negates, in one place. The peak
marks negate with it: the hardest right-hander threw the rider left, so
`extremes.right` is drawn on the left.

The lateral sign was re-derived first rather than flipped on faith, since its
original figure (r = -0.54) was measured through the broken gravity removal.
Against v·dheading/dt on GX010053 it now correlates at **r = +0.933**, which
confirms `lateral` is the vehicle's rightward acceleration and that both channels
are consistently in the vehicle frame.

`GForceRenderer.offset(for:reach:maxG:)` exists so this is testable as a contract
rather than by scanning pixels for a red blob — the first attempt at that test
failed twice on bitmap row order, which is a good sign the test was measuring the
wrong thing.


## 34. The camera's timestamps are local time labelled UTC

Photos taken at noon in Arizona were listed as 05:02 — seven hours out, which is
exactly the UTC offset, in the direction that means local time was being read as
UTC.

Both of the camera's timestamp sources do it. `/gopro/media/list` reports `mod`
and `cre` as seconds since the epoch *computed from the local wall clock*, and
`GET` on a file returns `Last-Modified: Fri, 28 Aug 2026 12:02:32 GMT` for a
photo taken at 12:02 local. Neither says anywhere that it is local.

`GoProCamera` reads `/gopro/camera/get_date_time` once at discovery and works the
offset out by parsing the camera's own wall clock *as if it were UTC* and
comparing it with now. That deliberately ignores the `tzone` and `dst` fields the
same response carries: it is not documented whether `tzone` already includes
daylight saving or whether `dst` must be added to it, and guessing wrong is an
hour's error for half the year across most of the world. Reading the clock needs
no such interpretation, and on this camera it produced -25200s against a reported
`tzone` of -420 minutes — the same answer, arrived at without the guess.

The result is rounded to a quarter hour, since every real zone is a multiple of
one, so a camera clock a few minutes out cannot skew it; and an offset over 15
hours is refused, because that is a wrong clock rather than a time zone and
baking it in would move every timestamp by the same error.

Two traps worth knowing. The static helper cannot be called `clockOffset` while
the property is: `GoProCamera.clockOffset(...)` is then ambiguous against the
property's unapplied member reference, and the compiler answers "failed to
produce diagnostic for expression" rather than saying so. And in the tests,
`#expect(offset == -7 * 3600)` against a `TimeInterval?` fails — the bare literal
expression does not infer to Double there — so the expectation is a typed
constant.
