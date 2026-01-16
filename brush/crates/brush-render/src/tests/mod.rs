use crate::{MainBackend, SplatForward, camera::Camera, gaussian_splats::SplatRenderMode};
use assert_approx_eq::assert_approx_eq;
use burn::tensor::{Distribution, Tensor, TensorPrimitive};
use burn_wgpu::WgpuDevice;
use glam::Vec3;

#[test]
fn renders_at_all() {
    // Check if rendering doesn't hard crash or anything.
    // These are some zero-sized gaussians, so we know
    // what the result should look like.
    let cam = Camera::new(
        glam::vec3(0.0, 0.0, 0.0),
        glam::Quat::IDENTITY,
        0.5,
        0.5,
        glam::vec2(0.5, 0.5),
    );
    let img_size = glam::uvec2(32, 32);
    let device = WgpuDevice::DefaultDevice;
    let num_points = 8;
    let means = Tensor::<MainBackend, 2>::zeros([num_points, 3], &device);
    let log_scales = Tensor::<MainBackend, 2>::ones([num_points, 3], &device) * 2.0;
    let quats: Tensor<MainBackend, 2> =
        Tensor::<MainBackend, 1>::from_floats(glam::Quat::IDENTITY.to_array(), &device)
            .unsqueeze_dim(0)
            .repeat_dim(0, num_points);
    let sh_coeffs = Tensor::<MainBackend, 3>::ones([num_points, 1, 3], &device);
    let raw_opacity = Tensor::<MainBackend, 1>::zeros([num_points], &device);
    let (output, aux) = <MainBackend as SplatForward<MainBackend>>::render_splats(
        &cam,
        img_size,
        means.into_primitive().tensor(),
        log_scales.into_primitive().tensor(),
        quats.into_primitive().tensor(),
        sh_coeffs.into_primitive().tensor(),
        raw_opacity.into_primitive().tensor(),
        SplatRenderMode::Default,
        Vec3::ZERO,
        true,
    );
    aux.validate_values();

    let output: Tensor<MainBackend, 3> = Tensor::from_primitive(TensorPrimitive::Float(output));
    let rgb = output.clone().slice([0..32, 0..32, 0..3]);
    let alpha = output.slice([0..32, 0..32, 3..4]);
    let rgb_mean = rgb.mean().to_data().as_slice::<f32>().expect("Wrong type")[0];
    let alpha_mean = alpha
        .mean()
        .to_data()
        .as_slice::<f32>()
        .expect("Wrong type")[0];
    assert_approx_eq!(rgb_mean, 0.0, 1e-5);
    assert_approx_eq!(alpha_mean, 0.0);
}

#[test]
fn renders_many_splats() {
    // Test rendering with a ton of gaussians to verify 2D dispatch works correctly.
    // This exceeds the 1D 65535 * 256 = 16.7M limit.
    let num_splats = 30_000_000;
    let cam = Camera::new(
        glam::vec3(0.0, 0.0, -5.0),
        glam::Quat::IDENTITY,
        0.5,
        0.5,
        glam::vec2(0.5, 0.5),
    );
    let img_size = glam::uvec2(64, 64);
    let device = WgpuDevice::DefaultDevice;

    // Create random gaussians spread in front of the camera
    let means = Tensor::<MainBackend, 2>::random(
        [num_splats, 3],
        Distribution::Uniform(-2.0, 2.0),
        &device,
    );
    // Small scales so they don't cover everything
    let log_scales = Tensor::<MainBackend, 2>::random(
        [num_splats, 3],
        Distribution::Uniform(-4.0, -2.0),
        &device,
    );
    // Random rotations (will be normalized)
    let quats = Tensor::<MainBackend, 2>::random(
        [num_splats, 4],
        Distribution::Uniform(-1.0, 1.0),
        &device,
    );
    // Simple SH coefficients (just base color)
    let sh_coeffs = Tensor::<MainBackend, 3>::random(
        [num_splats, 1, 3],
        Distribution::Uniform(0.0, 1.0),
        &device,
    );
    // Some visible, some not
    let raw_opacity =
        Tensor::<MainBackend, 1>::random([num_splats], Distribution::Uniform(-2.0, 2.0), &device);

    let (_output, aux) = <MainBackend as SplatForward<MainBackend>>::render_splats(
        &cam,
        img_size,
        means.into_primitive().tensor(),
        log_scales.into_primitive().tensor(),
        quats.into_primitive().tensor(),
        sh_coeffs.into_primitive().tensor(),
        raw_opacity.into_primitive().tensor(),
        SplatRenderMode::Default,
        Vec3::ZERO,
        true,
    );
    aux.validate_values();
}
