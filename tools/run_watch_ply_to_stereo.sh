#!/usr/bin/env sh
# Select a project and watch tmp/ply for new PLYs, rendering stereo frames as they appear.

set -eu

ROOT_DIR="/Users/alexanderturin/projects/4DSplat"
OUTPUT_ROOT="${ROOT_DIR}/output"

PROJECT_DIR=""
POLL_INTERVAL=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project-dir)
      PROJECT_DIR="$2"
      shift 2
      ;;
    --poll-interval)
      POLL_INTERVAL="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1"
      exit 1
      ;;
  esac
done

if [ ! -d "$OUTPUT_ROOT" ]; then
  echo "Output folder not found: $OUTPUT_ROOT"
  exit 1
fi

if [ -n "$PROJECT_DIR" ]; then
  project_dir="$PROJECT_DIR"
else
  project_list="$(find "$OUTPUT_ROOT" -maxdepth 1 -type d ! -path "$OUTPUT_ROOT" | sort)"
  if [ -z "$project_list" ]; then
    echo "No projects found in: $OUTPUT_ROOT"
    exit 1
  fi

  echo "Select project:"
  i=1
  printf "%s\n" "$project_list" | while IFS= read -r line; do
    printf "%d. %s\n" "$i" "$(basename "$line")"
    i=$((i + 1))
  done

  selected=""
  while [ -z "$selected" ]; do
    printf "Enter number: "
    read -r choice || exit 1
    case "$choice" in
      *[!0-9]*|"") echo "Please enter a number." ; continue ;;
    esac
    selected="$(printf "%s\n" "$project_list" | sed -n "${choice}p")"
    if [ -z "$selected" ]; then
      echo "Invalid selection."
      continue
    fi
  done

  project_dir="$selected"
fi
ply_dir="${project_dir}/tmp/ply"
stereo_dir="${project_dir}/tmp/stereo_frames"

mkdir -p "$ply_dir"
mkdir -p "$stereo_dir"

echo "Watching PLYs in: $ply_dir"
echo "Writing stereo frames to: $stereo_dir"

if [ -n "$POLL_INTERVAL" ]; then
  sh "${ROOT_DIR}/ply_to_stereo.sh" \
    --input "$ply_dir" \
    --output "$stereo_dir" \
    --watch \
    --sequential \
    --poll-interval "$POLL_INTERVAL"
else
  sh "${ROOT_DIR}/ply_to_stereo.sh" \
    --input "$ply_dir" \
    --output "$stereo_dir" \
    --watch \
    --sequential
fi

