// SPDX-License-Identifier: GPL-3.0-or-later
//! Retrait de taches : « corriger » (la zone source est ramenée à la teinte de son nouvel entourage) ou « cloner » (copie telle quelle).
//! Les positions sont des fractions de la photo ORIGINALE (avant recadrage et redressement), le rayon une fraction du grand côté :
//! une retouche vaut pour l'aperçu comme pour l'export.
use std::sync::Arc;

use crate::image::Image;
use crate::recipe::{Recipe, Spot};

const RING: f32 = 1.45; // l'anneau de comparaison va du rayon à 1,45 fois le rayon

fn radius_px(s: &Spot, w: usize, h: usize) -> f32 {
    ((s.r * w.max(h) as f64) as f32).max(1.5)
}

#[inline]
fn smooth(t: f32) -> f32 {
    let t = t.clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

/// Moyenne par canal des pixels de l'anneau [r, RING·r] autour de (cx, cy), échantillonnés en spirale (rapide, sans dépendre de la taille).
fn ring_mean(img: &Image, cx: f32, cy: f32, r: f32) -> [f32; 3] {
    let mut acc = [0f32; 3];
    let mut n = 0f32;
    let samples = 48;
    for i in 0..samples {
        let t = (i as f32 + 0.5) / samples as f32;
        let rad = r * (1.05 + (RING - 1.05) * t);
        let ang = i as f32 * 2.399_963; // angle d'or : répartition régulière
        let x = (cx + rad * ang.cos()).round() as isize;
        let y = (cy + rad * ang.sin()).round() as isize;
        if x >= 0 && y >= 0 && (x as usize) < img.w && (y as usize) < img.h {
            let k = (y as usize * img.w + x as usize) * 3;
            for c in 0..3 {
                acc[c] += img.data[k + c];
            }
            n += 1.0;
        }
    }
    if n == 0.0 {
        return [0.0; 3];
    }
    [acc[0] / n, acc[1] / n, acc[2] / n]
}

/// Applique les retouches dans l'ordre (chacune voit le résultat des précédentes).
pub fn apply_spots(img: &Arc<Image>, r: &Recipe) -> Arc<Image> {
    if r.spots.iter().all(|s| s.mode == "ai") {
        return img.clone();
    }
    let (w, h) = (img.w, img.h);
    let mut out = (**img).clone();
    for s in &r.spots {
        if s.mode == "ai" {
            continue; // retouche générative : calculée par le modèle d'IA côté Python, avant le moteur
        }
        let rad = radius_px(s, w, h);
        let (wf, hf) = (w as f32, h as f32);
        // centres des disques : le trait du pinceau, ou le seul cercle (x, y)
        let pts: Vec<(f32, f32)> = if s.stroke.is_empty() {
            vec![(s.x as f32 * wf, s.y as f32 * hf)]
        } else {
            s.stroke.iter().map(|p| (p[0] as f32 * wf, p[1] as f32 * hf)).collect()
        };
        let (cx, cy) = (s.x as f32 * wf, s.y as f32 * hf);
        // décalage source - cible (le même pour tout le trait) ; pour un cercle, la source reste entièrement dans la photo
        let (offx, offy) = if s.stroke.is_empty() {
            (
                (s.sx as f32 * wf).clamp(rad, (wf - rad).max(rad)) - cx,
                (s.sy as f32 * hf).clamp(rad, (hf - rad).max(rad)) - cy,
            )
        } else {
            (s.sx as f32 * wf - cx, s.sy as f32 * hf - cy)
        };
        let feather = s.feather.clamp(0.0, 1.0) as f32;
        let opacity = s.opacity.clamp(0.0, 1.0) as f32;
        let gain = if s.mode == "clone" {
            [1.0; 3]
        } else {
            // un nombre limité d'échantillons le long du trait (6 au plus), gains moyennés
            let n = pts.len().min(6);
            let mut g = [0f32; 3];
            for i in 0..n {
                let (px, py) = pts[if n == 1 { 0 } else { i * (pts.len() - 1) / (n - 1) }];
                let a = ring_mean(&out, px, py, rad);
                let b = ring_mean(&out, px + offx, py + offy, rad);
                for c in 0..3 {
                    g[c] += if b[c] > 1e-4 { (a[c] / b[c]).clamp(0.5, 2.0) } else { 1.0 };
                }
            }
            [g[0] / n as f32, g[1] / n as f32, g[2] / n as f32]
        };
        let (mut bx0, mut by0, mut bx1, mut by1) = (f32::MAX, f32::MAX, f32::MIN, f32::MIN);
        for &(px, py) in &pts {
            bx0 = bx0.min(px - rad);
            by0 = by0.min(py - rad);
            bx1 = bx1.max(px + rad);
            by1 = by1.max(py + rad);
        }
        let x0 = bx0.floor().max(0.0) as isize;
        let x1 = bx1.ceil().min(wf - 1.0) as isize;
        let y0 = by0.floor().max(0.0) as isize;
        let y1 = by1.ceil().min(hf - 1.0) as isize;
        if x1 < x0 || y1 < y0 {
            continue;
        }
        let (bw, bh) = ((x1 - x0 + 1) as usize, (y1 - y0 + 1) as usize);
        // masque de la retouche : union des disques (bord progressif)
        let mut mask = vec![0f32; bw * bh];
        let fe = feather * 0.6; // le bord progressif occupe au plus les 60 % extérieurs du rayon : une tache un peu plus petite que le cercle est entièrement couverte
        for &(px, py) in &pts {
            let (ya, yb) = (((py - rad).floor() as isize).max(y0), ((py + rad).ceil() as isize).min(y1));
            let (xa, xb) = (((px - rad).floor() as isize).max(x0), ((px + rad).ceil() as isize).min(x1));
            for y in ya..=yb {
                for x in xa..=xb {
                    let (dx, dy) = (x as f32 + 0.5 - px, y as f32 + 0.5 - py);
                    let d = (dx * dx + dy * dy).sqrt() / rad;
                    if d >= 1.0 {
                        continue;
                    }
                    let m = if fe <= 0.0 { 1.0 } else { 1.0 - smooth((d - (1.0 - fe)) / fe) };
                    let k = (y - y0) as usize * bw + (x - x0) as usize;
                    if m > mask[k] {
                        mask[k] = m;
                    }
                }
            }
        }
        // copie de la source AVANT écriture (source et cible peuvent se chevaucher)
        let mut patch: Vec<(usize, usize, [f32; 3], f32)> = Vec::new();
        for y in y0..=y1 {
            for x in x0..=x1 {
                let m = mask[(y - y0) as usize * bw + (x - x0) as usize] * opacity;
                if m <= 0.0 {
                    continue;
                }
                let (px, py) = ((x as f32 + 0.5 + offx).round() as isize, (y as f32 + 0.5 + offy).round() as isize);
                let (px, py) = (px.clamp(0, w as isize - 1) as usize, py.clamp(0, h as isize - 1) as usize);
                let k = (py * w + px) * 3;
                let v = [out.data[k] * gain[0], out.data[k + 1] * gain[1], out.data[k + 2] * gain[2]];
                patch.push((x as usize, y as usize, v, m));
            }
        }
        for (x, y, v, m) in patch {
            let k = (y * w + x) * 3;
            for c in 0..3 {
                out.data[k + c] = (out.data[k + c] + (v[c] - out.data[k + c]) * m).clamp(0.0, 1.0);
            }
        }
    }
    Arc::new(out)
}

/// Propose une source pour une tache en (x, y) (fractions de la photo), de rayon r (fraction du grand côté) :
/// la zone voisine qui ressemble le plus à l'entourage de la tache, sans contour ni détail marqué. Renvoie (sx, sy) en fractions.
pub fn suggest_source(img: &Image, x: f64, y: f64, r: f64) -> (f64, f64) {
    let (w, h) = (img.w as f32, img.h as f32);
    let rad = ((r * img.w.max(img.h) as f64) as f32).max(1.5);
    let (cx, cy) = (x as f32 * w, y as f32 * h);
    let target = ring_mean(img, cx, cy, rad);
    let luma = |k: usize| img.data[k] * 0.2126 + img.data[k + 1] * 0.7152 + img.data[k + 2] * 0.0722;
    let mut best: Option<(f32, f32, f32)> = None;
    for dist in [2.3f32, 3.2, 4.4] {
        for i in 0..16 {
            let ang = i as f32 * std::f32::consts::TAU / 16.0;
            let (sx, sy) = (cx + dist * rad * ang.cos(), cy + dist * rad * ang.sin());
            if sx < rad * RING || sy < rad * RING || sx > w - rad * RING || sy > h - rad * RING {
                continue;
            }
            let m = ring_mean(img, sx, sy, rad);
            let tone: f32 = (0..3).map(|c| (m[c] - target[c]).abs()).sum();
            // détail du disque candidat : écart moyen à sa propre moyenne (évite contours et motifs)
            let mut sum = 0f32;
            let mut sum2 = 0f32;
            let mut n = 0f32;
            for j in 0..24 {
                let t = (j as f32 + 0.5) / 24.0;
                let rr = rad * t.sqrt();
                let a = j as f32 * 2.399_963;
                let (px, py) = ((sx + rr * a.cos()) as usize, (sy + rr * a.sin()) as usize);
                let l = luma((py * img.w + px) * 3);
                sum += l;
                sum2 += l * l;
                n += 1.0;
            }
            let var = (sum2 / n - (sum / n) * (sum / n)).max(0.0);
            let score = tone + 2.0 * var.sqrt() + 0.01 * dist; // à égalité, plus près
            if best.map_or(true, |b| score < b.0) {
                best = Some((score, sx, sy));
            }
        }
    }
    match best {
        Some((_, sx, sy)) => ((sx / w) as f64, (sy / h) as f64),
        None => (((cx + 3.0 * rad).clamp(rad, (w - rad).max(rad)) / w) as f64, (cy / h) as f64),
    }
}
