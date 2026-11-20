// SPDX-License-Identifier: GPL-3.0-or-later
//! Espaces colorimétriques : tables sRGB ↔ lumière linéaire (mêmes tailles que la version Python).
use std::sync::OnceLock;

pub const LUMA: [f32; 3] = [0.2126, 0.7152, 0.0722];
pub const ENCODE_SIZE: usize = 16384;

#[inline]
pub fn luma(r: f32, g: f32, b: f32) -> f32 {
    r * LUMA[0] + g * LUMA[1] + b * LUMA[2]
}

pub fn srgb_to_linear(x: f32) -> f32 {
    let x = x.clamp(0.0, 1.0);
    if x <= 0.04045 {
        x / 12.92
    } else {
        ((x + 0.055) / 1.055).powf(2.4)
    }
}

fn linear_to_srgb_exact(x: f32) -> f32 {
    let x = x.clamp(0.0, 1.0);
    if x <= 0.0031308 {
        x * 12.92
    } else {
        1.055 * x.powf((1.0f64 / 2.4) as f32) - 0.055
    }
}

pub fn decode_lut8() -> &'static [f32; 256] {
    static L: OnceLock<[f32; 256]> = OnceLock::new();
    L.get_or_init(|| {
        let mut t = [0f32; 256];
        for (i, v) in t.iter_mut().enumerate() {
            *v = srgb_to_linear(i as f32 / 255.0);
        }
        t
    })
}

pub fn decode_lut16() -> &'static Vec<f32> {
    static L: OnceLock<Vec<f32>> = OnceLock::new();
    L.get_or_init(|| (0..65536u32).map(|i| srgb_to_linear(i as f32 / 65535.0)).collect())
}

fn encode_lut() -> &'static Vec<f32> {
    static L: OnceLock<Vec<f32>> = OnceLock::new();
    L.get_or_init(|| {
        let n = ENCODE_SIZE;
        let step = 1.0f64 / (n as f64 - 1.0);
        (0..n)
            .map(|i| {
                let x = if i == n - 1 { 1.0 } else { i as f64 * step };
                linear_to_srgb_exact(x as f32)
            })
            .collect()
    })
}

/// Lumière linéaire → sRGB (0..1) par lecture de table, comme la version Python.
#[inline]
pub fn linear_to_srgb(lut: &[f32], x: f32) -> f32 {
    let i = (x * (ENCODE_SIZE - 1) as f32 + 0.5).clamp(0.0, (ENCODE_SIZE - 1) as f32);
    lut[i as usize]
}

pub fn encode_table() -> &'static Vec<f32> {
    encode_lut()
}
