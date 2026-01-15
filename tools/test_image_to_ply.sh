#!/bin/bash
set -euo pipefail

root_dir="/Users/alexanderturin/projects/4DSplat"
input_image="${root_dir}/input.png"
output_dir="${root_dir}/ply_output"

mkdir -p "$output_dir"

python3 "${root_dir}/image_to_splat.py" \
  --input "$input_image" \
  --output "$output_dir"

echo "PLY output written to: $output_dir"

