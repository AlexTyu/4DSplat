#!/usr/bin/env bash
set -euo pipefail

read -r -p "YouTube link: " YT_URL
if [[ -z "${YT_URL}" ]]; then
  echo "No URL provided. Exiting."
  exit 1
fi

OUTPUT_DIR="input_videos"
mkdir -p "${OUTPUT_DIR}"

# Prefer 4K (2160p) if available, otherwise fall back to the best quality.
python -m yt_dlp \
  -f "bestvideo[height>=2160]+bestaudio/best[height>=2160]/best" \
  --merge-output-format mp4 \
  -o "${OUTPUT_DIR}/%(title).80s.%(ext)s" \
  "${YT_URL}"

