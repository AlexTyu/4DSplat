#!/usr/bin/env python3
from __future__ import annotations

import logging
import shutil
import subprocess
import sys
from pathlib import Path

from render_ply_to_image import (
    ensure_brush_binary,
    render_file,
    resolve_render_params,
    stereo_camera_positions,
)


ROOT_DIR = Path("/Users/alexanderturin/projects/4DSplat")
OUTPUT_ROOT = ROOT_DIR / "output"
BRUSH_BIN_DEFAULT = "brush-render"

DEFAULT_IPD = 0.063
DEFAULT_CAM_POS = [0.0, 0.0, 0.0]
DEFAULT_CAM_ROT = [0.0, 0.0, 0.0, 1.0]
DEFAULT_BG = [0.0, 0.0, 0.0]


class RenderArgs:
    def __init__(self) -> None:
        self.width = None
        self.height = None
        self.fov_x = None
        self.fov_y = None
        self.focal_x = None
        self.focal_y = None
        self.center_x = None
        self.center_y = None
        self.use_ply_camera = True


def resolve_brush_bin() -> str:
    brush_bin = BRUSH_BIN_DEFAULT
    if brush_bin == "brush-render":
        local_bin = ROOT_DIR / "brush" / "target" / "release" / "brush-render"
        if local_bin.exists():
            brush_bin = str(local_bin)
    return brush_bin


def render_stereo_from_ply(ply_path: Path, output_dir: Path, brush_bin: str) -> None:
    args = RenderArgs()
    params = resolve_render_params(ply_path, args)
    left_pos, right_pos = stereo_camera_positions(DEFAULT_CAM_POS, DEFAULT_IPD)

    left_path = output_dir / f"{ply_path.stem}_left.png"
    right_path = output_dir / f"{ply_path.stem}_right.png"

    code = render_file(
        ply_path,
        left_path,
        brush_bin,
        params["width"],
        params["height"],
        params["fov_x"],
        params["fov_y"],
        params["focal_x"],
        params["focal_y"],
        params["center_x"],
        params["center_y"],
        left_pos,
        DEFAULT_CAM_ROT,
        DEFAULT_BG,
        None,
        [],
        False,
    )
    if code != 0:
        raise RuntimeError(f"brush-render failed for {ply_path.name} (left)")

    code = render_file(
        ply_path,
        right_path,
        brush_bin,
        params["width"],
        params["height"],
        params["fov_x"],
        params["fov_y"],
        params["focal_x"],
        params["focal_y"],
        params["center_x"],
        params["center_y"],
        right_pos,
        DEFAULT_CAM_ROT,
        DEFAULT_BG,
        None,
        [],
        False,
    )
    if code != 0:
        raise RuntimeError(f"brush-render failed for {ply_path.name} (right)")


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


def run_spatial_make(left_video: Path, right_video: Path, output_path: Path) -> None:
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
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s - %(levelname)s - %(message)s",
    )

    if not OUTPUT_ROOT.exists():
        print(f"Output folder not found: {OUTPUT_ROOT}")
        return 1

    ply_dirs = sorted(
        {
            p
            for p in OUTPUT_ROOT.rglob("tmp/ply")
            if p.is_dir()
            and list(p.glob("*.ply"))
        }
    )
    if not ply_dirs:
        print(f"No tmp/ply folders with PLY files found in: {OUTPUT_ROOT}")
        return 1

    print("Select a project:")
    for idx, ply_dir in enumerate(ply_dirs, 1):
        rel_path = ply_dir.relative_to(OUTPUT_ROOT)
        project_name = rel_path.parts[0]
        print(f"{idx}. {project_name}")

    selection = None
    while selection is None:
        choice = input("Enter number: ").strip()
        if not choice.isdigit():
            print("Please enter a number.")
            continue
        index = int(choice)
        if 1 <= index <= len(ply_dirs):
            selection = ply_dirs[index - 1]
        else:
            print("Invalid selection.")

    ply_dir = selection
    project_dir = ply_dir.parents[1]
    tmp_dir = project_dir / "tmp"
    stereo_dir = tmp_dir / "stereo_frames"
    video_dir = project_dir / "video_output"
    spatial_output = video_dir / f"{project_dir.name}_spatial.mov"

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

    brush_bin = resolve_brush_bin()
    if not ensure_brush_binary(brush_bin):
        print(
            f"Error: brush-render binary not found: {brush_bin}. "
            "Build Brush and pass the correct binary if needed."
        )
        return 1

    def ply_index(path: Path) -> int:
        name = path.stem
        if name.startswith("frame_"):
            try:
                return int(name.split("_", 1)[1])
            except ValueError:
                return 0
        return 0

    ply_files = sorted(ply_dir.glob("*.ply"), key=ply_index)
    if not ply_files:
        print(f"No PLY files found in: {ply_dir}")
        return 1

    if not use_existing_stereo:
        for i, ply_path in enumerate(ply_files, 1):
            logging.info("[%d/%d] Rendering %s", i, len(ply_files), ply_path.name)
            render_stereo_from_ply(ply_path, stereo_dir, brush_bin)

    fps = 30.0
    left_video, right_video = create_eye_videos(stereo_dir, video_dir, fps)

    logging.info("Generating spatial video with spatial CLI...")
    run_spatial_make(left_video, right_video, spatial_output)

    logging.info("Done. Output in: %s", project_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())

