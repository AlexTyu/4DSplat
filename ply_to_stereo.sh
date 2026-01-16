#!/bin/sh
set -eu

# Default values
input_path="/Users/alexanderturin/projects/4DSplat/ply_frames"
output_dir="/Users/alexanderturin/projects/4DSplat/stereo_output"
ipd="0.063"
brush_bin="/Users/alexanderturin/projects/4DSplat/brush/target/release/brush-render"
keep_ply="${KEEP_PLY:-1}"

# Parse command line arguments
# Support both --flag and positional arguments for backward compatibility
use_flags=0
pos_arg1=""
pos_arg2=""
pos_arg3=""
pos_arg4=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --input)
      input_path="$2"
      use_flags=1
      shift 2
      ;;
    --output)
      output_dir="$2"
      use_flags=1
      shift 2
      ;;
    --ipd)
      ipd="$2"
      use_flags=1
      shift 2
      ;;
    --brush-bin)
      brush_bin="$2"
      use_flags=1
      shift 2
      ;;
    --watch|--sequential|--poll-interval)
      # Ignore watch-related flags (for compatibility with other scripts)
      if [ "$1" = "--poll-interval" ]; then
        shift 2
      else
        shift
      fi
      ;;
    *)
      # Positional argument (backward compatibility)
      if [ -z "$pos_arg1" ]; then
        pos_arg1="$1"
      elif [ -z "$pos_arg2" ]; then
        pos_arg2="$1"
      elif [ -z "$pos_arg3" ]; then
        pos_arg3="$1"
      elif [ -z "$pos_arg4" ]; then
        pos_arg4="$1"
      fi
      shift
      ;;
  esac
done

# Use positional arguments if flags weren't provided
if [ "$use_flags" -eq 0 ]; then
  if [ -n "$pos_arg1" ]; then
    input_path="$pos_arg1"
  fi
  if [ -n "$pos_arg2" ]; then
    output_dir="$pos_arg2"
  fi
  if [ -n "$pos_arg3" ]; then
    ipd="$pos_arg3"
  fi
  if [ -n "$pos_arg4" ]; then
    brush_bin="$pos_arg4"
  fi
fi

delete_input_ply=1
case "$(printf "%s" "$keep_ply" | tr '[:upper:]' '[:lower:]')" in
  1|true|yes|y) delete_input_ply=0 ;;
  0|false|no|n) delete_input_ply=1 ;;
esac

echo "[PLY_TO_STEREO] Input: $input_path"
echo "[PLY_TO_STEREO] Output: $output_dir"
echo "[PLY_TO_STEREO] KEEP_PLY=$keep_ply, delete_input_ply=$delete_input_ply"

if [ ! -x "$brush_bin" ]; then
  echo "brush-render binary not found or not executable: $brush_bin"
  exit 1
fi

mkdir -p "$output_dir"

half_ipd="$(awk "BEGIN{print $ipd/2}")"
left_x="$(awk "BEGIN{print -$half_ipd}")"
right_x="$half_ipd"

if [ -f "$input_path" ]; then
  ply_list="$input_path"
else
  ply_list="$(ls -1 "$input_path"/*.ply 2>/dev/null | sort || true)"
fi

if [ -z "$ply_list" ]; then
  echo "No PLY files found in $input_path"
  exit 1
fi

for ply_path in $ply_list; do
  filename="$(basename "$ply_path")"
  stem="${filename%.ply}"
  left_path="$output_dir/${stem}_left.png"
  right_path="$output_dir/${stem}_right.png"

  echo "Rendering $filename (left)"
  "$brush_bin" "$ply_path" \
    --output "$left_path" \
    --cam-pos "$left_x" 0.0 0.0 \
    --cam-rot 0.0 0.0 0.0 1.0 \
    --background 0.0 0.0 0.0

  echo "Rendering $filename (right)"
  "$brush_bin" "$ply_path" \
    --output "$right_path" \
    --cam-pos "$right_x" 0.0 0.0 \
    --cam-rot 0.0 0.0 0.0 1.0 \
    --background 0.0 0.0 0.0

  if [ "$delete_input_ply" -eq 1 ]; then
    echo "Deleting PLY file: $ply_path"
    rm -f "$ply_path"
    if [ -f "$ply_path" ]; then
      echo "Warning: Failed to delete $ply_path"
    fi
  fi
done
