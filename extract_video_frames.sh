#!/usr/bin/env sh
# Extract frames from a video file.

set -eu

input_video=""
output_dir=""
debug=0
max_frames=""
focal_length_mm="30.0"

while [ "$#" -gt 0 ]; do
  case "$1" in
    -i|--input)
      shift
      input_video="$1"
      ;;
    -o|--output)
      shift
      output_dir="$1"
      ;;
    --debug)
      debug=1
      ;;
    --max-frames)
      shift
      max_frames="$1"
      ;;
    --focal-length)
      shift
      focal_length_mm="$1"
      ;;
    *)
      echo "Unknown argument: $1"
      exit 1
      ;;
  esac
  shift
done

if [ -z "$input_video" ]; then
  echo "Missing --input"
  exit 1
fi

if [ -z "$output_dir" ]; then
  echo "Missing --output"
  exit 1
fi

if [ ! -f "$input_video" ]; then
  echo "Input video not found: $input_video"
  exit 1
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ffmpeg is required but not found in PATH."
  exit 1
fi

mkdir -p "$output_dir"

echo "[EXTRACT] Extracting frames from: $(basename "$input_video")"

# Extract frames as JPEG (supports EXIF natively) with maximum quality
if [ "$debug" -eq 1 ] || [ -n "$max_frames" ]; then
  frames_to_extract="${max_frames:-3}"
  echo "[EXTRACT] Extracting only first $frames_to_extract frames"
  ffmpeg -y -i "$input_video" -vframes "$frames_to_extract" -q:v 1 "${output_dir}/frame_%06d.jpg" >/dev/null
else
  ffmpeg -y -i "$input_video" -q:v 1 "${output_dir}/frame_%06d.jpg" >/dev/null
fi

frame_count=$(ls "$output_dir"/frame_*.jpg 2>/dev/null | wc -l | tr -d ' ')

# Add EXIF focal length metadata to JPEG frames
if [ "$frame_count" -gt 0 ]; then
  echo "[EXTRACT] Adding EXIF metadata to frames..."
  python3 - <<PY
import os
import sys
import site

# Add user site-packages to path
site.addsitedir(os.path.expanduser("~/Library/Python/3.11/lib/python/site-packages"))

output_dir = "$output_dir"
focal_length_mm = float("$focal_length_mm")

# Try to use piexif for proper EXIF embedding
try:
    import piexif
    piexif_available = True
except (ImportError, ModuleNotFoundError) as e:
    piexif_available = False
    print(f"Note: piexif not available ({e}), extracting frames without EXIF metadata", file=sys.stderr)

for jpeg_file in sorted([f for f in os.listdir(output_dir) if f.endswith('.jpg')]):
    jpeg_path = os.path.join(output_dir, jpeg_file)
    
    try:
        if piexif_available:
            # Read existing EXIF if any
            try:
                existing_exif = piexif.load(jpeg_path)
            except:
                existing_exif = {"0th": {}, "Exif": {}, "GPS": {}, "1st": {}, "thumbnail": None, "Interop": {}}
            
            # Add focal length to EXIF
            # FocalLength tag is 37386 (0x920A) in EXIF IFD
            existing_exif["Exif"][37386] = (int(focal_length_mm * 100), 100)  # FocalLength as rational
            
            # Convert to bytes and insert into JPEG
            exif_bytes = piexif.dump(existing_exif)
            
            # Insert EXIF directly into JPEG file using piexif
            piexif.insert(exif_bytes, jpeg_path)
        else:
            print(f"Note: piexif not available, skipping EXIF for {jpeg_file}", file=sys.stderr)
            
    except Exception as e:
        print(f"Warning: Could not add EXIF to {jpeg_file}: {e}", file=sys.stderr)

# Remove any extra frames that might have been extracted
debug_flag = "$debug"
max_frames_val = "$max_frames"
if debug_flag == "1" or max_frames_val:
    frames_to_extract = int(max_frames_val) if max_frames_val else 3
    jpeg_files = sorted([f for f in os.listdir(output_dir) if f.endswith('.jpg')])
    if len(jpeg_files) > frames_to_extract:
        for extra_file in jpeg_files[frames_to_extract:]:
            os.remove(os.path.join(output_dir, extra_file))
PY
fi

frame_count=$(ls "$output_dir"/frame_*.jpg 2>/dev/null | wc -l | tr -d ' ')

echo "[EXTRACT] Extracted $frame_count frames to: $output_dir"
echo "$frame_count"

