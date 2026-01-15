#!/usr/bin/env sh
# Pipeline steps:
# 1) Extract frames from the selected video into tmp/frames.
# 2) Convert frames to PLYs using image_to_splat.sh.
# 3) Convert PLYs to stereo frames using ply_to_stereo.sh.
# 4) Convert stereo frames to videos using stereo_frames_to_video.py.

set -eu

ROOT_DIR="/Users/alexanderturin/projects/4DSplat"
INPUT_VIDEOS_DIR="${ROOT_DIR}/input_videos"
OUTPUT_ROOT="${ROOT_DIR}/output"

KEEP_TEMP=1

for arg in "$@"; do
  case "$arg" in
    -keepTemp) KEEP_TEMP=1 ;;
  esac
done

if [ ! -d "$INPUT_VIDEOS_DIR" ]; then
  echo "[PIPELINE] Input videos folder not found: $INPUT_VIDEOS_DIR"
  exit 1
fi

input_list="$(find "$INPUT_VIDEOS_DIR" -maxdepth 1 -type f ! -name ".DS_Store" | sort)"
if [ -z "$input_list" ]; then
  echo "[PIPELINE] No input videos found in: $INPUT_VIDEOS_DIR"
  exit 1
fi

echo "[PIPELINE] Select input video:"
i=1
printf "%s\n" "$input_list" | while IFS= read -r line; do
  base_name="$(basename "$line")"
  printf "%d. %s\n" "$i" "$base_name"
  i=$((i + 1))
done

selected=""
while [ -z "$selected" ]; do
  printf "Enter number: "
  read -r choice || exit 1
  case "$choice" in
    *[!0-9]*|"") echo "[PIPELINE] Please enter a number." ; continue ;;
  esac
  selected="$(printf "%s\n" "$input_list" | sed -n "${choice}p")"
  if [ -z "$selected" ]; then
    echo "[PIPELINE] Invalid selection."
    continue
  fi
done

input_video="$selected"
project_name="$(basename "${input_video%.*}")"

printf "Keep temp files? [Y/n]: "
read -r keep_choice
keep_choice="$(printf "%s" "$keep_choice" | tr '[:upper:]' '[:lower:]')"
if [ -n "$keep_choice" ] && [ "$keep_choice" != "y" ] && [ "$keep_choice" != "yes" ]; then
  KEEP_TEMP=0
fi

project_dir="${OUTPUT_ROOT}/${project_name}"
tmp_dir="${project_dir}/tmp"
frames_dir="${tmp_dir}/frames"
ply_dir="${tmp_dir}/ply"
stereo_dir="${tmp_dir}/stereo_frames"
video_dir="${project_dir}/video_output"
spatial_output="${video_dir}/spatial_video_spatialmediakit.mov"

if [ -d "$tmp_dir" ]; then
  printf "Temp folder already exists for this project. Overwrite? [Y/n]: "
  read -r overwrite_choice
  overwrite_choice="$(printf "%s" "$overwrite_choice" | tr '[:upper:]' '[:lower:]')"
  if [ -z "$overwrite_choice" ] || [ "$overwrite_choice" = "y" ] || [ "$overwrite_choice" = "yes" ]; then
    rm -rf "$tmp_dir"
  else
    echo "[PIPELINE] Keeping existing temp folder."
  fi
fi

mkdir -p "$frames_dir" "$ply_dir" "$stereo_dir"

use_existing_stereo=0
if [ -d "$stereo_dir" ]; then
  rm -rf "$stereo_dir"
fi
mkdir -p "$stereo_dir"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "[PIPELINE] ffmpeg is required but not found in PATH."
  exit 1
fi

if ! command -v ffprobe >/dev/null 2>&1; then
  echo "[PIPELINE] ffprobe is required but not found in PATH."
  exit 1
fi

total_frames="$(
  ffprobe -v error -count_frames -select_streams v:0 \
    -show_entries stream=nb_read_frames \
    -of default=nw=1:nk=1 "$input_video" \
  | python3 - <<'PY'
import sys
val = sys.stdin.read().strip()
try:
    print(int(val))
except Exception:
    print(0)
PY
)"

fps="$(
  ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate \
    -of default=nw=1:nk=1 "$input_video" \
  | python3 - <<'PY'
import sys
rate = sys.stdin.read().strip()
if "/" in rate:
    num, den = rate.split("/", 1)
    try:
        print(float(num) / float(den))
    except Exception:
        print("30.0")
else:
    try:
        print(float(rate))
    except Exception:
        print("30.0")
PY
)"

frame_count=0
if [ "$use_existing_stereo" -eq 0 ]; then
  echo "[PIPELINE] Extracting frames..."
  ffmpeg -y -i "$input_video" "${frames_dir}/frame_%06d.png" >/dev/null
  frame_count=$(ls "$frames_dir"/frame_*.png 2>/dev/null | wc -l | tr -d ' ')
fi

if [ "$use_existing_stereo" -eq 0 ]; then
  if [ "$frame_count" -eq 0 ]; then
    echo "[PIPELINE] No frames processed."
    exit 1
  fi

  estimate_seconds="$(
    python3 - <<PY
frames = int("$frame_count")
print(frames * 6)
PY
  )"
  hours=$((estimate_seconds / 3600))
  minutes=$(((estimate_seconds % 3600) / 60))
  echo "[PIPELINE] Estimated processing time for ${frame_count} frames: ${hours}h ${minutes}m (6s/frame)."
  printf "Continue? [Y/n]: "
  read -r confirm_choice
  confirm_choice="$(printf "%s" "$confirm_choice" | tr '[:upper:]' '[:lower:]')"
  if [ -n "$confirm_choice" ] && [ "$confirm_choice" != "y" ] && [ "$confirm_choice" != "yes" ]; then
    echo "[PIPELINE] Aborted."
    exit 0
  fi

  echo "[PIPELINE] Batch PLY generation..."
  sh "${ROOT_DIR}/image_to_splat.sh" --input "$frames_dir" --output "$ply_dir"

  echo "[PIPELINE] Rendering stereo frames..."
  KEEP_TEMP="$KEEP_TEMP" sh "${ROOT_DIR}/ply_to_stereo.sh" --input "$ply_dir" --output "$stereo_dir"
fi

echo "[PIPELINE] Rendering videos for each eye..."
python3 "${ROOT_DIR}/stereo_frames_to_video.py" \
  --input "$stereo_dir" \
  --output "$video_dir" \
  --fps "$fps" \
  --spatial-output "$spatial_output"

echo "[PIPELINE] Done. Output in: $project_dir"

