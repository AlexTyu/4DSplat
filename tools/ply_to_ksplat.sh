#!/bin/bash
set -euo pipefail

input_dir="/Users/alexanderturin/projects/4DSplat/ply_frames"
output_dir="/Users/alexanderturin/projects/4DSplat/ksplat_output"

if ! command -v gsbox >/dev/null 2>&1; then
  echo "gsbox is required to write .ksplat files."
  echo "Install gsbox and ensure it is on PATH."
  exit 1
fi

help_text="$(gsbox --help 2>/dev/null || true)"
if ! echo "$help_text" | grep -qi "ply2ksplat"; then
  echo "gsbox v$(gsbox --version 2>/dev/null | head -n 1) does not support ply2ksplat."
  echo "No installed tool can write .ksplat directly from .ply here."
  echo "Use ./ply_to_sog.sh for best compression, or install a gsbox build with ply2ksplat."
  exit 1
fi

mkdir -p "$output_dir"

shopt -s nullglob
ply_files=("$input_dir"/*.ply)
if [ ${#ply_files[@]} -eq 0 ]; then
  echo "No PLY files found in $input_dir"
  exit 1
fi

for ply_path in "${ply_files[@]}"; do
  filename="$(basename "$ply_path")"
  stem="${filename%.ply}"
  output_path="$output_dir/${stem}.ksplat"
  echo "Converting $filename -> $(basename "$output_path")"
  gsbox ply2ksplat -i "$ply_path" -o "$output_path"
done

