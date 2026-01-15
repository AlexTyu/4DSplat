#!/bin/bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
left_input="${1:-$root_dir/video_output/left_eye.mp4}"
right_input="${2:-$root_dir/video_output/right_eye.mp4}"
output_path="${3:-$root_dir/video_output/spatial_video_spatialmediakit.mov}"
tmp_output="${output_path%.mov}.tmp.mov"

quality="${QUALITY:-50}"
hfov="${HFOV:-90.0}"
primary="${PRIMARY:-right}"
hadjust="${HADJUST:-}"
md_cdist="${MD_CDIST:-19.24}"
md_hfov="${MD_HFOV:-$hfov}"
md_hadjust="${MD_HADJUST:-0.02}"

tool_path="$(command -v spatial-media-kit-tool || true)"
if [ -z "$tool_path" ]; then
  if [ -x "$root_dir/spatial-media-kit-tool" ]; then
    tool_path="$root_dir/spatial-media-kit-tool"
  fi
fi

if [ -z "$tool_path" ]; then
  echo "spatial-media-kit-tool not found. Install from:"
  echo "https://github.com/sturmen/SpatialMediaKit"
  echo "Or place the binary at: $root_dir/spatial-media-kit-tool"
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

primary_flag="--right-is-primary"
if [ "$primary" = "left" ]; then
  primary_flag="--left-is-primary"
fi

merge_args=(
  merge
  --left-file "$left_input"
  --right-file "$right_input"
  --quality "$quality"
  "$primary_flag"
  --horizontal-field-of-view "$hfov"
  --output-file "$tmp_output"
)

if [ -n "$hadjust" ]; then
  merge_args+=(--horizontal-disparity-adjustment "$hadjust")
fi

rm -f "$tmp_output"
"$tool_path" "${merge_args[@]}"

if [ ! -f "$tmp_output" ]; then
  echo "Merge did not produce output: $tmp_output"
  exit 1
fi

if command -v spatial >/dev/null 2>&1; then
  metadata_output="${output_path%.mov}.metadata.mov"
  spatial metadata -i "$tmp_output" -o "$metadata_output" \
    --set "vexu:cameraBaseline=$md_cdist" \
    --set "vexu:horizontalFieldOfView=$md_hfov" \
    --set "vexu:horizontalDisparityAdjustment=$md_hadjust" \
    --set "vexu:heroEyeIndicator=$primary"
  mv -f "$metadata_output" "$output_path"
  rm -f "$tmp_output"
else
  echo "Note: spatial CLI not found; skipping metadata injection."
  echo "Install from https://blog.mikeswanson.com/spatial/ if needed."
  mv -f "$tmp_output" "$output_path"
fi

echo "SpatialMediaKit video written to: $output_path"

