#!/usr/bin/env python3
from __future__ import annotations

import argparse
import logging
import os
import time
from pathlib import Path

from render_ply_to_image import (
    ensure_brush_binary,
    render_file,
    resolve_render_params,
    stereo_camera_positions,
)

ROOT_DIR = Path("/Users/alexanderturin/projects/4DSplat")
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


def resolve_brush_bin(brush_bin: str | None) -> str:
    if brush_bin:
        return brush_bin
    local_bin = ROOT_DIR / "brush" / "target" / "release" / "brush-render"
    if local_bin.exists():
        return str(local_bin)
    return BRUSH_BIN_DEFAULT


def ply_index(path: Path) -> int:
    name = path.stem
    if name.startswith("frame_"):
        try:
            return int(name.split("_", 1)[1])
        except ValueError:
            return 0
    return 0


def render_stereo_from_ply(ply_path: Path, output_dir: Path, brush_bin: str, ipd: float) -> None:
    args = RenderArgs()
    params = resolve_render_params(ply_path, args)
    left_pos, right_pos = stereo_camera_positions(DEFAULT_CAM_POS, ipd)

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


def list_ply_files(input_path: Path) -> list[Path]:
    if input_path.is_file():
        return [input_path]
    return sorted(input_path.glob("*.ply"), key=ply_index)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Convert PLY files into stereo frames using brush-render."
    )
    parser.add_argument(
        "-i",
        "--input",
        required=True,
        help="PLY file or directory containing PLY files",
    )
    parser.add_argument(
        "-o",
        "--output",
        required=True,
        help="Output directory for stereo frames",
    )
    parser.add_argument(
        "--ipd",
        type=float,
        default=DEFAULT_IPD,
        help="Interpupillary distance in meters",
    )
    parser.add_argument(
        "--brush-bin",
        default=None,
        help="Optional path to brush-render executable",
    )
    parser.add_argument(
        "--watch",
        action="store_true",
        help="Watch input directory and render new PLY files as they appear",
    )
    parser.add_argument(
        "--sequential",
        action="store_true",
        help="When watching, process frame_XXXXXX.ply in order starting at 0",
    )
    parser.add_argument(
        "--poll-interval",
        type=float,
        default=1.0,
        help="Polling interval in seconds when using --watch",
    )

    args = parser.parse_args()
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s - %(levelname)s - %(message)s",
    )
    keep_temp = os.getenv("KEEP_TEMP", "1") != "0"

    input_path = Path(args.input)
    if not input_path.exists():
        logging.error("Input path not found: %s", input_path)
        return 1

    if args.watch and not input_path.is_dir():
        logging.error("--watch requires an input directory")
        return 1

    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)

    brush_bin = resolve_brush_bin(args.brush_bin)
    if not ensure_brush_binary(brush_bin):
        logging.error("brush-render binary not found: %s", brush_bin)
        return 1

    seen_sizes: dict[Path, int] = {}
    processed: set[Path] = set()

    def should_process(ply_path: Path) -> bool:
        left_path = output_dir / f"{ply_path.stem}_left.png"
        right_path = output_dir / f"{ply_path.stem}_right.png"
        if left_path.exists() and right_path.exists():
            return False
        return True

    def is_stable(ply_path: Path) -> bool:
        size = ply_path.stat().st_size
        last_size = seen_sizes.get(ply_path)
        seen_sizes[ply_path] = size
        return last_size is not None and last_size == size and size > 0

    def process_once() -> bool:
        ply_files = list_ply_files(input_path)
        if not ply_files:
            return False
        rendered_any = False
        for ply_path in ply_files:
            if not should_process(ply_path):
                continue
            if args.watch and not is_stable(ply_path):
                continue
            logging.info("Rendering %s", ply_path.name)
            render_stereo_from_ply(ply_path, output_dir, brush_bin, args.ipd)
            if not keep_temp:
                ply_path.unlink(missing_ok=True)
            processed.add(ply_path)
            rendered_any = True
        return rendered_any

    if not args.watch:
        process_once()
        return 0

    def frame_index_from_stem(stem: str) -> int | None:
        if stem.startswith("frame_"):
            try:
                return int(stem.split("_", 1)[1])
            except ValueError:
                return None
        return None

    def next_expected_index() -> int:
        existing = []
        for path in output_dir.glob("frame_*_left.png"):
            idx = frame_index_from_stem(path.stem.replace("_left", ""))
            if idx is not None:
                existing.append(idx)
        for path in output_dir.glob("frame_*_right.png"):
            idx = frame_index_from_stem(path.stem.replace("_right", ""))
            if idx is not None:
                existing.append(idx)
        if not existing:
            return 0
        return max(existing) + 1

    logging.info("Watching for PLY files in: %s", input_path)
    expected_index = next_expected_index() if args.sequential else None
    while True:
        if args.sequential:
            expected_name = f"frame_{expected_index:06d}.ply"
            expected_path = input_path / expected_name
            if expected_path.exists():
                if should_process(expected_path) and is_stable(expected_path):
                    logging.info("Rendering %s", expected_path.name)
                    render_stereo_from_ply(expected_path, output_dir, brush_bin, args.ipd)
                    if not keep_temp:
                        expected_path.unlink(missing_ok=True)
                expected_index += 1
                continue
            time.sleep(args.poll_interval)
            continue

        processed_any = process_once()
        if not processed_any:
            time.sleep(args.poll_interval)


if __name__ == "__main__":
    raise SystemExit(main())

