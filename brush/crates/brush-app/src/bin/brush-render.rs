#![recursion_limit = "256"]

use anyhow::{Context, Result};
use brush_render::{
    MainBackend, SplatForward,
    camera::{Camera, focal_to_fov, fov_to_focal},
    gaussian_splats::SplatRenderMode,
};
use brush_serde::load_splat_from_ply;
use burn::{prelude::Backend, tensor::{Tensor, TensorPrimitive}};
use clap::Parser;
use glam::{Quat, Vec2, Vec3, uvec2};
use image::RgbaImage;
use std::path::PathBuf;

#[derive(Parser)]
#[command(author, version, about = "Render a PLY splat file to a PNG using Brush")]
struct Args {
    /// Input PLY file
    #[arg(value_name = "PLY_PATH")]
    input: PathBuf,
    /// Output PNG path
    #[arg(short, long, value_name = "PNG_PATH")]
    output: PathBuf,
    /// Output width in pixels
    #[arg(long, default_value = "1920")]
    width: u32,
    /// Output height in pixels
    #[arg(long, default_value = "1080")]
    height: u32,
    /// Horizontal field of view in degrees
    #[arg(long, default_value = "60")]
    fov_x: f64,
    /// Vertical field of view in degrees (defaults to match fov-x)
    #[arg(long)]
    fov_y: Option<f64>,
    /// Horizontal focal length in pixels (overrides fov-x)
    #[arg(long)]
    focal_x: Option<f64>,
    /// Vertical focal length in pixels (overrides fov-y)
    #[arg(long)]
    focal_y: Option<f64>,
    /// Camera center X in normalized [0..1] (0.5 is center)
    #[arg(long, default_value = "0.5")]
    center_x: f32,
    /// Camera center Y in normalized [0..1] (0.5 is center)
    #[arg(long, default_value = "0.5")]
    center_y: f32,
    /// Camera position as x y z
    #[arg(
        long,
        num_args = 3,
        value_delimiter = ' ',
        default_values_t = [0.0, 0.0, 0.0],
        allow_hyphen_values = true
    )]
    cam_pos: Vec<f32>,
    /// Camera rotation as quaternion x y z w
    #[arg(
        long,
        num_args = 4,
        value_delimiter = ' ',
        default_values_t = [0.0, 0.0, 0.0, 1.0],
        allow_hyphen_values = true
    )]
    cam_rot: Vec<f32>,
    /// Background color as r g b in [0..1]
    #[arg(
        long,
        num_args = 3,
        value_delimiter = ' ',
        default_values_t = [0.0, 0.0, 0.0],
        allow_hyphen_values = true
    )]
    background: Vec<f32>,
    /// Subsample splats by taking every nth point
    #[arg(long)]
    subsample_points: Option<u32>,
}

fn compute_fov(args: &Args) -> (f64, f64) {
    let fov_x = if let Some(focal_x) = args.focal_x {
        focal_to_fov(focal_x, args.width)
    } else {
        args.fov_x.to_radians()
    };

    let fov_y = if let Some(focal_y) = args.focal_y {
        focal_to_fov(focal_y, args.height)
    } else if let Some(fov_y) = args.fov_y {
        fov_y.to_radians()
    } else {
        let focal_x = fov_to_focal(fov_x, args.width);
        focal_to_fov(focal_x, args.height)
    };

    (fov_x, fov_y)
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();

    let device = brush_process::burn_init_setup().await;
    <MainBackend as Backend>::seed(&device, 42);

    let file = tokio::fs::File::open(&args.input)
        .await
        .with_context(|| format!("Failed to open {}", args.input.display()))?;

    let message = load_splat_from_ply(file, args.subsample_points)
        .await
        .context("Failed to parse PLY splats")?;

    let render_mode = message.meta.render_mode.unwrap_or(SplatRenderMode::Default);
    let splats = message.data.into_splats::<MainBackend>(&device, render_mode);

    let (fov_x, fov_y) = compute_fov(&args);
    let center_uv = Vec2::new(args.center_x, args.center_y);
    let position = Vec3::new(args.cam_pos[0], args.cam_pos[1], args.cam_pos[2]);
    let rotation = Quat::from_xyzw(
        args.cam_rot[0],
        args.cam_rot[1],
        args.cam_rot[2],
        args.cam_rot[3],
    );
    let camera = Camera::new(position, rotation, fov_x, fov_y, center_uv);

    let background = Vec3::new(
        args.background[0],
        args.background[1],
        args.background[2],
    );

    let (img, _) = MainBackend::render_splats(
        &camera,
        uvec2(args.width, args.height),
        splats.means.val().into_primitive().tensor(),
        splats.log_scales.val().into_primitive().tensor(),
        splats.rotations.val().into_primitive().tensor(),
        splats.sh_coeffs.val().into_primitive().tensor(),
        splats.raw_opacities.val().into_primitive().tensor(),
        splats.render_mode,
        background,
        true,
    );

    let img = Tensor::<MainBackend, 3>::from_primitive(TensorPrimitive::Float(img));
    let [h, w, c] = img.dims();
    if c != 4 {
        return Err(anyhow::anyhow!("Expected 4-channel output, got {c}"));
    }

    let data = img.into_data_async().await?;
    let data: Vec<f32> = data.into_vec()?;
    let mut rgba = Vec::with_capacity(h * w * 4);
    for chunk in data.chunks_exact(4) {
        let r = (chunk[0].clamp(0.0, 1.0) * 255.0).round() as u8;
        let g = (chunk[1].clamp(0.0, 1.0) * 255.0).round() as u8;
        let b = (chunk[2].clamp(0.0, 1.0) * 255.0).round() as u8;
        let a = (chunk[3].clamp(0.0, 1.0) * 255.0).round() as u8;
        rgba.extend_from_slice(&[r, g, b, a]);
    }

    if let Some(parent) = args.output.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }

    let image = RgbaImage::from_raw(w as u32, h as u32, rgba)
        .context("Failed to build output image buffer")?;
    image.save(&args.output)?;
    println!("Saved image to {}", args.output.display());

    Ok(())
}

