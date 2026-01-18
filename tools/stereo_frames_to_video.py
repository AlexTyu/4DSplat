#!/usr/bin/env python3
from __future__ import annotations

import argparse
import logging
import subprocess
from pathlib import Path

ROOT_DIR = Path("/Users/alexanderturin/projects/4DSplat")


def create_eye_videos(stereo_dir: Path, video_dir: Path, fps: float) -> tuple[Path, Path]:
    video_dir.mkdir(parents=True, exist_ok=True)
    left_video = video_dir / "left_eye.mp4"
    right_video = video_dir / "right_eye.mp4"

    subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-framerate",
            str(fps),
            "-i",
            str(stereo_dir / "frame_%06d_left.png"),
            "-c:v",
            "libx264",
            "-crf",
            "0",
            "-preset",
            "veryslow",
            "-pix_fmt",
            "yuv420p",
            "-r",
            str(fps),
            str(left_video),
        ],
        check=True,
    )
    subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-framerate",
            str(fps),
            "-i",
            str(stereo_dir / "frame_%06d_right.png"),
            "-c:v",
            "libx264",
            "-crf",
            "0",
            "-preset",
            "veryslow",
            "-pix_fmt",
            "yuv420p",
            "-r",
            str(fps),
            str(right_video),
        ],
        check=True,
    )

    return left_video, right_video


def run_spatial_cli(left_video: Path, right_video: Path, output_path: Path) -> None:
    script_path = ROOT_DIR / "make_spatial_video.sh"
    subprocess.run(
        [
            "bash",
            str(script_path),
            str(left_video),
            str(right_video),
            str(output_path),
        ],
        check=True,
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Convert stereo frames into left/right videos and a spatial video."
    )
    parser.add_argument(
        "-i",
        "--input",
        required=True,
        help="Directory containing stereo frames named frame_XXXXXX_left/right.png",
    )
    parser.add_argument(
        "-o",
        "--output",
        required=True,
        help="Output directory for videos",
    )
    parser.add_argument(
        "--fps",
        type=float,
        default=30.0,
        help="Frame rate for output videos",
    )
    parser.add_argument(
        "--spatial-output",
        default=None,
        help="Optional path for spatial video output (defaults to output/spatial_video_spatialmediakit.mov)",
    )

    args = parser.parse_args()
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s - %(levelname)s - %(message)s",
    )

    stereo_dir = Path(args.input)
    if not stereo_dir.exists():
        logging.error("Stereo frames directory not found: %s", stereo_dir)
        return 1

    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)

    spatial_output = (
        Path(args.spatial_output)
        if args.spatial_output
        else output_dir / "spatial_video_spatialmediakit.mov"
    )

    logging.info("Rendering left/right eye videos...")
    left_video, right_video = create_eye_videos(stereo_dir, output_dir, args.fps)

    logging.info("Generating spatial video with spatial CLI...")
    run_spatial_cli(left_video, right_video, spatial_output)

    logging.info("Done. Output in: %s", output_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

