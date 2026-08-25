#!/usr/bin/env python3
"""Copy clips off a USB-tethered GoPro, fast.

Uses several parallel range requests per file, which measurably beats a single
stream over the camera's USB-Ethernet link (~60 MB/s vs ~40 MB/s).
"""

import argparse
import os
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gopro_lib import Camera, CameraError  # noqa: E402

DEFAULT_DEST = os.path.expanduser("~/Movies/GoPro")
CONNECTIONS = 4
MIN_CHUNKED = 8 * 1024 * 1024   # below this, one connection is faster
CHUNK = 512 * 1024
RETRIES = 3


def human(n):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return "%.1f %s" % (n, unit)
        n /= 1024.0


class Progress(object):
    def __init__(self, label, total):
        self.label, self.total = label, total
        self.done = 0
        self.started = time.time()
        self.lock = threading.Lock()
        self.quiet = not sys.stderr.isatty()

    def advance(self, n):
        with self.lock:
            self.done += n
            if not self.quiet:
                self._draw()

    def _draw(self):
        elapsed = max(time.time() - self.started, 1e-6)
        pct = (self.done / self.total * 100.0) if self.total else 100.0
        sys.stderr.write("\r  %-24s %5.1f%%  %8s/s" % (
            self.label[:24], pct, human(self.done / elapsed)))
        sys.stderr.flush()

    def finish(self):
        elapsed = max(time.time() - self.started, 1e-6)
        sys.stderr.write("\r  %-24s   done  %8s/s  (%s in %.1fs)\n" % (
            self.label[:24], human(self.done / elapsed), human(self.done), elapsed))
        sys.stderr.flush()


def _fetch_range(camera, folder, name, fd, start, end, progress):
    """Download [start, end] into fd at the right offset, with retries."""
    last_err = None
    for attempt in range(RETRIES):
        pos = start
        try:
            resp, conn = camera.open_file(
                folder, name, byte_range="bytes=%d-%d" % (pos, end))
            try:
                if resp.status not in (200, 206):
                    raise IOError("HTTP %d" % resp.status)
                while pos <= end:
                    data = resp.read(CHUNK)
                    if not data:
                        break
                    os.pwrite(fd, data, pos)
                    pos += len(data)
                    progress.advance(len(data))
            finally:
                conn.close()
            if pos > end:
                return
            last_err = IOError("short read: got %d of %d bytes" % (pos - start, end - start + 1))
        except Exception as exc:
            last_err = exc
        # Roll the progress bar back over whatever this attempt managed.
        progress.advance(-(pos - start))
        time.sleep(0.5 * (attempt + 1))
    raise IOError("%s: %s" % (name, last_err))


def download(camera, folder, name, size, dest, connections=CONNECTIONS):
    tmp = dest + ".part"
    progress = Progress(name, size)
    with open(tmp, "wb") as fh:
        fh.truncate(size)
    fd = os.open(tmp, os.O_WRONLY)
    try:
        if size < MIN_CHUNKED or connections <= 1:
            _fetch_range(camera, folder, name, fd, 0, size - 1, progress)
        else:
            span = size // connections
            bounds = []
            for i in range(connections):
                start = i * span
                end = (size - 1) if i == connections - 1 else (start + span - 1)
                bounds.append((start, end))
            errors = []
            threads = []
            for start, end in bounds:
                def work(s=start, e=end):
                    try:
                        _fetch_range(camera, folder, name, fd, s, e, progress)
                    except Exception as exc:
                        errors.append(exc)
                t = threading.Thread(target=work)
                t.start()
                threads.append(t)
            for t in threads:
                t.join()
            if errors:
                raise errors[0]
    finally:
        os.close(fd)

    actual = os.path.getsize(tmp)
    if actual != size:
        os.unlink(tmp)
        raise IOError("%s: expected %d bytes, got %d" % (name, size, actual))
    os.rename(tmp, dest)
    progress.finish()


def main(argv):
    ap = argparse.ArgumentParser(description="Copy clips off a USB-tethered GoPro.")
    ap.add_argument("--dest", default=DEFAULT_DEST, help="destination root (default: %s)" % DEFAULT_DEST)
    ap.add_argument("--flat", action="store_true", help="don't sort into per-date folders")
    ap.add_argument("--list", action="store_true", help="list what's on the card and exit")
    ap.add_argument("--pick", action="store_true", help="choose which clips to copy")
    ap.add_argument("--all", action="store_true", help="re-copy even files already present")
    ap.add_argument("--connections", type=int, default=CONNECTIONS)
    ap.add_argument("--open", dest="reveal", action="store_true", help="reveal in Finder when done")
    args = ap.parse_args(argv)

    try:
        camera = Camera.discover()
    except CameraError as exc:
        sys.stderr.write("%s\n" % exc)
        return 2
    camera.enable_wired_control()

    tree = camera.media_list()
    items = []
    for folder in sorted(tree):
        for name in sorted(tree[folder]):
            if name.startswith("._"):
                continue
            meta = tree[folder][name]
            items.append((folder, name, meta["size"], meta["mtime"]))

    if not items:
        print("Card is empty.")
        return 0

    total = sum(i[2] for i in items)
    print("%s at %s -- %d file(s), %s"
          % (camera.model, camera.ip, len(items), human(total)))

    def dest_for(name, mtime):
        if args.flat:
            return os.path.join(args.dest, name)
        day = time.strftime("%Y-%m-%d", time.localtime(mtime)) if mtime else "undated"
        return os.path.join(args.dest, day, name)

    if args.list:
        for folder, name, size, mtime in items:
            when = time.strftime("%Y-%m-%d %H:%M", time.localtime(mtime)) if mtime else "?"
            have = "have" if os.path.exists(dest_for(name, mtime)) else "new "
            print("  [%s] %-28s %10s  %s" % (have, name, human(size), when))
        return 0

    # Work out what's actually missing.
    todo = []
    for folder, name, size, mtime in items:
        path = dest_for(name, mtime)
        if not args.all and os.path.exists(path) and os.path.getsize(path) == size:
            continue
        todo.append((folder, name, size, mtime, path))

    if args.pick and todo:
        print("\nSelect clips (e.g. 1,3 or 1-4, blank = all):")
        for i, (_, name, size, mtime, _p) in enumerate(todo, 1):
            when = time.strftime("%Y-%m-%d %H:%M", time.localtime(mtime)) if mtime else "?"
            print("  %2d) %-28s %10s  %s" % (i, name, human(size), when))
        raw = input("> ").strip()
        if raw:
            chosen = set()
            for part in raw.replace(" ", "").split(","):
                if not part:
                    continue
                if "-" in part:
                    a, b = part.split("-", 1)
                    chosen.update(range(int(a), int(b) + 1))
                else:
                    chosen.add(int(part))
            todo = [t for i, t in enumerate(todo, 1) if i in chosen]

    if not todo:
        print("Nothing new to copy -- everything is already in %s" % args.dest)
        return 0

    print("\nCopying %d file(s), %s -> %s\n"
          % (len(todo), human(sum(t[2] for t in todo)), args.dest))

    failed = []
    for folder, name, size, mtime, path in todo:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        try:
            download(camera, folder, name, size, path, args.connections)
            if mtime:
                os.utime(path, (mtime, mtime))
        except Exception as exc:
            sys.stderr.write("\n  FAILED %s: %s\n" % (name, exc))
            failed.append(name)

    print("")
    if failed:
        print("%d of %d file(s) failed: %s" % (len(failed), len(todo), ", ".join(failed)))
    else:
        print("Copied %d file(s) to %s" % (len(todo), args.dest))

    if args.reveal:
        os.system('open %s' % _shquote(args.dest))
    return 1 if failed else 0


def _shquote(s):
    return "'" + s.replace("'", "'\\''") + "'"


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
