#!/bin/bash
set -euo pipefail

input_path="/Users/alexanderturin/projects/4DSplat/input.MOV"

if ! command -v ffprobe >/dev/null 2>&1; then
  echo "ffprobe is required (part of ffmpeg)."
  exit 1
fi

frame_count="$(ffprobe -v error -select_streams v:0 -count_frames \
  -show_entries stream=nb_read_frames -of csv=p=0 "$input_path")"

if [ -z "$frame_count" ]; then
  echo "Unable to read frame count for: $input_path"
  exit 1
fi

total_gb="$(awk -v frames="$frame_count" 'BEGIN { total_mb = frames * 66.1; printf "%.3f", total_mb / 1024 }')"

echo "Frames: $frame_count"
echo "Estimated total size: ${total_gb} GB"

