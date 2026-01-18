#!/usr/bin/env sh
# Pipeline steps:
# 1) Extract frames from the selected video into frames/.
# 2) Convert frames to PLYs using image_to_splat.sh.
# 3) Convert PLYs to stereo frames using ply_to_stereo.sh.
# 4) Convert stereo frames to videos using stereo_frames_to_video.sh.

set -eu

# Progress bar function
show_progress() {
  local current=$1
  local total=$2
  local start_time=$3
  local width=50
  
  # Calculate percentage with 2 decimal places
  local percentage
  if [ "$total" -gt 0 ]; then
    percentage=$(awk "BEGIN {printf \"%.2f\", ($current * 100.0) / $total}")
  else
    percentage="0.00"
  fi
  
  # Calculate filled and empty bars
  local filled
  filled=$(awk "BEGIN {printf \"%.0f\", ($current * $width) / $total}")
  if [ "$filled" -gt "$width" ]; then
    filled=$width
  fi
  
  # Calculate elapsed time
  local current_time
  current_time="$(date +%s)"
  local elapsed=$((current_time - start_time))
  local hours=$((elapsed / 3600))
  local minutes=$(((elapsed % 3600) / 60))
  local seconds=$((elapsed % 60))
  
  # Format elapsed time
  local elapsed_str
  if [ "$hours" -gt 0 ]; then
    elapsed_str=$(printf "%dh %dm %ds" "$hours" "$minutes" "$seconds")
  elif [ "$minutes" -gt 0 ]; then
    elapsed_str=$(printf "%dm %ds" "$minutes" "$seconds")
  else
    elapsed_str=$(printf "%ds" "$seconds")
  fi
  
  # Calculate estimated time remaining
  local remaining_str=""
  if [ "$current" -gt 0 ] && [ "$elapsed" -gt 0 ]; then
    local avg_time_per_frame
    avg_time_per_frame=$(awk "BEGIN {printf \"%.2f\", $elapsed / $current}")
    local remaining_frames=$((total - current))
    local remaining_seconds
    remaining_seconds=$(awk "BEGIN {printf \"%.0f\", $avg_time_per_frame * $remaining_frames}")
    
    if [ "$remaining_seconds" -gt 0 ]; then
      local rem_hours=$((remaining_seconds / 3600))
      local rem_minutes=$(((remaining_seconds % 3600) / 60))
      local rem_secs=$((remaining_seconds % 60))
      
      if [ "$rem_hours" -gt 0 ]; then
        remaining_str=$(printf " | ETA: %dh %dm %ds" "$rem_hours" "$rem_minutes" "$rem_secs")
      elif [ "$rem_minutes" -gt 0 ]; then
        remaining_str=$(printf " | ETA: %dm %ds" "$rem_minutes" "$rem_secs")
      else
        remaining_str=$(printf " | ETA: %ds" "$rem_secs")
      fi
    fi
  fi
  
  # Build progress bar
  local bar=""
  local i=0
  while [ $i -lt "$filled" ]; do
    bar="${bar}█"
    i=$((i + 1))
  done
  while [ $i -lt $width ]; do
    bar="${bar}░"
    i=$((i + 1))
  done
  
  printf "\r[PIPELINE] Progress: [%s] %s%% (%d/%d frames) | Elapsed: %s%s" "$bar" "$percentage" "$current" "$total" "$elapsed_str" "$remaining_str"
}

# Format seconds into readable time string
format_time() {
  local seconds=$1
  local hours=$((seconds / 3600))
  local minutes=$(((seconds % 3600) / 60))
  local secs=$((seconds % 60))
  
  if [ "$hours" -gt 0 ]; then
    printf "%dh %dm %ds" "$hours" "$minutes" "$secs"
  elif [ "$minutes" -gt 0 ]; then
    printf "%dm %ds" "$minutes" "$secs"
  else
    printf "%ds" "$secs"
  fi
}

# Debug mode: skip all prompts and auto-select video 6
DEBUG="${DEBUG:-0}"
VERBOSE="${VERBOSE:-0}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --debug)
      DEBUG=1
      shift
      ;;
    --verbose|-v)
      VERBOSE=1
      shift
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: $0 [--debug] [--verbose]"
      exit 1
      ;;
  esac
done

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

# Options menu
MODE="default"
if [ "$DEBUG" -eq 1 ]; then
  echo "[PIPELINE] DEBUG MODE: Using default mode"
  MODE="default"
else
  echo "[PIPELINE] Select mode:"
  echo "  1. Default (full pipeline)"
  echo "  2. Generate spatial video from existing stereo frames"
  echo "  3. Generate ply Frames only"
  echo "  4. Generate PLY frames only (time range)"
  echo "  5. Deploy PLY files to Vision Pro"
  echo "  6. Extract video frames"
  echo "  7. Render ply frames in Brush Viewer"
  echo "  8. Generate PLY from existing frames"
  echo "  9. Predict Focal length in Frames"
  printf "Enter number [1]: "
  read -r mode_choice
  mode_choice="${mode_choice:-1}"
  case "$mode_choice" in
    1)
      MODE="default"
      ;;
    2)
      MODE="spatial_from_stereo"
      ;;
    3)
      MODE="single_ply"
      ;;
    4)
      MODE="ply_frames_only"
      ;;
    5)
      MODE="deploy_to_vision_pro"
      ;;
    6)
      MODE="extract_frames"
      ;;
    7)
      MODE="render_ply_viewer"
      ;;
    8)
      MODE="ply_from_frames"
      ;;
    9)
      MODE="predict_focal_length"
      ;;
    *)
      echo "[PIPELINE] Invalid selection, using default mode"
      MODE="default"
      ;;
  esac
fi

# Set verbose mode for all modes except default (mode 1)
if [ "$MODE" != "default" ]; then
  VERBOSE=1
fi

# Focal length setting (default 30mm)
FOCAL_LENGTH="30.0"
if [ "$MODE" = "default" ] || [ "$MODE" = "single_ply" ] || [ "$MODE" = "ply_frames_only" ] || [ "$MODE" = "extract_frames" ] || [ "$MODE" = "ply_from_frames" ]; then
  if [ "$DEBUG" -eq 1 ]; then
    echo "[PIPELINE] DEBUG MODE: Using default focal length 30.0mm"
    FOCAL_LENGTH="30.0"
  else
    printf "Enter camera focal length in mm [30.0]: "
    read -r focal_input
    focal_input="${focal_input:-30.0}"
    # Validate that it's a number
    case "$focal_input" in
      *[!0-9.]*|"")
        echo "[PIPELINE] Invalid focal length, using default 30.0mm"
        FOCAL_LENGTH="30.0"
        ;;
      *)
        FOCAL_LENGTH="$focal_input"
        ;;
    esac
  fi
fi

if [ "$MODE" = "default" ]; then
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
fi

project_dir="${OUTPUT_ROOT}/${project_name}"
frames_dir="${project_dir}/frames"
ply_dir="${project_dir}/ply"
stereo_dir="${project_dir}/stereo_frames"
video_dir="${project_dir}/video_output"
spatial_output="${video_dir}/spatial_video_spatialmediakit.mov"

# Handle mode-specific logic
if [ "$MODE" = "single_ply" ]; then
  # Single PLY mode: ask for frame number(s) - space-separated for multiple frames
  if [ "$DEBUG" -eq 1 ]; then
    frame_input="1"
    echo "[PIPELINE] DEBUG MODE: Using frame number 1"
  else
    printf "Enter frame number(s) (0-indexed, space-separated for multiple, e.g., 0 10 20): "
    read -r frame_input
  fi
  
  # Parse space-separated frame numbers
  frame_numbers=""
  for frame_str in $frame_input; do
    frame_str="$(echo "$frame_str" | tr -d '[:space:]')"
    case "$frame_str" in
      *[!0-9]*|"")
        echo "[PIPELINE] Invalid frame number: $frame_str"
        exit 1
        ;;
      *)
        if [ -z "$frame_numbers" ]; then
          frame_numbers="$frame_str"
        else
          frame_numbers="$frame_numbers $frame_str"
        fi
        ;;
    esac
  done
  
  if [ -z "$frame_numbers" ]; then
    echo "[PIPELINE] ERROR: No valid frame numbers provided"
    exit 1
  fi
  
  mkdir -p "$frames_dir" "$ply_dir"
  
  # Process each frame
  total_frames=$(echo "$frame_numbers" | wc -w | tr -d ' ')
  current_frame=0
  last_ply_file=""
  
  for frame_num in $frame_numbers; do
    current_frame=$((current_frame + 1))
    frame_name="frame_$(printf '%06d' "$frame_num")"
    
    echo "[PIPELINE] Processing frame $frame_num ($current_frame/$total_frames)..."
    
    # Check if frame already exists
    if [ -f "${frames_dir}/${frame_name}.jpg" ]; then
      echo "[PIPELINE] Frame $frame_num already exists, skipping extraction"
    else
      # Extract frame (ffmpeg uses 0-indexed frames)
      echo "[PIPELINE] Extracting frame $frame_num..."
      ffmpeg -y -i "$input_video" -vf "select=eq(n\,$frame_num)" -vframes 1 -q:v 1 "${frames_dir}/${frame_name}.jpg"
      
      if [ ! -f "${frames_dir}/${frame_name}.jpg" ]; then
        echo "[PIPELINE] ERROR: Failed to extract frame $frame_num"
        echo "[PIPELINE] Frame may be out of range. Check video frame count."
        continue
      fi
    fi
    
    # Add EXIF focal length metadata to extracted frame
    echo "[PIPELINE] Adding EXIF metadata (focal length: ${FOCAL_LENGTH}mm)..."
    python3 - <<PY
import os
import sys
import site

# Add user site-packages to path
site.addsitedir(os.path.expanduser("~/Library/Python/3.11/lib/python/site-packages"))

jpeg_path = "${frames_dir}/${frame_name}.jpg"
focal_length_mm = float("$FOCAL_LENGTH")

# Try to use piexif for proper EXIF embedding
try:
    import piexif
    piexif_available = True
except (ImportError, ModuleNotFoundError) as e:
    piexif_available = False
    print(f"Note: piexif not available ({e}), skipping EXIF metadata", file=sys.stderr)

if piexif_available:
    try:
        # Read existing EXIF if any
        try:
            existing_exif = piexif.load(jpeg_path)
        except:
            existing_exif = {"0th": {}, "Exif": {}, "GPS": {}, "1st": {}, "thumbnail": None, "Interop": {}}
        
        # Add focal length to EXIF
        # FocalLength tag is 37386 (0x920A) in EXIF IFD
        existing_exif["Exif"][37386] = (int(focal_length_mm * 100), 100)  # FocalLength as rational
        
        # Convert to bytes and insert into JPEG
        exif_bytes = piexif.dump(existing_exif)
        
        # Insert EXIF directly into JPEG file using piexif
        piexif.insert(exif_bytes, jpeg_path)
    except Exception as e:
        print(f"Warning: Could not add EXIF to {jpeg_path}: {e}", file=sys.stderr)
PY
    
    # Check if PLY already exists
    ply_file="${ply_dir}/${frame_name}.ply"
    if [ -f "$ply_file" ]; then
      echo "[PIPELINE] PLY file already exists for frame $frame_num, skipping generation"
      last_ply_file="$ply_file"
    else
      # Generate PLY for frame (always verbose in mode 3)
      echo "[PIPELINE] Generating PLY for frame $frame_num..."
      if ! sh "${ROOT_DIR}/image_to_splat.sh" --input "${frames_dir}/${frame_name}.jpg" --output "$ply_dir"; then
        echo "[PIPELINE] ERROR: Failed to generate PLY file for frame $frame_num"
        continue
      fi
      
      if [ -f "$ply_file" ]; then
        echo "[PIPELINE] Successfully generated PLY: $ply_file"
        last_ply_file="$ply_file"
      else
        echo "[PIPELINE] ERROR: PLY file not found at expected location: $ply_file"
      fi
    fi
    
    echo ""
  done
  
  # Summary and open last PLY file with brush viewer
  if [ -n "$last_ply_file" ]; then
    echo "[PIPELINE] Completed processing $total_frames frame(s)"
    
    # Open last PLY file with brush viewer
    brush_bin="${ROOT_DIR}/brush/target/release/brush"
    if [ -x "$brush_bin" ]; then
      echo "[PIPELINE] Opening last PLY file with brush viewer..."
      cd "${ROOT_DIR}/brush"
      "$brush_bin" --with-viewer "$last_ply_file" &
      echo "[PIPELINE] Brush viewer launched in background"
    else
      echo "[PIPELINE] WARNING: Brush binary not found at $brush_bin"
    fi
    
    echo "[PIPELINE] PLY files saved in: $ply_dir"
    echo "[PIPELINE] Done."
    exit 0
  else
    echo "[PIPELINE] ERROR: No PLY files were successfully generated"
    echo "[PIPELINE] Checking for other PLY files in output directory..."
    ls -la "$ply_dir"/*.ply 2>/dev/null || echo "[PIPELINE] No PLY files found in $ply_dir"
    exit 1
  fi
elif [ "$MODE" = "ply_frames_only" ]; then
  # PLY frames only mode: extract frames in time range and generate PLY files
  if [ "$DEBUG" -eq 1 ]; then
    echo "[PIPELINE] DEBUG MODE: Using full video range"
    start_time=""
    end_time=""
  else
    # Get video duration
    video_duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$input_video" 2>/dev/null || echo "")
    
    if [ -n "$video_duration" ]; then
      duration_formatted=$(python3 - <<PY
import sys
try:
    seconds = float("$video_duration")
    hours = int(seconds // 3600)
    minutes = int((seconds % 3600) // 60)
    secs = int(seconds % 60)
    if hours > 0:
        print(f"{hours:02d}:{minutes:02d}:{secs:02d}")
    else:
        print(f"{minutes:02d}:{secs:02d}")
except:
    print("unknown")
PY
      )
      echo "[PIPELINE] Video duration: $duration_formatted"
    fi
    
    printf "Enter start time (HH:MM:SS or seconds, empty for start): "
    read -r start_time_input
    start_time="${start_time_input:-}"
    
    printf "Enter end time (HH:MM:SS or seconds, empty for end): "
    read -r end_time_input
    end_time="${end_time_input:-}"
  fi
  
  if [ -d "$frames_dir" ] || [ -d "$ply_dir" ]; then
    if [ "$DEBUG" -eq 1 ]; then
      echo "[PIPELINE] DEBUG MODE: Overwriting existing project folders"
      rm -rf "$frames_dir" "$ply_dir"
    else
      printf "Project folders already exist for this project. Overwrite? [Y/n]: "
      read -r overwrite_choice
      overwrite_choice="$(printf "%s" "$overwrite_choice" | tr '[:upper:]' '[:lower:]')"
      if [ -z "$overwrite_choice" ] || [ "$overwrite_choice" = "y" ] || [ "$overwrite_choice" = "yes" ]; then
        rm -rf "$frames_dir" "$ply_dir"
      else
        echo "[PIPELINE] Keeping existing project folders."
      fi
    fi
  fi
  
  mkdir -p "$frames_dir" "$ply_dir"
  
  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "[PIPELINE] ffmpeg is required but not found in PATH."
    exit 1
  fi
  
  if ! command -v ffprobe >/dev/null 2>&1; then
    echo "[PIPELINE] ffprobe is required but not found in PATH."
    exit 1
  fi
  
  # Extract frames with time range
  echo "[PIPELINE] Extracting frames from video..."
  ffmpeg_cmd="ffmpeg -y -i \"$input_video\""
  
  if [ -n "$start_time" ]; then
    ffmpeg_cmd="$ffmpeg_cmd -ss \"$start_time\""
  fi
  
  if [ -n "$end_time" ]; then
    # Calculate duration if both start and end are provided
    if [ -n "$start_time" ]; then
      duration=$(python3 - <<PY
import sys
def time_to_seconds(time_str):
    if ':' in time_str:
        parts = time_str.split(':')
        if len(parts) == 3:
            h, m, s = map(float, parts)
            return h * 3600 + m * 60 + s
        elif len(parts) == 2:
            m, s = map(float, parts)
            return m * 60 + s
    else:
        return float(time_str)

try:
    start = time_to_seconds("$start_time")
    end = time_to_seconds("$end_time")
    duration = end - start
    if duration > 0:
        print(duration)
    else:
        print("")
except:
    print("")
PY
      )
      if [ -n "$duration" ]; then
        ffmpeg_cmd="$ffmpeg_cmd -t \"$duration\""
      else
        ffmpeg_cmd="$ffmpeg_cmd -to \"$end_time\""
      fi
    else
      ffmpeg_cmd="$ffmpeg_cmd -to \"$end_time\""
    fi
  fi
  
  ffmpeg_cmd="$ffmpeg_cmd -q:v 1 \"${frames_dir}/frame_%06d.jpg\""
  
  if [ "$VERBOSE" -eq 1 ]; then
    eval "$ffmpeg_cmd"
  else
    eval "$ffmpeg_cmd" >/dev/null 2>&1
  fi
  
  frame_count=$(ls "$frames_dir"/frame_*.jpg 2>/dev/null | wc -l | tr -d ' ')
  
  if [ "$frame_count" -eq 0 ]; then
    echo "[PIPELINE] ERROR: No frames extracted. Check time range."
    exit 1
  fi
  
  echo "[PIPELINE] Extracted $frame_count frames"
  
  # Add EXIF focal length metadata to extracted frames
  echo "[PIPELINE] Adding EXIF metadata (focal length: ${FOCAL_LENGTH}mm)..."
  python3 - <<PY
import os
import sys
import site

# Add user site-packages to path
site.addsitedir(os.path.expanduser("~/Library/Python/3.11/lib/python/site-packages"))

frames_dir = "$frames_dir"
focal_length_mm = float("$FOCAL_LENGTH")

# Try to use piexif for proper EXIF embedding
try:
    import piexif
    piexif_available = True
except (ImportError, ModuleNotFoundError) as e:
    piexif_available = False
    print(f"Note: piexif not available ({e}), skipping EXIF metadata", file=sys.stderr)

if piexif_available:
    for jpeg_file in sorted([f for f in os.listdir(frames_dir) if f.endswith('.jpg')]):
        jpeg_path = os.path.join(frames_dir, jpeg_file)
        try:
            # Read existing EXIF if any
            try:
                existing_exif = piexif.load(jpeg_path)
            except:
                existing_exif = {"0th": {}, "Exif": {}, "GPS": {}, "1st": {}, "thumbnail": None, "Interop": {}}
            
            # Add focal length to EXIF
            # FocalLength tag is 37386 (0x920A) in EXIF IFD
            existing_exif["Exif"][37386] = (int(focal_length_mm * 100), 100)  # FocalLength as rational
            
            # Convert to bytes and insert into JPEG
            exif_bytes = piexif.dump(existing_exif)
            
            # Insert EXIF directly into JPEG file using piexif
            piexif.insert(exif_bytes, jpeg_path)
        except Exception as e:
            print(f"Warning: Could not add EXIF to {jpeg_file}: {e}", file=sys.stderr)
PY
  
  # Get list of frame files
  frame_list="$(ls -1 "$frames_dir"/frame_*.jpg 2>/dev/null | sort || true)"
  if [ -z "$frame_list" ]; then
    echo "[PIPELINE] No frame files found."
    exit 1
  fi
  
  # Count total frames for progress tracking
  total_frames=0
  for _ in $frame_list; do
    total_frames=$((total_frames + 1))
  done
  
  # Record start time for elapsed time tracking
  processing_start_time="$(date +%s)"
  
  # Create single sharp_batch folder in project
  sharp_batch_dir="${project_dir}/sharp_batch"
  mkdir -p "$sharp_batch_dir"
  trap 'rm -rf "$sharp_batch_dir"' EXIT
  
  batch_size=20
  # Calculate total batches
  total_batches=$(((total_frames + batch_size - 1) / batch_size))
  batch_num=0
  batch_frames=""
  frame_count=0
  processed_frames=0
  
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
      
      echo "[PIPELINE] Batch $batch_num/$total_batches: Generating PLY files..."
      ply_start_time="$(date +%s)"
      if [ "$VERBOSE" -eq 1 ]; then
        if ! sh "${ROOT_DIR}/image_to_splat.sh" --input "$sharp_batch_dir" --output "$ply_dir"; then
          echo "[PIPELINE] ERROR: Failed to generate PLY files for batch $batch_num/$total_batches"
          exit 1
        fi
      else
        if ! sh "${ROOT_DIR}/image_to_splat.sh" --input "$sharp_batch_dir" --output "$ply_dir" >/dev/null 2>&1; then
          echo "[PIPELINE] ERROR: Failed to generate PLY files for batch $batch_num/$total_batches"
          exit 1
        fi
      fi
      ply_end_time="$(date +%s)"
      ply_time=$((ply_end_time - ply_start_time))
      
      processed_frames=$((processed_frames + batch_size))
      
      echo ""
      echo "[PIPELINE] Batch $batch_num/$total_batches: Successfully processed $batch_size PLY file(s)"
      echo "[PIPELINE]   PLY generation: $(format_time $ply_time)"
      show_progress "$processed_frames" "$total_frames" "$processing_start_time"
      echo ""
      
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
    
    echo "[PIPELINE] Batch $batch_num/$total_batches: Generating PLY files..."
    ply_start_time="$(date +%s)"
    if [ "$VERBOSE" -eq 1 ]; then
      if ! sh "${ROOT_DIR}/image_to_splat.sh" --input "$sharp_batch_dir" --output "$ply_dir"; then
        echo "[PIPELINE] ERROR: Failed to generate PLY files for batch $batch_num/$total_batches"
        exit 1
      fi
    else
      if ! sh "${ROOT_DIR}/image_to_splat.sh" --input "$sharp_batch_dir" --output "$ply_dir" >/dev/null 2>&1; then
        echo "[PIPELINE] ERROR: Failed to generate PLY files for batch $batch_num/$total_batches"
        exit 1
      fi
    fi
    ply_end_time="$(date +%s)"
    ply_time=$((ply_end_time - ply_start_time))
    
    processed_frames=$((processed_frames + frame_count))
    
    echo ""
    echo "[PIPELINE] Batch $batch_num/$total_batches: Successfully processed $frame_count PLY file(s)"
    echo "[PIPELINE]   PLY generation: $(format_time $ply_time)"
    show_progress "$processed_frames" "$total_frames" "$processing_start_time"
    echo ""
  fi
  
  rm -rf "$sharp_batch_dir"
  echo ""
  echo "[PIPELINE] Completed processing $batch_num batches ($processed_frames/$total_frames frames)"
  echo "[PIPELINE] PLY files saved in: $ply_dir"
  echo "[PIPELINE] Done."
  exit 0
elif [ "$MODE" = "deploy_to_vision_pro" ]; then
  # Deploy PLY files to Vision Pro mode: copy PLY files from project to DSplat
  vision_pro_ply_dir="${ROOT_DIR}/DSplat/SampleApp/App/ply_frames"
  vision_pro_thumbnails_dir="${ROOT_DIR}/DSplat/SampleApp/App/thumbnails"
  
  if [ ! -d "$ply_dir" ]; then
    echo "[PIPELINE] ERROR: PLY directory not found: $ply_dir"
    echo "[PIPELINE] Please run the pipeline first to generate PLY files for project: $project_name"
    exit 1
  fi
  
  ply_file_count=$(ls "$ply_dir"/*.ply 2>/dev/null | wc -l | tr -d ' ')
  if [ "$ply_file_count" -eq 0 ]; then
    echo "[PIPELINE] ERROR: No PLY files found in: $ply_dir"
    echo "[PIPELINE] Please run the pipeline first to generate PLY files for project: $project_name"
    exit 1
  fi
  
  echo "[PIPELINE] Found $ply_file_count PLY file(s) in project: $project_name"
  echo "[PIPELINE] Deploying to Vision Pro: $vision_pro_ply_dir"
  
  # Create destination directory if it doesn't exist
  mkdir -p "$vision_pro_ply_dir"
  mkdir -p "$vision_pro_thumbnails_dir"
  
  # Ask if user wants to remove existing files
  existing_files_count=$(ls "$vision_pro_ply_dir"/*.ply 2>/dev/null | wc -l | tr -d ' ')
  if [ "$existing_files_count" -gt 0 ]; then
    echo "[PIPELINE] Found $existing_files_count existing PLY file(s) in Vision Pro directory"
    if [ "$DEBUG" -eq 1 ]; then
      echo "[PIPELINE] DEBUG MODE: Not removing existing files"
      REMOVE_EXISTING=0
    else
      printf "Remove existing PLY files from Vision Pro directory? [y/N]: "
      read -r remove_choice
      remove_choice="$(printf "%s" "$remove_choice" | tr '[:upper:]' '[:lower:]')"
      if [ "$remove_choice" = "y" ] || [ "$remove_choice" = "yes" ]; then
        REMOVE_EXISTING=1
      else
        REMOVE_EXISTING=0
      fi
    fi
    
    if [ "$REMOVE_EXISTING" -eq 1 ]; then
      echo "[PIPELINE] Removing existing PLY files from Vision Pro directory..."
      rm -f "$vision_pro_ply_dir"/*.ply
      echo "[PIPELINE] Removed $existing_files_count existing file(s)"
    fi
  fi
  
  # Copy PLY files
  copied_count=0
  for ply_file in "$ply_dir"/*.ply; do
    if [ -f "$ply_file" ]; then
      filename="$(basename "$ply_file")"
      dest_path="$vision_pro_ply_dir/$filename"
      
      if [ "$VERBOSE" -eq 1 ]; then
        echo "[PIPELINE] Copying: $filename"
      fi
      
      if cp "$ply_file" "$dest_path"; then
        copied_count=$((copied_count + 1))
      else
        echo "[PIPELINE] WARNING: Failed to copy $filename"
      fi
    fi
  done
  
  # Copy thumbnails if frames directory exists
  thumbnail_count=0
  if [ -d "$frames_dir" ]; then
    echo "[PIPELINE] Copying thumbnails from: $frames_dir"
    
    # Match frame images to PLY files
    for ply_file in "$ply_dir"/*.ply; do
      if [ -f "$ply_file" ]; then
        ply_basename="$(basename "$ply_file" .ply)"
        # Try to find matching frame image (frame_000001.ply -> frame_000001.jpg)
        frame_image="${frames_dir}/${ply_basename}.jpg"
        
        if [ -f "$frame_image" ]; then
          thumbnail_dest="${vision_pro_thumbnails_dir}/${ply_basename}.jpg"
          if cp "$frame_image" "$thumbnail_dest"; then
            thumbnail_count=$((thumbnail_count + 1))
            if [ "$VERBOSE" -eq 1 ]; then
              echo "[PIPELINE] Copied thumbnail: $(basename "$thumbnail_dest")"
            fi
          fi
        fi
      fi
    done
  else
    echo "[PIPELINE] WARNING: Frames directory not found: $frames_dir"
    echo "[PIPELINE] Skipping thumbnail copy (thumbnails will not be available)"
  fi
  
  if [ "$copied_count" -gt 0 ]; then
    echo "[PIPELINE] Successfully deployed $copied_count PLY file(s) to Vision Pro"
    if [ "$thumbnail_count" -gt 0 ]; then
      echo "[PIPELINE] Successfully deployed $thumbnail_count thumbnail(s) to Vision Pro"
    fi
    echo "[PIPELINE] Destination: $vision_pro_ply_dir"
    echo "[PIPELINE] Done."
    exit 0
  else
    echo "[PIPELINE] ERROR: No files were copied"
    exit 1
  fi
elif [ "$MODE" = "extract_frames" ]; then
  # Extract video frames mode: extract frames only with focal length metadata
  if [ -d "$frames_dir" ]; then
    if [ "$DEBUG" -eq 1 ]; then
      echo "[PIPELINE] DEBUG MODE: Overwriting existing frames folder"
      rm -rf "$frames_dir"
    else
      printf "Frames folder already exists for this project. Overwrite? [Y/n]: "
      read -r overwrite_choice
      overwrite_choice="$(printf "%s" "$overwrite_choice" | tr '[:upper:]' '[:lower:]')"
      if [ -z "$overwrite_choice" ] || [ "$overwrite_choice" = "y" ] || [ "$overwrite_choice" = "yes" ]; then
        rm -rf "$frames_dir"
      else
        echo "[PIPELINE] Keeping existing frames folder."
      fi
    fi
  fi
  
  mkdir -p "$frames_dir"
  
  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "[PIPELINE] ffmpeg is required but not found in PATH."
    exit 1
  fi
  
  if ! command -v ffprobe >/dev/null 2>&1; then
    echo "[PIPELINE] ffprobe is required but not found in PATH."
    exit 1
  fi
  
  # Extract frames using extract_video_frames.sh
  echo "[PIPELINE] Extracting frames from video..."
  if [ "$VERBOSE" -eq 1 ]; then
    frame_count=$(sh "${ROOT_DIR}/extract_video_frames.sh" --input "$input_video" --output "$frames_dir" --focal-length "$FOCAL_LENGTH" | tail -n 1)
  else
    frame_count=$(sh "${ROOT_DIR}/extract_video_frames.sh" --input "$input_video" --output "$frames_dir" --focal-length "$FOCAL_LENGTH" 2>/dev/null | tail -n 1)
  fi
  
  if [ "$frame_count" -eq 0 ]; then
    echo "[PIPELINE] ERROR: No frames extracted."
    exit 1
  fi
  
  echo "[PIPELINE] Successfully extracted $frame_count frames"
  echo "[PIPELINE] Frames saved in: $frames_dir"
  echo "[PIPELINE] Focal length metadata: ${FOCAL_LENGTH}mm"
  echo "[PIPELINE] Done."
  exit 0
elif [ "$MODE" = "ply_from_frames" ]; then
  # Generate PLY from existing frames mode: convert existing frame images to PLY files
  if [ ! -d "$frames_dir" ]; then
    echo "[PIPELINE] ERROR: Frames directory not found: $frames_dir"
    echo "[PIPELINE] Please extract frames first or run mode 6 (Extract video frames)"
    exit 1
  fi
  
  # Find all image files in frames directory
  frame_files=$(find "$frames_dir" -maxdepth 1 \( -name "*.jpg" -o -name "*.jpeg" -o -name "*.png" \) -type f | sort)
  if [ -z "$frame_files" ]; then
    echo "[PIPELINE] ERROR: No image files found in: $frames_dir"
    echo "[PIPELINE] Please extract frames first or run mode 6 (Extract video frames)"
    exit 1
  fi
  
  frame_count=$(echo "$frame_files" | wc -l | tr -d ' ')
  echo "[PIPELINE] Found $frame_count frame image(s) in: $frames_dir"
  
  # Set focal length in existing frames
  echo "[PIPELINE] Setting focal length to ${FOCAL_LENGTH}mm in existing frames..."
  if ! sh "${ROOT_DIR}/set_focal_length.sh" --frames-dir "$frames_dir" --focal-length "$FOCAL_LENGTH"; then
    echo "[PIPELINE] ERROR: Failed to set focal length in frames"
    exit 1
  fi
  
  mkdir -p "$ply_dir"
  
  # Record start time for elapsed time tracking
  processing_start_time="$(date +%s)"
  
  # Process each frame
  current_frame=0
  processed_count=0
  skipped_count=0
  
  for frame_file in $frame_files; do
    current_frame=$((current_frame + 1))
    frame_filename="$(basename "$frame_file")"
    frame_basename="${frame_filename%.*}"
    ply_file="${ply_dir}/${frame_basename}.ply"
    
    echo "[PIPELINE] Processing frame: $frame_filename ($current_frame/$frame_count)..."
    
    # Check if PLY already exists
    if [ -f "$ply_file" ]; then
      echo "[PIPELINE] PLY file already exists, skipping: $frame_basename.ply"
      skipped_count=$((skipped_count + 1))
      continue
    fi
    
    # Generate PLY for frame (always verbose in mode 8)
    echo "[PIPELINE] Generating PLY for: $frame_filename..."
    if ! sh "${ROOT_DIR}/image_to_splat.sh" --input "$frame_file" --output "$ply_dir"; then
      echo "[PIPELINE] ERROR: Failed to generate PLY file for $frame_filename"
      continue
    fi
    
    if [ -f "$ply_file" ]; then
      echo "[PIPELINE] Successfully generated PLY: $ply_file"
      processed_count=$((processed_count + 1))
    else
      echo "[PIPELINE] ERROR: PLY file not found at expected location: $ply_file"
    fi
    
    echo ""
  done
  
  echo "[PIPELINE] Completed processing $frame_count frame(s)"
  echo "[PIPELINE]   Generated: $processed_count PLY file(s)"
  echo "[PIPELINE]   Skipped (already exist): $skipped_count PLY file(s)"
  echo "[PIPELINE] PLY files saved in: $ply_dir"
  echo "[PIPELINE] Done."
  exit 0
elif [ "$MODE" = "predict_focal_length" ]; then
  # Predict focal length in frames mode: predict and write focal length to EXIF
  if [ ! -d "$frames_dir" ]; then
    echo "[PIPELINE] ERROR: Frames directory not found: $frames_dir"
    echo "[PIPELINE] Please extract frames first or run mode 6 (Extract video frames)"
    exit 1
  fi
  
  # Find all image files in frames directory
  frame_files=$(find "$frames_dir" -maxdepth 1 \( -name "*.jpg" -o -name "*.jpeg" -o -name "*.png" \) -type f | sort)
  if [ -z "$frame_files" ]; then
    echo "[PIPELINE] ERROR: No image files found in: $frames_dir"
    echo "[PIPELINE] Please extract frames first or run mode 6 (Extract video frames)"
    exit 1
  fi
  
  frame_count=$(echo "$frame_files" | wc -l | tr -d ' ')
  echo "[PIPELINE] Found $frame_count frame image(s) in: $frames_dir"
  
  # Check if MLFocalLengths directory exists
  MLFOCAL_DIR="${ROOT_DIR}/MLFocalLengths"
  if [ ! -d "$MLFOCAL_DIR" ]; then
    echo "[PIPELINE] ERROR: MLFocalLengths directory not found at: $MLFOCAL_DIR"
    echo "[PIPELINE] Cloning MLFocalLengths repository..."
    if ! git clone https://github.com/nandometzger/MLFocalLengths.git "$MLFOCAL_DIR"; then
      echo "[PIPELINE] ERROR: Failed to clone MLFocalLengths repository"
      exit 1
    fi
    echo "[PIPELINE] MLFocalLengths repository cloned successfully"
  fi
  
  # Check if gdown is available (needed for checkpoint download)
  if ! command -v gdown >/dev/null 2>&1 && ! python3 -c "import gdown" 2>/dev/null; then
    echo "[PIPELINE] Installing gdown for checkpoint download..."
    python3 -m pip install --user gdown
    if [ $? -ne 0 ]; then
      echo "[PIPELINE] WARNING: Failed to install gdown. Checkpoint may need manual download."
    else
      echo "[PIPELINE] gdown installed successfully"
    fi
  fi
  
  # Check if dependencies are needed and install if missing
  if ! python3 -c "import piexif" 2>/dev/null; then
    echo "[PIPELINE] Missing Python dependencies, installing..."
    echo "[PIPELINE] Installing Python dependencies for focal length prediction..."
    echo "[PIPELINE] Note: Installing numpy<2 for compatibility with MLFocalLengths..."
    python3 -m pip install --user "numpy<2" piexif torch torchvision pillow tqdm configargparse opencv-python rawpy exifread matplotlib scikit-learn h5py
    if [ $? -ne 0 ]; then
      echo "[PIPELINE] ERROR: Failed to install dependencies"
      echo "[PIPELINE] You can try installing manually with: pip install --user 'numpy<2' piexif torch torchvision"
      exit 1
    fi
    echo "[PIPELINE] Dependencies installed successfully"
  else
    # Check if numpy version is compatible (needs to be < 2.0)
    numpy_version=$(python3 -c "import numpy; print(numpy.__version__)" 2>/dev/null || echo "")
    if [ -n "$numpy_version" ]; then
      major_version=$(echo "$numpy_version" | cut -d. -f1)
      if [ "$major_version" -ge 2 ]; then
        echo "[PIPELINE] WARNING: NumPy $numpy_version detected, but MLFocalLengths requires NumPy < 2.0"
        echo "[PIPELINE] Downgrading NumPy to compatible version..."
        python3 -m pip install --user "numpy<2" --force-reinstall
        if [ $? -ne 0 ]; then
          echo "[PIPELINE] ERROR: Failed to downgrade NumPy"
          echo "[PIPELINE] Please manually install: pip install --user 'numpy<2'"
          exit 1
        fi
        echo "[PIPELINE] NumPy downgraded successfully"
      fi
    fi
  fi
  
  echo "[PIPELINE] Predicting focal length for all frames..."
  echo "[PIPELINE] Note: First run may take longer (downloading model weights if needed)..."
  echo ""
  
  # Run focal length prediction and capture output while showing it in real-time
  # Use a temp file to capture output while also displaying it
  temp_output_file=$(mktemp)
  trap "rm -f '$temp_output_file'" EXIT
  
  # Run prediction script, showing output in real-time and saving to file
  echo "[PIPELINE] Starting prediction (output will appear below)..."
  echo ""
  if ! sh "${ROOT_DIR}/predict_focal_length.sh" --input "$frames_dir" 2>&1 | tee "$temp_output_file"; then
    echo ""
    echo "[PIPELINE] ERROR: Failed to predict focal length"
    rm -f "$temp_output_file"
    trap - EXIT
    exit 1
  fi
  
  echo ""
  # Read captured output
  prediction_output=$(cat "$temp_output_file")
  rm -f "$temp_output_file"
  trap - EXIT
  
  # Parse predictions from output and write to EXIF
  echo "[PIPELINE] Writing predicted focal lengths to EXIF metadata..."
  python3 - <<PY
import os
import sys
import re
import site

# Add user site-packages to path
site.addsitedir(os.path.expanduser("~/Library/Python/3.11/lib/python/site-packages"))

frames_dir = "$frames_dir"
prediction_output = """$prediction_output"""

# Try to use piexif for proper EXIF embedding
try:
    import piexif
    piexif_available = True
except (ImportError, ModuleNotFoundError) as e:
    piexif_available = False
    print(f"ERROR: piexif not available ({e})", file=sys.stderr)
    sys.exit(1)

# Get list of image files in order
image_files = []
for filename in sorted(os.listdir(frames_dir)):
    if filename.lower().endswith(('.jpg', '.jpeg')):
        image_files.append(filename)

# Parse predictions from output
# Format: /path/to/file.jpg Predicted  75.5mm or just "Predicted  75.5mm"
predictions = []
for line in prediction_output.split('\n'):
    # Match lines with "Predicted" and a focal length
    match = re.search(r'Predicted\s+([\d.]+)mm', line)
    if match:
        focal_length = float(match.group(1))
        predictions.append(focal_length)

# Match predictions to files by order (since predict.py processes them sequentially)
if len(predictions) != len(image_files):
    print(f"WARNING: Found {len(predictions)} predictions but {len(image_files)} image files", file=sys.stderr)
    print("Attempting to match by processing order...", file=sys.stderr)

processed_count = 0
error_count = 0
skipped_count = 0

# Process all image files and apply predictions
for idx, filename in enumerate(image_files):
    image_path = os.path.join(frames_dir, filename)
    
    # Get predicted focal length for this file by index
    if idx >= len(predictions):
        skipped_count += 1
        print(f"Warning: No prediction found for {filename} (index {idx})", file=sys.stderr)
        continue
    
    focal_length_mm = predictions[idx]
    
    try:
        # Read existing EXIF if any
        try:
            existing_exif = piexif.load(image_path)
        except:
            existing_exif = {"0th": {}, "Exif": {}, "GPS": {}, "1st": {}, "thumbnail": None, "Interop": {}}
        
        # Add focal length to EXIF
        # FocalLength tag is 37386 (0x920A) in EXIF IFD
        existing_exif["Exif"][37386] = (int(focal_length_mm * 100), 100)  # FocalLength as rational
        
        # Convert to bytes and insert into JPEG
        exif_bytes = piexif.dump(existing_exif)
        
        # Insert EXIF directly into JPEG file using piexif
        piexif.insert(exif_bytes, image_path)
        processed_count += 1
        verbose = os.environ.get("VERBOSE", "0") == "1"
        if verbose:
            print(f"Set focal length {focal_length_mm}mm for {filename}")
    except Exception as e:
        print(f"Warning: Could not add EXIF to {filename}: {e}", file=sys.stderr)
        error_count += 1

print(f"Processed {processed_count} image(s)")
if skipped_count > 0:
    print(f"Skipped {skipped_count} image(s) (no prediction found)", file=sys.stderr)
if error_count > 0:
    print(f"Errors: {error_count} image(s)", file=sys.stderr)
    sys.exit(1)
PY
  
  if [ $? -ne 0 ]; then
    echo "[PIPELINE] ERROR: Failed to write focal lengths to EXIF"
    exit 1
  fi
  
  echo "[PIPELINE] Successfully predicted and wrote focal length to EXIF for $frame_count frame(s)"
  echo "[PIPELINE] Frames directory: $frames_dir"
  echo "[PIPELINE] Done."
  exit 0
elif [ "$MODE" = "render_ply_viewer" ]; then
  # Render PLY frames in Brush Viewer mode: open PLY files with brush viewer
  if [ ! -d "$ply_dir" ]; then
    echo "[PIPELINE] ERROR: PLY directory not found: $ply_dir"
    echo "[PIPELINE] Please run the pipeline first to generate PLY files for project: $project_name"
    exit 1
  fi
  
  ply_file_count=$(ls "$ply_dir"/*.ply 2>/dev/null | wc -l | tr -d ' ')
  if [ "$ply_file_count" -eq 0 ]; then
    echo "[PIPELINE] ERROR: No PLY files found in: $ply_dir"
    echo "[PIPELINE] Please run the pipeline first to generate PLY files for project: $project_name"
    exit 1
  fi
  
  echo "[PIPELINE] Found $ply_file_count PLY file(s) in project: $project_name"
  
  brush_bin="${ROOT_DIR}/brush/target/release/brush"
  if [ ! -x "$brush_bin" ]; then
    echo "[PIPELINE] ERROR: Brush binary not found at $brush_bin"
    echo "[PIPELINE] Please build brush first"
    exit 1
  fi
  
  echo "[PIPELINE] Opening PLY files with brush viewer..."
  cd "${ROOT_DIR}/brush"
  "$brush_bin" --with-viewer "$ply_dir" &
  echo "[PIPELINE] Brush viewer launched in background"
  echo "[PIPELINE] PLY directory: $ply_dir"
  echo "[PIPELINE] Done."
  exit 0
elif [ "$MODE" = "spatial_from_stereo" ]; then
  # Spatial from stereo mode: check if stereo frames exist
  if [ ! -d "$stereo_dir" ]; then
    echo "[PIPELINE] ERROR: Stereo frames directory not found: $stereo_dir"
    echo "[PIPELINE] Please run the full pipeline first to generate stereo frames."
    exit 1
  fi
  
  stereo_frame_count=$(ls "$stereo_dir"/frame_*_left.png 2>/dev/null | wc -l | tr -d ' ')
  if [ "$stereo_frame_count" -eq 0 ]; then
    echo "[PIPELINE] ERROR: No stereo frames found in: $stereo_dir"
    echo "[PIPELINE] Please run the full pipeline first to generate stereo frames."
    exit 1
  fi
  
  echo "[PIPELINE] Found $stereo_frame_count stereo frame pairs"
  echo "[PIPELINE] Skipping PLY and stereo generation, proceeding to video generation..."
  
  mkdir -p "$video_dir"
  
  # Get FPS from video
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
  
  echo "[PIPELINE] Rendering videos for each eye..."
  sh "${ROOT_DIR}/stereo_frames_to_video.sh" \
    --input "$stereo_dir" \
    --output "$video_dir" \
    --fps "$fps" \
    --spatial-output "$spatial_output"
  
  echo "[PIPELINE] Done. Output in: $project_dir"
  exit 0
fi

# Default mode: continue with normal pipeline
if [ -d "$frames_dir" ] || [ -d "$ply_dir" ] || [ -d "$stereo_dir" ]; then
  if [ "$DEBUG" -eq 1 ]; then
    echo "[PIPELINE] DEBUG MODE: Overwriting existing project folders"
    rm -rf "$frames_dir" "$ply_dir" "$stereo_dir"
  else
    printf "Project folders already exist for this project. Overwrite? [Y/n]: "
    read -r overwrite_choice
    overwrite_choice="$(printf "%s" "$overwrite_choice" | tr '[:upper:]' '[:lower:]')"
    if [ -z "$overwrite_choice" ] || [ "$overwrite_choice" = "y" ] || [ "$overwrite_choice" = "yes" ]; then
      rm -rf "$frames_dir" "$ply_dir" "$stereo_dir"
    else
      echo "[PIPELINE] Keeping existing project folders."
    fi
  fi
fi

mkdir -p "$frames_dir" "$ply_dir" "$stereo_dir"

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
  frame_count=$(sh "${ROOT_DIR}/extract_video_frames.sh" --input "$input_video" --output "$frames_dir" --focal-length "$FOCAL_LENGTH" --debug | tail -n 1)
else
  frame_count=$(sh "${ROOT_DIR}/extract_video_frames.sh" --input "$input_video" --output "$frames_dir" --focal-length "$FOCAL_LENGTH" | tail -n 1)
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

  echo "[PIPELINE] Processing frames in batches..."
  
  # Get list of frame files
  frame_list="$(ls -1 "$frames_dir"/frame_*.jpg 2>/dev/null | sort || true)"
  if [ -z "$frame_list" ]; then
    echo "[PIPELINE] No frame files found."
    exit 1
  fi
  
  # Count total frames for progress tracking
  total_frames=0
  for _ in $frame_list; do
    total_frames=$((total_frames + 1))
  done
  
  # Record start time for elapsed time tracking
  start_time="$(date +%s)"
  
  # Create single sharp_batch folder in project
  sharp_batch_dir="${project_dir}/sharp_batch"
  mkdir -p "$sharp_batch_dir"
  trap 'rm -rf "$sharp_batch_dir"' EXIT
  
  batch_size=20
  # Calculate total batches
  total_batches=$(((total_frames + batch_size - 1) / batch_size))
  batch_num=0
  batch_frames=""
  frame_count=0
  processed_frames=0
  
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
      
      echo "[PIPELINE] Batch $batch_num/$total_batches: Generating PLY files..."
      ply_start_time="$(date +%s)"
      if [ "$VERBOSE" -eq 1 ]; then
        if ! sh "${ROOT_DIR}/image_to_splat.sh" --input "$sharp_batch_dir" --output "$ply_dir"; then
          echo "[PIPELINE] ERROR: Failed to generate PLY files for batch $batch_num/$total_batches"
          exit 1
        fi
      else
        if ! sh "${ROOT_DIR}/image_to_splat.sh" --input "$sharp_batch_dir" --output "$ply_dir" >/dev/null 2>&1; then
          echo "[PIPELINE] ERROR: Failed to generate PLY files for batch $batch_num/$total_batches"
          exit 1
        fi
      fi
      ply_end_time="$(date +%s)"
      ply_time=$((ply_end_time - ply_start_time))
      
      echo "[PIPELINE] Batch $batch_num/$total_batches: Generating stereo images..."
      stereo_start_time="$(date +%s)"
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
            echo "[PIPELINE] Batch $batch_num/$total_batches: Processing $ply_name..."
            if [ "$VERBOSE" -eq 1 ]; then
              if ! KEEP_PLY="$KEEP_PLY" sh "${ROOT_DIR}/ply_to_stereo.sh" --input "$ply_path" --output "$stereo_dir"; then
                echo "[PIPELINE] ERROR: Failed to generate stereo images for $ply_name"
                exit 1
              fi
            else
              if ! KEEP_PLY="$KEEP_PLY" sh "${ROOT_DIR}/ply_to_stereo.sh" --input "$ply_path" --output "$stereo_dir" >/dev/null 2>&1; then
                echo "[PIPELINE] ERROR: Failed to generate stereo images for $ply_name"
                exit 1
              fi
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
      stereo_end_time="$(date +%s)"
      stereo_time=$((stereo_end_time - stereo_start_time))
      
      if [ "$ply_files_processed" -gt 0 ]; then
        processed_frames=$((processed_frames + ply_files_processed))
        total_batch_time=$((ply_time + stereo_time))
        avg_time_per_frame=$(awk "BEGIN {printf \"%.2f\", $total_batch_time / $ply_files_processed}")
        
        echo ""
        echo "[PIPELINE] Batch $batch_num/$total_batches: Successfully processed $ply_files_processed PLY file(s)"
        echo "[PIPELINE]   PLY generation: $(format_time $ply_time)"
        echo "[PIPELINE]   Stereo generation: $(format_time $stereo_time)"
        echo "[PIPELINE]   Total batch time: $(format_time $total_batch_time)"
        echo "[PIPELINE]   Average time per frame: ${avg_time_per_frame}s"
        show_progress "$processed_frames" "$total_frames" "$start_time"
        echo ""
      else
        echo ""
        echo "[PIPELINE] WARNING: Batch $batch_num/$total_batches: No PLY files found in $ply_dir for this batch"
        show_progress "$processed_frames" "$total_frames" "$start_time"
        echo ""
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
    
    echo "[PIPELINE] Batch $batch_num/$total_batches: Generating PLY files..."
    ply_start_time="$(date +%s)"
    if [ "$VERBOSE" -eq 1 ]; then
      if ! sh "${ROOT_DIR}/image_to_splat.sh" --input "$sharp_batch_dir" --output "$ply_dir"; then
        echo "[PIPELINE] ERROR: Failed to generate PLY files for batch $batch_num/$total_batches"
        exit 1
      fi
    else
      if ! sh "${ROOT_DIR}/image_to_splat.sh" --input "$sharp_batch_dir" --output "$ply_dir" >/dev/null 2>&1; then
        echo "[PIPELINE] ERROR: Failed to generate PLY files for batch $batch_num/$total_batches"
        exit 1
      fi
    fi
    ply_end_time="$(date +%s)"
    ply_time=$((ply_end_time - ply_start_time))
    
    echo "[PIPELINE] Batch $batch_num/$total_batches: Generating stereo images..."
    stereo_start_time="$(date +%s)"
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
          if [ "$VERBOSE" -eq 1 ]; then
            if ! KEEP_PLY="$KEEP_PLY" sh "${ROOT_DIR}/ply_to_stereo.sh" --input "$ply_path" --output "$stereo_dir"; then
              echo "[PIPELINE] ERROR: Failed to generate stereo images for $ply_name"
              exit 1
            fi
          else
            if ! KEEP_PLY="$KEEP_PLY" sh "${ROOT_DIR}/ply_to_stereo.sh" --input "$ply_path" --output "$stereo_dir" >/dev/null 2>&1; then
              echo "[PIPELINE] ERROR: Failed to generate stereo images for $ply_name"
              exit 1
            fi
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
    stereo_end_time="$(date +%s)"
    stereo_time=$((stereo_end_time - stereo_start_time))
    
    if [ "$ply_files_processed" -gt 0 ]; then
      processed_frames=$((processed_frames + ply_files_processed))
      total_batch_time=$((ply_time + stereo_time))
      avg_time_per_frame=$(awk "BEGIN {printf \"%.2f\", $total_batch_time / $ply_files_processed}")
      
      echo ""
      echo "[PIPELINE] Batch $batch_num/$total_batches: Successfully processed $ply_files_processed PLY file(s)"
      echo "[PIPELINE]   PLY generation: $(format_time $ply_time)"
      echo "[PIPELINE]   Stereo generation: $(format_time $stereo_time)"
      echo "[PIPELINE]   Total batch time: $(format_time $total_batch_time)"
      echo "[PIPELINE]   Average time per frame: ${avg_time_per_frame}s"
      show_progress "$processed_frames" "$total_frames" "$start_time"
      echo ""
    else
      echo ""
      echo "[PIPELINE] WARNING: Batch $batch_num/$total_batches: No PLY files found in $ply_dir for this batch"
      show_progress "$processed_frames" "$total_frames" "$start_time"
      echo ""
    fi
  fi
  
  rm -rf "$sharp_batch_dir"
  echo ""
  echo "[PIPELINE] Completed processing $batch_num batches ($processed_frames/$total_frames frames)"
fi

echo "[PIPELINE] Rendering videos for each eye..."
sh "${ROOT_DIR}/stereo_frames_to_video.sh" \
  --input "$stereo_dir" \
  --output "$video_dir" \
  --fps "$fps" \
  --spatial-output "$spatial_output"

echo "[PIPELINE] Done. Output in: $project_dir"

