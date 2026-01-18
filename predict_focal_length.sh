#!/usr/bin/env sh
# Predict focal length for images using MLFocalLengths model.
# Usage: ./predict_focal_length.sh --input <image_or_directory> [--checkpoint <path>]

set -eu

ROOT_DIR="/Users/alexanderturin/projects/4DSplat"
MLFOCAL_DIR="${ROOT_DIR}/MLFocalLengths"
CHECKPOINT_DIR="${MLFOCAL_DIR}/checkpoints"
CHECKPOINT_FILE="${CHECKPOINT_DIR}/model.pt"
CHECKPOINT_URL="https://drive.google.com/uc?export=download&id=16Yf8dQrIAg-k8RKcy_chRsctrhQ4yzse"

input_path=""
checkpoint_path=""
install_deps=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    -i|--input)
      shift
      input_path="$1"
      ;;
    -c|--checkpoint)
      shift
      checkpoint_path="$1"
      ;;
    --install-deps)
      install_deps=1
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: $0 --input <image_or_directory> [--checkpoint <path>] [--install-deps]"
      exit 1
      ;;
  esac
  shift
done

if [ -z "$input_path" ]; then
  echo "ERROR: Missing --input"
  echo "Usage: $0 --input <image_or_directory> [--checkpoint <path>] [--install-deps]"
  exit 1
fi

if [ ! -e "$input_path" ]; then
  echo "ERROR: Input path not found: $input_path"
  exit 1
fi

# Check if MLFocalLengths directory exists
if [ ! -d "$MLFOCAL_DIR" ]; then
  echo "ERROR: MLFocalLengths directory not found at: $MLFOCAL_DIR"
  echo "Please clone the repository first:"
  echo "  git clone https://github.com/nandometzger/MLFocalLengths.git"
  exit 1
fi

# Install dependencies if requested
if [ "$install_deps" -eq 1 ]; then
  echo "[INSTALL] Installing Python dependencies..."
  if [ -f "${MLFOCAL_DIR}/requirements_pip.txt" ]; then
    python3 -m pip install --user -r "${MLFOCAL_DIR}/requirements_pip.txt"
  else
    python3 -m pip install --user "numpy<2" torch torchvision pillow piexif tqdm configargparse opencv-python rawpy exifread matplotlib scikit-learn h5py
  fi
  # Ensure numpy < 2.0 even if requirements file didn't enforce it
  numpy_version=$(python3 -c "import numpy; print(numpy.__version__)" 2>/dev/null || echo "")
  if [ -n "$numpy_version" ]; then
    major_version=$(echo "$numpy_version" | cut -d. -f1)
    if [ "$major_version" -ge 2 ]; then
      echo "[INSTALL] Downgrading NumPy to < 2.0 for MLFocalLengths compatibility..."
      python3 -m pip install --user "numpy<2" --force-reinstall
    fi
  fi
  echo "[INSTALL] Dependencies installed."
fi

# Determine checkpoint path
if [ -n "$checkpoint_path" ]; then
  CHECKPOINT_FILE="$checkpoint_path"
elif [ ! -f "$CHECKPOINT_FILE" ]; then
  echo "[DOWNLOAD] Checkpoint not found. Attempting to download..."
  mkdir -p "$CHECKPOINT_DIR"
  
  # Try using gdown if available, otherwise prompt user
  if command -v gdown >/dev/null 2>&1; then
    echo "[DOWNLOAD] Using gdown to download checkpoint..."
    gdown "$CHECKPOINT_URL" -O "$CHECKPOINT_FILE"
  elif python3 -c "import gdown" 2>/dev/null; then
    echo "[DOWNLOAD] Using gdown (Python package) to download checkpoint..."
    python3 -c "import gdown; gdown.download('$CHECKPOINT_URL', '$CHECKPOINT_FILE', quiet=False)"
  else
    echo "[DOWNLOAD] gdown not found. Please install it or download manually:"
    echo "  Install: pip install gdown"
    echo "  Or download manually from: https://drive.google.com/file/d/16Yf8dQrIAg-k8RKcy_chRsctrhQ4yzse/view?usp=share_link"
    echo "  Save to: $CHECKPOINT_FILE"
    exit 1
  fi
fi

if [ ! -f "$CHECKPOINT_FILE" ]; then
  echo "ERROR: Checkpoint file not found: $CHECKPOINT_FILE"
  echo "Please download it from: https://drive.google.com/file/d/16Yf8dQrIAg-k8RKcy_chRsctrhQ4yzse/view?usp=share_link"
  exit 1
fi

# Determine if input is a file or directory
if [ -f "$input_path" ]; then
  # Single file - create temporary directory with a symlink to preserve original path
  # This way predict.py can update the original file's EXIF
  temp_dir=$(mktemp -d)
  filename=$(basename "$input_path")
  ln -s "$(realpath "$input_path")" "$temp_dir/$filename"
  input_dir="$temp_dir"
  cleanup_temp=1
elif [ -d "$input_path" ]; then
  input_dir="$input_path"
  cleanup_temp=0
else
  echo "ERROR: Input must be a file or directory"
  exit 1
fi

echo "[PREDICT] Predicting focal length for images in: $input_path"
echo "[PREDICT] Using checkpoint: $CHECKPOINT_FILE"

# Run prediction
cd "$MLFOCAL_DIR"
# Set SSL certificate path for macOS Python SSL issues
export SSL_CERT_FILE=$(python3 -m certifi 2>/dev/null || echo "")
export REQUESTS_CA_BUNDLE="$SSL_CERT_FILE"
# Use unbuffered Python output (-u) to see predictions in real-time
python3 -u predict.py \
  --checkpoint "$CHECKPOINT_FILE" \
  --root_dir "$input_dir" \
  --num-workers 4

# Cleanup temporary directory if created
if [ "$cleanup_temp" -eq 1 ]; then
  rm -rf "$temp_dir"
fi

echo "[PREDICT] Done."

