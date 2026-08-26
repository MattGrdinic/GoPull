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
