// SPDX-License-Identifier: GPL-3.0-or-later
//! Reflet du flash dans la pupille : yeux rouges des personnes, reflets verts, jaunes ou bleus des yeux d'animaux.
//! Port de `sursaut/eyeshine.py::find_eyeshine` (recherche libre, sans détecteur de visages) :
//! repère les taches colorées et vives, arrondies, de la taille d'une pupille, entourées de sombre ; les paires d'yeux passent avant les taches isolées.
//! La correction elle-même n'est pas faite ici : l'application ajoute un masque local à la recette (voir `domain/eyes.dart`), comme `eyeshine.eye_mask` sur le PC.

const SEARCH_MAX: f32 = 900.0; // côté de l'image réduite où l'on cherche les pupilles
const MIN_CHROMA: f32 = 30.0; // couleur minimale (Lab) d'un reflet de pupille
const CATCHLIGHT_L: f32 = 88.0; // au-dessus, c'est le reflet blanc de l'œil

#[derive(Clone, Debug, PartialEq)]
pub struct Eye {
    pub x: f64,      // centre, fraction de la largeur
    pub y: f64,      // centre, fraction de la hauteur
    pub r: f64,      // rayon, fraction du plus grand côté
    pub hue: &'static str, // "rouge", "vert", "jaune" ou "bleu"
    pub score: f64,
    pub chroma: f64, // couleur (Lab) médiane de la tache
}

fn srgb_to_linear(v: f32) -> f32 {
    if v <= 0.04045 {
        v / 12.92
    } else {
        ((v + 0.055) / 1.055).powf(2.4)
    }
}

/// sRGB 8 bits → Lab (D65), comme OpenCV en flottant : L 0..100, a et b environ ±127.
fn rgb_to_lab(r: u8, g: u8, b: u8) -> (f32, f32, f32) {
    let (r, g, b) = (srgb_to_linear(r as f32 / 255.0), srgb_to_linear(g as f32 / 255.0), srgb_to_linear(b as f32 / 255.0));
    let x = (0.412453 * r + 0.357580 * g + 0.180423 * b) / 0.950456;
    let y = 0.212671 * r + 0.715160 * g + 0.072169 * b;
    let z = (0.019334 * r + 0.119193 * g + 0.950227 * b) / 1.088754;
    let f = |t: f32| if t > 0.008856 { t.cbrt() } else { 7.787 * t + 16.0 / 116.0 };
    let (fx, fy, fz) = (f(x), f(y), f(z));
    let l = if y > 0.008856 { 116.0 * fy - 16.0 } else { 903.3 * y };
    (l, 500.0 * (fx - fy), 200.0 * (fy - fz))
}

fn hue_name(a: f32, b: f32) -> &'static str {
    if a > 18.0 && a > b.abs() * 0.6 {
        return "rouge";
    }
    if a < -10.0 {
        return if b > -5.0 { "vert" } else { "bleu" };
    }
    if b > 0.0 {
        "jaune"
    } else {
        "bleu"
    }
}

fn median(v: &mut [f32]) -> f32 {
    v.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let n = v.len();
    if n == 0 {
        0.0
    } else if n % 2 == 1 {
        v[n / 2]
    } else {
        0.5 * (v[n / 2 - 1] + v[n / 2])
    }
}

/// Centile (interpolation linéaire, comme numpy) d'un tableau déjà trié.
fn percentile_sorted(v: &[f32], p: f32) -> f32 {
    if v.is_empty() {
        return 0.0;
    }
    let pos = p / 100.0 * (v.len() - 1) as f32;
    let lo = pos.floor() as usize;
    let hi = (lo + 1).min(v.len() - 1);
    v[lo] + (v[hi] - v[lo]) * (pos - lo as f32)
}

/// Dilatation par un carré (2·demi+1)² d'une grille booléenne w×h (séparable).
fn dilate_square(m: &[bool], w: usize, h: usize, half: usize) -> Vec<bool> {
    let mut tmp = vec![false; w * h];
    for y in 0..h {
        for x in 0..w {
            let x0 = x.saturating_sub(half);
            let x1 = (x + half).min(w - 1);
            tmp[y * w + x] = (x0..=x1).any(|xx| m[y * w + xx]);
        }
    }
    let mut out = vec![false; w * h];
    for y in 0..h {
        let y0 = y.saturating_sub(half);
        let y1 = (y + half).min(h - 1);
        for x in 0..w {
            out[y * w + x] = (y0..=y1).any(|yy| tmp[yy * w + x]);
        }
    }
    out
}

/// Image réduite (moyenne par blocs) dont le grand côté est au plus `SEARCH_MAX`.
fn shrink(rgb: &[u8], w: usize, h: usize) -> (Vec<u8>, usize, usize, f32) {
    let k = (w.max(h) as f32 / SEARCH_MAX).max(1.0);
    if k <= 1.0 {
        return (rgb.to_vec(), w, h, 1.0);
    }
    let (nw, nh) = (((w as f32 / k) as usize).max(1), ((h as f32 / k) as usize).max(1));
    let mut out = vec![0u8; nw * nh * 3];
    for y in 0..nh {
        let (sy0, sy1) = (((y as f32 * k) as usize).min(h - 1), (((y + 1) as f32 * k).ceil() as usize).clamp(1, h));
        for x in 0..nw {
            let (sx0, sx1) = (((x as f32 * k) as usize).min(w - 1), (((x + 1) as f32 * k).ceil() as usize).clamp(1, w));
            let mut acc = [0u32; 3];
            let mut n = 0u32;
            for sy in sy0..sy1.max(sy0 + 1) {
                for sx in sx0..sx1.max(sx0 + 1) {
                    let i = (sy * w + sx) * 3;
                    acc[0] += rgb[i] as u32;
                    acc[1] += rgb[i + 1] as u32;
                    acc[2] += rgb[i + 2] as u32;
                    n += 1;
                }
            }
            let n = n.max(1);
            let o = (y * nw + x) * 3;
            for c in 0..3 {
                out[o + c] = ((acc[c] + n / 2) / n) as u8;
            }
        }
    }
    (out, nw, nh, k)
}

/// Reflets de pupille probables dans une photo RVB 8 bits (hauteur × largeur × 3), du plus sûr au moins sûr.
pub fn find_eyeshine(rgb: &[u8], w0: usize, h0: usize, max_eyes: usize) -> Vec<Eye> {
    if w0 < 16 || h0 < 16 || rgb.len() < w0 * h0 * 3 {
        return Vec::new();
    }
    let (small, w, h, k) = shrink(rgb, w0, h0);
    let n = w * h;
    let mut ll = vec![0f32; n];
    let mut aa = vec![0f32; n];
    let mut bb = vec![0f32; n];
    let mut chroma = vec![0f32; n];
    for i in 0..n {
        let (l, a, b) = rgb_to_lab(small[i * 3], small[i * 3 + 1], small[i * 3 + 2]);
        ll[i] = l;
        aa[i] = a;
        bb[i] = b;
        chroma[i] = a.hypot(b);
    }
    let cand: Vec<bool> = (0..n).map(|i| chroma[i] > MIN_CHROMA && ll[i] > 18.0 && ll[i] < CATCHLIGHT_L).collect();
    // ouverture 2×2 (érosion puis dilatation), pour ôter les pixels isolés
    let mut eroded = vec![false; n];
    for y in 1..h {
        for x in 1..w {
            eroded[y * w + x] = cand[y * w + x] && cand[y * w + x - 1] && cand[(y - 1) * w + x] && cand[(y - 1) * w + x - 1];
        }
    }
    let mut open = vec![false; n];
    for y in 0..h {
        for x in 0..w {
            open[y * w + x] = eroded[y * w + x]
                || (x + 1 < w && eroded[y * w + x + 1])
                || (y + 1 < h && eroded[(y + 1) * w + x])
                || (x + 1 < w && y + 1 < h && eroded[(y + 1) * w + x + 1]);
        }
    }
    // composantes connexes (8 voisins)
    let mut seen = vec![false; n];
    let side = w.max(h) as f32;
    let mut found: Vec<Eye> = Vec::new();
    let mut stack: Vec<usize> = Vec::new();
    for start in 0..n {
        if !open[start] || seen[start] {
            continue;
        }
        let mut pix: Vec<usize> = Vec::new();
        seen[start] = true;
        stack.push(start);
        while let Some(p) = stack.pop() {
            pix.push(p);
            let (px, py) = (p % w, p / w);
            for dy in -1i32..=1 {
                for dx in -1i32..=1 {
                    let (nx, ny) = (px as i32 + dx, py as i32 + dy);
                    if nx < 0 || ny < 0 || nx >= w as i32 || ny >= h as i32 {
                        continue;
                    }
                    let q = ny as usize * w + nx as usize;
                    if open[q] && !seen[q] {
                        seen[q] = true;
                        stack.push(q);
                    }
                }
            }
        }
        let area = pix.len();
        let (mut x0, mut x1, mut y0, mut y1) = (w, 0usize, h, 0usize);
        let (mut sx, mut sy) = (0f64, 0f64);
        for &p in &pix {
            let (px, py) = (p % w, p / w);
            x0 = x0.min(px);
            x1 = x1.max(px);
            y0 = y0.min(py);
            y1 = y1.max(py);
            sx += px as f64;
            sy += py as f64;
        }
        let (bw, bh) = ((x1 - x0 + 1) as f32, (y1 - y0 + 1) as f32);
        let r = (area as f32 / std::f32::consts::PI).sqrt();
        if area < 6 || r > side * 0.04 || bw > 2.2 * bh || bh > 2.2 * bw || (area as f32) < 0.45 * bw * bh {
            continue; // trop petit, trop grand (un vêtement) ou pas arrondi
        }
        // anneau : carré de (2,5 r) autour de la tache, sans son voisinage immédiat (3×3)
        let ks = (((r * 2.5) as usize) | 1).max(1);
        let half = ks / 2;
        let (gx0, gy0) = (x0.saturating_sub(half + 1), y0.saturating_sub(half + 1));
        let (gx1, gy1) = ((x1 + half + 2).min(w), (y1 + half + 2).min(h));
        let (gw, gh) = (gx1 - gx0, gy1 - gy0);
        let mut m = vec![false; gw * gh];
        for &p in &pix {
            m[(p / w - gy0) * gw + (p % w - gx0)] = true;
        }
        let big = dilate_square(&m, gw, gh, half);
        let small3 = dilate_square(&m, gw, gh, 1);
        let mut ring: Vec<f32> = Vec::new();
        for gy in 0..gh {
            for gx in 0..gw {
                let g = gy * gw + gx;
                if big[g] && !small3[g] {
                    ring.push(ll[(gy + gy0) * w + gx + gx0]);
                }
            }
        }
        if ring.len() < 8 {
            continue;
        }
        ring.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        let med_ring = if ring.len() % 2 == 1 { ring[ring.len() / 2] } else { 0.5 * (ring[ring.len() / 2 - 1] + ring[ring.len() / 2]) };
        let around = 0.5 * (med_ring + percentile_sorted(&ring, 25.0));
        let mut l_in: Vec<f32> = pix.iter().map(|&p| ll[p]).collect();
        let inside = median(&mut l_in);
        let dark = ((55.0 - around) / 30.0).clamp(0.0, 1.0);
        let pop = ((inside - around + 5.0) / 25.0).clamp(0.0, 1.0);
        if dark * 0.7 + pop * 0.3 < 0.25 {
            continue;
        }
        let mut av: Vec<f32> = pix.iter().map(|&p| aa[p]).collect();
        let mut bv: Vec<f32> = pix.iter().map(|&p| bb[p]).collect();
        let mut cv: Vec<f32> = pix.iter().map(|&p| chroma[p]).collect();
        let (ma, mb, mc) = (median(&mut av), median(&mut bv), median(&mut cv));
        let score = (mc / 60.0).clamp(0.0, 1.0) * 0.4 + dark * 0.4 + pop * 0.2;
        found.push(Eye {
            x: sx / area as f64 / w as f64,
            y: sy / area as f64 / h as f64,
            r: (r * k / w0.max(h0) as f32) as f64,
            hue: hue_name(ma, mb),
            score: score as f64,
            chroma: mc as f64,
        });
    }
    // les paires d'yeux : même couleur, même taille, à peu près à la même hauteur
    let snapshot = found.clone();
    for (i, e) in found.iter_mut().enumerate() {
        for (j, o) in snapshot.iter().enumerate() {
            let big_r = o.r.max(e.r);
            if i != j && o.hue == e.hue && (o.r - e.r).abs() < 0.45 * big_r && (o.y - e.y).abs() < 4.0 * big_r * w0.max(h0) as f64 / h0 as f64 {
                e.score += 0.35;
                break;
            }
        }
    }
    found.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal));
    found.truncate(max_eyes);
    found
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Fond sombre, iris sombre et pupille colorée de rayon `r` au centre (cx, cy).
    fn picture(w: usize, h: usize, eyes: &[(usize, usize, usize, [u8; 3])]) -> Vec<u8> {
        let mut v = vec![0u8; w * h * 3];
        for p in v.chunks_mut(3) {
            p.copy_from_slice(&[60, 50, 45]);
        }
        for &(cx, cy, r, col) in eyes {
            for y in 0..h {
                for x in 0..w {
                    let d = (((x as f32 - cx as f32).powi(2) + (y as f32 - cy as f32).powi(2)) as f32).sqrt();
                    let i = (y * w + x) * 3;
                    if d <= r as f32 {
                        v[i..i + 3].copy_from_slice(&col);
                    } else if d <= r as f32 * 2.6 {
                        v[i..i + 3].copy_from_slice(&[18, 14, 12]);
                    }
                }
            }
        }
        v
    }

    #[test]
    fn trouve_une_paire_d_yeux_rouges() {
        let img = picture(600, 400, &[(200, 200, 8, [210, 40, 40]), (330, 202, 8, [205, 45, 40])]);
        let eyes = find_eyeshine(&img, 600, 400, 4);
        assert_eq!(eyes.len(), 2, "{eyes:?}");
        for e in &eyes {
            assert_eq!(e.hue, "rouge");
            assert!(e.chroma > 45.0);
            assert!((e.r - 8.0 / 600.0).abs() < 0.004, "{e:?}");
        }
        let mut xs: Vec<f64> = eyes.iter().map(|e| e.x * 600.0).collect();
        xs.sort_by(|a, b| a.partial_cmp(b).unwrap());
        assert!((xs[0] - 200.0).abs() < 2.0 && (xs[1] - 330.0).abs() < 2.0, "{xs:?}");
    }

    #[test]
    fn reconnait_un_reflet_vert_d_animal() {
        let img = picture(500, 400, &[(250, 200, 7, [60, 200, 70])]);
        let eyes = find_eyeshine(&img, 500, 400, 4);
        assert_eq!(eyes.len(), 1, "{eyes:?}");
        assert_eq!(eyes[0].hue, "vert");
    }

    #[test]
    fn rien_dans_une_photo_sans_reflet() {
        let img = picture(500, 400, &[]);
        assert!(find_eyeshine(&img, 500, 400, 4).is_empty());
        // un grand aplat rouge (vêtement) n'est pas une pupille
        let mut big = picture(500, 400, &[]);
        for y in 100..300 {
            for x in 100..300 {
                let i = (y * 500 + x) * 3;
                big[i..i + 3].copy_from_slice(&[200, 30, 30]);
            }
        }
        assert!(find_eyeshine(&big, 500, 400, 4).is_empty());
        // entrée trop petite ou tronquée : liste vide, pas de panique
        assert!(find_eyeshine(&[0u8; 12], 2, 2, 4).is_empty());
    }
}
