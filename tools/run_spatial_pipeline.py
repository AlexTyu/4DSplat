#!/usr/bin/env python3
# Pipeline steps:
# 1) Extract frames from the selected video into tmp/frames.
# 2) Convert frames to PLYs using image_to_splat.py.
# 3) Convert PLYs to stereo frames using ply_to_stereo.py.
# 4) Convert stereo frames to videos using stereo_frames_to_video.py.
from __future__ import annotations

import logging
import os
import time
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

try:
    import cv2
except ImportError:
    cv2 = None


ROOT_DIR = Path("/Users/alexanderturin/projects/4DSplat")
INPUT_VIDEOS_DIR = ROOT_DIR / "input_videos"
OUTPUT_ROOT = ROOT_DIR / "output"
KEEP_TEMP = "-keepTemp" in sys.argv or os.getenv("KEEP_TEMP") == "1"
PARALLEL_RENDER = True
RENDER_WORKERS = int(os.getenv("RENDER_WORKERS", "2"))


def ensure_dependencies() -> None:
    if cv2 is None:
        raise RuntimeError("OpenCV (cv2) is required. Install with: pip install opencv-python")


def get_video_fps(cap: "cv2.VideoCapture") -> float:
    fps = cap.get(cv2.CAP_PROP_FPS)
    if fps and fps > 0:
        return fps
    return 30.0


def render_with_ply_to_stereo(ply_input: Path, output_dir: Path) -> None:
    subprocess.run(
        [
            sys.executable,
            str(ROOT_DIR / "ply_to_stereo.py"),
            "--input",
            str(ply_input),
            "--output",
            str(output_dir),
        ],
        check=True,
    )


def main() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s - %(levelname)s - %(message)s",
    )

    if not INPUT_VIDEOS_DIR.exists():
        print(f"Input videos folder not found: {INPUT_VIDEOS_DIR}")
        return 1

    input_files = sorted([p for p in INPUT_VIDEOS_DIR.iterdir() if p.is_file()])
    if not input_files:
        print(f"No input videos found in: {INPUT_VIDEOS_DIR}")
        return 1

    print("Select input video:")
    for idx, path in enumerate(input_files, 1):
        print(f"{idx}. {path.name}")

    selected = None
    while selected is None:
        choice = input("Enter number: ").strip()
        if not choice.isdigit():
            print("Please enter a number.")
            continue
        index = int(choice)
        if 1 <= index <= len(input_files):
            selected = input_files[index - 1]
        else:
            print("Invalid selection.")

    input_video = selected
    project_name = input_video.stem

    keep_temp = KEEP_TEMP
    if not keep_temp:
        keep_choice = input("Keep temp files? [y/N]: ").strip().lower()
        if keep_choice in {"y", "yes"}:
            keep_temp = True

    project_dir = OUTPUT_ROOT / project_name
    tmp_dir = project_dir / "tmp"
    frames_dir = tmp_dir / "frames"
    ply_dir = tmp_dir / "ply"
    stereo_dir = tmp_dir / "stereo_frames"
    video_dir = project_dir / "video_output"
    spatial_output = video_dir / "spatial_video_spatialmediakit.mov"

    if tmp_dir.exists():
        overwrite = input(
            "Temp folder already exists for this project. Overwrite? [y/N]: "
        ).strip().lower()
        if overwrite in {"y", "yes"}:
            shutil.rmtree(tmp_dir, ignore_errors=True)
        else:
            print("Keeping existing temp folder.")

    frames_dir.mkdir(parents=True, exist_ok=True)
    ply_dir.mkdir(parents=True, exist_ok=True)
    stereo_dir.mkdir(parents=True, exist_ok=True)
    existing_stereo = any(stereo_dir.glob("frame_*_left.png")) or any(
        stereo_dir.glob("frame_*_right.png")
    )
    use_existing_stereo = False
    if existing_stereo:
        regen_choice = input(
            "Stereo frames already exist in tmp/stereo_frames. Regenerate? [y/N]: "
        ).strip().lower()
        if regen_choice not in {"y", "yes"}:
            use_existing_stereo = True
        else:
            shutil.rmtree(stereo_dir, ignore_errors=True)
            stereo_dir.mkdir(parents=True, exist_ok=True)

    ensure_dependencies()

    cap = cv2.VideoCapture(str(input_video))
    if not cap.isOpened():
        print(f"Failed to open video: {input_video}")
        return 1

    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    if not use_existing_stereo:
        if total_frames > 0:
            estimate_seconds = total_frames * 7
            hours = int(estimate_seconds // 3600)
            minutes = int((estimate_seconds % 3600) // 60)
            print(
                f"Estimated processing time for {total_frames} frames: "
                f"{hours}h {minutes}m (13.45s/frame)."
            )
            confirm = input("Continue? [y/N]: ").strip().lower()
            if confirm not in {"y", "yes"}:
                print("Aborted.")
                cap.release()
                return 0

    fps = get_video_fps(cap)
    frame_idx = 0

    if not use_existing_stereo:
        while True:
            ret, frame = cap.read()
            if not ret:
                break

            frame_name = f"frame_{frame_idx:06d}.png"
            frame_path = frames_dir / frame_name
            cv2.imwrite(str(frame_path), frame)

            frame_idx += 1

    cap.release()

    if not use_existing_stereo:
        if frame_idx == 0:
            print("No frames processed.")
            return 1

        batch_start = time.perf_counter()
        subprocess.run(
            [
                sys.executable,
                str(ROOT_DIR / "image_to_splat.py"),
                "--input",
                str(frames_dir),
                "--output",
                str(ply_dir),
            ],
            check=True,
        )
        batch_elapsed = time.perf_counter() - batch_start
        logging.info("Batch PLY generation time: %.2fs", batch_elapsed)

        ply_files = sorted(ply_dir.glob("*.ply"))
        if not ply_files:
            raise RuntimeError(f"No PLY files found in: {ply_dir}")

        if PARALLEL_RENDER:
            logging.info("Rendering stereo in parallel (%d worker(s))", RENDER_WORKERS)
            with ThreadPoolExecutor(max_workers=RENDER_WORKERS) as executor:
                futures = {
                    executor.submit(render_with_ply_to_stereo, ply_path, stereo_dir): ply_path
                    for ply_path in ply_files
                }
                for future in futures:
                    future.result()
        else:
            logging.info("Rendering stereo frames from %s", ply_dir)
            render_with_ply_to_stereo(ply_dir, stereo_dir)

        if not keep_temp:
            for ply_path in ply_files:
                ply_path.unlink()

    logging.info("Rendering videos for each eye...")
    subprocess.run(
        [
            sys.executable,
            str(ROOT_DIR / "stereo_frames_to_video.py"),
            "--input",
            str(stereo_dir),
            "--output",
            str(video_dir),
            "--fps",
            str(fps),
            "--spatial-output",
            str(spatial_output),
        ],
        check=True,
    )

    logging.info("Done. Output in: %s", project_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())

