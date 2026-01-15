#!/bin/bash
set -euo pipefail

brush_bin="/Users/alexanderturin/projects/4DSplat/brush/target/release/brush"
zip_path="/Users/alexanderturin/projects/4DSplat/ply_frames.zip"

if [ ! -x "$brush_bin" ]; then
  echo "Brush binary not found or not executable: $brush_bin"
  exit 1
fi

if [ ! -f "$zip_path" ]; then
  echo "Zip file not found: $zip_path"
  exit 1
fi

cd /Users/alexanderturin/projects/4DSplat/brush
./target/release/brush "$zip_path"

