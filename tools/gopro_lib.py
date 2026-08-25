#!/usr/bin/env python3
"""Shared helpers for talking to a USB-tethered GoPro (GoPro Connect / NCM).

When a modern GoPro is plugged into a Mac it does NOT appear as mass storage.
It brings up a USB Ethernet (NCM) interface and serves:
  * a JSON control API at  http://<cam>:8080/gopro/...
  * a plain file server at http://<cam>:8080/videos/DCIM/...
The Mac side of that link gets x.x.x.55, the camera x.x.x.51.
"""

import http.client
import json
import re
import subprocess

HTTP_PORT = 8080
CAMERA_LAST_OCTET = 51
DCIM_ROOT = "/videos/DCIM"
CONNECT_TIMEOUT = 4.0


class CameraError(Exception):
    pass


def _candidate_ips():
    """Every plausible camera IP, derived from our own GoPro-Connect addresses."""
    try:
        out = subprocess.run(["ifconfig"], capture_output=True, text=True).stdout
    except OSError:
        return []
    seen, cands = set(), []
    for ip in re.findall(r"inet (\d+\.\d+\.\d+\.\d+)", out):
        octets = ip.split(".")
        # GoPro Connect always lands in 172.16.0.0/12
        if octets[0] != "172" or not (16 <= int(octets[1]) <= 31):
            continue
        guess = "%s.%s.%s.%d" % (octets[0], octets[1], octets[2], CAMERA_LAST_OCTET)
        if guess not in seen:
            seen.add(guess)
            cands.append(guess)
    return cands


def find_camera():
    """Return (ip, info_dict) for the attached camera, or raise CameraError."""
    tried = _candidate_ips()
    for ip in tried:
        try:
            info = _get_json(ip, "/gopro/camera/info", timeout=CONNECT_TIMEOUT)
        except Exception:
            continue
        if "model_name" in info:
            return ip, info
    raise CameraError(
        "No GoPro found. Checked: %s\n"
        "Plug the camera in, power it on, and make sure it is in "
        "'GoPro Connect' USB mode (not MTP)." % (", ".join(tried) or "no USB network interface")
    )


def _get_json(ip, path, timeout=10.0):
    conn = http.client.HTTPConnection(ip, HTTP_PORT, timeout=timeout)
    try:
        conn.request("GET", path)
        resp = conn.getresponse()
        body = resp.read()
        if resp.status != 200:
            raise CameraError("%s -> HTTP %d" % (path, resp.status))
        return json.loads(body.decode("utf-8"))
    finally:
        conn.close()


class Camera(object):
    def __init__(self, ip, info=None):
        self.ip = ip
        self.info = info or {}

    @classmethod
    def discover(cls):
        ip, info = find_camera()
        return cls(ip, info)

    @property
    def model(self):
        return self.info.get("model_name", "GoPro")

    def get_json(self, path, timeout=10.0):
        return _get_json(self.ip, path, timeout=timeout)

    def poke(self, path, timeout=5.0):
        """Fire-and-forget control call; returns True on HTTP 200."""
        try:
            conn = http.client.HTTPConnection(self.ip, HTTP_PORT, timeout=timeout)
            try:
                conn.request("GET", path)
                return conn.getresponse().status == 200
            finally:
                conn.close()
        except Exception:
            return False

    def keep_alive(self):
        return self.poke("/gopro/camera/keep_alive")

    def enable_wired_control(self):
        return self.poke("/gopro/camera/control/wired_usb?p=1")

    def media_list(self):
        """Return {dirname: {filename: {'size': int, 'mtime': int}}}."""
        data = self.get_json("/gopro/media/list", timeout=20.0)
        tree = {}
        for entry in data.get("media", []):
            folder = entry.get("d")
            if not folder:
                continue
            files = tree.setdefault(folder, {})
            for f in entry.get("fs", []):
                for name in _expand(f):
                    files[name] = {
                        "size": int(f.get("s", 0) or 0),
                        "mtime": int(f.get("mod") or f.get("cre") or 0),
                    }
        return tree

    def free_bytes(self):
        """Free space on the card, in bytes (camera status key 54 is in KB)."""
        try:
            state = self.get_json("/gopro/camera/state", timeout=8.0)["status"]
            return int(state["54"]) * 1024
        except Exception:
            return 0

    def file_url_path(self, folder, name):
        return "%s/%s/%s" % (DCIM_ROOT, folder, name)

    def open_file(self, folder, name, byte_range=None, timeout=60.0):
        """Return (http.client.HTTPResponse, conn). Caller must close conn."""
        conn = http.client.HTTPConnection(self.ip, HTTP_PORT, timeout=timeout)
        headers = {}
        if byte_range:
            headers["Range"] = byte_range
        conn.request("GET", self.file_url_path(folder, name), headers=headers)
        return conn.getresponse(), conn


def _expand(f):
    """Yield real filenames for a media-list entry, expanding burst/group entries."""
    name = f.get("n")
    if not name:
        return
    grouped = "g" in f and "b" in f and "l" in f
    if not grouped:
        yield name
        return
    m = re.match(r"^(\D*)(\d+)(\..+)$", name)
    if not m:
        yield name
        return
    prefix, digits, ext = m.group(1), m.group(2), m.group(3)
    width = len(digits)
    try:
        first, last = int(f["b"]), int(f["l"])
    except (TypeError, ValueError):
        yield name
        return
    if last < first or last - first > 10000:
        yield name
        return
    for n in range(first, last + 1):
        yield "%s%0*d%s" % (prefix, width, n, ext)
