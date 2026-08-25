#!/bin/bash
# Double-click this in Finder to copy new clips off the camera.
cd "$(dirname "$0")"
./gopro-pull --open
echo
echo "Press any key to close..."
read -n 1 -s
