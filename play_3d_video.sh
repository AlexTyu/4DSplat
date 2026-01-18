#!/bin/sh
set -eu    

root_dir="/Users/alexanderturin/projects/4DSplat"
output_root="${root_dir}/output"

if [ ! -d "$output_root" ]; then
  echo "Output folder not found: $output_root"
  exit 1
fi

tmp_list="$(mktemp)"
find "$output_root" -type d \( -path "*/tmp/ply" -o -path "*/tmp/work/ply" \) -print | sort -u > "$tmp_list"
if [ ! -s "$tmp_list" ]; then
  rm -f "$tmp_list"
  echo "No output folders with tmp/ply found in: $output_root"
  exit 1
fi

echo "Select a project:"
awk '{ print NR }' "$tmp_list" | while read -r idx; do
  ply_dir="$(sed -n "${idx}p" "$tmp_list")"
  rel_path="${ply_dir#${output_root}/}"
  project_name="$(printf "%s" "$rel_path" | cut -d'/' -f1)"
  printf "%s. %s\n" "$idx" "$project_name"
done

selection=""
while [ -z "$selection" ]; do
  read -r -p "Enter number: " choice
  if printf "%s" "$choice" | grep -Eq '^[0-9]+$'; then
    total="$(wc -l < "$tmp_list" | tr -d ' ')"
    if [ "$choice" -ge 1 ] && [ "$choice" -le "$total" ]; then
      selection="$choice"
    else
      echo "Invalid selection."
    fi
  else
    echo "Invalid selection."
  fi
done

ply_dir="$(sed -n "${selection}p" "$tmp_list")"
rm -f "$tmp_list"
if ! find "$ply_dir" -maxdepth 1 -name "*.ply" -print -quit | grep -q .; then
  echo "No PLY files in: $ply_dir"
  exit 1
fi

cd "${root_dir}/brush"
./target/release/brush --with-viewer "$ply_dir"

