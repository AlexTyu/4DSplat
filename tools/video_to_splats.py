#!/usr/bin/env python3
"""
Convert video to Gaussian splats by processing each frame through ml-sharp.

This script:
1. Extracts frames from a video file
2. Processes each frame through ml-sharp to generate 3D Gaussian splats
3. Saves the resulting .ply files to an output folder
"""

from __future__ import annotations

import argparse
import logging
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# Try to import cv2 for video processing
try:
    import cv2
except ImportError:
    cv2 = None

# Try to import plyfile for PLY manipulation
try:
    from plyfile import PlyData, PlyElement
except ImportError:
    PlyData = None
    PlyElement = None

LOGGER = logging.getLogger(__name__)


def _find_sharp_bin() -> str | None:
    """
    Try to locate an installed `sharp` executable.
    """
    # Check PATH first
    which = shutil.which("sharp")
    if which:
        return which

    # Common user-local installs on macOS:
    home = Path.home()
    candidates = []
    for p in home.glob("Library/Python/*/bin/sharp"):
        candidates.append(p)
    for p in home.glob(".local/bin/sharp"):
        candidates.append(p)

    # Pick the newest version
    def score(path: Path) -> tuple[int, int, str]:
        m = None
        try:
            m = __import__("re").search(r"/Python/(\d+)\.(\d+)/bin/sharp$", str(path))
        except Exception:
            m = None
        if m:
            return (int(m.group(1)), int(m.group(2)), str(path))
        return (0, 0, str(path))

    candidates_sorted = sorted(candidates, key=score, reverse=True)
    for c in candidates_sorted:
        if c.exists() and os.access(c, os.X_OK):
            return str(c)
    return None


def extract_frames(video_path: Path, output_dir: Path, frame_interval: int = 1, max_frames: int | None = None) -> list[Path]:
    """
    Extract frames from video using OpenCV.
    
    Args:
        video_path: Path to input video file
        output_dir: Directory to save extracted frames
        frame_interval: Extract every Nth frame (1 = all frames, 2 = every other frame, etc.)
    
    Returns:
        List of paths to extracted frame images
    """
    if cv2 is None:
        raise ImportError(
            "OpenCV (cv2) is required for video processing. "
            "Install it with: pip install opencv-python"
        )
    
    LOGGER.info("Extracting frames from %s", video_path)
    
    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        raise RuntimeError(f"Failed to open video file: {video_path}")
    
    output_dir.mkdir(parents=True, exist_ok=True)
    
    frame_paths = []
    frame_count = 0
    extracted_count = 0
    
    # Get total frame count for progress reporting
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    fps = cap.get(cv2.CAP_PROP_FPS)
    
    LOGGER.info("Video info: %d frames @ %.2f fps", total_frames, fps)
    LOGGER.info("Extracting every %d frame(s)", frame_interval)
    
    while True:
        ret, frame = cap.read()
        if not ret:
            break
        
        if frame_count % frame_interval == 0:
            frame_filename = output_dir / f"frame_{extracted_count:06d}.png"
            cv2.imwrite(str(frame_filename), frame)
            frame_paths.append(frame_filename)
            extracted_count += 1
            
            if extracted_count % 10 == 0:
                LOGGER.info("Extracted %d frames...", extracted_count)
            
            # Stop if max_frames limit reached
            if max_frames is not None and extracted_count >= max_frames:
                LOGGER.info("Reached max_frames limit (%d), stopping extraction", max_frames)
                break
        
        frame_count += 1
    
    cap.release()
    
    LOGGER.info("Extracted %d total frames from %d video frames", extracted_count, frame_count)
    return frame_paths


def downsample_ply(ply_path: Path, output_path: Path | None = None) -> Path:
    """
    Downsample a PLY file by removing every other point.
    
    Args:
        ply_path: Path to input PLY file
        output_path: Optional output path (defaults to overwriting input)
    
    Returns:
        Path to the downsampled PLY file
    """
    if PlyData is None:
        raise ImportError(
            "plyfile is required for downsampling. "
            "Install it with: pip install plyfile"
        )
    
    LOGGER.debug("Downsampling %s", ply_path)
    
    # Read the PLY file
    plydata = PlyData.read(str(ply_path))
    
    # Get the vertex element
    vertex_element = plydata['vertex']
    original_count = len(vertex_element.data)
    
    # Keep every other point (0, 2, 4, 6, ...)
    # Make a copy to ensure C-contiguous array
    downsampled_vertices = vertex_element.data[::2].copy()
    new_count = len(downsampled_vertices)
    
    LOGGER.debug("Reduced vertices from %d to %d (%.1f%% reduction)", 
                 original_count, new_count, 100 * (1 - new_count / original_count))
    
    # Create new vertex element with downsampled data
    new_vertex_element = PlyElement.describe(
        downsampled_vertices, 
        'vertex',
        comments=vertex_element.comments
    )
    
    # Keep all other elements unchanged
    new_elements = [new_vertex_element]
    for element in plydata.elements:
        if element.name != 'vertex':
            new_elements.append(element)
    
    # Create new PLY data
    new_plydata = PlyData(new_elements, text=plydata.text, 
                          byte_order=plydata.byte_order, comments=plydata.comments)
    
    # Write to output
    if output_path is None:
        output_path = ply_path
    
    new_plydata.write(str(output_path))
    
    return output_path


def run_sharp_predict(
    input_dir: Path,
    output_dir: Path,
    device: str = "default",
    checkpoint_path: Path | None = None,
    sharp_bin: str | None = None,
) -> None:
    """
    Run SHARP prediction on a directory of images.
    
    Args:
        input_dir: Directory containing input images
        output_dir: Directory to save output .ply files
        device: Device to use (default/cpu/mps/cuda)
        checkpoint_path: Optional path to model checkpoint
        sharp_bin: Optional path to sharp executable
    """
    output_dir.mkdir(parents=True, exist_ok=True)
    
    # Find sharp executable
    sharp_exe = sharp_bin or _find_sharp_bin()
    
    if sharp_exe:
        LOGGER.info("Using sharp executable: %s", sharp_exe)
        cmd = [
            str(sharp_exe),
            "predict",
            "-i",
            str(input_dir),
            "-o",
            str(output_dir),
            "--device",
            str(device),
        ]
        if checkpoint_path:
            cmd += ["-c", str(checkpoint_path)]
        
        LOGGER.info("Running: %s", " ".join(cmd))
        subprocess.run(cmd, check=True)
    else:
        # Fallback: try to import sharp from Splat-R&D folder
        LOGGER.info("Sharp executable not found, trying to import from Splat-R&D")
        
        # Look for ml-sharp in parent directory or Splat-R&D workspace
        candidates = [
            Path(__file__).parent.parent / "Splat-R&D" / "ml-sharp" / "src",
            Path.home() / "projects" / "Splat-R&D" / "ml-sharp" / "src",
        ]
        
        sharp_src = None
        for candidate in candidates:
            if candidate.exists():
                sharp_src = candidate
                break
        
        if not sharp_src:
            raise FileNotFoundError(
                "Could not find sharp executable or ml-sharp sources. "
                "Please install ml-sharp or ensure it's available in the Splat-R&D folder."
            )
        
        LOGGER.info("Using sharp from: %s", sharp_src)
        sys.path.insert(0, str(sharp_src))
        
        from sharp.cli import main_cli
        
        # Set up arguments for sharp CLI
        sys.argv = [
            "sharp",
            "predict",
            "-i",
            str(input_dir),
            "-o",
            str(output_dir),
            "--device",
            str(device),
        ]
        if checkpoint_path:
            sys.argv += ["-c", str(checkpoint_path)]
        
        LOGGER.info("Running sharp CLI with args: %s", sys.argv)
        main_cli()


def main() -> int:
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description="Convert video to Gaussian splats using ml-sharp"
    )
    parser.add_argument(
        "-i",
        "--input",
        type=str,
        required=True,
        help="Path to input video file",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=str,
        required=True,
        help="Directory to save output .ply files",
    )
    parser.add_argument(
        "--frame-interval",
        type=int,
        default=1,
        help="Extract every Nth frame (1=all frames, 2=every other frame, etc.)",
    )
    parser.add_argument(
        "--device",
        type=str,
        default="default",
        help="Device to use: default/cpu/mps/cuda",
    )
    parser.add_argument(
        "--checkpoint",
        type=str,
        default=None,
        help="Optional path to ml-sharp checkpoint .pt file",
    )
    parser.add_argument(
        "--keep-frames",
        action="store_true",
        help="Keep extracted frames (saved in output/frames)",
    )
    parser.add_argument(
        "--downsample",
        action="store_true",
        default=False,
        help="Remove every other point from the splats to reduce file size by ~50%% (default: False)",
    )
    parser.add_argument(
        "--first-frame-only",
        action="store_true",
        help="Process only the first frame for debugging",
    )
    parser.add_argument(
        "--sharp-bin",
        type=str,
        default=None,
        help="Optional path to sharp executable",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="Enable verbose logging",
    )
    
    args = parser.parse_args()
    
    # Configure logging
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    )
    
    # Validate input
    input_video = Path(args.input)
    if not input_video.exists():
        LOGGER.error("Input video not found: %s", input_video)
        return 1
    
    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)
    
    checkpoint_path = Path(args.checkpoint) if args.checkpoint else None
    
    # Create temporary directory for frames or use persistent directory
    if args.keep_frames:
        frames_dir = output_dir / "frames"
        frames_dir.mkdir(exist_ok=True)
        LOGGER.info("Frames will be saved to: %s", frames_dir)
    else:
        frames_dir = Path(tempfile.mkdtemp(prefix="video_frames_"))
        LOGGER.info("Using temporary directory for frames: %s", frames_dir)
    
    try:
        # Step 1: Extract frames from video
        max_frames = 1 if args.first_frame_only else None
        if args.first_frame_only:
            LOGGER.info("DEBUG MODE: Processing only the first frame")
        
        frame_paths = extract_frames(input_video, frames_dir, args.frame_interval, max_frames=max_frames)
        
        if not frame_paths:
            LOGGER.error("No frames extracted from video")
            return 1
        
        # Step 2: Run ml-sharp prediction
        LOGGER.info("Processing %d frames with ml-sharp...", len(frame_paths))
        run_sharp_predict(
            input_dir=frames_dir,
            output_dir=output_dir,
            device=args.device,
            checkpoint_path=checkpoint_path,
            sharp_bin=args.sharp_bin,
        )
        
        # Step 3: Downsample PLY files if requested
        if args.downsample:
            LOGGER.info("Downsampling PLY files (removing every other point)...")
            ply_files = list(output_dir.glob("*.ply"))
            for i, ply_file in enumerate(ply_files, 1):
                LOGGER.info("Downsampling %d/%d: %s", i, len(ply_files), ply_file.name)
                downsample_ply(ply_file)
            LOGGER.info("Downsampling complete!")
        
        LOGGER.info("Done! Gaussian splats saved to: %s", output_dir)
        
    finally:
        # Clean up temporary frames if not keeping them
        if not args.keep_frames and frames_dir.exists():
            LOGGER.info("Cleaning up temporary frames...")
            shutil.rmtree(frames_dir)
    
    return 0


if __name__ == "__main__":
    sys.exit(main())

