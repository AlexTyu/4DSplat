#!/bin/bash
set -euo pipefail

ROOT_DIR="/Users/alexanderturin/projects/4DSplat"

usage() {
  echo "Usage: $0 -i <stereo_frames_dir> -o <output_dir> [--fps <fps>] [--spatial-output <path>]"
}

input_dir=""
output_dir=""
fps="30"
spatial_output=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -i|--input)
      input_dir="$2"
      shift 2
      ;;
    -o|--output)
      output_dir="$2"
      shift 2
      ;;
    --fps)
      fps="$2"
      shift 2
      ;;
    --spatial-output)
      spatial_output="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

if [ -z "$input_dir" ] || [ -z "$output_dir" ]; then
  usage
  exit 1
fi

if [ ! -d "$input_dir" ]; then
  echo "Stereo frames directory not found: $input_dir"
  exit 1
fi

mkdir -p "$output_dir"

left_video="$output_dir/left_eye.mp4"
right_video="$output_dir/right_eye.mp4"
if [ -z "$spatial_output" ]; then
  spatial_output="$output_dir/spatial_video_spatialmediakit.mov"
fi

ffmpeg -y -framerate "$fps" -i "$input_dir/frame_%06d_left.png" \
  -c:v libx264 -crf 0 -preset veryslow -pix_fmt yuv420p -r "$fps" "$left_video"

ffmpeg -y -framerate "$fps" -i "$input_dir/frame_%06d_right.png" \
  -c:v libx264 -crf 0 -preset veryslow -pix_fmt yuv420p -r "$fps" "$right_video"

spatial_script="$ROOT_DIR/make_spatial_video.sh"
if [ ! -f "$spatial_script" ]; then
  echo "Spatial video script not found: $spatial_script"
  exit 1
fi

bash "$spatial_script" "$left_video" "$right_video" "$spatial_output"
echo "Done. Output in: $output_dir"

