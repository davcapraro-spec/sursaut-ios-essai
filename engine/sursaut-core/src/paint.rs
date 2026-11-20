// SPDX-License-Identifier: GPL-3.0-or-later
//! Peinture sur les pixels d'un calque : pinceau, gomme, tampon de duplication, pot de peinture et dégradé.
//! Les images sont en RGBA 8 bits à alpha droit (non prémultiplié), rangées ligne par ligne.
//!
//! Un trait se fait par segments (`paint_segment`) sur un tampon de couverture (`cov`, 0..1 par pixel) : les empreintes qui se recouvrent
//! s'accumulent selon le « flux », mais jamais au-delà de l'opacité du trait. Les pixels touchés sont toujours recalculés depuis
//! l'image `orig` d'avant le trait, donc deux empreintes superposées ne se somment pas et un segment peut être rejoué sans dérive.

/// Ce que dépose le pinceau.
#[derive(Clone, Copy)]
pub enum Mode<'a> {
    /// Une couleur unie.
    Color([u8; 3]),
    /// Efface (diminue l'opacité des pixels).
    Erase,
    /// Copie l'image `src` (RGBA, même taille) décalée de (dx, dy) : le tampon de duplication.
    Clone { src: &'a [u8], dx: i32, dy: i32 },
}

/// Profil d'une empreinte : 1 au centre, 0 au bord, bord de dureté réglable (au moins 1 pixel de lissage).
#[inline]
fn profile(dist: f32, radius: f32, hardness: f32) -> f32 {
    let ramp = (radius * (1.0 - hardness.clamp(0.0, 1.0))).max(1.0);
    let t = ((radius - dist + 0.5) / ramp).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

/// Pose `color` d'opacité `ca` (0..1) sur le pixel `base` : « normal » en alpha droit.
#[inline]
fn over(out: &mut [u8], base: &[u8], color: [f32; 3], ca: f32) {
    let oa = base[3] as f32 / 255.0;
    let na = oa + ca * (1.0 - oa);
    if na <= 0.0 {
        out[..4].copy_from_slice(&[base[0], base[1], base[2], 0]);
        return;
    }
    for c in 0..3 {
        let v = (color[c] * ca + base[c] as f32 * oa * (1.0 - ca)) / na;
        out[c] = (v + 0.5).clamp(0.0, 255.0) as u8;
    }
    out[3] = (na * 255.0 + 0.5).clamp(0.0, 255.0) as u8;
}

#[inline]
fn erase(out: &mut [u8], base: &[u8], ca: f32) {
    out[..3].copy_from_slice(&base[..3]);
    out[3] = (base[3] as f32 * (1.0 - ca) + 0.5).clamp(0.0, 255.0) as u8;
}

/// Un segment de trait de (x0, y0) à (x1, y1), en pixels de l'image ; rend la distance parcourue depuis la dernière empreinte
/// (à repasser au segment suivant ; au début d'un trait, passer une grande valeur pour poser une empreinte au point de départ).
/// `radius` en pixels ; `hardness`, `opacity`, `flow` entre 0 et 1 ; `spacing` en fraction du diamètre ; `limit` : plan 0..255 (une sélection) hors
/// duquel on ne peint pas.
#[allow(clippy::too_many_arguments)]
pub fn paint_segment(
    image: &mut [u8], orig: &[u8], cov: &mut [f32], w: usize, h: usize, (x0, y0, x1, y1): (f32, f32, f32, f32), radius: f32, hardness: f32,
    opacity: f32, flow: f32, spacing: f32, carry: f32, mode: Mode, limit: Option<&[u8]>,
) -> f32 {
    assert_eq!(image.len(), w * h * 4);
    assert_eq!(orig.len(), w * h * 4);
    assert_eq!(cov.len(), w * h);
    let radius = radius.max(0.5);
    let step = (spacing * 2.0 * radius).max(1.0);
    let len = ((x1 - x0).powi(2) + (y1 - y0).powi(2)).sqrt();
    let mut pos = if carry >= step { 0.0 } else { step - carry };
    let mut last = f32::NAN;
    while pos <= len + 1e-4 {
        let t = if len > 0.0 { pos / len } else { 0.0 };
        dab(image, orig, cov, w, h, x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, radius, hardness, opacity, flow, mode, limit);
        last = pos;
        pos += step;
    }
    if last.is_nan() {
        carry + len
    } else {
        len - last
    }
}

#[allow(clippy::too_many_arguments)]
fn dab(
    image: &mut [u8], orig: &[u8], cov: &mut [f32], w: usize, h: usize, cx: f32, cy: f32, radius: f32, hardness: f32, opacity: f32, flow: f32,
    mode: Mode, limit: Option<&[u8]>,
) {
    let x0 = ((cx - radius - 1.0).floor().max(0.0)) as usize;
    let y0 = ((cy - radius - 1.0).floor().max(0.0)) as usize;
    let x1 = (((cx + radius + 2.0).ceil()).min(w as f32)).max(0.0) as usize;
    let y1 = (((cy + radius + 2.0).ceil()).min(h as f32)).max(0.0) as usize;
    for y in y0..y1 {
        for x in x0..x1 {
            let d = ((x as f32 + 0.5 - cx).powi(2) + (y as f32 + 0.5 - cy).powi(2)).sqrt();
            let a = profile(d, radius, hardness) * flow;
            if a <= 0.0 {
                continue;
            }
            let i = y * w + x;
            cov[i] = 1.0 - (1.0 - cov[i]) * (1.0 - a);
            let mut ca = cov[i] * opacity;
            if let Some(l) = limit {
                ca *= l[i] as f32 / 255.0;
            }
            let (o, b) = (&mut image[i * 4..i * 4 + 4], &orig[i * 4..i * 4 + 4]);
            match mode {
                Mode::Color(c) => over(o, b, [c[0] as f32, c[1] as f32, c[2] as f32], ca),
                Mode::Erase => erase(o, b, ca),
                Mode::Clone { src, dx, dy } => {
                    let (sx, sy) = (x as i64 + dx as i64, y as i64 + dy as i64);
                    if sx < 0 || sy < 0 || sx >= w as i64 || sy >= h as i64 {
                        o.copy_from_slice(b);
                        continue;
                    }
                    let s = &src[(sy as usize * w + sx as usize) * 4..][..4];
                    over(o, b, [s[0] as f32, s[1] as f32, s[2] as f32], ca * s[3] as f32 / 255.0);
                }
            }
        }
    }
}

/// Remplit (ou efface, `erase_it`) les pixels du plan `mask` (0..255, taille de l'image) avec `color` à l'opacité donnée ; `limit` : sélection.
pub fn fill_mask(image: &mut [u8], mask: &[u8], w: usize, h: usize, color: [u8; 3], opacity: f32, erase_it: bool, limit: Option<&[u8]>) {
    assert_eq!(image.len(), w * h * 4);
    assert_eq!(mask.len(), w * h);
    let col = [color[0] as f32, color[1] as f32, color[2] as f32];
    for i in 0..w * h {
        let mut ca = mask[i] as f32 / 255.0 * opacity;
        if let Some(l) = limit {
            ca *= l[i] as f32 / 255.0;
        }
        if ca <= 0.0 {
            continue;
        }
        let base: [u8; 4] = image[i * 4..i * 4 + 4].try_into().unwrap();
        if erase_it {
            erase(&mut image[i * 4..i * 4 + 4], &base, ca);
        } else {
            over(&mut image[i * 4..i * 4 + 4], &base, col, ca);
        }
    }
}

/// Zone de couleur proche du pixel (x, y) (les quatre canaux, RGBA, comptent) : le pot de peinture. `tolerance` : écart maximal par canal ;
/// `contiguous` : seulement la zone reliée au point (4 voisins). Le bord est adouci d'un pixel (anti-crénelage). `None` si le point est hors de l'image.
pub fn similar_region(rgba: &[u8], w: usize, h: usize, x: usize, y: usize, tolerance: u8, contiguous: bool) -> Option<Vec<u8>> {
    assert_eq!(rgba.len(), w * h * 4);
    if x >= w || y >= h {
        return None;
    }
    let s0 = (y * w + x) * 4;
    let seed = [rgba[s0], rgba[s0 + 1], rgba[s0 + 2], rgba[s0 + 3]];
    let close = |i: usize| (0..4).all(|c| rgba[i * 4 + c].abs_diff(seed[c]) <= tolerance);
    let mut out = vec![0u8; w * h];
    if contiguous {
        let mut stack = vec![y * w + x];
        out[y * w + x] = 255;
        while let Some(i) = stack.pop() {
            let (cx, cy) = (i % w, i / w);
            let mut push = |j: usize| {
                if out[j] == 0 && close(j) {
                    out[j] = 255;
                    stack.push(j);
                }
            };
            if cx > 0 {
                push(i - 1);
            }
            if cx + 1 < w {
                push(i + 1);
            }
            if cy > 0 {
                push(i - w);
            }
            if cy + 1 < h {
                push(i + w);
            }
        }
    } else {
        for i in 0..w * h {
            if close(i) {
                out[i] = 255;
            }
        }
    }
    Some(soften(&out, w, h))
}

/// Flou carré 3 × 3 d'un plan (bords : on répète le pixel du bord).
fn soften(m: &[u8], w: usize, h: usize) -> Vec<u8> {
    let mut out = vec![0u8; w * h];
    for y in 0..h {
        for x in 0..w {
            let mut s = 0u32;
            for dy in -1i64..=1 {
                for dx in -1i64..=1 {
                    let (xx, yy) = ((x as i64 + dx).clamp(0, w as i64 - 1) as usize, (y as i64 + dy).clamp(0, h as i64 - 1) as usize);
                    s += m[yy * w + xx] as u32;
                }
            }
            out[y * w + x] = ((s + 4) / 9) as u8;
        }
    }
    out
}

/// Dégradé de `c0` (au point de départ) à `c1` (au point d'arrivée), posé sur l'image à l'opacité donnée. Formes : « linear », « radial »,
/// « reflected » (miroir autour du départ), « diamond » et « angle » (tour complet autour du départ). Les couleurs sont RGBA : un dégradé vers
/// un alpha 0 donne un dégradé vers le transparent (mélange prémultiplié : pas de liseré sombre). `limit` : sélection.
#[allow(clippy::too_many_arguments)]
pub fn gradient(
    image: &mut [u8], w: usize, h: usize, (x0, y0, x1, y1): (f32, f32, f32, f32), kind: &str, c0: [u8; 4], c1: [u8; 4], opacity: f32, erase_it: bool,
    limit: Option<&[u8]>,
) {
    assert_eq!(image.len(), w * h * 4);
    let (vx, vy) = (x1 - x0, y1 - y0);
    let len2 = (vx * vx + vy * vy).max(1e-6);
    let len = len2.sqrt();
    let (a0, a1) = (c0[3] as f32 / 255.0, c1[3] as f32 / 255.0);
    for y in 0..h {
        for x in 0..w {
            let (px, py) = (x as f32 + 0.5 - x0, y as f32 + 0.5 - y0);
            let t = match kind {
                "radial" => (px * px + py * py).sqrt() / len,
                "reflected" => ((px * vx + py * vy) / len2).abs(),
                "diamond" => (px.abs() + py.abs()) / len,
                "angle" => {
                    let base = vy.atan2(vx);
                    (((py.atan2(px) - base) / std::f32::consts::TAU).rem_euclid(1.0)).clamp(0.0, 1.0)
                }
                _ => (px * vx + py * vy) / len2,
            }
            .clamp(0.0, 1.0);
            let a = a0 + (a1 - a0) * t;
            let mut ca = a * opacity;
            if let Some(l) = limit {
                ca *= l[y * w + x] as f32 / 255.0;
            }
            if ca <= 0.0 {
                continue;
            }
            let i = (y * w + x) * 4;
            let base: [u8; 4] = image[i..i + 4].try_into().unwrap();
            if erase_it {
                erase(&mut image[i..i + 4], &base, ca);
                continue;
            }
            let mut col = [0f32; 3];
            if a > 0.0 {
                for c in 0..3 {
                    col[c] = (c0[c] as f32 * a0 * (1.0 - t) + c1[c] as f32 * a1 * t) / a;
                }
            }
            over(&mut image[i..i + 4], &base, col, ca);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn blank(w: usize, h: usize) -> Vec<u8> {
        vec![0u8; w * h * 4]
    }

    fn px(img: &[u8], w: usize, x: usize, y: usize) -> [u8; 4] {
        img[(y * w + x) * 4..][..4].try_into().unwrap()
    }

    #[test]
    fn a_dab_paints_a_disk_and_leaves_the_rest() {
        let (w, h) = (40, 40);
        let mut img = blank(w, h);
        let orig = img.clone();
        let mut cov = vec![0f32; w * h];
        paint_segment(&mut img, &orig, &mut cov, w, h, (20.0, 20.0, 20.0, 20.0), 6.0, 1.0, 1.0, 1.0, 0.25, 1e9, Mode::Color([200, 10, 30]), None);
        assert_eq!(px(&img, w, 20, 20), [200, 10, 30, 255]);
        assert_eq!(px(&img, w, 2, 2), [0, 0, 0, 0]);
        assert_eq!(px(&img, w, 20, 30)[3], 0, "hors du disque");
    }

    #[test]
    fn overlapping_dabs_never_exceed_the_stroke_opacity() {
        let (w, h) = (60, 20);
        let mut img = blank(w, h);
        let orig = img.clone();
        let mut cov = vec![0f32; w * h];
        paint_segment(&mut img, &orig, &mut cov, w, h, (5.0, 10.0, 55.0, 10.0), 5.0, 1.0, 0.5, 1.0, 0.1, 1e9, Mode::Color([255, 255, 255]), None);
        let a = px(&img, w, 30, 10)[3] as i32;
        assert!((a - 128).abs() <= 1, "opacité du trait = 50 % même avec des dizaines d'empreintes (alpha {a})");
    }

    #[test]
    fn a_stroke_in_two_segments_equals_one_segment() {
        let (w, h) = (80, 30);
        let run = |parts: &[(f32, f32, f32, f32)]| {
            let mut img = blank(w, h);
            let orig = img.clone();
            let mut cov = vec![0f32; w * h];
            let mut carry = 1e9;
            for p in parts {
                carry = paint_segment(&mut img, &orig, &mut cov, w, h, *p, 4.0, 0.8, 1.0, 1.0, 0.25, carry, Mode::Color([9, 99, 199]), None);
            }
            img
        };
        let whole = run(&[(10.0, 15.0, 70.0, 15.0)]);
        let split = run(&[(10.0, 15.0, 33.3, 15.0), (33.3, 15.0, 70.0, 15.0)]);
        let diff = whole.iter().zip(&split).map(|(a, b)| (*a as i32 - *b as i32).abs()).max().unwrap();
        assert!(diff <= 3, "écart {diff}");
    }

    #[test]
    fn soft_brush_fades_to_the_edge() {
        let (w, h) = (50, 50);
        let mut img = blank(w, h);
        let orig = img.clone();
        let mut cov = vec![0f32; w * h];
        paint_segment(&mut img, &orig, &mut cov, w, h, (25.0, 25.0, 25.0, 25.0), 15.0, 0.0, 1.0, 1.0, 0.25, 1e9, Mode::Color([255, 0, 0]), None);
        let (c, m, e) = (px(&img, w, 25, 25)[3], px(&img, w, 33, 25)[3], px(&img, w, 39, 25)[3]);
        assert!(c > m && m > e && e < 60, "{c} {m} {e}");
    }

    #[test]
    fn painting_over_a_color_blends_it_and_the_eraser_removes_it() {
        let (w, h) = (20, 20);
        let mut img: Vec<u8> = (0..w * h).flat_map(|_| [0u8, 0, 255, 255]).collect();
        let orig = img.clone();
        let mut cov = vec![0f32; w * h];
        paint_segment(&mut img, &orig, &mut cov, w, h, (10.0, 10.0, 10.0, 10.0), 5.0, 1.0, 0.5, 1.0, 0.25, 1e9, Mode::Color([255, 0, 0]), None);
        let p = px(&img, w, 10, 10);
        assert!(p[0] > 120 && p[0] < 135 && p[2] > 120 && p[2] < 135 && p[3] == 255, "{p:?}");
        let orig2 = img.clone();
        let mut cov2 = vec![0f32; w * h];
        paint_segment(&mut img, &orig2, &mut cov2, w, h, (10.0, 10.0, 10.0, 10.0), 5.0, 1.0, 1.0, 1.0, 0.25, 1e9, Mode::Erase, None);
        assert_eq!(px(&img, w, 10, 10)[3], 0);
        assert_eq!(px(&img, w, 1, 1), [0, 0, 255, 255]);
    }

    #[test]
    fn the_limit_plane_confines_the_paint() {
        let (w, h) = (30, 30);
        let mut img = blank(w, h);
        let orig = img.clone();
        let mut cov = vec![0f32; w * h];
        let limit: Vec<u8> = (0..w * h).map(|i| if i % w < 15 { 255 } else { 0 }).collect();
        paint_segment(&mut img, &orig, &mut cov, w, h, (15.0, 15.0, 15.0, 15.0), 8.0, 1.0, 1.0, 1.0, 0.25, 1e9, Mode::Color([1, 2, 3]), Some(&limit));
        assert_eq!(px(&img, w, 12, 15)[3], 255);
        assert_eq!(px(&img, w, 18, 15)[3], 0);
    }

    #[test]
    fn clone_copies_the_offset_source() {
        let (w, h) = (40, 20);
        let mut src = blank(w, h);
        for y in 0..h {
            for x in 30..40 {
                src[(y * w + x) * 4..][..4].copy_from_slice(&[10, 200, 10, 255]);
            }
        }
        let mut img = blank(w, h);
        let orig = img.clone();
        let mut cov = vec![0f32; w * h];
        paint_segment(&mut img, &orig, &mut cov, w, h, (8.0, 10.0, 8.0, 10.0), 3.0, 1.0, 1.0, 1.0, 0.25, 1e9, Mode::Clone { src: &src, dx: 25, dy: 0 }, None);
        assert_eq!(px(&img, w, 8, 10), [10, 200, 10, 255], "x = 8 + 25 = 33 est dans la bande verte");
        let mut img2 = blank(w, h);
        let mut cov2 = vec![0f32; w * h];
        paint_segment(&mut img2, &orig, &mut cov2, w, h, (8.0, 10.0, 8.0, 10.0), 3.0, 1.0, 1.0, 1.0, 0.25, 1e9, Mode::Clone { src: &src, dx: -100, dy: 0 }, None);
        assert_eq!(px(&img2, w, 8, 10)[3], 0, "source hors de l'image : rien");
    }

    #[test]
    fn similar_region_respects_contiguity_and_tolerance() {
        let (w, h) = (20, 10);
        let mut img: Vec<u8> = (0..w * h).flat_map(|_| [100u8, 100, 100, 255]).collect();
        for y in 0..h {
            img[(y * w + 10) * 4..][..4].copy_from_slice(&[250, 0, 0, 255]);        // un mur rouge
            img[(y * w + 15) * 4..][..4].copy_from_slice(&[104, 100, 100, 255]);   // presque gris
        }
        let region = similar_region(&img, w, h, 2, 5, 8, true).unwrap();
        assert_eq!(region[5 * w + 2], 255);
        assert!(region[5 * w + 17] < 10, "derrière le mur : pas relié");
        let all = similar_region(&img, w, h, 2, 5, 8, false).unwrap();
        assert_eq!(all[5 * w + 17], 255);
        assert!(all[5 * w + 15] > 200, "104 est dans la tolérance de 8");
        assert!(all[5 * w + 10] < 200, "le mur (1 pixel) est adouci mais pas rempli");
        assert!(similar_region(&img, w, h, 99, 0, 8, true).is_none());
    }

    #[test]
    fn fill_mask_paints_and_erases_by_coverage() {
        let (w, h) = (10, 10);
        let mut img = blank(w, h);
        let mask: Vec<u8> = (0..w * h).map(|i| if i % w < 5 { 255 } else { 0 }).collect();
        fill_mask(&mut img, &mask, w, h, [10, 20, 30], 1.0, false, None);
        assert_eq!(px(&img, w, 2, 2), [10, 20, 30, 255]);
        assert_eq!(px(&img, w, 7, 2)[3], 0);
        fill_mask(&mut img, &mask, w, h, [0, 0, 0], 1.0, true, None);
        assert_eq!(px(&img, w, 2, 2)[3], 0);
    }

    #[test]
    fn gradients_run_from_start_to_end_color() {
        let (w, h) = (100, 10);
        let mut img = blank(w, h);
        gradient(&mut img, w, h, (0.0, 5.0, 100.0, 5.0), "linear", [255, 0, 0, 255], [0, 0, 255, 255], 1.0, false, None);
        let (l, m, r) = (px(&img, w, 1, 5), px(&img, w, 50, 5), px(&img, w, 98, 5));
        assert!(l[0] > 240 && l[2] < 15);
        assert!((m[0] as i32 - 127).abs() < 8 && (m[2] as i32 - 128).abs() < 8);
        assert!(r[2] > 240 && r[0] < 15);
        let mut t = blank(w, h);
        gradient(&mut t, w, h, (0.0, 5.0, 100.0, 5.0), "linear", [255, 0, 0, 255], [0, 0, 255, 0], 1.0, false, None);
        let (a, b) = (px(&t, w, 2, 5), px(&t, w, 95, 5));
        assert!(a[3] > 240 && b[3] < 20, "vers le transparent : {a:?} {b:?}");
        assert!(b[0] > 200, "la couleur reste rouge là où il reste de l'opacité (pas de liseré sombre) : {b:?}");
    }

    #[test]
    fn radial_gradient_is_symmetric() {
        let (w, h) = (41, 41);
        let mut img = blank(w, h);
        gradient(&mut img, w, h, (20.5, 20.5, 40.5, 20.5), "radial", [255, 255, 255, 255], [0, 0, 0, 255], 1.0, false, None);
        assert_eq!(px(&img, w, 10, 20), px(&img, w, 30, 20));
        assert!(px(&img, w, 20, 20)[0] > px(&img, w, 35, 20)[0]);
    }
}
