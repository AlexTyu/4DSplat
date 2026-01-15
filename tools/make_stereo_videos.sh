#!/bin/bash
set -euo pipefail

input_dir="${1:-stereo_output}"
fps="${2:-30}"
output_dir="${3:-video_output}"
output_left_name="${4:-left_eye.mp4}"
output_right_name="${5:-right_eye.mp4}"
spatial_name="${6:-spatial_video.mov}"

mkdir -p "$output_dir"
output_left="${output_dir}/${output_left_name}"
output_right="${output_dir}/${output_right_name}"
spatial_output="${output_dir}/${spatial_name}"
spatial_sbs_output="${output_dir}/spatial_video_sbs.mp4"

ffmpeg -y -framerate "$fps" -i "${input_dir}/frame_%06d_left.png" \
  -c:v libx264 -pix_fmt yuv420p -r "$fps" "$output_left"

ffmpeg -y -framerate "$fps" -i "${input_dir}/frame_%06d_right.png" \
  -c:v libx264 -pix_fmt yuv420p -r "$fps" "$output_right"

# Apple Spatial Video uses MV-HEVC (multiview HEVC) in a .mov container.
# We attempt MV-HEVC first and fall back to a side-by-side stereo file if
# the local ffmpeg/x265 build doesn't support multiview.
mvhevc_ok=false
if ffmpeg -y -i "$output_left" -i "$output_right" \
  -map 0:v -map 1:v \
  -c:v libx265 -pix_fmt yuv420p \
  -tag:v hvc1 \
  -x265-params "multiview=1:views=2" \
  "$spatial_output" >/tmp/spatial_encode.log 2>&1; then
  video_streams="$(ffprobe -v error -select_streams v \
    -show_entries stream=index -of csv=p=0 "$spatial_output" | wc -l | tr -d ' ')"
  if [ "$video_streams" = "1" ]; then
    mvhevc_ok=true
  else
    rm -f "$spatial_output"
  fi
fi

if [ "$mvhevc_ok" = "true" ]; then
  echo "Spatial video written to: $spatial_output"
else
  echo "MV-HEVC not supported by this ffmpeg/x265 build."
  echo "Writing side-by-side fallback to: $spatial_sbs_output"
  ffmpeg -y -i "$output_left" -i "$output_right" \
    -filter_complex "[0:v][1:v]hstack=inputs=2[v]" \
    -map "[v]" -c:v libx264 -pix_fmt yuv420p -r "$fps" \
    -metadata:s:v:0 stereo_mode=left_right \
    "$spatial_sbs_output"
  echo "Tip: Use Apple Compressor/Final Cut Pro to export MV-HEVC spatial video."
fi

