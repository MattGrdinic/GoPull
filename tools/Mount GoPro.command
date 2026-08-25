#!/bin/bash
# Double-click this in Finder to mount the camera.
cd "$(dirname "$0")"
./gopro-mount
echo
echo "Press any key to close..."
read -n 1 -s
