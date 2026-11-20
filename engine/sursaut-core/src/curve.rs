// SPDX-License-Identifier: GPL-3.0-or-later
//! Courbe de tonalité : spline d'Hermite monotone (Fritsch–Carlson), table de 4096 entrées.
pub const LUT_SIZE: usize = 4096;

pub fn normalize(points: &[[f64; 2]]) -> Vec<[f64; 2]> {
    let mut pts: Vec<[f64; 2]> = points.iter().map(|p| [p[0].clamp(0.0, 1.0), p[1].clamp(0.0, 1.0)]).collect();
    pts.sort_by(|a, b| a[0].partial_cmp(&b[0]).unwrap_or(std::cmp::Ordering::Equal));
    let mut out: Vec<[f64; 2]> = Vec::new();
    for p in pts {
        if let Some(last) = out.last() {
            if p[0] - last[0] < 1e-4 {
                continue;
            }
        }
        out.push(p);
    }
    if out.len() < 2 {
        return vec![[0.0, 0.0], [1.0, 1.0]];
    }
    if out[0][0] > 0.0 {
        let y = out[0][1];
        out.insert(0, [0.0, y]);
    }
    if out[out.len() - 1][0] < 1.0 {
        let y = out[out.len() - 1][1];
        out.push([1.0, y]);
    }
    out
}

pub fn is_identity(points: &[[f64; 2]]) -> bool {
    points.iter().all(|p| (p[0] - p[1]).abs() < 1e-6)
}

pub fn build_lut(points: &[[f64; 2]]) -> Vec<f32> {
    build_lut_sized(points, LUT_SIZE)
}

/// Table de `size` entrées (l'interface dessine la courbe avec 256 entrées).
pub fn build_lut_sized(points: &[[f64; 2]], size: usize) -> Vec<f32> {
    let pts = normalize(points);
    let n = pts.len();
    let x: Vec<f64> = pts.iter().map(|p| p[0]).collect();
    let y: Vec<f64> = pts.iter().map(|p| p[1]).collect();
    let h: Vec<f64> = (0..n - 1).map(|i| x[i + 1] - x[i]).collect();
    let delta: Vec<f64> = (0..n - 1).map(|i| (y[i + 1] - y[i]) / h[i]).collect();
    let mut m = vec![0.0f64; n];
    m[0] = delta[0];
    m[n - 1] = delta[n - 2];
    if n > 2 {
        for i in 1..n - 1 {
            m[i] = if delta[i - 1] * delta[i] > 0.0 { (delta[i - 1] + delta[i]) / 2.0 } else { 0.0 };
        }
    }
    for k in 0..n - 1 {
        if delta[k] == 0.0 {
            m[k] = 0.0;
            m[k + 1] = 0.0;
            continue;
        }
        let a = m[k] / delta[k];
        let b = m[k + 1] / delta[k];
        let s = a * a + b * b;
        if s > 9.0 {
            let t = 3.0 / s.sqrt();
            m[k] = t * a * delta[k];
            m[k + 1] = t * b * delta[k];
        }
    }
    let step = 1.0f64 / (size as f64 - 1.0);
    (0..size)
        .map(|i| {
            let xs = if i == size - 1 { 1.0 } else { i as f64 * step };
            let idx = x.partition_point(|&v| v <= xs).saturating_sub(1).min(n - 2);
            let t = (xs - x[idx]) / h[idx];
            let (t2, t3) = (t * t, t * t * t);
            let v = (2.0 * t3 - 3.0 * t2 + 1.0) * y[idx]
                + (t3 - 2.0 * t2 + t) * h[idx] * m[idx]
                + (-2.0 * t3 + 3.0 * t2) * y[idx + 1]
                + (t3 - t2) * h[idx] * m[idx + 1];
            v.clamp(0.0, 1.0) as f32
        })
        .collect()
}

#[inline]
pub fn apply(lut: &[f32], x: f32) -> f32 {
    let i = (x * (LUT_SIZE - 1) as f32 + 0.5).clamp(0.0, (LUT_SIZE - 1) as f32);
    lut[i as usize]
}
