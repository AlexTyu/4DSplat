#!/usr/bin/env sh
# Set focal length EXIF metadata in existing frame images.

set -eu

ROOT_DIR="/Users/alexanderturin/projects/4DSplat"

frames_dir=""
focal_length_mm="30.0"

while [ "$#" -gt 0 ]; do
  case "$1" in
    -i|--input|--frames-dir)
      shift
      frames_dir="$1"
      ;;
    --focal-length)
      shift
      focal_length_mm="$1"
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: $0 --frames-dir <dir> --focal-length <mm>"
      exit 1
      ;;
  esac
  shift
done

if [ -z "$frames_dir" ]; then
  echo "ERROR: Missing --frames-dir"
  echo "Usage: $0 --frames-dir <dir> --focal-length <mm>"
  exit 1
fi

if [ ! -d "$frames_dir" ]; then
  echo "ERROR: Frames directory not found: $frames_dir"
  exit 1
fi

echo "[SET_FOCAL] Setting focal length to ${focal_length_mm}mm in frames..."

python3 - <<PY
import os
import sys
import site

# Add user site-packages to path
site.addsitedir(os.path.expanduser("~/Library/Python/3.11/lib/python/site-packages"))

frames_dir = "$frames_dir"
focal_length_mm = float("$focal_length_mm")

# Try to use piexif for proper EXIF embedding
try:
    import piexif
    piexif_available = True
except (ImportError, ModuleNotFoundError) as e:
    piexif_available = False
    print(f"ERROR: piexif not available ({e})", file=sys.stderr)
    print("Install with: pip install piexif", file=sys.stderr)
    sys.exit(1)

processed_count = 0
error_count = 0
skipped_count = 0

# Process all image files
image_extensions = ('.jpg', '.jpeg')
for filename in sorted(os.listdir(frames_dir)):
    if not filename.lower().endswith(image_extensions):
        continue
    
    image_path = os.path.join(frames_dir, filename)
    
    try:
        # Read existing EXIF if any
        try:
            existing_exif = piexif.load(image_path)
        except:
            existing_exif = {"0th": {}, "Exif": {}, "GPS": {}, "1st": {}, "thumbnail": None, "Interop": {}}
        
        # Check if focal length already exists in EXIF
        # FocalLength tag is 37386 (0x920A) in EXIF IFD
        FOCAL_LENGTH_TAG = 37386
        if "Exif" in existing_exif and FOCAL_LENGTH_TAG in existing_exif["Exif"]:
            # Focal length already exists, skip this image
            existing_focal = existing_exif["Exif"][FOCAL_LENGTH_TAG]
            if isinstance(existing_focal, tuple) and len(existing_focal) == 2:
                existing_focal_mm = existing_focal[0] / existing_focal[1]
            else:
                existing_focal_mm = existing_focal / 100.0 if isinstance(existing_focal, (int, float)) else "unknown"
            print(f"Skipping {filename}: focal length already exists ({existing_focal_mm}mm)", flush=True)
            skipped_count += 1
            continue
        
        # Add focal length to EXIF
        existing_exif["Exif"][FOCAL_LENGTH_TAG] = (int(focal_length_mm * 100), 100)  # FocalLength as rational
        
        # Convert to bytes and insert into JPEG
        exif_bytes = piexif.dump(existing_exif)
        
        # Insert EXIF directly into image file using piexif
        piexif.insert(exif_bytes, image_path)
        processed_count += 1
    except Exception as e:
        print(f"Warning: Could not add EXIF to {filename}: {e}", file=sys.stderr)
        error_count += 1

print(f"Processed {processed_count} image(s)")
if skipped_count > 0:
    print(f"Skipped {skipped_count} image(s) (focal length already exists in EXIF)", file=sys.stderr)
if error_count > 0:
    print(f"Errors: {error_count} image(s)", file=sys.stderr)
    sys.exit(1)
PY

echo "[SET_FOCAL] Done."

