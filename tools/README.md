# GoPro over USB — mount it, or pull from it

Modern GoPros (this one is a **MISSION 1 PRO**) do **not** appear as a USB mass-storage
disk on macOS. When you plug one in it brings up a *USB Ethernet* interface and serves
two things over HTTP on port 8080:

* a control API — `/gopro/camera/...`
* a plain file server for the card — `/videos/DCIM/...`

That file server supports byte ranges, which is what makes a real mount possible.

These tools put a small **read-only WebDAV bridge** in front of the camera and mount it
with macOS's own WebDAV client. **No macFUSE, no kernel extension, no reboot, no
Homebrew, no sudo** — everything runs on the Python that already ships with macOS.

## The app

There is now a native Mac app: **/Applications/GoPull.app**. Launch it from Finder,
Spotlight or the Dock. It reimplements everything below in Swift, so it needs no
Python and no command line.

* **Mount as Drive** — mounts the card at `~/GoPro-Camera` and opens it in Finder.
* **Import** — copies new clips, with a progress bar and transfer rate.
* It keeps a **menu bar item**, so you can close the window and the volume stays up.
* It polls every 3 seconds, so plugging the camera in or unplugging it is picked up
  on its own, and it pings keep-alive so the camera doesn't sleep mid-transfer.

Unlike the Python bridge, the app never proxies video data. It answers `OPTIONS`
and `PROPFIND` itself but replies to `GET` with a **302 redirect** to the camera's
own file server. macOS follows the redirect *and re-sends its Range header*, so
clip data flows straight from the camera to the kernel — a 500 MB file is never
buffered in the app, and seeking stays as fast as reading the camera directly.

Two things worth knowing about the app:

* **The mount belongs to the app.** The WebDAV server runs inside the process, so
  quitting the app unmounts the volume (it does this deliberately rather than
  leaving a dead volume in Finder). Leave it running while you work in Resolve.
* **App Sandbox is switched off** for the app target. A sandboxed child process
  can't mount a filesystem, so `mount_webdav` would fail. Hardened Runtime is
  still on, and the app is signed with your Apple Development identity.

To rebuild and reinstall after changing the Swift sources:

```
xcodebuild -project GoPull.xcodeproj -scheme GoPull -configuration Release build
cp -R <DerivedData>/Build/Products/Release/GoPull.app /Applications/
```

The command line tools below still work and are handy for scripting an ingest.


## Mount the camera as a drive (command line)

```
./gopro-mount             # mounts at ~/GoPro-Camera and opens it in Finder
./gopro-unmount           # unmount and stop the bridge
```

Options: `--at PATH` (different mountpoint), `--port N`, `--no-open`.

The volume is **read-only** on purpose — you can't accidentally delete footage off the
card, and it means macOS never tries to write `.DS_Store` files to it.

You can open clips straight off this mount in Resolve, QuickTime or Finder. Seeking
works properly: reading 1 MB from the 494 MB mark of a 519 MB clip takes ~0.12s,
because the bridge passes HTTP range requests through to the camera rather than
downloading the whole file first.

## Copy clips off the camera (command line)

```
./gopro-pull                    # copy anything new into ~/Movies/GoPro/<date>/
./gopro-pull --list             # show what's on the card, and what you already have
./gopro-pull --pick             # choose which clips to copy
./gopro-pull --dest /Volumes/Fast --flat
```

This is the faster path for ingest: it runs 4 parallel range requests per file, which
gets ~51 MB/s versus ~40 MB/s for a single stream. Files already copied are skipped,
timestamps are preserved, and a partial download leaves a `.part` file rather than a
corrupt clip.

From Finder you can also just double-click **Mount GoPro.command** or
**Import from GoPro.command**.

## Measured on this setup

| | |
|---|---|
| Single stream from camera | ~40 MB/s |
| 4 parallel streams | ~60 MB/s |
| `gopro-pull` (real 495 MB clip) | 51 MB/s, 9.7s |
| Read through the mount | ~41 MB/s — no penalty vs. direct |
| Seek to 494 MB mark | 0.12s |
| Integrity | MD5 through the mount and through both importers matches the camera exactly |

The Swift implementation was verified the same way: mounted, checksummed a 519 MB
clip byte-for-byte, decoded a frame through the mount with AVFoundation, and
confirmed a Hardened-Runtime-signed binary can still bind the listener and call
`mount_webdav`.

## Notes and limitations

* **The camera must be in "GoPro Connect" USB mode**, not MTP.
* **`df` reports the volume as 0 bytes.** macOS's WebDAV client only ever asks for
  `getlastmodified`, `getcontentlength`, `creationdate` and `resourcetype` — it never
  requests the RFC 4331 quota properties, so it has no way to learn the card's real
  size. The bridge serves them correctly anyway for other clients. This is cosmetic and
  does not affect reading files.
* The bridge serves an empty `.metadata_never_index` at the volume root so Spotlight
  won't drag every clip across the USB link to index it.
* The camera IP is discovered automatically (GoPro Connect gives the Mac `x.x.x.55` and
  the camera `x.x.x.51`), so this keeps working across reconnects and other GoPro models.
* A keep-alive is pinged every 3s while the bridge is running so the camera doesn't
  sleep mid-transfer.
* For long editing sessions, prefer copying with `gopro-pull` — a mount is great for
  browsing and quick edits, but you don't want a multi-hour grade depending on a USB
  cable staying seated.

## Files

| file | what it is |
|---|---|
| `gopro_lib.py` | camera discovery + HTTP client |
| `gopro_webdavd.py` | the read-only WebDAV bridge |
| `gopro-mount` / `gopro-unmount` | mount management |
| `gopro_pull.py` (`gopro-pull`) | parallel downloader |
| `gopro_probe.py` | one-line "what's attached?" check |

App sources live in [`../GoPull/`](../GoPull/):

| file | what it is |
|---|---|
| `GoProCamera.swift` | discovery (`getifaddrs` → `x.x.x.51`) and the HTTP client |
| `WebDAVServer.swift` | the read-only WebDAV server, plus its HTTP connection handling |
| `MountController.swift` | `mount_webdav` / `umount` and mount detection via `statfs` |
| `Importer.swift` | parallel range downloader |
| `AppModel.swift` | polling, state, and orchestration |
| `ContentView.swift`, `GoPullApp.swift` | the UI and menu bar item |
