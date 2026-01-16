#!/usr/bin/env sh
# Convert one or more images to PLY splats using ml-sharp.

set -eu

# Get script directory and convert to absolute path
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"
DEFAULT_DEVICE="default"

inputs_file="$(mktemp -t sharp_inputs_list_XXXXXX)"
trap 'rm -f "$inputs_file"; [ -n "${temp_dir:-}" ] && rm -rf "$temp_dir"' EXIT

output_dir=""
device="$DEFAULT_DEVICE"
checkpoint=""
sharp_bin=""
batch_size=""
parallel_jobs=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -i|--input)
      shift
      if [ "$#" -eq 0 ]; then
        echo "Missing argument for --input"
        exit 1
      fi
      printf "%s\n" "$1" >> "$inputs_file"
      ;;
    -o|--output)
      shift
      output_dir="$1"
      ;;
    --device)
      shift
      device="$1"
      ;;
    --checkpoint)
      shift
      checkpoint="$1"
      ;;
    --sharp-bin)
      shift
      sharp_bin="$1"
      ;;
    --batch-size)
      shift
      batch_size="$1"
      ;;
    -j|--jobs)
      shift
      parallel_jobs="$1"
      ;;
    *)
      echo "Unknown argument: $1"
      exit 1
      ;;
  esac
  shift
done

if [ ! -s "$inputs_file" ]; then
  echo "No inputs provided. Use -i/--input."
  exit 1
fi

if [ -z "$output_dir" ]; then
  echo "Missing --output"
  exit 1
fi

mkdir -p "$output_dir"

if [ -z "$checkpoint" ]; then
  # Check project checkpoints directory first
  project_checkpoint="${ROOT_DIR}/checkpoints/sharp_2572gikvuh.pt"
  if [ -f "$project_checkpoint" ]; then
    checkpoint="$project_checkpoint"
    echo "Using project checkpoint: $checkpoint"
  else
    # Fallback to default location
    default_checkpoint="${HOME}/.cache/torch/hub/checkpoints/sharp_2572gikvuh.pt"
    if [ -f "$default_checkpoint" ]; then
      checkpoint="$default_checkpoint"
      echo "Using cached checkpoint: $checkpoint"
    fi
  fi
fi

allowed_exts='png|jpg|jpeg|bmp|tif|tiff|webp'
image_list="$(mktemp -t sharp_image_list_XXXXXX)"
temp_dir_created=0
trap 'rm -f "$inputs_file" "$image_list"; [ "$temp_dir_created" -eq 1 ] && [ -n "${temp_dir:-}" ] && rm -rf "$temp_dir"' EXIT

# Check if we have a single directory input (can use it directly)
input_count="$(wc -l < "$inputs_file" | tr -d ' ')"
use_input_directly=0
if [ "$input_count" -eq 1 ]; then
  single_input="$(head -n 1 "$inputs_file")"
  if [ -d "$single_input" ]; then
    # Check if directory has image files
    image_count="$(find "$single_input" -maxdepth 1 \( -type f -o -type l \) \
      | awk -v exts="$allowed_exts" 'tolower($0) ~ "\\.(" exts ")$"' \
      | wc -l | tr -d ' ')"
    if [ "$image_count" -gt 0 ]; then
      use_input_directly=1
      temp_dir="$single_input"
    fi
  fi
fi

# Only create temp directory if we're not using input directly
if [ "$use_input_directly" -eq 0 ]; then
  # Use project tmp folder if output_dir is in a tmp subdirectory, otherwise use system temp
  if [ -n "$output_dir" ] && echo "$output_dir" | grep -q "/tmp/"; then
    # Create temp directory in the same tmp folder as output_dir
    project_tmp="$(echo "$output_dir" | sed 's|/[^/]*$||')"
    temp_dir="${project_tmp}/sharp_inputs"
    mkdir -p "$temp_dir"
  else
    temp_dir="$(mktemp -d -t sharp_inputs_XXXXXX)"
  fi
  temp_dir_created=1
  
  while IFS= read -r input_path; do
    if [ -d "$input_path" ]; then
      find "$input_path" -maxdepth 1 \( -type f -o -type l \) \
        | awk -v exts="$allowed_exts" 'tolower($0) ~ "\\.(" exts ")$"' \
        >> "$image_list"
    else
      printf "%s\n" "$input_path" >> "$image_list"
    fi
  done < "$inputs_file"
  
  if [ ! -s "$image_list" ]; then
    echo "No input images found."
    exit 1
  fi
  
  start_time="$(date +%s.%N 2>/dev/null || date +%s)"
  
  while IFS= read -r image_path; do
    if [ ! -f "$image_path" ]; then
      echo "Input image not found: $image_path"
      exit 1
    fi
    base_name="$(basename "$image_path")"
    target_name="$base_name"
    if [ -e "$temp_dir/$target_name" ]; then
      stem="${base_name%.*}"
      ext="${base_name##*.}"
      if [ "$ext" = "$base_name" ]; then
        ext=""
      else
        ext=".$ext"
      fi
      i=1
      while [ -e "${temp_dir}/${stem}_$(printf '%03d' "$i")${ext}" ]; do
        i=$((i + 1))
      done
      target_name="${stem}_$(printf '%03d' "$i")${ext}"
    fi
  
    if ln "$image_path" "$temp_dir/$target_name" 2>/dev/null; then
      :
    elif ln -s "$image_path" "$temp_dir/$target_name" 2>/dev/null; then
      :
    else
      cp "$image_path" "$temp_dir/$target_name"
    fi
  done < "$image_list"
else
  # Using input directory directly
  start_time="$(date +%s.%N 2>/dev/null || date +%s)"
  # Don't need to copy/link files, temp_dir already points to input directory
fi

prep_end="$(date +%s.%N 2>/dev/null || date +%s)"
awk -v start="$start_time" -v end="$prep_end" 'BEGIN { printf "Prep time: %.2fs\n", end - start }'

if [ -n "$sharp_bin" ]; then
  sharp_exe="$sharp_bin"
  use_python=0
else
  sharp_exe="$(command -v sharp || true)"
  use_python=0
  # Fallback to Python module if executable not found
  if [ -z "$sharp_exe" ]; then
    # Check if ml-sharp is installed locally in project
    if [ -d "${ROOT_DIR}/ml-sharp/src" ]; then
      sharp_exe="python"
      use_python=1
      # Ensure Python can find the ml-sharp module
      export PYTHONPATH="${ROOT_DIR}/ml-sharp/src:${PYTHONPATH:-}"
    else
      echo "sharp executable not found. Install ml-sharp or pass --sharp-bin."
      exit 1
    fi
  fi
fi

cmd_time_start="$(date +%s.%N 2>/dev/null || date +%s)"

image_count="$(wc -l < "$image_list" | tr -d ' ')"

if [ -n "$batch_size" ] && [ "$batch_size" -gt 0 ] && [ "$image_count" -gt "$batch_size" ]; then
  # Batch processing mode
  batch_dirs="$(mktemp -d -t sharp_batches_XXXXXX)"
  trap 'rm -f "$inputs_file" "$image_list"; [ -n "${temp_dir:-}" ] && rm -rf "$temp_dir"; [ -n "${batch_dirs:-}" ] && rm -rf "$batch_dirs"' EXIT
  
  # Split images into batches
  batch_num=0
  current_batch_dir=""
  images_in_batch=0
  
  while IFS= read -r image_path; do
    if [ "$images_in_batch" -eq 0 ]; then
      batch_num=$((batch_num + 1))
      current_batch_dir="$batch_dirs/batch_$(printf '%04d' "$batch_num")"
      mkdir -p "$current_batch_dir"
      images_in_batch=0
    fi
    
    base_name="$(basename "$image_path")"
    target_name="$base_name"
    if [ -e "$current_batch_dir/$target_name" ]; then
      stem="${base_name%.*}"
      ext="${base_name##*.}"
      if [ "$ext" = "$base_name" ]; then
        ext=""
      else
        ext=".$ext"
      fi
      i=1
      while [ -e "$current_batch_dir/${stem}_$(printf '%03d' "$i")${ext}" ]; do
        i=$((i + 1))
      done
      target_name="${stem}_$(printf '%03d' "$i")${ext}"
    fi
    
    if ln "$image_path" "$current_batch_dir/$target_name" 2>/dev/null || \
       ln -s "$image_path" "$current_batch_dir/$target_name" 2>/dev/null || \
       cp "$image_path" "$current_batch_dir/$target_name"; then
      images_in_batch=$((images_in_batch + 1))
      if [ "$images_in_batch" -ge "$batch_size" ]; then
        images_in_batch=0
      fi
    fi
  done < "$image_list"
  
  total_batches="$batch_num"
  echo "Processing $image_count images in $total_batches batches of up to $batch_size images"
  
  if [ -n "$parallel_jobs" ] && [ "$parallel_jobs" -gt 1 ]; then
    # Parallel batch processing
    echo "Processing batches in parallel with $parallel_jobs jobs"
    export sharp_exe output_dir device checkpoint use_python PYTHONPATH
    find "$batch_dirs" -mindepth 1 -maxdepth 1 -type d | sort | \
      xargs -P "$parallel_jobs" -I {} sh -c '
        batch_dir="$1"
        if [ "$use_python" -eq 1 ]; then
          set -- "$sharp_exe" -m sharp.cli predict -i "$batch_dir" -o "$output_dir" --device "$device"
        else
          set -- "$sharp_exe" predict -i "$batch_dir" -o "$output_dir" --device "$device"
        fi
        if [ -n "$checkpoint" ]; then
          set -- "$@" -c "$checkpoint"
        fi
        echo "Processing batch: $(basename "$batch_dir")"
        "$@"
      ' _ {}
  else
    # Sequential batch processing (checkpoint loads once per batch)
    batch_num=1
    for batch_dir in $(find "$batch_dirs" -mindepth 1 -maxdepth 1 -type d | sort); do
      echo "Processing batch $batch_num/$total_batches: $(basename "$batch_dir")"
      if [ "$use_python" -eq 1 ]; then
        set -- "$sharp_exe" -m sharp.cli predict -i "$batch_dir" -o "$output_dir" --device "$device"
      else
        set -- "$sharp_exe" predict -i "$batch_dir" -o "$output_dir" --device "$device"
      fi
      if [ -n "$checkpoint" ]; then
        set -- "$@" -c "$checkpoint"
      fi
      "$@"
      batch_num=$((batch_num + 1))
    done
  fi
  
  rm -rf "$batch_dirs"
else
  # Single batch - process all images at once (checkpoint loads once)
  if [ "$use_python" -eq 1 ]; then
    set -- "$sharp_exe" -m sharp.cli predict -i "$temp_dir" -o "$output_dir" --device "$device"
  else
    set -- "$sharp_exe" predict -i "$temp_dir" -o "$output_dir" --device "$device"
  fi
  if [ -n "$checkpoint" ]; then
    set -- "$@" -c "$checkpoint"
  fi
  echo "Running: $*"
  "$@"
fi

cmd_time_end="$(date +%s.%N 2>/dev/null || date +%s)"

awk -v start="$cmd_time_start" -v end="$cmd_time_end" -v total_start="$start_time" 'BEGIN {
  sharp_time = end - start
  total_time = end - total_start
  printf "SHARP time: %.2fs\n", sharp_time
  printf "Total time: %.2fs\n", total_time
}'

echo "Done. Output in: $output_dir"

