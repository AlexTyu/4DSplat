#!/bin/bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
left_input="${1:-$root_dir/video_output/left_eye.mp4}"
right_input="${2:-$root_dir/video_output/right_eye.mp4}"
output_path="${3:-$root_dir/video_output/spatial_video.mov}"

hfov="${HFOV:-63.4}"
cdist="${CDIST:-19.24}"
projection="${PROJECTION:-rect}"
primary="${PRIMARY:-right}"
hadjust="${HADJUST:-0.02}"
quality="${QUALITY:-1.0}"
bitrate="${BITRATE:-}"

if ! command -v spatial >/dev/null 2>&1; then
  echo "spatial CLI not found. Install with: brew install spatial"
  exit 1
fi

if [ ! -f "$left_input" ]; then
  echo "Left input not found: $left_input"
  exit 1
fi

if [ ! -f "$right_input" ]; then
  echo "Right input not found: $right_input"
  exit 1
fi

if command -v ffprobe >/dev/null 2>&1; then
  left_info="$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate \
    -of default=nw=1 "$left_input" | tr '\n' ' ')"
  right_info="$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate \
    -of default=nw=1 "$right_input" | tr '\n' ' ')"
  if [ "$left_info" != "$right_info" ]; then
    echo "Left/right video mismatch. Ensure same resolution and frame rate."
    echo "Left:  $left_info"
    echo "Right: $right_info"
    exit 1
  fi
fi

cmd=(
  spatial make
  --input "$left_input"
  --input "$right_input"
  --hfov "$hfov"
  --cdist "$cdist"
  --hadjust "$hadjust"
  --projection "$projection"
  --primary "$primary"
  --output "$output_path"
)

if [ -n "$quality" ]; then
  cmd+=(--quality "$quality")
fi
if [ -n "$bitrate" ]; then
  cmd+=(--bitrate "$bitrate")
fi

"${cmd[@]}"

echo "Spatial video written to: $output_path"

