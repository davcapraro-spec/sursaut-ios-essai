// SPDX-License-Identifier: GPL-3.0-or-later
//! Les étages (objectif, taches, géométrie, tonalité, courbe, bruit, détail, couleur). Chaque étage reproduit la version Python opération par opération (mêmes constantes,
//! mêmes arrondis en float32) ; un étage sans effet renvoie l'image reçue sans la copier.
use std::sync::Arc;

use rayon::prelude::*;

use crate::blur::{box_blur, box_blur_smooth};
use crate::color::{self, luma};
use crate::curve;
use crate::image::Image;
use crate::recipe::{LensProfile, Recipe};

type Img = Arc<Image>;

fn map_pixels<F: Fn(f32, f32, f32) -> [f32; 3] + Sync>(img: &Image, f: F) -> Image {
    let mut data = vec![0f32; img.data.len()];
    data.par_chunks_mut(3 * 256).zip(img.data.par_chunks(3 * 256)).for_each(|(o, i)| {
        for (op, ip) in o.chunks_exact_mut(3).zip(i.chunks_exact(3)) {
            let v = f(ip[0], ip[1], ip[2]);
            op.copy_from_slice(&v);
        }
    });
    Image { w: img.w, h: img.h, data }
}

fn inscribed_scale(w: usize, h: usize, angle_deg: f64) -> f64 {
    let th = angle_deg.to_radians().abs();
    let (w, h) = (w as f64, h as f64);
    1.0 / (th.cos() + (w / h).max(h / w) * th.sin())
}

/// À 100 %, un bord est resserré de 30 % de sa longueur de chaque côté (même échelle que la perspective des calques).
const PERSP_MAX_INSET: f64 = 0.3;

/// Résout `a · x = b` (système carré, élimination de Gauss avec pivot). `None` si le système est singulier.
fn solve_linear(mut a: Vec<Vec<f64>>, mut b: Vec<f64>) -> Option<Vec<f64>> {
    let n = b.len();
    for col in 0..n {
        let piv = (col..n).max_by(|&i, &j| a[i][col].abs().total_cmp(&a[j][col].abs()))?;
        if a[piv][col].abs() < 1e-12 {
            return None;
        }
        a.swap(col, piv);
        b.swap(col, piv);
        for row in col + 1..n {
            let f = a[row][col] / a[col][col];
            for k in col..n {
                a[row][k] -= f * a[col][k];
            }
            b[row] -= f * b[col];
        }
    }
    let mut x = vec![0.0; n];
    for row in (0..n).rev() {
        let s: f64 = (row + 1..n).map(|k| a[row][k] * x[k]).sum();
        x[row] = (b[row] - s) / a[row][row];
    }
    Some(x)
}

/// Homographie `h` (9 valeurs, h[8] = 1) qui envoie les 4 points `from` sur les 4 points `to`.
fn homography(from: &[[f64; 2]; 4], to: &[[f64; 2]; 4]) -> Option<[f64; 9]> {
    let mut a = Vec::with_capacity(8);
    let mut b = Vec::with_capacity(8);
    for (p, q) in from.iter().zip(to.iter()) {
        let (x, y, xx, yy) = (p[0], p[1], q[0], q[1]);
        a.push(vec![x, y, 1.0, 0.0, 0.0, 0.0, -xx * x, -xx * y]);
        b.push(xx);
        a.push(vec![0.0, 0.0, 0.0, x, y, 1.0, -yy * x, -yy * y]);
        b.push(yy);
    }
    let s = solve_linear(a, b)?;
    Some([s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7], 1.0])
}

/// Perspective de la recette : (correspondance « image corrigée → photo » en coordonnées continues (0..w, 0..h), zoom qui évite les coins vides).
/// `None` si les deux réglages sont à zéro (aucun calcul, aucune différence avec une photo sans perspective).
pub fn perspective_plan(w: usize, h: usize, r: &Recipe) -> Option<([f64; 9], f64)> {
    let v = (r.persp_v / 100.0).clamp(-1.0, 1.0);
    let hz = (r.persp_h / 100.0).clamp(-1.0, 1.0);
    if v == 0.0 && hz == 0.0 {
        return None;
    }
    let (wf, hf) = (w as f64, h as f64);
    let top_in = (-v).max(0.0) * PERSP_MAX_INSET * wf;
    let bot_in = v.max(0.0) * PERSP_MAX_INSET * wf;
    let left_in = (-hz).max(0.0) * PERSP_MAX_INSET * hf;
    let right_in = hz.max(0.0) * PERSP_MAX_INSET * hf;
    let src = [[0.0, 0.0], [wf, 0.0], [wf, hf], [0.0, hf]];
    let dst = [[top_in, left_in], [wf - top_in, right_in], [wf - bot_in, hf - right_in], [bot_in, hf - left_in]];
    let inv = homography(&dst, &src)?;
    let ins_x = top_in.max(bot_in);
    let ins_y = left_in.max(right_in);
    let zoom = (wf / (wf - 2.0 * ins_x)).max(hf / (hf - 2.0 * ins_y));
    Some((inv, zoom))
}

/// Taille (largeur, hauteur) après recadrage et redressement.
pub fn output_size(w: usize, h: usize, r: &Recipe) -> (usize, usize) {
    let (l, t, rt, b) = r.crop_rect();
    let k = if r.angle != 0.0 { inscribed_scale(w, h, r.angle) } else { 1.0 };
    let ow = (w as f64 * k * (rt - l)).round_ties_even().max(1.0) as usize;
    let oh = (h as f64 * k * (b - t)).round_ties_even().max(1.0) as usize;
    (ow, oh)
}

/// Force maximale de la correction de distorsion (réglage ±100) sur le terme en r³ (r = distance au centre / demi-diagonale).
const LENS_DISTORTION: f32 = 0.35;
/// Décalage maximal d'un canal pour l'aberration chromatique (réglage ±100) : 1 % du rayon.
const LENS_CA: f32 = 0.01;
/// Variation maximale de luminosité du vignetage, en IL (vues en lumière linéaire), au bord extrême.
const LENS_VIGNETTE_EV: f32 = 2.0;

#[inline]
fn sample_channel(img: &Image, x: f32, y: f32, ch: usize) -> f32 {
    let (w, h) = (img.w, img.h);
    let x = x.clamp(0.0, (w - 1) as f32);
    let y = y.clamp(0.0, (h - 1) as f32);
    let x0 = (x.floor() as usize).min(w.saturating_sub(2));
    let y0 = (y.floor() as usize).min(h.saturating_sub(2));
    let (x1, y1) = ((x0 + 1).min(w - 1), (y0 + 1).min(h - 1));
    let (fx, fy) = (x - x0 as f32, y - y0 as f32);
    let p = |yy: usize, xx: usize| img.data[(yy * w + xx) * 3 + ch];
    let top = p(y0, x0) * (1.0 - fx) + p(y0, x1) * fx;
    let bottom = p(y1, x0) * (1.0 - fx) + p(y1, x1) * fx;
    top * (1.0 - fy) + bottom * fy
}

/// Lecture bilinéaire des trois canaux avec les mêmes poids (cas sans aberration chromatique : un seul calcul de position).
#[inline]
fn sample_rgb(img: &Image, x: f32, y: f32) -> [f32; 3] {
    let (w, h) = (img.w, img.h);
    let x = x.clamp(0.0, (w - 1) as f32);
    let y = y.clamp(0.0, (h - 1) as f32);
    let x0 = (x as usize).min(w.saturating_sub(2));
    let y0 = (y as usize).min(h.saturating_sub(2));
    let (x1, y1) = ((x0 + 1).min(w - 1), (y0 + 1).min(h - 1));
    let (fx, fy) = (x - x0 as f32, y - y0 as f32);
    let (a, b, c, d) = ((1.0 - fx) * (1.0 - fy), fx * (1.0 - fy), (1.0 - fx) * fy, fx * fy);
    let (i00, i01, i10, i11) = ((y0 * w + x0) * 3, (y0 * w + x1) * 3, (y1 * w + x0) * 3, (y1 * w + x1) * 3);
    let px = &img.data;
    [
        px[i00] * a + px[i01] * b + px[i10] * c + px[i11] * d,
        px[i00 + 1] * a + px[i01 + 1] * b + px[i10 + 1] * c + px[i11 + 1] * d,
        px[i00 + 2] * a + px[i01 + 2] * b + px[i10 + 2] * c + px[i11 + 2] * d,
    ]
}

/// Corrections d'objectif manuelles : distorsion, aberration chromatique latérale (canaux rouge et bleu décalés
/// radialement) et vignetage. Une seule passe : pour chaque pixel de sortie, on lit la source à un rayon corrigé.
/// Valeur d'une table radiale (interpolation linéaire, `rn` borné à 0..1). Table vide : `neutral`.
fn lut(table: &[f32], rn: f32, neutral: f32) -> f32 {
    match table.len() {
        0 => neutral,
        1 => table[0],
        n => {
            let x = rn.clamp(0.0, 1.0) * (n - 1) as f32;
            let i = (x.floor() as usize).min(n - 2);
            let f = x - i as f32;
            table[i] * (1.0 - f) + table[i + 1] * f
        }
    }
}

pub fn lens(img: &Img, r: &Recipe) -> Img {
    let l = &r.lens;
    if l.is_neutral() {
        return img.clone();
    }
    let (w, h) = (img.w, img.h);
    let cx = (w as f32 - 1.0) / 2.0;
    let cy = (h as f32 - 1.0) / 2.0;
    let half_diag = (cx * cx + cy * cy).sqrt().max(1.0);
    let k = (l.lens_distortion / 100.0) as f32 * LENS_DISTORTION;
    let zoom = 1.0 / (l.lens_scale.clamp(50.0, 150.0) / 100.0) as f32;
    let ca = [(l.lens_ca_red / 100.0) as f32 * LENS_CA, 0.0, (l.lens_ca_blue / 100.0) as f32 * LENS_CA];
    let empty = LensProfile::default();
    let prof = l.lens_profile.as_ref().unwrap_or(&empty);
    let prof_ca = !prof.ca_r.is_empty() || !prof.ca_b.is_empty();
    let no_ca = ca[0] == 0.0 && ca[2] == 0.0 && !prof_ca;
    let geometric = k != 0.0 || zoom != 1.0 || ca[0] != 0.0 || ca[2] != 0.0 || !prof.geo.is_empty() || prof_ca;
    let vig = (l.lens_vignette / 100.0) as f32 * LENS_VIGNETTE_EV;
    let start = 0.1 + 0.8 * (l.lens_vignette_mid / 100.0).clamp(0.0, 1.0) as f32;
    let mut data = vec![0f32; w * h * 3];
    data.par_chunks_mut(w * 3).enumerate().for_each(|(j, row)| {
        for i in 0..w {
            let (dx, dy) = (i as f32 - cx, j as f32 - cy);
            let rn = (dx * dx + dy * dy).sqrt() / half_diag;
            let manual = if vig != 0.0 { (vig * smooth_step(start, 1.0, rn)).exp2() } else { 1.0 };
            let gain = manual * lut(&prof.vig, rn, 1.0);
            let rs = zoom * (1.0 - k * rn * rn) * lut(&prof.geo, rn, 1.0);
            let px = if !geometric {
                let o = (j * w + i) * 3;
                [img.data[o], img.data[o + 1], img.data[o + 2]]
            } else if no_ca {
                sample_rgb(img, cx + dx * rs, cy + dy * rs)
            } else {
                let mut v = [0f32; 3];
                for ch in 0..3 {
                    let table = match ch { 0 => &prof.ca_r, 2 => &prof.ca_b, _ => &empty.ca_r };
                    let rc = rs * (1.0 + ca[ch]) * lut(table, rn, 1.0);
                    v[ch] = sample_channel(img, cx + dx * rc, cy + dy * rc, ch);
                }
                v
            };
            row[i * 3..i * 3 + 3].copy_from_slice(&[px[0] * gain, px[1] * gain, px[2] * gain]);
        }
    });
    Arc::new(Image { w, h, data })
}

pub fn geometry(img: &Img, r: &Recipe) -> Img {
    let (l, t, rt, b) = r.crop_rect();
    let (w, h) = (img.w, img.h);
    let persp = perspective_plan(w, h, r);
    if r.angle == 0.0 && persp.is_none() {
        if (l, t, rt, b) == (0.0, 0.0, 1.0, 1.0) {
            return img.clone();
        }
        let x0 = ((l * w as f64).round_ties_even() as usize).min(w - 1);
        let y0 = ((t * h as f64).round_ties_even() as usize).min(h - 1);
        let x1 = (x0 + 1).max((rt * w as f64).round_ties_even() as usize).min(w);
        let y1 = (y0 + 1).max((b * h as f64).round_ties_even() as usize).min(h);
        let (cw, ch) = (x1 - x0, y1 - y0);
        let mut data = Vec::with_capacity(cw * ch * 3);
        for y in y0..y1 {
            data.extend_from_slice(&img.data[(y * w + x0) * 3..(y * w + x1) * 3]);
        }
        return Arc::new(Image { w: cw, h: ch, data });
    }
    let th = r.angle.to_radians();
    let (c, s) = (th.cos() as f32, th.sin() as f32);
    let k = inscribed_scale(w, h, r.angle);
    let zoom = persp.map_or(1.0, |p| p.1);       // la perspective découvre des coins : on avance dans l'image d'autant
    let (fw, fh) = (w as f64 * k / zoom, h as f64 * k / zoom);
    let (ow, oh) = output_size(w, h, r);
    let dl = (rt - l) as f32;
    let dt = (b - t) as f32;
    let u: Vec<f32> = (0..ow)
        .map(|i| (fw as f32) * ((l as f32) + ((i as f32 + 0.5) / ow as f32) * dl) - (fw / 2.0) as f32)
        .collect();
    let v: Vec<f32> = (0..oh)
        .map(|j| (fh as f32) * ((t as f32) + ((j as f32 + 0.5) / oh as f32) * dt) - (fh / 2.0) as f32)
        .collect();
    let cx = (w as f64 / 2.0 - 0.5) as f32;
    let cy = (h as f64 / 2.0 - 0.5) as f32;
    let mut data = vec![0f32; ow * oh * 3];
    data.par_chunks_mut(ow * 3).enumerate().for_each(|(j, row)| {
        for i in 0..ow {
            let (mut sx, mut sy) = (u[i] * c + v[j] * s + cx, (-u[i]) * s + v[j] * c + cy);
            if let Some((hm, _)) = &persp {
                // position dans l'image redressée (coordonnées continues), puis correspondance perspective vers la photo
                let (qx, qy) = (sx as f64 + 0.5, sy as f64 + 0.5);
                let den = hm[6] * qx + hm[7] * qy + hm[8];
                sx = ((hm[0] * qx + hm[1] * qy + hm[2]) / den - 0.5) as f32;
                sy = ((hm[3] * qx + hm[4] * qy + hm[5]) / den - 0.5) as f32;
            }
            let x0 = (sx.floor() as i64).clamp(0, w as i64 - 2) as usize;
            let y0 = (sy.floor() as i64).clamp(0, h as i64 - 2) as usize;
            let fx = (sx as f64 - x0 as f64).clamp(0.0, 1.0) as f32;
            let fy = (sy as f64 - y0 as f64).clamp(0.0, 1.0) as f32;
            for ch in 0..3 {
                let p = |yy: usize, xx: usize| img.data[(yy * w + xx) * 3 + ch];
                let top = p(y0, x0) * (1.0 - fx) + p(y0, x0 + 1) * fx;
                let bottom = p(y0 + 1, x0) * (1.0 - fx) + p(y0 + 1, x0 + 1) * fx;
                row[i * 3 + ch] = top * (1.0 - fy) + bottom * fy;
            }
        }
    });
    Arc::new(Image { w: ow, h: oh, data })
}

/// Rotation du vecteur `v` autour de l'axe des gris (1, 1, 1) : change la teinte sans toucher à la luminosité.
fn rotate_about_gray(v: [f64; 3], angle: f64) -> [f64; 3] {
    let k = 1.0 / 3f64.sqrt();
    let (c, s) = (angle.cos(), angle.sin());
    let dot = k * (v[0] + v[1] + v[2]);
    let cross = [k * (v[2] - v[1]), k * (v[0] - v[2]), k * (v[1] - v[0])];
    [0, 1, 2].map(|i| v[i] * c + cross[i] * s + k * dot * (1.0 - c))
}

/// Calibration de l'appareil : matrice 3×3 (lignes = sortie) qui tourne la teinte et change la saturation des trois primaires, en gardant le blanc
/// (1, 1, 1) inchangé. `None` si les six réglages sont à zéro.
pub fn calibration_matrix(r: &Recipe) -> Option<[[f32; 3]; 3]> {
    let prim = [(r.calib_red_hue, r.calib_red_sat), (r.calib_green_hue, r.calib_green_sat), (r.calib_blue_hue, r.calib_blue_sat)];
    if prim.iter().all(|&(h, s)| h == 0.0 && s == 0.0) {
        return None;
    }
    let mut cols = [[0f64; 3]; 3]; // cols[j] = nouvelle image du primaire j
    for (j, &(hue, sat)) in prim.iter().enumerate() {
        let mut e = [0.0; 3];
        e[j] = 1.0;
        let rot = rotate_about_gray(e, (hue / 100.0).clamp(-1.0, 1.0) * 30f64.to_radians());
        let mean = (rot[0] + rot[1] + rot[2]) / 3.0;
        let k = 1.0 + (sat / 100.0).clamp(-1.0, 1.0);
        cols[j] = [0, 1, 2].map(|i| mean + k * (rot[i] - mean));
    }
    // d tel que somme_j d[j] * cols[j] = (1, 1, 1) : le blanc reste blanc
    let a: Vec<Vec<f64>> = (0..3).map(|i| (0..3).map(|j| cols[j][i]).collect()).collect();
    let d = solve_linear(a, vec![1.0, 1.0, 1.0])?;
    let mut m = [[0f32; 3]; 3];
    for i in 0..3 {
        for j in 0..3 {
            m[i][j] = (cols[j][i] * d[j]) as f32;
        }
    }
    Some(m)
}

pub fn wb_exposure(img: &Img, r: &Recipe) -> Img {
    let calib = calibration_matrix(r);
    let shadow_tint = (r.calib_shadow_tint / 100.0).clamp(-1.0, 1.0);
    if r.exposure == 0.0 && r.temperature == 0.0 && r.tint == 0.0 && calib.is_none() && shadow_tint == 0.0 {
        return img.clone();
    }
    let (t, ti) = (r.temperature / 100.0, r.tint / 100.0);
    let e = 2.0f64.powf(r.exposure) as f32;
    let g = [
        (2.0f64.powf(0.5 * t) as f32) * e,
        (2.0f64.powf(-0.3 * ti) as f32) * e,
        (2.0f64.powf(-0.5 * t) as f32) * e,
    ];
    if calib.is_none() && shadow_tint == 0.0 {
        return Arc::new(map_pixels(img, |r_, g_, b_| [r_ * g[0], g_ * g[1], b_ * g[2]]));
    }
    let st = shadow_tint as f32;
    Arc::new(map_pixels(img, |r_, g_, b_| {
        let (r_, g_, b_) = match &calib {
            Some(m) => (
                m[0][0] * r_ + m[0][1] * g_ + m[0][2] * b_,
                m[1][0] * r_ + m[1][1] * g_ + m[1][2] * b_,
                m[2][0] * r_ + m[2][1] * g_ + m[2][2] * b_,
            ),
            None => (r_, g_, b_),
        };
        let mut v = [r_ * g[0], g_ * g[1], b_ * g[2]];
        if st != 0.0 {
            let p = luma(v[0], v[1], v[2]).clamp(0.0, 1.0).sqrt();
            let w = (1.0 - p) * (1.0 - p);
            v[1] *= (-0.3 * st * w).exp2(); // comme la teinte, mais seulement dans les ombres : + = magenta
        }
        v
    }))
}

pub fn tone_regions(img: &Img, r: &Recipe) -> Img {
    if r.highlights == 0.0 && r.shadows == 0.0 {
        return img.clone();
    }
    let ks = (1.5 * (r.shadows / 100.0)) as f32;
    let kh = (1.5 * (r.highlights / 100.0)) as f32;
    Arc::new(map_pixels(img, |r_, g, b| {
        let lum = luma(r_, g, b);
        let p = lum.clamp(0.0, 1.0).sqrt();
        let sm = (1.0 - p) * (1.0 - p);
        let hm = p * p;
        let gain = (ks * sm + kh * hm).exp2();
        [r_ * gain, g * gain, b * gain]
    }))
}

pub fn contrast_curve(img: &Img, r: &Recipe) -> Img {
    let enc = color::encode_table();
    let wb = r.whites != 0.0 || r.blacks != 0.0;
    let (lo, scale) = if wb {
        let lo = -0.12 * r.blacks / 100.0;
        let hi = 1.0 - 0.15 * r.whites / 100.0;
        (lo as f32, (hi - lo) as f32)
    } else {
        (0.0, 1.0)
    };
    let c = (r.contrast / 100.0) as f32;
    let main = if curve::is_identity(&r.curve) { None } else { Some(curve::build_lut(&r.curve)) };
    let chan = [&r.curve_red, &r.curve_green, &r.curve_blue];
    let any_chan = chan.iter().any(|p| !curve::is_identity(p));
    let chan_lut: Vec<Option<Vec<f32>>> =
        chan.iter().map(|p| if curve::is_identity(p) { None } else { Some(curve::build_lut(p)) }).collect();
    Arc::new(map_pixels(img, |r_, g, b| {
        let mut px = [r_, g, b];
        for v in px.iter_mut() {
            let mut x = color::linear_to_srgb(enc, *v);
            if wb {
                x = ((x - lo) / scale).clamp(0.0, 1.0);
            }
            if c != 0.0 {
                let s = x * x * (3.0 - 2.0 * x);
                x += c * (s - x);
            }
            if let Some(l) = &main {
                x = curve::apply(l, x);
            }
            *v = x;
        }
        if any_chan {
            for (i, l) in chan_lut.iter().enumerate() {
                if let Some(l) = l {
                    px[i] = curve::apply(l, px[i]);
                }
            }
        }
        px
    }))
}

/// Position d'une bande dans la photo entière : les réglages qui dépendent de la taille ou de la position (rayons des flous, vignetage,
/// grain, masques locaux) se calculent sur la photo entière, pas sur la bande. Sans contexte, l'image traitée EST la photo entière.
#[derive(Clone, Copy, Debug)]
pub struct Tile {
    pub full_w: usize,
    pub full_h: usize,
    /// Rang, dans la photo entière, de la première rangée de l'image traitée.
    pub y0: usize,
}

thread_local! {
    static TILE: std::cell::Cell<Option<Tile>> = const { std::cell::Cell::new(None) };
}

/// Exécute `f` (les étages tournent dans ce même fil) avec le contexte de bande `t`.
pub fn with_tile<R>(t: Tile, f: impl FnOnce() -> R) -> R {
    let old = TILE.with(|c| c.replace(Some(t)));
    let out = f();
    TILE.with(|c| c.set(old));
    out
}

/// Contexte courant, ou la photo entière (`w` × `h`) quand on ne rend pas par bandes.
pub(crate) fn tile_of(w: usize, h: usize) -> Tile {
    TILE.with(|c| c.get()).unwrap_or(Tile { full_w: w, full_h: h, y0: 0 })
}

/// Rayon (pixels) du halo de la lueur : de 0,5 % à 6 % du grand côté de la photo entière selon le réglage « Rayon ».
fn glow_radius(r: &Recipe, ls: f64) -> usize {
    let k = (r.glow_radius / 100.0).clamp(0.0, 1.0);
    ((ls * (0.005 + 0.055 * k)).round() as usize).max(2)
}

fn dehaze_radius(ls: usize) -> usize {
    ((ls as f64 * 0.03) as usize).max(2)
}
fn clarity_radius(ls: usize) -> usize {
    ((ls as f64 * 0.012) as usize).max(2)
}
fn texture_radius(ls: usize) -> f64 {
    (ls as f64 * 0.002).max(1.0)
}
fn sharpen_radius(r: &Recipe, ls: f64) -> f64 {
    (r.sharpen_radius.clamp(0.5, 3.0) as f64 * ls / 3000.0).max(0.5)
}
fn denoise_color_radius(r: &Recipe, ls: f64) -> usize {
    let mix = (((r.denoise_color.clamp(0.0, 100.0) / 100.0) as f32) * COLOR_NR_GAIN).min(1.0);
    let smooth = (r.denoise_color_smooth.clamp(0.0, 100.0) / 100.0) as f32;
    ((ls * 0.0025 * mix as f64 * (0.5 + smooth as f64) * 2.0).round() as usize).max(2)
}
fn denoise_luma_radius(ls: f64) -> f64 {
    (ls * 0.0015).max(1.0)
}

/// Flou de rayon non entier : mélange des deux flous entiers voisins (rayon 0,53 = 47 % du rayon 0 et 53 % du rayon 1).
/// Les rayons sont proportionnels au grand côté de l'image ; arrondis à l'entier, l'aperçu (1 600 px) donnait un autre rendu
/// que l'export (6 000 px). Un rayon entier donne exactement le flou entier.
fn blur_frac(a: &[f32], w: usize, h: usize, radius: f64) -> Vec<f32> {
    let radius = radius.max(0.0);
    let lo = radius.floor() as usize;
    let t = (radius - lo as f64) as f32;
    let base = if lo == 0 { a.to_vec() } else { box_blur(a, w, h, lo) };
    if t < 0.01 {
        return base;
    }
    let up = box_blur(a, w, h, lo + 1);
    base.iter().zip(up.iter()).map(|(b, u)| b + (u - b) * t).collect()
}

/// Rangées de marge à ajouter de chaque côté d'une bande pour que le rendu par bandes donne le même résultat que le rendu entier :
/// somme des portées (trois passes de flou = trois fois le rayon) des flous enchaînés par la réduction du bruit et le détail.
pub fn band_halo(r: &Recipe, long_side: usize) -> usize {
    let lsf = long_side as f64;
    let mut reach = 0usize;
    if r.denoise_color != 0.0 {
        reach += 3 * denoise_color_radius(r, lsf);
    }
    if r.denoise_luma != 0.0 {
        reach += 3 * denoise_luma_radius(lsf).ceil() as usize;
    }
    if r.dehaze > 0.0 {
        reach += 3 * dehaze_radius(long_side);
    }
    if r.clarity != 0.0 {
        reach += 3 * clarity_radius(long_side);
    }
    if r.texture != 0.0 {
        reach += 3 * texture_radius(long_side).ceil() as usize;
    }
    if r.sharpen_amount != 0.0 {
        reach += 3 * sharpen_radius(r, lsf).ceil() as usize;
    }
    if r.glow_amount > 0.0 {
        reach += 3 * glow_radius(r, lsf);
    }
    if reach == 0 { 0 } else { reach + 8 }
}

pub fn detail(img: &Img, r: &Recipe) -> Img {
    if r.dehaze == 0.0 && r.clarity == 0.0 && r.texture == 0.0 && r.sharpen_amount == 0.0 {
        return img.clone();
    }
    let (w, h) = (img.w, img.h);
    let tile = tile_of(w, h);
    let long_side = tile.full_w.max(tile.full_h);
    let mut x = img.data.clone();
    let n = w * h;
    let lumas = |x: &Vec<f32>| -> Vec<f32> { (0..n).map(|i| luma(x[3 * i], x[3 * i + 1], x[3 * i + 2])).collect() };
    if r.dehaze != 0.0 {
        let a = r.dehaze / 100.0;
        if a > 0.0 {
            let dark: Vec<f32> = (0..n).map(|i| x[3 * i].min(x[3 * i + 1]).min(x[3 * i + 2])).collect();
            let veil = box_blur_smooth(&dark, w, h, dehaze_radius(long_side));
            let k = (0.85 * a) as f32;
            x.par_chunks_mut(3).zip(veil.par_iter()).for_each(|(p, &vl)| {
                let v = k * vl;
                let d = (1.0 - v).max(0.05);
                for c in p.iter_mut() {
                    *c = ((*c - v) / d).clamp(0.0, 1.0);
                }
            });
        } else {
            let hh = 0.5 * -a;
            let (m, add) = ((1.0 - hh) as f32, (0.85 * hh) as f32);
            x.par_iter_mut().for_each(|c| *c = *c * m + add);
        }
    }
    if r.clarity != 0.0 || r.texture != 0.0 {
        let mut l = lumas(&x);
        if r.clarity != 0.0 {
            let blur = box_blur_smooth(&l, w, h, clarity_radius(long_side));
            let k = (0.9 * r.clarity / 100.0) as f32;
            x.par_chunks_mut(3).enumerate().for_each(|(i, p)| {
                let lu = l[i];
                let d = lu - blur[i];
                let mid = 4.0 * lu * (1.0 - lu);
                let add = k * (d * mid);
                for c in p.iter_mut() {
                    *c += add;
                }
            });
        }
        if r.texture != 0.0 {
            l = lumas(&x);
            let blur = blur_frac(&l, w, h, texture_radius(long_side));
            let k = (1.2 * r.texture / 100.0) as f32;
            x.par_chunks_mut(3).enumerate().for_each(|(i, p)| {
                let add = k * (l[i] - blur[i]);
                for c in p.iter_mut() {
                    *c += add;
                }
            });
        }
        x.par_iter_mut().for_each(|c| *c = c.clamp(0.0, 1.0));
    }
    if r.sharpen_amount != 0.0 {
        sharpen(&mut x, w, h, long_side, r);
    }
    Arc::new(Image { w, h, data: x })
}

/// Netteté : masque flou sur la luminosité. Le rayon est exprimé pour une image de 3000 px de long
/// (il grandit avec l'image, pour que l'aperçu et l'export aient le même aspect).
/// « Détail » (0..100) : bas = les contours francs sont compressés (peu de halos), haut = netteté pleine
/// et accentuation supplémentaire des détails très fins (texture, grain compris).
fn sharpen(x: &mut [f32], w: usize, h: usize, long_side: usize, r: &Recipe) {
    let n = w * h;
    let rad = sharpen_radius(r, long_side as f64);
    let l: Vec<f32> = (0..n).map(|i| luma(x[3 * i], x[3 * i + 1], x[3 * i + 2])).collect();
    let blur = blur_frac(&l, w, h, rad);
    let ds = (r.sharpen_detail.clamp(0.0, 100.0) / 100.0) as f32;
    let fine = if ds > 0.0 { Some(blur_frac(&l, w, h, (long_side as f64 / 3000.0).max(0.5))) } else { None };
    let k = (1.5 * r.sharpen_amount / 100.0) as f32;
    let thr = (0.04 * r.sharpen_masking.clamp(0.0, 100.0) / 100.0) as f32;
    // genou de compression : à Détail 0 l'écart ajouté plafonne vite (pas de halo) ; à Détail 100 il est linéaire
    let knee = 0.03 + 0.97 * ds * ds;
    x.par_chunks_mut(3).enumerate().for_each(|(i, p)| {
        let d = l[i] - blur[i];
        // seuil : les petits écarts (grain) ne sont pas accentués, les vrais contours le sont pleinement
        let gate = if thr > 0.0 { ((d.abs() - 0.25 * thr) / (0.75 * thr)).clamp(0.0, 1.0) } else { 1.0 };
        let soft = knee * (d / knee).tanh();
        let mut add = k * soft * gate;
        if let Some(f) = &fine {
            add += 0.6 * ds * k * (l[i] - f[i]) * gate;
        }
        for c in p.iter_mut() {
            *c = (*c + add).clamp(0.0, 1.0);
        }
    });
}

/// Réduction du bruit à la manière de Lightroom : deux volets (luminosité, couleur), chacun avec ses réglages de finesse.
/// Première version volontairement simple (lissage pondéré par le contraste local) ; un débruitage plus fin
/// (non-local means, ou un modèle IA) pourra la remplacer sans changer les réglages.
/// Gain du volet couleur : l'effet est complet (mélange 100 %) à partir de 100 / COLOR_NR_GAIN %.
const COLOR_NR_GAIN: f32 = 4.0;

pub fn denoise(img: &Img, r: &Recipe) -> Img {
    if r.denoise_luma == 0.0 && r.denoise_color == 0.0 {
        return img.clone();
    }
    let (w, h) = (img.w, img.h);
    let n = w * h;
    let tile = tile_of(w, h);
    let long_side = tile.full_w.max(tile.full_h) as f64;
    let mut x = img.data.clone();
    let lum = |x: &[f32]| -> Vec<f32> { (0..n).map(|i| luma(x[3 * i], x[3 * i + 1], x[3 * i + 2])).collect() };
    let pct = |v: f64| (v.clamp(0.0, 100.0) / 100.0) as f32;
    if r.denoise_color != 0.0 {
        let a = pct(r.denoise_color);
        // Le curseur 25 de Lightroom efface déjà presque tout le bruit de couleur : on mélange donc à 100 % dès 25 (mesuré 0.23.10 sur ISO 1250).
        let mix = (a * COLOR_NR_GAIN).min(1.0);
        let detail = pct(r.denoise_color_detail);
        let l = lum(&x);
        // « Lissage » élargit la zone de moyenne (grandes taches) ; « Détail » protège les contours de couleur.
        let rad = denoise_color_radius(r, long_side);
        let edge_scale = 0.04 * (1.6 - 1.2 * detail);
        let lb = box_blur_smooth(&l, w, h, rad);
        let ls = blur_frac(&l, w, h, (long_side * 2.0 / 3000.0).max(1.0)); // luminosité un peu lissée : le grain ne doit pas faire varier le poids d'un pixel à l'autre
        let cr: Vec<f32> = (0..n).map(|i| x[3 * i] - l[i]).collect();
        let cb: Vec<f32> = (0..n).map(|i| x[3 * i + 2] - l[i]).collect();
        let crb = box_blur_smooth(&cr, w, h, rad);
        let cbb = box_blur_smooth(&cb, w, h, rad);
        x.par_chunks_mut(3).enumerate().for_each(|(i, p)| {
            let e = (ls[i] - lb[i]).abs() / edge_scale;
            let wgt = mix / (1.0 + e * e); // près d'un contour : on ne lisse pas la couleur
            let nr = cr[i] + (crb[i] - cr[i]) * wgt;
            let nb = cb[i] + (cbb[i] - cb[i]) * wgt;
            // reconstruit G pour garder la luminosité : l = 0.2126 r + 0.7152 g + 0.0722 b
            let ng = -(color::LUMA[0] * nr + color::LUMA[2] * nb) / color::LUMA[1];
            p[0] = (l[i] + nr).clamp(0.0, 1.0);
            p[1] = (l[i] + ng).clamp(0.0, 1.0);
            p[2] = (l[i] + nb).clamp(0.0, 1.0);
        });
    }
    if r.denoise_luma != 0.0 {
        let a = pct(r.denoise_luma);
        let detail = pct(r.denoise_luma_detail);
        let contrast = pct(r.denoise_luma_contrast);
        let l = lum(&x);
        let rad = denoise_luma_radius(long_side);
        let lb = blur_frac(&l, w, h, rad);
        // « Détail » : plus il est haut, plus le seuil de contour est bas (on épargne davantage de petits détails)
        let sigma = (0.005 + 0.08 * a) * (1.6 - 1.2 * detail);
        x.par_chunks_mut(3).enumerate().for_each(|(i, p)| {
            let d = l[i] - lb[i];
            let e = d / sigma;
            let wgt = a / (1.0 + e * e);
            // « Contraste » : on garde une part des écarts de contraste moyen au lieu de les aplatir
            let keep = contrast * smooth_step(0.0, 0.05, d.abs());
            let add = -d * wgt * (1.0 - keep);
            for c in p.iter_mut() {
                *c = (*c + add).clamp(0.0, 1.0);
            }
        });
    }
    Arc::new(Image { w, h, data: x })
}

#[inline]
fn smooth_step(lo: f32, hi: f32, x: f32) -> f32 {
    let t = ((x - lo) / (hi - lo)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

const HSL_CENTERS: [f32; 9] = [0.0, 30.0, 60.0, 120.0, 180.0, 240.0, 270.0, 300.0, 360.0];

/// Poids des 8 familles de couleurs pour une teinte (degrés) : deux familles voisines se partagent la transition.
#[inline]
fn hsl_weights(hue: f32) -> (usize, usize, f32) {
    let mut i = 0;
    while i < 7 && hue >= HSL_CENTERS[i + 1] {
        i += 1;
    }
    let t = (hue - HSL_CENTERS[i]) / (HSL_CENTERS[i + 1] - HSL_CENTERS[i]);
    let t = t * t * (3.0 - 2.0 * t);
    (i, (i + 1) % 8, t)
}

#[inline]
fn smooth(lo: f32, hi: f32, x: f32) -> f32 {
    let t = ((x - lo) / (hi - lo)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

/// Mélangeur de couleurs : décale la teinte, la saturation et la luminosité de chaque famille de couleurs.
fn hsl_mix(r_: f32, g: f32, b: f32, bands: &[[f32; 3]; 8]) -> [f32; 3] {
    let mx = r_.max(g).max(b);
    let mn = r_.min(g).min(b);
    let chroma = mx - mn;
    if chroma < 1e-6 {
        return [r_, g, b];
    }
    let mut hue = if mx == r_ {
        60.0 * (((g - b) / chroma) % 6.0)
    } else if mx == g {
        60.0 * ((b - r_) / chroma + 2.0)
    } else {
        60.0 * ((r_ - g) / chroma + 4.0)
    };
    if hue < 0.0 {
        hue += 360.0;
    }
    let s = chroma / mx;
    let (i, j, t) = hsl_weights(hue);
    let mix = |k: usize| bands[i][k] * (1.0 - t) + bands[j][k] * t;
    let (dh, ds, dl) = (mix(0), mix(1), mix(2));
    let hue = (hue + dh * 0.3).rem_euclid(360.0); // ±100 = ±30°
    let s2 = (s * (1.0 + ds / 100.0)).clamp(0.0, 1.0);
    // HSV → RVB
    let c = mx * s2;
    let hp = hue / 60.0;
    let xx = c * (1.0 - (hp % 2.0 - 1.0).abs());
    let (r1, g1, b1) = match hp as u32 {
        0 => (c, xx, 0.0),
        1 => (xx, c, 0.0),
        2 => (0.0, c, xx),
        3 => (0.0, xx, c),
        4 => (xx, 0.0, c),
        _ => (c, 0.0, xx),
    };
    let m = mx - c;
    let mut out = [r1 + m, g1 + m, b1 + m];
    // luminosité de la famille : les gris ne bougent pas
    let a = dl / 100.0 * 0.5 * smooth(0.0, 0.15, s);
    if a != 0.0 {
        for v in out.iter_mut() {
            *v = if a > 0.0 { *v + (1.0 - *v) * a } else { *v * (1.0 + a) };
        }
    }
    [out[0].clamp(0.0, 1.0), out[1].clamp(0.0, 1.0), out[2].clamp(0.0, 1.0)]
}

/// Teinte (degrés) à pleine saturation, ramenée à la même luminosité que le gris : on ne fait que pousser la couleur.
fn grading_tint(hue_deg: f64) -> [f32; 3] {
    let hp = (hue_deg.rem_euclid(360.0) / 60.0) as f32;
    let x = 1.0 - (hp % 2.0 - 1.0).abs();
    let (r, g, b) = match hp as u32 {
        0 => (1.0, x, 0.0),
        1 => (x, 1.0, 0.0),
        2 => (0.0, 1.0, x),
        3 => (0.0, x, 1.0),
        4 => (x, 0.0, 1.0),
        _ => (1.0, 0.0, x),
    };
    let l = luma(r, g, b);
    [r - l, g - l, b - l]
}

/// Réglages préparés du Color Grading : pour chaque zone (ombres, tons moyens, hautes lumières, global) une poussée
/// de couleur [r, g, b] et un décalage de luminosité.
struct GradingPlan {
    tint: [[f32; 3]; 4],
    lift: [f32; 4],
    pivot: f32,
    half: f32,
}

/// Force maximale de la poussée de couleur (saturation 100) : de l'ordre de ce que fait Lightroom.
const GRADING_STRENGTH: f32 = 0.3;
/// Amplitude maximale du décalage de luminosité (luminosité ±100).
const GRADING_LIFT: f32 = 0.2;

impl GradingPlan {
    fn new(g: &crate::recipe::Grading) -> GradingPlan {
        let mut tint = [[0f32; 3]; 4];
        let mut lift = [0f32; 4];
        for (i, z) in g.zones().iter().enumerate() {
            let t = grading_tint(z[0]);
            let k = (z[1] / 100.0) as f32 * GRADING_STRENGTH;
            tint[i] = [t[0] * k, t[1] * k, t[2] * k];
            lift[i] = (z[2] / 100.0) as f32 * GRADING_LIFT;
        }
        // Équilibre positif : les hautes lumières gagnent du terrain (le point de bascule descend).
        let pivot = (0.5 - 0.3 * (g.cg_balance / 100.0) as f32).clamp(0.15, 0.85);
        let half = 0.1 + 0.4 * (g.cg_blending / 100.0).clamp(0.0, 1.0) as f32;
        GradingPlan { tint, lift, pivot, half }
    }

    /// Poids (ombres, tons moyens, hautes lumières) d'une luminosité d'affichage ; leur somme vaut 1.
    #[inline]
    fn weights(&self, l: f32) -> [f32; 3] {
        // Les ombres et les hautes lumières mordent sur les tons moyens (et l'une sur l'autre quand le fondu est large) ;
        // si elles se recouvrent, on les ramène à une somme de 1.
        let k = self.half;
        let mut s = 1.0 - smooth_step(self.pivot - k, self.pivot + 0.25 * k, l);
        let mut h = smooth_step(self.pivot - 0.25 * k, self.pivot + k, l);
        if s + h > 1.0 {
            let t = s + h;
            s /= t;
            h /= t;
        }
        [s, 1.0 - s - h, h]
    }

    #[inline]
    fn apply(&self, rgb: [f32; 3]) -> [f32; 3] {
        let w = self.weights(luma(rgb[0], rgb[1], rgb[2]));
        let weights = [w[0], w[1], w[2], 1.0];
        let mut out = rgb;
        for z in 0..4 {
            for c in 0..3 {
                out[c] += weights[z] * (self.tint[z][c] + self.lift[z]);
            }
        }
        [out[0].clamp(0.0, 1.0), out[1].clamp(0.0, 1.0), out[2].clamp(0.0, 1.0)]
    }
}

/// Poids rouge, vert, bleu du noir et blanc : la luminance habituelle, déplacée par les trois curseurs (±100 = ±0,5), puis ramenée à une somme de 1
/// pour garder la luminosité globale. `None` si les curseurs sont à zéro (calcul d'avant, identique au bit près).
fn bw_weights(r: &Recipe) -> Option<[f32; 3]> {
    if r.bw_red == 0.0 && r.bw_green == 0.0 && r.bw_blue == 0.0 {
        return None;
    }
    let base = [0.2126, 0.7152, 0.0722];
    let delta = [r.bw_red, r.bw_green, r.bw_blue];
    let mut w = [0f64; 3];
    for i in 0..3 {
        w[i] = base[i] + (delta[i] / 100.0).clamp(-1.0, 1.0) * 0.5;
    }
    let sum: f64 = w.iter().sum();
    if sum.abs() < 0.05 {
        return None;
    }
    Some([(w[0] / sum) as f32, (w[1] / sum) as f32, (w[2] / sum) as f32])
}

pub fn color_stage(img: &Img, r: &Recipe) -> Img {
    let hsl_on = !r.hsl.is_neutral();
    let grading_on = !r.grading.is_neutral();
    let bw = r.bw;
    if r.saturation == 0.0 && r.vibrance == 0.0 && !hsl_on && !grading_on && !bw {
        return img.clone();
    }
    let sat = (1.0 + r.saturation / 100.0) as f32;
    let vib = (r.vibrance / 100.0) as f32;
    let basic = r.saturation != 0.0 || r.vibrance != 0.0;
    let mut bands = [[0f32; 3]; 8];
    for (b, src) in bands.iter_mut().zip(r.hsl.bands().iter()) {
        for k in 0..3 {
            b[k] = src[k] as f32;
        }
        if bw {
            b[0] = 0.0; // en noir et blanc seule la luminosité des familles compte : ni teinte ni saturation
            b[1] = 0.0;
        }
    }
    let plan = GradingPlan::new(&r.grading);
    let bw_w = bw_weights(r);
    Arc::new(map_pixels(img, |r_, g, b| {
        if bw {
            // mélangeur noir et blanc : chaque famille est d'abord éclaircie ou assombrie, puis l'image devient son gris de luminance
            let c = if hsl_on { hsl_mix(r_, g, b, &bands) } else { [r_, g, b] };
            let l = match &bw_w {
                Some(w) => c[0] * w[0] + c[1] * w[1] + c[2] * w[2],
                None => luma(c[0], c[1], c[2]),
            };
            let out = [l, l, l];
            return if grading_on { plan.apply(out) } else { out };
        }
        let (mut r_, mut g, mut b) = (r_, g, b);
        if basic {
            let l = luma(r_, g, b);
            let chroma = r_.max(g).max(b) - r_.min(g).min(b);
            let factor = (sat * (1.0 + vib * (1.0 - chroma))).max(0.0);
            r_ = (l + (r_ - l) * factor).clamp(0.0, 1.0);
            g = (l + (g - l) * factor).clamp(0.0, 1.0);
            b = (l + (b - l) * factor).clamp(0.0, 1.0);
        }
        let mut out = if hsl_on { hsl_mix(r_, g, b, &bands) } else { [r_, g, b] };
        if grading_on {
            out = plan.apply(out);
        }
        out
    }))
}

#[cfg(test)]
mod perspective_tests {
    use super::*;

    #[test]
    fn no_perspective_means_no_plan() {
        assert!(perspective_plan(600, 400, &Recipe::default()).is_none());
    }

    #[test]
    fn homography_maps_the_four_corners() {
        let from = [[0.0, 0.0], [10.0, 0.0], [10.0, 6.0], [0.0, 6.0]];
        let to = [[1.0, 0.5], [9.0, 0.0], [8.0, 6.5], [2.0, 5.0]];
        let h = homography(&from, &to).unwrap();
        for (p, q) in from.iter().zip(to.iter()) {
            let den = h[6] * p[0] + h[7] * p[1] + 1.0;
            assert!(((h[0] * p[0] + h[1] * p[1] + h[2]) / den - q[0]).abs() < 1e-9);
            assert!(((h[3] * p[0] + h[4] * p[1] + h[5]) / den - q[1]).abs() < 1e-9);
        }
    }

    #[test]
    fn vertical_correction_is_symmetric_and_zooms_in() {
        let r = Recipe { persp_v: 50.0, ..Recipe::default() };
        let (inv, zoom) = perspective_plan(600, 400, &r).unwrap();
        assert!(zoom > 1.0);
        let map = |x: f64, y: f64| {
            let den = inv[6] * x + inv[7] * y + inv[8];
            ((inv[0] * x + inv[1] * y + inv[2]) / den, (inv[3] * x + inv[4] * y + inv[5]) / den)
        };
        let (cx, cy) = map(300.0, 200.0);                 // le centre reste le centre (symétrie gauche-droite)
        assert!((cx - 300.0).abs() < 1e-6 && cy > 150.0 && cy < 250.0);
        let (lx, _) = map(100.0, 200.0);
        let (rx, _) = map(500.0, 200.0);
        assert!(((lx + rx) / 2.0 - 300.0).abs() < 1e-6);
    }
}

// ---------------------------------------------------------------------------------------------------------------------------------
// Grain et vignetage artistique : derniers réglages de l'image (après les masques locaux), sur les valeurs affichables 0..1.
// ---------------------------------------------------------------------------------------------------------------------------------

/// Dernier étage : les masques locaux, puis le vignetage artistique et le grain (le nom d'étage reste « local »).
pub fn local_and_finish(img: &Img, r: &Recipe) -> Img {
    let after_masks = crate::masks::local_stage(img, r);
    finish(&glow(&after_masks, r), r)
}

/// Lueur (« glow ») : les hautes lumières débordent en un halo doux, mélangé en « écran » (jamais plus sombre que l'original).
/// Le seuil choisit ce qui brille : haut = seulement les sources de lumière (bloom), bas = toute l'image (diffusion douce).
pub fn glow(img: &Img, r: &Recipe) -> Img {
    let amount = (r.glow_amount / 100.0).clamp(0.0, 1.0) as f32;
    if amount == 0.0 {
        return img.clone();
    }
    let (w, h) = (img.w, img.h);
    let tile = tile_of(w, h);
    let radius = glow_radius(r, tile.full_w.max(tile.full_h) as f64);
    let thr = (r.glow_threshold / 100.0).clamp(0.0, 1.0) as f32;
    let (lo, hi) = ((thr - 0.2).max(0.0), (thr + 0.2).min(1.0).max(thr + 0.05));
    let mut planes = vec![vec![0f32; w * h]; 3];
    for i in 0..w * h {
        let (rr, gg, bb) = (img.data[i * 3], img.data[i * 3 + 1], img.data[i * 3 + 2]);
        let k = if thr <= 0.0 { 1.0 } else { smooth_step(lo, hi, luma(rr, gg, bb)) };
        planes[0][i] = rr * k;
        planes[1][i] = gg * k;
        planes[2][i] = bb * k;
    }
    let blurred: Vec<Vec<f32>> = planes.iter().map(|p| box_blur_smooth(p, w, h, radius)).collect();
    let mut data = img.data.clone();
    data.par_chunks_mut(w * 3).enumerate().for_each(|(j, row)| {
        for i in 0..w {
            for c in 0..3 {
                let g = (blurred[c][j * w + i] * amount).clamp(0.0, 1.0);
                let v = row[i * 3 + c];
                row[i * 3 + c] = 1.0 - (1.0 - v) * (1.0 - g);
            }
        }
    });
    Arc::new(Image { w, h, data })
}

/// Hachage d'un point de grille : nombre uniforme dans [0, 1[, identique à chaque calcul (le grain ne « bouge » pas d'un rendu à l'autre).
#[inline]
fn hash01(x: i32, y: i32, seed: u32) -> f32 {
    let mut h = (x as u32).wrapping_mul(0x9E37_79B1) ^ (y as u32).wrapping_mul(0x85EB_CA77) ^ seed.wrapping_mul(0xC2B2_AE3D);
    h ^= h >> 15;
    h = h.wrapping_mul(0x2C1B_3C6D);
    h ^= h >> 12;
    h = h.wrapping_mul(0x297A_2D39);
    h ^= h >> 15;
    (h >> 8) as f32 / 16_777_216.0
}

/// Bruit de moyenne nulle et d'écart-type voisin de 1 (somme de trois uniformes).
#[inline]
fn gauss(x: i32, y: i32, seed: u32) -> f32 {
    (hash01(x, y, seed) + hash01(x, y, seed.wrapping_add(1)) + hash01(x, y, seed.wrapping_add(2)) - 1.5) * 2.0
}

/// Bruit doux : interpolation entre les points d'une grille de pas `cell` pixels.
#[inline]
fn smooth_noise(x: f32, y: f32, cell: f32, seed: u32) -> f32 {
    let (gx, gy) = (x / cell, y / cell);
    let (ix, iy) = (gx.floor(), gy.floor());
    let (fx, fy) = (gx - ix, gy - iy);
    let (sx, sy) = (fx * fx * (3.0 - 2.0 * fx), fy * fy * (3.0 - 2.0 * fy));
    let (ix, iy) = (ix as i32, iy as i32);
    let a = gauss(ix, iy, seed);
    let b = gauss(ix + 1, iy, seed);
    let c = gauss(ix, iy + 1, seed);
    let d = gauss(ix + 1, iy + 1, seed);
    let top = a + (b - a) * sx;
    let bottom = c + (d - c) * sx;
    (top + (bottom - top) * sy) * 1.3 // l'interpolation resserre le bruit : on rattrape son écart-type
}

/// Amplitude du grain à 100 % (écart-type, sur des valeurs 0..1).
const GRAIN_AMPLITUDE: f32 = 0.12;
/// Variation de luminosité maximale du vignetage artistique, en IL.
const VIG_EV: f32 = 2.0;

pub fn finish(img: &Img, r: &Recipe) -> Img {
    let vig = (r.vig_amount / 100.0).clamp(-1.0, 1.0) as f32;
    let grain = (r.grain_amount / 100.0).clamp(0.0, 1.0) as f32;
    if vig == 0.0 && grain == 0.0 {
        return img.clone();
    }
    let (w, h) = (img.w, img.h);
    let tile = tile_of(w, h);
    let long_side = tile.full_w.max(tile.full_h) as f32;
    let (cx, cy) = (tile.full_w as f32 / 2.0, tile.full_h as f32 / 2.0);
    let half_diag = (cx * cx + cy * cy).sqrt();
    let mid = (r.vig_mid / 100.0).clamp(0.0, 1.0) as f32;
    let feather = (r.vig_feather / 100.0).clamp(0.0, 1.0) as f32;
    let t_round = ((r.vig_round / 100.0).clamp(-1.0, 1.0) as f32 + 1.0) / 2.0; // 0 : suit le cadre, 1 : cercle
    let start = (mid * 0.95 * (1.0 - 0.8 * feather)).min(0.95);
    let cell = ((r.grain_size / 25.0).clamp(0.2, 4.0) as f32 * long_side / 1800.0 * 1.2).max(1.0);
    let rough = (r.grain_roughness / 100.0).clamp(0.0, 1.0) as f32;
    let mut data = img.data.clone();
    data.par_chunks_mut(w * 3).enumerate().for_each(|(j, row)| {
        let j = j + tile.y0;
        for i in 0..w {
            let px = &mut row[i * 3..i * 3 + 3];
            if vig != 0.0 {
                let (dx, dy) = (i as f32 + 0.5 - cx, j as f32 + 0.5 - cy);
                let frame = ((dx / cx).powi(2) + (dy / cy).powi(2)).sqrt() / std::f32::consts::SQRT_2;
                let circle = (dx * dx + dy * dy).sqrt() / half_diag;
                let rn = frame * (1.0 - t_round) + circle * t_round;
                let gain = (vig * VIG_EV * smooth_step(start, 1.0, rn) / 2.2).exp2(); // valeurs affichables : IL ramenés par le gamma
                for c in px.iter_mut() {
                    *c = (*c * gain).clamp(0.0, 1.0);
                }
            }
            if grain != 0.0 {
                let (x, y) = (i as f32, j as f32);
                let n_smooth = smooth_noise(x, y, cell, 7);
                let n_raw = gauss(i as i32, j as i32, 99);
                let n = n_smooth * (1.0 - rough) + n_raw * rough;
                let l = luma(px[0], px[1], px[2]).clamp(0.0, 1.0);
                let weight = 0.45 + 0.55 * 4.0 * l * (1.0 - l); // plus visible dans les tons moyens, discret aux extrêmes
                let d = n * grain * GRAIN_AMPLITUDE * weight;
                for c in px.iter_mut() {
                    *c = (*c + d).clamp(0.0, 1.0);
                }
            }
        }
    });
    Arc::new(Image { w, h, data })
}

#[cfg(test)]
mod finish_tests {
    use super::*;

    fn flat(w: usize, h: usize, v: f32) -> Img {
        Arc::new(Image { w, h, data: vec![v; w * h * 3] })
    }

    #[test]
    fn neutral_recipe_returns_the_same_image() {
        let img = flat(32, 24, 0.5);
        let out = finish(&img, &Recipe::default());
        assert!(Arc::ptr_eq(&img, &out));
    }

    #[test]
    fn vignette_darkens_corners_not_center() {
        let img = flat(64, 48, 0.5);
        let r = Recipe { vig_amount: -80.0, ..Recipe::default() };
        let out = finish(&img, &r);
        let at = |x: usize, y: usize| out.data[(y * 64 + x) * 3];
        assert!(at(0, 0) < 0.45 && (at(32, 24) - 0.5).abs() < 1e-4);
        let lighter = finish(&img, &Recipe { vig_amount: 80.0, ..Recipe::default() });
        assert!(lighter.data[0] > 0.55);
    }

    #[test]
    fn grain_is_deterministic_and_zero_mean() {
        let img = flat(96, 96, 0.5);
        let r = Recipe { grain_amount: 60.0, ..Recipe::default() };
        let (a, b) = (finish(&img, &r), finish(&img, &r));
        assert_eq!(a.data, b.data);
        let mean: f32 = a.data.iter().sum::<f32>() / a.data.len() as f32;
        let var: f32 = a.data.iter().map(|v| (v - mean) * (v - mean)).sum::<f32>() / a.data.len() as f32;
        assert!((mean - 0.5).abs() < 0.01 && var.sqrt() > 0.01);
    }

    #[test]
    fn glow_is_neutral_at_zero_and_never_darkens() {
        let img = flat(64, 48, 0.6);
        assert!(Arc::ptr_eq(&img, &glow(&img, &Recipe::default())));
        let mut data = vec![0.1f32; 64 * 48 * 3];
        for y in 20..28 {
            for x in 28..36 {
                for c in 0..3 {
                    data[(y * 64 + x) * 3 + c] = 1.0;
                }
            }
        }
        let img = Arc::new(Image { w: 64, h: 48, data });
        let out = glow(&img, &Recipe { glow_amount: 80.0, glow_threshold: 70.0, ..Recipe::default() });
        assert!(out.data.iter().zip(img.data.iter()).all(|(o, i)| o >= &(i - 1e-6)));
        let near = out.data[(24 * 64 + 26) * 3]; // hors du carré clair, à côté : le halo l'éclaire
        assert!(near > img.data[(24 * 64 + 26) * 3] + 0.005);
    }

    #[test]
    fn calibration_keeps_white_and_neutral_returns_none() {
        assert!(calibration_matrix(&Recipe::default()).is_none());
        let r = Recipe { calib_red_hue: 40.0, calib_blue_sat: 30.0, calib_green_sat: -20.0, ..Recipe::default() };
        let m = calibration_matrix(&r).unwrap();
        for i in 0..3 {
            assert!((m[i][0] + m[i][1] + m[i][2] - 1.0).abs() < 1e-5);
        }
    }

    #[test]
    fn bw_weights_sum_to_one() {
        assert!(bw_weights(&Recipe::default()).is_none());
        let w = bw_weights(&Recipe { bw_red: 40.0, bw_blue: -30.0, ..Recipe::default() }).unwrap();
        assert!((w[0] + w[1] + w[2] - 1.0).abs() < 1e-5 && w[0] > 0.2126);
    }
}

#[cfg(test)]
mod frac_blur_tests {
    use super::*;

    fn ramp(w: usize, h: usize) -> Vec<f32> {
        (0..w * h).map(|i| (((i % w) * 7 + (i / w) * 3) % 31) as f32 / 31.0).collect()
    }

    #[test]
    fn integer_radius_equals_the_integer_blur() {
        let a = ramp(40, 30);
        assert_eq!(blur_frac(&a, 40, 30, 3.0), box_blur(&a, 40, 30, 3));
    }

    #[test]
    fn fractional_radius_lies_between_its_neighbours() {
        let a = ramp(40, 30);
        let (lo, hi, mid) = (box_blur(&a, 40, 30, 1), box_blur(&a, 40, 30, 2), blur_frac(&a, 40, 30, 1.5));
        for i in 0..a.len() {
            let (m, n) = (lo[i].min(hi[i]), lo[i].max(hi[i]));
            assert!(mid[i] >= m - 1e-6 && mid[i] <= n + 1e-6);
        }
    }

    #[test]
    fn sharpen_radius_scales_with_the_image_without_rounding() {
        let r = Recipe::default();
        let small = sharpen_radius(&r, 1600.0);
        let big = sharpen_radius(&r, 6000.0);
        assert!((big / small - 6000.0 / 1600.0).abs() < 1e-9, "proportionnel : {small} px à 1 600 px, {big} px à 6 000 px");
    }
}
