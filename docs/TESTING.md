# Testing

Most of this project only does anything interesting with a camera physically attached, and the
app's buttons can't be clicked from automation. This is how it gets verified anyway.

## The harness pattern

Compile the **non-UI** sources into a throwaway CLI with `swiftc` and drive them directly. This
exercises the real `GoProCamera`, `WebDAVServer`, `MountController` and `Importer` — not
reimplementations of them.

```bash
swiftc -swift-version 5 -O \
  GoPull/GoProCamera.swift GoPull/WebDAVServer.swift \
  GoPull/MountController.swift GoPull/Importer.swift \
  /path/to/harness/main.swift -o /tmp/gopro-test
```

`AppModel.swift` can be included too (it imports SwiftUI, which links fine in a CLI). Only
`ContentView.swift` and `GoPullApp.swift` need to be left out.

### Three pitfalls, all of which cost time once

**The harness file must be named `main.swift`.** Otherwise `swiftc` rejects top-level code with
`error: expressions are not allowed at the top level`. Put it in its own directory.

**End with `dispatchMain()`, never `semaphore.wait()`.** Blocking the main thread means the main
dispatch queue never runs, so every `@MainActor` task — including all of `Importer` — deadlocks
silently. The first version of the harness hung for exactly this reason and looked like an
`Importer` bug.

**`for x in seq where cond { }` filters, it does not break.** Once `cond` goes false the loop
spins through its remaining iterations instantly rather than stopping. A harness "wait until
finished" loop written that way falls straight through and reports a perfectly good import as a
failure — which cost a debugging round here. Wait for the work to *start*, then for it to
*finish*, as two separate loops.

**`setbuf(stdout, nil)`.** `print` is block-buffered when redirected to a file, so a harness that
is working looks like a harness that is hung.

Plain `swiftc -swift-version 5` also does **not** enable bare-slash regex literals, while the
Xcode build passes `-enable-bare-slash-regex`. Code shared with the harness should avoid them.

## What to verify after touching the mount path

Once the harness has mounted, from another shell:

```bash
MP=~/GoPro-App-Test

ls -laR "$MP"                                          # listing, and the Spotlight marker
dd if="$MP/100GOPRO/CLIP.MP4" of=/dev/null bs=1m count=1 iseek=494   # seek must be ~0.1s
md5 -q "$MP/100GOPRO/CLIP.MP4"                         # must match the camera exactly
touch "$MP/100GOPRO/x.txt"                             # must fail: Read-only file system
qlmanage -t -s 320 -o /tmp "$MP/100GOPRO/CLIP.MP4"     # AVFoundation must decode a frame
mount | grep webdav                                    # must say read-only
```

Compare the checksum against the camera directly:

```bash
curl -s http://172.24.113.51:8080/videos/DCIM/100GOPRO/CLIP.MP4 | md5 -q
```

`qlmanage` is the cheapest proxy for "will Resolve be able to read this" — it forces
AVFoundation to demux and decode through the mount.

## Verifying Hardened Runtime assumptions

A plain `swiftc` binary is ad-hoc signed and *not* hardened, so it does not prove the shipped
app can bind a listener or spawn `mount_webdav`. Re-sign the harness and re-run:

```bash
codesign --force --sign - --options runtime /tmp/gopro-test
codesign -dv /tmp/gopro-test 2>&1 | grep flags     # expect flags=0x10002(adhoc,runtime)
```

This was done, and a hardened binary mounts and imports successfully.

## Inspecting what macOS actually requests

Several findings in [DECISIONS.md](DECISIONS.md) came from logging the raw request stream rather
than guessing. The quickest way is to copy `tools/gopro_webdavd.py`, dump the method, path,
`Depth`, `User-Agent` and body in `_drain()`, and mount against it. Two things to know:

* The copy must sit **beside `gopro_lib.py`**, or its `sys.path` insert won't find the module.
* Kill it by port, not by name — a debug copy under a different filename will happily keep
  squatting on port 8788 and serve stale code, which invalidates every subsequent test:

```bash
lsof -nP -tiTCP:8788 -sTCP:LISTEN | xargs -r kill -9
```

## Unit tests

```bash
xcodebuild test -project GoPull.xcodeproj -scheme GoPull -destination 'platform=macOS' -only-testing:GoPullTests
```

`GoPullTests` uses Swift Testing; `GoPullUITests` uses XCTest and launches the app, so it's worth
excluding while iterating.

## Results on this hardware

MISSION 1 PRO, firmware `H26.01.02.02.00`, over USB to an Apple Silicon Mac.

| measurement | result |
|---|---|
| Single stream from camera | ~40 MB/s |
| 4 parallel range requests | ~60 MB/s |
| `Importer` on a real 495 MB clip | 51 MB/s, 9.7s |
| Read through the mount | ~41 MB/s — no penalty vs. direct |
| Seek to the 494 MB mark of a 519 MB clip | 0.12s |
| MD5 through the mount / both importers | identical to the camera |
| Modification times | preserved from the camera |
| Hardened-Runtime-signed binary | binds listener, mounts, imports |
| AVFoundation decode through the mount | succeeds |
| Mount + Finder browsing from the shipped app | confirmed working |
| Unplug mid-import (real cable pull) | UI resets; volume auto-ejects |
| Cancel a running import | stops in 0.05s, no `.part`, no partial clip |
| Normal import after a cancel | completes, exact size, MD5 matches |
| Orphan sweep with decoys | removes media `.part` only, nested included |
| 11.5 GB clip, end to end | completes in 8m28s; previously failed at ~20% every time |
| Spot-checks at 1/3/4/6/9 GiB offsets | byte-identical to the camera |
| 1.16 GB clip after a cancel | MD5 identical to the camera |
| Control API during an import | `media/list`, `DCIM/` and `keep_alive` all hit the 15s timeout |
