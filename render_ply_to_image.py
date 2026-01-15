#!/usr/bin/env python3
"""
Render Gaussian splat PLY files to images using the Brush renderer.

Brush repo: https://github.com/ArthurBrussee/brush
"""

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np


def ensure_brush_binary(brush_bin):
    """Return True if the brush binary is available."""
    return shutil.which(brush_bin) is not None


def parse_ply_metadata(ply_path):
    intrinsics = None
    image_size = None

    try:
        with open(ply_path, "rb") as f:
            header_lines = []
            header_bytes = b""
            while True:
                line = f.readline()
                header_lines.append(line)
                header_bytes += line
                if b"end_header" in line:
                    break

            header_str = header_bytes.decode("ascii", errors="ignore")
            vertex_count = 0
            vertex_props = []
            in_vertex = False
            for line in header_str.split("\n"):
                parts = line.strip().split()
                if len(parts) >= 2 and parts[0] == "element":
                    in_vertex = parts[1] == "vertex"
                    if in_vertex and len(parts) >= 3:
                        vertex_count = int(parts[2])
                    continue
                if in_vertex and len(parts) >= 3 and parts[0] == "property":
                    vertex_props.append(parts[1])

            type_sizes = {
                "char": 1,
                "int8": 1,
                "uchar": 1,
                "uint8": 1,
                "short": 2,
                "int16": 2,
                "ushort": 2,
                "uint16": 2,
                "int": 4,
                "int32": 4,
                "uint": 4,
                "uint32": 4,
                "float": 4,
                "float32": 4,
                "double": 8,
                "float64": 8,
            }
            vertex_size = 0
            for prop_type in vertex_props:
                vertex_size += type_sizes.get(prop_type, 4)

            header_size = len(header_bytes)
            f.seek(header_size + vertex_count * vertex_size)

            extrinsic_bytes = f.read(16 * 4)
            intrinsic_bytes = f.read(9 * 4)
            image_size_bytes = f.read(2 * 4)

            if len(intrinsic_bytes) == 9 * 4:
                intrinsic_data = np.frombuffer(intrinsic_bytes, dtype=np.float32)
                intrinsics = intrinsic_data.reshape(3, 3).copy()
            if len(image_size_bytes) == 2 * 4:
                image_size_data = np.frombuffer(image_size_bytes, dtype=np.uint32)
                image_size = (int(image_size_data[0]), int(image_size_data[1]))
    except Exception as exc:
        print(f"Warning: Could not parse PLY camera metadata: {exc}")

    return intrinsics, image_size


def resolve_render_params(ply_path, args):
    intrinsics = None
    image_size = None
    if args.use_ply_camera:
        intrinsics, image_size = parse_ply_metadata(ply_path)

    width = args.width if args.width is not None else (image_size[0] if image_size else 1920)
    height = args.height if args.height is not None else (image_size[1] if image_size else 1080)

    focal_x = args.focal_x
    focal_y = args.focal_y
    if intrinsics is not None:
        if focal_x is None:
            focal_x = float(intrinsics[0, 0])
        if focal_y is None:
            focal_y = float(intrinsics[1, 1])

    center_x = args.center_x
    center_y = args.center_y
    if intrinsics is not None:
        if center_x is None and width:
            center_x = float(intrinsics[0, 2]) / float(width)
        if center_y is None and height:
            center_y = float(intrinsics[1, 2]) / float(height)

    if center_x is None:
        center_x = 0.5
    if center_y is None:
        center_y = 0.5

    fov_x = args.fov_x
    fov_y = args.fov_y
    if fov_x is None and focal_x is None:
        fov_x = 60.0

    return {
        "width": width,
        "height": height,
        "fov_x": fov_x,
        "fov_y": fov_y,
        "focal_x": focal_x,
        "focal_y": focal_y,
        "center_x": center_x,
        "center_y": center_y,
    }


def build_brush_command(
    brush_bin,
    ply_path,
    output_path,
    width,
    height,
    fov_x,
    fov_y,
    focal_x,
    focal_y,
    center_x,
    center_y,
    cam_pos,
    cam_rot,
    background,
    subsample_points,
    extra_args,
):
    cmd = [brush_bin, str(ply_path), "--output", str(output_path)]

    if width is not None:
        cmd.extend(["--width", str(width)])
    if height is not None:
        cmd.extend(["--height", str(height)])
    if fov_x is not None:
        cmd.extend(["--fov-x", str(fov_x)])
    cmd.extend(["--center-x", str(center_x), "--center-y", str(center_y)])
    cmd.extend(
        [
            "--cam-pos",
            str(cam_pos[0]),
            str(cam_pos[1]),
            str(cam_pos[2]),
            "--cam-rot",
            str(cam_rot[0]),
            str(cam_rot[1]),
            str(cam_rot[2]),
            str(cam_rot[3]),
            "--background",
            str(background[0]),
            str(background[1]),
            str(background[2]),
        ]
    )

    if fov_y is not None:
        cmd.extend(["--fov-y", str(fov_y)])
    if focal_x is not None:
        cmd.extend(["--focal-x", str(focal_x)])
    if focal_y is not None:
        cmd.extend(["--focal-y", str(focal_y)])
    if subsample_points is not None:
        cmd.extend(["--subsample-points", str(subsample_points)])
    if extra_args:
        cmd.extend(extra_args)

    return cmd


def render_file(
    ply_path,
    output_path,
    brush_bin,
    width,
    height,
    fov_x,
    fov_y,
    focal_x,
    focal_y,
    center_x,
    center_y,
    cam_pos,
    cam_rot,
    background,
    subsample_points,
    extra_args,
    dry_run,
):
    output_path.parent.mkdir(parents=True, exist_ok=True)
    cmd = build_brush_command(
        brush_bin,
        ply_path,
        output_path,
        width,
        height,
        fov_x,
        fov_y,
        focal_x,
        focal_y,
        center_x,
        center_y,
        cam_pos,
        cam_rot,
        background,
        subsample_points,
        extra_args,
    )

    print(f"Running: {' '.join(cmd)}")
    if dry_run:
        return 0

    result = subprocess.run(cmd)
    if result.returncode != 0:
        print(f"Error: brush exited with code {result.returncode}")
        return result.returncode

    return 0


def stereo_camera_positions(cam_pos, ipd):
    half = ipd * 0.5
    left = [cam_pos[0] - half, cam_pos[1], cam_pos[2]]
    right = [cam_pos[0] + half, cam_pos[1], cam_pos[2]]
    return left, right


def main():
    parser = argparse.ArgumentParser(
        description="Render Gaussian splat PLY files to images using Brush",
    )
    parser.add_argument(
        "-i",
        "--input",
        type=str,
        default="ply_frames",
        help="Input directory containing PLY files (default: ply_frames)",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=str,
        default="stereo_output",
        help="Output directory for rendered images (default: stereo_output)",
    )
    parser.add_argument(
        "--file",
        type=str,
        default=None,
        help="Process a single PLY file instead of all files in directory",
    )
    parser.add_argument(
        "--firstFrame",
        action="store_true",
        help="Render only the first PLY file in the input directory",
    )
    parser.add_argument(
        "--brush-bin",
        type=str,
        default="brush-render",
        help="Brush renderer binary name or path (default: brush-render)",
    )
    parser.add_argument(
        "--width",
        type=int,
        default=None,
        help="Output image width (default: from PLY metadata or 1920)",
    )
    parser.add_argument(
        "--height",
        type=int,
        default=None,
        help="Output image height (default: from PLY metadata or 1080)",
    )
    parser.add_argument(
        "--fov-x",
        type=float,
        default=None,
        help="Horizontal field of view in degrees (default: derived from focal or 60)",
    )
    parser.add_argument(
        "--fov-y",
        type=float,
        default=None,
        help="Vertical field of view in degrees (default: derived from fov-x)",
    )
    parser.add_argument(
        "--focal-x",
        type=float,
        default=None,
        help="Horizontal focal length in pixels (overrides fov-x)",
    )
    parser.add_argument(
        "--focal-y",
        type=float,
        default=None,
        help="Vertical focal length in pixels (overrides fov-y)",
    )
    parser.add_argument(
        "--center-x",
        type=float,
        default=None,
        help="Camera center X in normalized [0..1] (default: from PLY metadata or 0.5)",
    )
    parser.add_argument(
        "--center-y",
        type=float,
        default=None,
        help="Camera center Y in normalized [0..1] (default: from PLY metadata or 0.5)",
    )
    parser.add_argument(
        "--cam-pos",
        type=float,
        nargs=3,
        default=[0.0, 0.0, 0.0],
        help="Camera position as x y z (default: 0 0 0)",
    )
    parser.add_argument(
        "--cam-rot",
        type=float,
        nargs=4,
        default=[0.0, 0.0, 0.0, 1.0],
        help="Camera rotation as quaternion x y z w (default: 0 0 0 1)",
    )
    parser.add_argument(
        "--background",
        type=float,
        nargs=3,
        default=[0.0, 0.0, 0.0],
        help="Background color as r g b in [0..1] (default: 0 0 0)",
    )
    parser.add_argument(
        "--mono",
        action="store_true",
        help="Render a single mono image instead of left/right stereo",
    )
    parser.add_argument(
        "--ipd",
        type=float,
        default=0.063,
        help="Interpupillary distance in meters (default: 0.063)",
    )
    parser.add_argument(
        "--no-ply-camera",
        action="store_true",
        help="Disable using camera metadata embedded in the PLY file",
    )
    parser.add_argument(
        "--subsample-points",
        type=int,
        default=None,
        help="Subsample splats by taking every nth point",
    )
    parser.add_argument(
        "--brush-args",
        nargs="*",
        default=[],
        help="Extra args passed through to brush",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print brush commands without executing",
    )

    args = parser.parse_args()

    brush_bin = args.brush_bin
    if brush_bin == "brush-render":
        local_bin = Path(__file__).resolve().parent / "brush" / "target" / "release" / "brush-render"
        if local_bin.exists():
            brush_bin = str(local_bin)

    if not ensure_brush_binary(brush_bin):
        print(
            f"Error: brush-render binary not found: {brush_bin}. "
            "Build Brush and pass --brush-bin with the path if needed."
        )
        return 1

    input_dir = Path(args.input)
    output_dir = Path(args.output)

    if args.file:
        ply_path = Path(args.file)
        if not ply_path.exists():
            print(f"Error: PLY file not found: {ply_path}")
            return 1

        args.use_ply_camera = not args.no_ply_camera
        params = resolve_render_params(ply_path, args)

        if args.mono:
            output_path = output_dir / f"{ply_path.stem}.png"
            return render_file(
                ply_path,
                output_path,
                brush_bin,
                params["width"],
                params["height"],
                params["fov_x"],
                params["fov_y"],
                params["focal_x"],
                params["focal_y"],
                params["center_x"],
                params["center_y"],
                args.cam_pos,
                args.cam_rot,
                args.background,
                args.subsample_points,
                args.brush_args,
                args.dry_run,
            )

        left_pos, right_pos = stereo_camera_positions(args.cam_pos, args.ipd)
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
            args.cam_rot,
            args.background,
            args.subsample_points,
            args.brush_args,
            args.dry_run,
        )
        if code != 0:
            return code
        return render_file(
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
            args.cam_rot,
            args.background,
            args.subsample_points,
            args.brush_args,
            args.dry_run,
        )

    if not input_dir.exists():
        print(f"Error: Input directory not found: {input_dir}")
        return 1

    ply_files = sorted(input_dir.glob("*.ply"))
    if not ply_files:
        print(f"No PLY files found in: {input_dir}")
        return 1

    if args.firstFrame:
        ply_files = ply_files[:1]

    print(f"Found {len(ply_files)} PLY files")
    for i, ply_path in enumerate(ply_files, 1):
        print(f"\n[{i}/{len(ply_files)}] Processing: {ply_path.name}")
        args.use_ply_camera = not args.no_ply_camera
        params = resolve_render_params(ply_path, args)

        if args.mono:
            output_path = output_dir / f"{ply_path.stem}.png"
            code = render_file(
                ply_path,
                output_path,
                brush_bin,
                params["width"],
                params["height"],
                params["fov_x"],
                params["fov_y"],
                params["focal_x"],
                params["focal_y"],
                params["center_x"],
                params["center_y"],
                args.cam_pos,
                args.cam_rot,
                args.background,
                args.subsample_points,
                args.brush_args,
                args.dry_run,
            )
            if code != 0:
                return code
            continue

        left_pos, right_pos = stereo_camera_positions(args.cam_pos, args.ipd)
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
            args.cam_rot,
            args.background,
            args.subsample_points,
            args.brush_args,
            args.dry_run,
        )
        if code != 0:
            return code
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
            args.cam_rot,
            args.background,
            args.subsample_points,
            args.brush_args,
            args.dry_run,
        )
        if code != 0:
            return code

    print(f"\nDone! Rendered images saved to: {output_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

