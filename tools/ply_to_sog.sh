#!/bin/bash
set -euo pipefail

input_dir="/Users/alexanderturin/projects/4DSplat/ply_frames"
output_root="/Users/alexanderturin/projects/4DSplat/sog_output"

mkdir -p "$output_root"

if ! command -v npx >/dev/null 2>&1; then
  echo "npx is required to run splat-transform."
  exit 1
fi

shopt -s nullglob
ply_files=("$input_dir"/*.ply)
if [ ${#ply_files[@]} -eq 0 ]; then
  echo "No PLY files found in $input_dir"
  exit 1
fi

for ply_path in "${ply_files[@]}"; do
  filename="$(basename "$ply_path")"
  stem="${filename%.ply}"
  output_dir="$output_root/$stem"
  mkdir -p "$output_dir"
  output_meta="$output_dir/meta.json"
  echo "Converting $filename -> $output_dir/"
  npx --yes splat-transform -w "$ply_path" "$output_meta"
done

