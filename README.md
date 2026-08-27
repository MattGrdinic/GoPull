# GoPull

A macOS app that mounts a USB-tethered GoPro's card as a drive, and pulls footage off it fast.

Modern GoPros don't appear as USB disks. Plug one into a Mac and you get no volume — just a
USB Ethernet interface and an HTTP server on the camera. This app puts a read-only WebDAV
server in front of that and mounts it with macOS's own WebDAV client, so the card shows up in
Finder like any other drive.

**No macFUSE, no kernel extension, no reboot, no Homebrew, no `sudo`.**

Built for a **GoPro MISSION 1 PRO**, but camera discovery is generic and should work with other
GoPro Connect models.

## Features

* **Mount as Drive** — the card appears at `~/GoPro-Camera`, read-only. Open clips directly in
  Resolve, QuickTime or Finder; seeking works properly.
* **Preview before you copy** — every clip carries a thumbnail plus its duration, resolution
  and frame rate, read from the camera. Double-click one to play it: the camera has a
  low-resolution `.LRV` proxy beside every clip, so an 11.5 GB 8K recording previews from a
  364 MB file that streams off the card without copying anything.
* **G-force meter** — an optional third overlay: a ball on a target showing cornering and
  braking, with a short trail behind it. Read from the camera's 200 Hz accelerometer, with
  gravity removed.
* **GPR → DNG** — GoPro's raw stills are DNGs whose image tile is VC-5 compressed, which
  nothing on macOS can decode: ImageIO reads the metadata and then produces no pixels. GoPull
  decodes the tile and writes a real DNG beside it, keeping every colour tag, in about half a
  second for a 8192×6144 frame.
* **Import** — copies new clips to `~/Movies/GoPro/<date>/` at ~51 MB/s using parallel range
  requests, with progress and transfer rate. Already-imported clips are detected and skipped.
* **Folder options** — sort clips into date folders, per-camera folders, or both. Two bodies
  of the same model are told apart by a number you set once; it's remembered per serial, and
  `#1` is left out of the folder name. The footer previews the exact path clips will land in.
* **Menu bar item** — close the window and the volume stays mounted.
* **Automatic discovery** — plugging in or unplugging the camera is picked up within ~3
  seconds. Keep-alive stops the camera sleeping mid-transfer.
* **Survives being unplugged** — pull the cable and the volume is ejected for you rather than
  left dead in Finder; an import in progress stops immediately instead of grinding through
  every remaining clip, and never leaves a partial file behind. A camera with no card in it is
  reported as exactly that, not as "no camera".

## Using it

Build and install:

```bash
xcodebuild -project GoPull.xcodeproj -scheme GoPull -configuration Release \
  -destination 'platform=macOS' -derivedDataPath /tmp/gopull-dd build
rm -rf /Applications/GoPull.app && cp -R /tmp/gopull-dd/Build/Products/Release/GoPull.app /Applications/
```

Then launch **GoPull.app** from Finder or Spotlight, with the camera connected by USB and
powered on. The camera must be in **GoPro Connect** USB mode, not MTP.

There are also Python command-line equivalents in [tools/](tools/) that need no build step —
useful for scripting an ingest. See [tools/README.md](tools/README.md).

## Things to know

* **The volume is read-only**, deliberately — footage can't be deleted from the card by
  accident, and macOS won't write `.DS_Store` files onto it.
* **Quitting the app unmounts the volume.** The WebDAV server runs inside the app; it
  unmounts on quit rather than stranding a dead volume in Finder. Leave it running while
  you're working.
* **`df` reports the volume as 0 bytes.** macOS's WebDAV client never asks for the quota
  properties, so it can't know the card's size. Cosmetic; reading is unaffected.
* **App Sandbox is off** for the app target — a sandboxed process can't mount a filesystem.
  Hardened Runtime is still on.
* For a long grade, prefer importing over editing off the mount. A mount is great for
  browsing and quick edits, but you don't want a multi-hour session depending on a USB cable
  staying seated.

## Documentation

| | |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | How it works — discovery, the mount, the redirect design, importing |
| [docs/DECISIONS.md](docs/DECISIONS.md) | Why it's built this way, and what was tried and rejected |
| [docs/TESTING.md](docs/TESTING.md) | Verifying changes against real hardware |
| [tools/README.md](tools/README.md) | The Python command-line tools |
| [CLAUDE.md](CLAUDE.md) | Orientation for Claude Code |
