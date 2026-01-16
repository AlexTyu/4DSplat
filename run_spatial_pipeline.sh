#!/usr/bin/env sh
# Pipeline steps:
# 1) Extract frames from the selected video into tmp/frames.
# 2) Convert frames to PLYs using image_to_splat.sh.
# 3) Convert PLYs to stereo frames using ply_to_stereo.sh.
# 4) Convert stereo frames to videos using stereo_frames_to_video.sh.

set -eu

# Debug mode: skip all prompts and auto-select video 6
DEBUG="${DEBUG:-0}"
if [ "$#" -gt 0 ] && [ "$1" = "--debug" ]; then
  DEBUG=1
  shift
fi

ROOT_DIR="/Users/alexanderturin/projects/4DSplat"
INPUT_VIDEOS_DIR="${ROOT_DIR}/input_videos"
OUTPUT_ROOT="${ROOT_DIR}/output"

KEEP_PLY=0

if [ ! -d "$INPUT_VIDEOS_DIR" ]; then
  echo "[PIPELINE] Input videos folder not found: $INPUT_VIDEOS_DIR"
  exit 1
fi

input_list="$(find "$INPUT_VIDEOS_DIR" -maxdepth 1 -type f ! -name ".DS_Store" | sort)"
if [ -z "$input_list" ]; then
  echo "[PIPELINE] No input videos found in: $INPUT_VIDEOS_DIR"
  exit 1
fi

if [ "$DEBUG" -eq 1 ]; then
  echo "[PIPELINE] DEBUG MODE: Auto-selecting video 6 (fur-micro.mov)"
  choice=6
else
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
fi

selected="$(printf "%s\n" "$input_list" | sed -n "${choice}p")"
if [ -z "$selected" ]; then
  echo "[PIPELINE] Invalid selection."
  exit 1
fi

input_video="$selected"
project_name="$(basename "${input_video%.*}")"

if [ "$DEBUG" -eq 1 ]; then
  echo "[PIPELINE] DEBUG MODE: Not keeping PLY files"
  KEEP_PLY=0
else
  printf "Keep PLY files? [y/N]: "
  read -r keep_choice
  keep_choice="$(printf "%s" "$keep_choice" | tr '[:upper:]' '[:lower:]')"
  if [ "$keep_choice" = "y" ] || [ "$keep_choice" = "yes" ]; then
    KEEP_PLY=1
  else
    KEEP_PLY=0
  fi
fi

project_dir="${OUTPUT_ROOT}/${project_name}"
tmp_dir="${project_dir}/tmp"
frames_dir="${tmp_dir}/frames"
ply_dir="${tmp_dir}/ply"
stereo_dir="${tmp_dir}/stereo_frames"
video_dir="${project_dir}/video_output"
spatial_output="${video_dir}/spatial_video_spatialmediakit.mov"

if [ -d "$tmp_dir" ]; then
  if [ "$DEBUG" -eq 1 ]; then
    echo "[PIPELINE] DEBUG MODE: Overwriting existing temp folder"
    rm -rf "$tmp_dir"
  else
    printf "Temp folder already exists for this project. Overwrite? [Y/n]: "
    read -r overwrite_choice
    overwrite_choice="$(printf "%s" "$overwrite_choice" | tr '[:upper:]' '[:lower:]')"
    if [ -z "$overwrite_choice" ] || [ "$overwrite_choice" = "y" ] || [ "$overwrite_choice" = "yes" ]; then
      rm -rf "$tmp_dir"
    else
      echo "[PIPELINE] Keeping existing temp folder."
    fi
  fi
fi

mkdir -p "$frames_dir" "$ply_dir" "$stereo_dir"
rm -rf "$stereo_dir"
mkdir -p "$stereo_dir"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "[PIPELINE] ffmpeg is required but not found in PATH."
  exit 1
fi

if ! command -v ffprobe >/dev/null 2>&1; then
  echo "[PIPELINE] ffprobe is required but not found in PATH."
  exit 1
fi

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
if [ "$DEBUG" -eq 1 ]; then
  frame_count=$(sh "${ROOT_DIR}/extract_video_frames.sh" --input "$input_video" --output "$frames_dir" --debug | tail -n 1)
else
  frame_count=$(sh "${ROOT_DIR}/extract_video_frames.sh" --input "$input_video" --output "$frames_dir" | tail -n 1)
fi

if [ "$frame_count" -eq 0 ]; then
  echo "[PIPELINE] No frames processed."
  exit 1
fi

if [ "$frame_count" -gt 0 ]; then
  estimate_seconds="$(
    python3 - <<PY
frames = int("$frame_count")
print(frames * 6)
PY
  )"
  hours=$((estimate_seconds / 3600))
  minutes=$(((estimate_seconds % 3600) / 60))
  if [ "$DEBUG" -eq 1 ]; then
    echo "[PIPELINE] DEBUG MODE: Processing only ${frame_count} frames (estimated ${hours}h ${minutes}m)"
    echo "[PIPELINE] DEBUG MODE: Auto-continuing"
  else
    echo "[PIPELINE] Estimated processing time for ${frame_count} frames: ${hours}h ${minutes}m (6s/frame)."
    printf "Continue? [Y/n]: "
    read -r confirm_choice
    confirm_choice="$(printf "%s" "$confirm_choice" | tr '[:upper:]' '[:lower:]')"
    if [ -n "$confirm_choice" ] && [ "$confirm_choice" != "y" ] && [ "$confirm_choice" != "yes" ]; then
      echo "[PIPELINE] Aborted."
      exit 0
    fi
  fi

  echo "[PIPELINE] Processing frames in batches of 5..."
  
  # Get list of frame files
  frame_list="$(ls -1 "$frames_dir"/frame_*.jpg 2>/dev/null | sort || true)"
  if [ -z "$frame_list" ]; then
    echo "[PIPELINE] No frame files found."
    exit 1
  fi
  
  # Create single sharp_batch folder in tmp
  sharp_batch_dir="${tmp_dir}/sharp_batch"
  mkdir -p "$sharp_batch_dir"
  trap 'rm -rf "$sharp_batch_dir"' EXIT
  
  batch_size=10
  batch_num=0
  batch_frames=""
  frame_count=0
  
  for frame_path in $frame_list; do
    batch_frames="$batch_frames$frame_path
"
    frame_count=$((frame_count + 1))
    
    if [ "$frame_count" -ge "$batch_size" ]; then
      batch_num=$((batch_num + 1))
      
      # Clear and populate sharp_batch folder with current batch
      rm -f "$sharp_batch_dir"/*
      printf "%s" "$batch_frames" | while IFS= read -r f; do
        if [ -n "$f" ] && [ -f "$f" ]; then
          frame_name="$(basename "$f")"
          abs_path="$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"
          ln -s "$abs_path" "$sharp_batch_dir/$frame_name" 2>/dev/null || cp "$f" "$sharp_batch_dir/$frame_name"
        fi
      done
      
      echo "[PIPELINE] Batch $batch_num: Generating PLY files..."
      if ! sh "${ROOT_DIR}/image_to_splat.sh" --input "$sharp_batch_dir" --output "$ply_dir"; then
        echo "[PIPELINE] ERROR: Failed to generate PLY files for batch $batch_num"
        exit 1
      fi
      
      echo "[PIPELINE] Batch $batch_num: Generating stereo images..."
      # Process PLY files directly from ply_dir for this batch
      ply_files_processed=0
      while IFS= read -r f; do
        if [ -n "$f" ] && [ -f "$f" ]; then
          frame_name="$(basename "$f")"
          # Strip any extension and add .ply
          frame_stem="${frame_name%.*}"
          ply_name="${frame_stem}.ply"
          ply_path="$ply_dir/$ply_name"
          if [ -f "$ply_path" ]; then
            echo "[PIPELINE] Batch $batch_num: Processing $ply_name..."
            if ! KEEP_PLY="$KEEP_PLY" sh "${ROOT_DIR}/ply_to_stereo.sh" --input "$ply_path" --output "$stereo_dir"; then
              echo "[PIPELINE] ERROR: Failed to generate stereo images for $ply_name"
              exit 1
            fi
            ply_files_processed=$((ply_files_processed + 1))
            
            # If KEEP_PLY=0, delete PLY file after stereo generation
            if [ "$KEEP_PLY" -eq 0 ]; then
              rm -f "$ply_path"
            fi
          else
            echo "[PIPELINE] WARNING: PLY file not found: $ply_path"
          fi
        fi
      done <<EOF
$batch_frames
EOF
      
      if [ "$ply_files_processed" -gt 0 ]; then
        echo "[PIPELINE] Batch $batch_num: Successfully processed $ply_files_processed PLY file(s)"
      else
        echo "[PIPELINE] WARNING: Batch $batch_num: No PLY files found in $ply_dir for this batch"
      fi
      
      batch_frames=""
      frame_count=0
    fi
  done
  
  # Process remaining frames if any
  if [ "$frame_count" -gt 0 ]; then
    batch_num=$((batch_num + 1))
    
    # Clear and populate sharp_batch folder with remaining frames
    rm -f "$sharp_batch_dir"/*
    printf "%s" "$batch_frames" | while IFS= read -r f; do
      if [ -n "$f" ] && [ -f "$f" ]; then
        frame_name="$(basename "$f")"
        abs_path="$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"
        ln -s "$abs_path" "$sharp_batch_dir/$frame_name" 2>/dev/null || cp "$f" "$sharp_batch_dir/$frame_name"
      fi
    done
    
    echo "[PIPELINE] Batch $batch_num: Generating PLY files..."
    if ! sh "${ROOT_DIR}/image_to_splat.sh" --input "$sharp_batch_dir" --output "$ply_dir"; then
      echo "[PIPELINE] ERROR: Failed to generate PLY files for batch $batch_num"
      exit 1
    fi
    
    echo "[PIPELINE] Batch $batch_num: Generating stereo images..."
    # Process PLY files directly from ply_dir for this batch
    ply_files_processed=0
    while IFS= read -r f; do
      if [ -n "$f" ] && [ -f "$f" ]; then
        frame_name="$(basename "$f")"
        # Strip any extension and add .ply
        frame_stem="${frame_name%.*}"
        ply_name="${frame_stem}.ply"
        ply_path="$ply_dir/$ply_name"
        if [ -f "$ply_path" ]; then
          echo "[PIPELINE] Batch $batch_num: Processing $ply_name..."
          if ! KEEP_PLY="$KEEP_PLY" sh "${ROOT_DIR}/ply_to_stereo.sh" --input "$ply_path" --output "$stereo_dir"; then
            echo "[PIPELINE] ERROR: Failed to generate stereo images for $ply_name"
            exit 1
          fi
          ply_files_processed=$((ply_files_processed + 1))
          
          # If KEEP_PLY=0, delete PLY file after stereo generation
          if [ "$KEEP_PLY" -eq 0 ]; then
            rm -f "$ply_path"
          fi
        else
          echo "[PIPELINE] WARNING: PLY file not found: $ply_path"
        fi
      fi
    done <<EOF
$batch_frames
EOF
    
    if [ "$ply_files_processed" -gt 0 ]; then
      echo "[PIPELINE] Batch $batch_num: Successfully processed $ply_files_processed PLY file(s)"
    else
      echo "[PIPELINE] WARNING: Batch $batch_num: No PLY files found in $ply_dir for this batch"
    fi
  fi
  
  rm -rf "$sharp_batch_dir"
  echo "[PIPELINE] Completed processing $batch_num batches"
fi

echo "[PIPELINE] Rendering videos for each eye..."
sh "${ROOT_DIR}/stereo_frames_to_video.sh" \
  --input "$stereo_dir" \
  --output "$video_dir" \
  --fps "$fps" \
  --spatial-output "$spatial_output"

echo "[PIPELINE] Done. Output in: $project_dir"

