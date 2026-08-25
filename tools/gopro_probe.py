#!/usr/bin/env python3
"""Print a one-line description of the attached camera, or explain why not."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gopro_lib import Camera, CameraError

try:
    cam = Camera.discover()
except CameraError as exc:
    sys.stderr.write("%s\n" % exc)
    sys.exit(1)

tree = {}
try:
    tree = cam.media_list()
except Exception:
    pass
count = sum(len(v) for v in tree.values())
size = sum(m["size"] for v in tree.values() for m in v.values())
print("Found %s at %s -- %d file(s), %.1f GB"
      % (cam.model, cam.ip, count, size / 1e9))
