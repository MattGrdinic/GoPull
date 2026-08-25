# Architecture

## The problem

A modern GoPro is not a USB disk. Plugging a **MISSION 1 PRO** into a Mac produces no volume
in `/Volumes` and no entry in `diskutil list`. What it *does* produce is a network interface:

```
Hardware Port: MISSION 1 PRO
Device: en8
```

with the Mac holding `172.24.113.55`. This is **GoPro Connect** — a USB Ethernet (NCM) gadget.
The camera sits at `172.24.113.51` and serves HTTP on port 8080:

| endpoint | what it gives you |
|---|---|
| `/gopro/camera/info` | model, serial, firmware |
| `/gopro/camera/state` | status keys; **54** is free space on the card, in kilobytes |
| `/gopro/media/list` | JSON index of the card |
| `/gopro/camera/keep_alive` | stops the camera sleeping |
| `/gopro/camera/control/wired_usb?p=1` | enables wired control |
| `/videos/DCIM/…` | the card itself, as a plain file server |

The decisive detail is that the file server answers `Accept-Ranges: bytes` and returns
`206 Partial Content`. Random access is possible, so a real mount — not just a download
script — is achievable.

## The data path

```
                    ┌─────────────────────────────────────────┐
                    │  GoPull.app                              │
   Finder /         │                                         │
   Resolve /  ──►   │  WebDAVServer (NWListener, 127.0.0.1)   │
   QuickTime        │    OPTIONS / PROPFIND ── answered here   │
       ▲            │    GET / HEAD ────────── 302 redirect ──┼──┐
       │            └─────────────────────────────────────────┘  │
       │                          ▲                              │
       │  mount_webdav            │ mounts                       │
       └──────────────────────────┘                              │
                                                                 ▼
   video bytes ◄─────────────────────────────────────  camera 172.24.113.51:8080
                       (never pass through the app)         /videos/DCIM/…
```

Three things are happening:

**1. Discovery.** `GoProCamera.candidateAddresses()` walks `getifaddrs`, keeps every IPv4
address inside `172.16.0.0/12`, and rewrites the last octet to `.51`. Each candidate is probed
with `/gopro/camera/info` on a 3-second timeout. Nothing is hardcoded, so reconnects, a
different camera, or a different subnet all keep working.

**2. Mounting.** `WebDAVServer` binds an ephemeral port on loopback. `MountController` then
shells out to `/sbin/mount_webdav -S -v GoPro http://127.0.0.1:<port>/ ~/GoPro-Camera`.
macOS's own WebDAV client (`webdavfs`) does the mounting, which is why no kernel extension,
no macFUSE and no `sudo` are involved — an unprivileged user can mount as long as they own
the mount point.

**3. Reading.** This is the part worth understanding properly.

## The redirect

The server implements only the metadata half of WebDAV — `OPTIONS` and `PROPFIND`. For
`GET` and `HEAD` it replies:

```
HTTP/1.1 302 Found
Location: http://172.24.113.51:8080/videos/DCIM/100GOPRO/GX010001.MP4
```

macOS follows the redirect **and re-sends its `Range` header** on the redirected request. This
was verified by instrumenting the request stream:

```
REDIRECT /100GOPRO/GX010001.MP4 -> http://172.24.113.51:8080/... (range=bytes=209715200-210763775)
```

The consequences are worth spelling out:

* Video data never enters the app's address space. A 500 MB clip is never buffered, and there
  is no streaming/backpressure code to get wrong.
* Reading through the mount runs at the same speed as reading the camera directly.
* Seeking is genuinely random-access: reading 1 MB from the 494 MB mark of a 519 MB clip
  takes **0.12s**.

The Python bridge in `tools/` predates this and *does* proxy the bytes. Both produce
byte-identical output; the redirect version simply has less machinery.

## Why the volume is read-only

The server advertises `DAV: 1` in its `OPTIONS` response — deliberately *not* class 2, which
would imply locking — and returns `403` for `PUT`, `DELETE`, `MKCOL`, `MOVE`, `COPY`,
`PROPPATCH`, `LOCK` and `UNLOCK`. macOS probes for write support, finds none, and mounts the
volume read-only:

```
http://127.0.0.1:64209/ on /Users/matt/GoPro-Camera (webdav, nodev, noexec, nosuid, read-only, mounted by matt)
```

That is the desired outcome twice over: footage cannot be deleted from the card by accident,
and macOS never tries to scatter `.DS_Store` files across it.

## What macOS actually asks for

Instrumenting `webdavfs` showed it requests exactly four properties, and nothing else:

```xml
<D:propfind xmlns:D="DAV:"><D:prop>
  <D:getlastmodified/><D:getcontentlength/><D:creationdate/><D:resourcetype/>
</D:prop></D:propfind>
```

Two findings came out of that:

* **It never requests RFC 4331 quota properties**, which is why `df` reports the volume as
  0 bytes. The server sends `quota-used-bytes` / `quota-available-bytes` anyway for other
  clients. This is cosmetic and does not affect reading.
* **It probes `.metadata_never_index`** on mount. The server serves that as an empty file,
  which stops Spotlight dragging every clip across the USB link to index it.

It also probes a lot of AppleDouble junk (`/._.`, `/._100GOPRO`, `.DS_Store`), all of which is
answered `404`. Files starting with `._` are filtered out of listings so the mount stays clean
even when the card has been touched by Finder before.

## Importing

Mounting is the right tool for browsing and quick edits. Bulk ingest uses a separate path,
because parallelism measurably wins:

| | throughput |
|---|---|
| single stream | ~40 MB/s |
| 4 parallel range requests | ~60 MB/s |
| `Importer` on a real 495 MB clip | **51 MB/s** (9.7s) |

`Importer` splits each file into 8 MB ranges and keeps 4 in flight, which bounds memory at
~32 MB regardless of clip size. Chunks are written with `pwrite` at their offset into a
preallocated `.part` file — `pwrite` is thread-safe and needs no seek/lock coordination. Only
when the final size matches is the `.part` renamed into place, so an interrupted import can
never leave a corrupt clip behind. Each chunk retries up to 3 times independently, and the
camera's modification date is restored onto the copied file.

## Concurrency model

* `GoProCamera` is an `actor`. It is the only type that talks to the camera's control API.
  Its `let` properties (`ip`, `info`) are `Sendable`, so they read without `await`.
* `AppModel` and `Importer` are `@MainActor ObservableObject`s. All UI state mutation is
  therefore main-thread by construction.
* `WebDAVServer` is *not* actor-isolated — it serves connections on its own `DispatchQueue`
  and guards its snapshot with an `NSLock`. It has to be callable from the network queue.
* `AppModel` publishes a fresh `CardSnapshot` into the server on every poll, so the mounted
  volume reflects new recordings without a remount.

`OnceFlag` exists because `NWListener`'s state handler can fire repeatedly from another
thread while a `CheckedContinuation` may only be resumed once; the naive captured-`Bool`
version is a data race and a hard error under Swift 6.

## Lifecycle

Polling starts in `applicationDidFinishLaunching`, not in a view's `onAppear`, so the menu bar
item keeps working when no window is open. Every 3 seconds `AppModel.refresh()` re-checks the
mount, re-reads the media list, refreshes free space and pings keep-alive — which is how the
app notices the camera being plugged in or pulled without any user action.

Because the WebDAV server lives inside the app, **quitting the app unmounts the volume**.
`applicationWillTerminate` does this deliberately; the alternative is a dead volume left in
Finder pointing at a port nothing is listening on.

## Losing the camera

Three failure shapes are handled separately, because they need different answers.

**The camera is pulled while idle.** `refresh()` fails, `handleMissedPoll()` counts it, and
after **three consecutive misses** (~9 seconds) a mounted volume is ejected automatically. The
delay matters: a single dropped poll shouldn't tear down a working mount. A mounted volume
whose server can no longer reach the camera is worse than no volume, because Finder blocks on
it.

**The camera is pulled mid-import.** Three things cooperate here, and the first version got
all three wrong — found by actually yanking the cable during an import:

* `Importer` probes with `keepAlive()` after any file fails. If the camera is gone it records
  `ImportError.disconnected` and **stops**, rather than running every remaining clip through
  three retries and a backoff each.
* Chunk requests use a **dedicated `URLSession` with a 15s request and 60s resource timeout**.
  `URLSession.shared` defaults to a *seven day* resource timeout, so requests issued just
  before the cable came out hung around long after the UI had given up on the camera.
* `AppModel` **owns the import `Task`** and cancels it once the camera is confirmed gone. The
  first implementation stored the task on `Importer`, where it was never assigned — which
  silently made the Cancel button a no-op as well.

Downloads land in a `.part` file that is only renamed once the size matches, so nothing partial
is ever presented as a real clip. A `.part` can still survive if the process dies before its
cleanup runs, so `AppModel` sweeps orphaned `.part` files for known clips before each import.

**The card is out but the camera is present.** This looks identical at first glance — the
media list fails — but `/gopro/camera/info` and keep-alive still answer. The app keeps the
camera identified and reports "No SD card detected in the camera." rather than claiming
there's no camera. This case was found by accident during testing, when a card was removed and
the app reported the camera missing.

One implementation detail is load-bearing here: **`statfs` and `umount` can block on a WebDAV
volume whose server has gone**, so `AppModel` runs both on a detached task and only touches
published state back on the main actor. Doing this work inline would beachball the UI in
precisely the situation the code exists to handle.
