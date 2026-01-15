#!/usr/bin/env sh
# Shell wrapper for converting PLY files into stereo frames.

set -eu

ROOT_DIR="/Users/alexanderturin/projects/4DSplat"

watch_mode=0
input_path=""
pass_args=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -i|--input)
      input_path="$2"
      pass_args="$pass_args $1 \"$2\""
      shift 2
      ;;
    --watch)
      watch_mode=1
      pass_args="$pass_args $1"
      shift
      ;;
    *)
      pass_args="$pass_args $1"
      shift
      ;;
  esac
done

eval "python3 \"${ROOT_DIR}/ply_to_stereo.py\" $pass_args"

if [ "${KEEP_TEMP:-1}" -eq 0 ] && [ "$watch_mode" -eq 0 ] && [ -n "$input_path" ]; then
  if [ -f "$input_path" ]; then
    rm -f "$input_path"
  elif [ -d "$input_path" ]; then
    find "$input_path" -maxdepth 1 -type f -name "*.ply" -delete
  fi
fi

