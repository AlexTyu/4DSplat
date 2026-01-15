#!/usr/bin/env sh
# Convert one or more images to PLY splats using ml-sharp.

set -eu

ROOT_DIR="/Users/alexanderturin/projects/4DSplat"
DEFAULT_DEVICE="default"

inputs_file="$(mktemp -t sharp_inputs_list_XXXXXX)"
trap 'rm -f "$inputs_file"; [ -n "${temp_dir:-}" ] && rm -rf "$temp_dir"' EXIT

output_dir=""
device="$DEFAULT_DEVICE"
checkpoint=""
sharp_bin=""

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
  default_checkpoint="${HOME}/.cache/torch/hub/checkpoints/sharp_2572gikvuh.pt"
  if [ -f "$default_checkpoint" ]; then
    checkpoint="$default_checkpoint"
    echo "Using cached checkpoint: $checkpoint"
  fi
fi

temp_dir="$(mktemp -d -t sharp_inputs_XXXXXX)"

allowed_exts='png|jpg|jpeg|bmp|tif|tiff|webp'
image_list="$(mktemp -t sharp_image_list_XXXXXX)"
trap 'rm -f "$inputs_file" "$image_list"; [ -n "${temp_dir:-}" ] && rm -rf "$temp_dir"' EXIT

while IFS= read -r input_path; do
  if [ -d "$input_path" ]; then
    find "$input_path" -maxdepth 1 -type f \
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

start_time="$(python3 - <<'PY'
import time
print(time.monotonic())
PY
)"

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

prep_end="$(python3 - <<'PY'
import time
print(time.monotonic())
PY
)"
python3 - <<PY
start = float("$start_time")
end = float("$prep_end")
print(f"Prep time: {end - start:.2f}s")
PY

if [ -n "$sharp_bin" ]; then
  sharp_exe="$sharp_bin"
else
  sharp_exe="$(command -v sharp || true)"
fi

if [ -z "$sharp_exe" ]; then
  echo "sharp executable not found. Install ml-sharp or pass --sharp-bin."
  exit 1
fi

cmd_time_start="$(python3 - <<'PY'
import time
print(time.monotonic())
PY
)"

set -- "$sharp_exe" predict -i "$temp_dir" -o "$output_dir" --device "$device"
if [ -n "$checkpoint" ]; then
  set -- "$@" -c "$checkpoint"
fi
echo "Running: $*"
"$@"

cmd_time_end="$(python3 - <<'PY'
import time
print(time.monotonic())
PY
)"

python3 - <<PY
start = float("$cmd_time_start")
end = float("$cmd_time_end")
print(f"SHARP time: {end - start:.2f}s")
print(f"Total time: {end - float('$start_time'):.2f}s")
PY

echo "Done. Output in: $output_dir"

