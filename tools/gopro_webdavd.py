#!/usr/bin/env python3
"""Read-only WebDAV bridge in front of a USB-tethered GoPro.

macOS has a built-in WebDAV client (/sbin/mount_webdav), so pointing it at this
server mounts the camera's card as a normal volume -- no macFUSE, no kext.

The camera's own file server already supports byte ranges, so seeking works.
"""

import email.utils
import os
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import quote, unquote

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gopro_lib import Camera, CameraError  # noqa: E402

TREE_TTL = 5.0          # seconds to cache the media list
KEEPALIVE_EVERY = 3.0   # seconds between camera keep-alive pokes
CHUNK = 512 * 1024

# Serving this as an empty file stops Spotlight indexing the volume -- otherwise
# mds would drag every clip across the USB link just to index it.
VIRTUAL_FILES = ("/.metadata_never_index",)


# Junk the SD card may carry from a previous Finder copy; hide it from the mount.
def _hidden(name):
    return name.startswith("._") or name == ".DS_Store"


class Tree(object):
    """Short-TTL cache of the camera's media list."""

    def __init__(self, camera):
        self.camera = camera
        self._lock = threading.Lock()
        self._data = {}
        self._at = 0.0
        self._free = 0
        self._free_at = 0.0

    def get(self, force=False):
        with self._lock:
            if force or time.time() - self._at > TREE_TTL:
                try:
                    self._data = self.camera.media_list()
                    self._at = time.time()
                except Exception:
                    # Keep serving the last good tree if the camera hiccups.
                    if not self._data:
                        raise
            return self._data

    def quota(self):
        """(used_bytes, available_bytes) so the volume reports a real capacity."""
        tree = self.get()
        used = sum(m["size"] for files in tree.values() for m in files.values())
        with self._lock:
            if time.time() - self._free_at > 15.0:
                self._free = self.camera.free_bytes()
                self._free_at = time.time()
        return used, self._free

    def resolve(self, path):
        """Map a URL path to ('root'|'dir'|'file'|None, folder, name, meta)."""
        if path in VIRTUAL_FILES:
            return ("virtual", None, path.lstrip("/"), {"size": 0, "mtime": 0})
        parts = [p for p in path.split("/") if p]
        tree = self.get()
        if not parts:
            return ("root", None, None, None)
        if len(parts) == 1:
            if parts[0] in tree:
                return ("dir", parts[0], None, None)
            return (None, None, None, None)
        if len(parts) == 2:
            folder, name = parts
            meta = tree.get(folder, {}).get(name)
            if meta and not _hidden(name):
                return ("file", folder, name, meta)
            return (None, None, None, None)
        return (None, None, None, None)


def _httpdate(ts):
    return email.utils.formatdate(ts, usegmt=True)


def _isodate(ts):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts))


def _xml_escape(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "GoProDAV/1.0"

    # ---- plumbing -------------------------------------------------------
    def log_message(self, fmt, *args):
        if self.server.verbose:
            sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    def _drain(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)

    def _send(self, code, body=b"", ctype="text/plain; charset=utf-8", extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or []):
            self.send_header(k, v)
        self.end_headers()
        if body and self.command != "HEAD":
            self.wfile.write(body)

    def _deny(self):
        """Every mutating method: refuse, so macOS mounts the volume read-only."""
        self._drain()
        self._send(403, b"GoPro card is mounted read-only.\n")

    do_PUT = do_DELETE = do_MKCOL = do_MOVE = do_COPY = _deny
    do_PROPPATCH = do_LOCK = do_UNLOCK = _deny

    # ---- WebDAV ---------------------------------------------------------
    def do_OPTIONS(self):
        self._drain()
        self.send_response(200)
        # DAV: 1 only -- advertising class 2 (locking) would make macOS think
        # the volume is writable.
        self.send_header("DAV", "1")
        self.send_header("MS-Author-Via", "DAV")
        self.send_header("Allow", "OPTIONS, GET, HEAD, PROPFIND")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_PROPFIND(self):
        self._drain()
        path = unquote(self.path.split("?", 1)[0])
        try:
            kind, folder, name, meta = self.server.tree.resolve(path)
        except Exception as exc:
            self._send(503, ("camera unavailable: %s\n" % exc).encode("utf-8"))
            return
        if kind is None:
            self._send(404, b"Not found\n")
            return

        depth = self.headers.get("Depth", "1")
        responses = []
        tree = self.server.tree.get()
        used, free = self.server.tree.quota()

        if kind == "root":
            responses.append(self._collection("/", "GoPro", used, free))
            if depth != "0":
                for folder_name in sorted(tree):
                    responses.append(self._collection("/%s/" % folder_name, folder_name, used, free))
                for vpath in VIRTUAL_FILES:
                    responses.append(
                        self._file(vpath, vpath.lstrip("/"), {"size": 0, "mtime": 0}))
        elif kind == "dir":
            responses.append(self._collection("/%s/" % folder, folder, used, free))
            if depth != "0":
                for fname in sorted(tree.get(folder, {})):
                    if _hidden(fname):
                        continue
                    fmeta = tree[folder][fname]
                    responses.append(self._file("/%s/%s" % (folder, fname), fname, fmeta))
        elif kind == "virtual":
            responses.append(self._file("/" + name, name, meta))
        else:
            responses.append(self._file("/%s/%s" % (folder, name), name, meta))

        body = (
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<D:multistatus xmlns:D="DAV:">\n%s</D:multistatus>\n' % "".join(responses)
        ).encode("utf-8")
        self._send(207, body, ctype='text/xml; charset="utf-8"')

    def _href(self, path):
        return quote(path)

    def _collection(self, path, display, used=0, free=0):
        return (
            "<D:response><D:href>%s</D:href><D:propstat><D:prop>"
            "<D:displayname>%s</D:displayname>"
            "<D:resourcetype><D:collection/></D:resourcetype>"
            "<D:getcontenttype>httpd/unix-directory</D:getcontenttype>"
            "<D:getlastmodified>%s</D:getlastmodified>"
            "<D:creationdate>%s</D:creationdate>"
            "<D:quota-used-bytes>%d</D:quota-used-bytes>"
            "<D:quota-available-bytes>%d</D:quota-available-bytes>"
            "</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>\n"
            % (
                self._href(path),
                _xml_escape(display),
                _httpdate(self.server.started),
                _isodate(self.server.started),
                used,
                free,
            )
        )

    def _file(self, path, display, meta):
        size, mtime = meta["size"], meta["mtime"] or self.server.started
        return (
            "<D:response><D:href>%s</D:href><D:propstat><D:prop>"
            "<D:displayname>%s</D:displayname>"
            "<D:resourcetype/>"
            "<D:getcontentlength>%d</D:getcontentlength>"
            "<D:getcontenttype>%s</D:getcontenttype>"
            "<D:getlastmodified>%s</D:getlastmodified>"
            "<D:creationdate>%s</D:creationdate>"
            "<D:getetag>\"%s-%d\"</D:getetag>"
            "</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>\n"
            % (
                self._href(path),
                _xml_escape(display),
                size,
                _content_type(display),
                _httpdate(mtime),
                _isodate(mtime),
                display.replace('"', ""),
                size,
            )
        )

    # ---- file bodies ----------------------------------------------------
    def do_HEAD(self):
        self._serve(body=False)

    def do_GET(self):
        self._serve(body=True)

    def _serve(self, body):
        self._drain()
        path = unquote(self.path.split("?", 1)[0])
        try:
            kind, folder, name, meta = self.server.tree.resolve(path)
        except Exception as exc:
            self._send(503, ("camera unavailable: %s\n" % exc).encode("utf-8"))
            return
        if kind == "virtual":
            self._send(200, b"", ctype="application/octet-stream")
            return
        if kind != "file":
            self._send(404 if kind is None else 403, b"Not a file\n")
            return

        rng = self.headers.get("Range")
        try:
            resp, conn = self.server.camera.open_file(folder, name, byte_range=rng)
        except Exception as exc:
            self._send(502, ("camera read failed: %s\n" % exc).encode("utf-8"))
            return

        try:
            if resp.status not in (200, 206):
                resp.read()
                self._send(502, b"camera returned HTTP %d\n" % resp.status)
                return
            self.send_response(resp.status)
            self.send_header("Content-Type", _content_type(name))
            self.send_header("Accept-Ranges", "bytes")
            length = resp.getheader("Content-Length")
            if length is not None:
                self.send_header("Content-Length", length)
            crange = resp.getheader("Content-Range")
            if crange:
                self.send_header("Content-Range", crange)
            self.send_header("Last-Modified", _httpdate(meta["mtime"] or self.server.started))
            self.end_headers()
            if not body:
                return
            while True:
                chunk = resp.read(CHUNK)
                if not chunk:
                    break
                self.wfile.write(chunk)
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True   # client (Finder/Resolve) gave up on a seek
        finally:
            try:
                conn.close()
            except Exception:
                pass


_TYPES = {
    ".mp4": "video/mp4", ".lrv": "video/mp4", ".thm": "image/jpeg",
    ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gpr": "image/x-adobe-dng",
    ".png": "image/png", ".wav": "audio/wav", ".360": "video/mp4",
}


def _content_type(name):
    return _TYPES.get(os.path.splitext(name)[1].lower(), "application/octet-stream")


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def _keepalive_loop(camera, stop):
    while not stop.is_set():
        camera.keep_alive()
        stop.wait(KEEPALIVE_EVERY)


def main(argv):
    import argparse

    ap = argparse.ArgumentParser(description="Read-only WebDAV bridge to a USB GoPro.")
    ap.add_argument("--port", type=int, default=8788)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args(argv)

    try:
        camera = Camera.discover()
    except CameraError as exc:
        sys.stderr.write("%s\n" % exc)
        return 2
    camera.enable_wired_control()

    server = Server((args.host, args.port), Handler)
    server.camera = camera
    server.tree = Tree(camera)
    server.started = int(time.time())
    server.verbose = args.verbose

    stop = threading.Event()
    threading.Thread(target=_keepalive_loop, args=(camera, stop), daemon=True).start()

    sys.stderr.write(
        "Serving %s (%s) at http://%s:%d/\n"
        % (camera.model, camera.ip, args.host, args.port)
    )
    sys.stderr.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
