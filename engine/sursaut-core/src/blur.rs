// SPDX-License-Identifier: GPL-3.0-or-later
//! Flou de boîte séparable (trois passes ≈ gaussien), sommes cumulées en float32 comme la version Python.
use rayon::prelude::*;

/// Une passe horizontale : chaque ligne indépendante.
fn pass_h(src: &[f32], w: usize, h: usize, radius: usize) -> Vec<f32> {
    let size = 2 * radius + 1;
    let inv = 1.0f32 / size as f32;
    let mut out = vec![0f32; w * h];
    out.par_chunks_mut(w).zip(src.par_chunks(w)).for_each(|(o, row)| {
        let plen = w + 2 * radius + 1;
        let mut c = vec![0f32; plen];
        let mut acc = 0f32;
        for (i, ci) in c.iter_mut().enumerate() {
            let s = (i as isize - (radius as isize + 1)).clamp(0, w as isize - 1) as usize;
            acc += row[s];
            *ci = acc;
        }
        for (i, oi) in o.iter_mut().enumerate() {
            *oi = (c[i + size] - c[i]) * inv;
        }
    });
    out
}

/// Une passe verticale : somme cumulée par colonne (rangées parcourues dans l'ordre), sorties en parallèle.
fn pass_v(src: &[f32], w: usize, h: usize, radius: usize) -> Vec<f32> {
    let size = 2 * radius + 1;
    let inv = 1.0f32 / size as f32;
    let plen = h + 2 * radius + 1;
    let mut c = vec![0f32; plen * w];
    for i in 0..plen {
        let s = (i as isize - (radius as isize + 1)).clamp(0, h as isize - 1) as usize;
        let (prev, cur) = c.split_at_mut(i * w);
        let cur = &mut cur[..w];
        let src_row = &src[s * w..(s + 1) * w];
        if i == 0 {
            cur.copy_from_slice(src_row);
        } else {
            let p = &prev[(i - 1) * w..i * w];
            for x in 0..w {
                cur[x] = p[x] + src_row[x];
            }
        }
    }
    let mut out = vec![0f32; w * h];
    out.par_chunks_mut(w).enumerate().for_each(|(y, o)| {
        let hi = &c[(y + size) * w..(y + size + 1) * w];
        let lo = &c[y * w..(y + 1) * w];
        for x in 0..w {
            o[x] = (hi[x] - lo[x]) * inv;
        }
    });
    out
}

fn blur_exact(a: &[f32], w: usize, h: usize, radius: usize) -> Vec<f32> {
    let mut cur = a.to_vec();
    for _ in 0..3 {
        cur = pass_h(&cur, w, h, radius);
        cur = pass_v(&cur, w, h, radius);
    }
    cur
}
// NB : la version Python enchaîne axe 0 puis axe 1 à chaque tour ; l'ordre ne change pas le résultat
// à la précision des sommes cumulées, mais on le reproduit à l'identique ci-dessous.
fn blur_exact_py_order(a: &[f32], w: usize, h: usize, radius: usize) -> Vec<f32> {
    let mut cur = a.to_vec();
    for _ in 0..3 {
        cur = pass_v(&cur, w, h, radius);
        cur = pass_h(&cur, w, h, radius);
    }
    cur
}

/// Réduit le plan par blocs de `f × f` puis le floute (partie commune des deux versions de `box_blur`).
fn reduce_and_blur(a: &[f32], w: usize, h: usize, radius: usize, f: usize) -> (Vec<f32>, usize, usize, usize, usize) {
    let (hh, ww) = (h / f * f, w / f * f);
    let (sh, sw) = (hh / f, ww / f);
    let mut small = vec![0f32; sh * sw];
    small.par_chunks_mut(sw).enumerate().for_each(|(by, row)| {
        for (bx, v) in row.iter_mut().enumerate() {
            let mut s = 0f32;
            for dy in 0..f {
                for dx in 0..f {
                    s += a[(by * f + dy) * w + bx * f + dx];
                }
            }
            *v = s / (f * f) as f32;
        }
    });
    let small = blur_exact_py_order(&small, sw, sh, (radius / f).max(1));
    (small, sw, sh, ww, hh)
}

/// Flou d'un plan (hauteur × largeur). Grands rayons : on floute une version réduite puis on agrandit (au plus proche voisin : en escalier).
pub fn box_blur(a: &[f32], w: usize, h: usize, radius: usize) -> Vec<f32> {
    let _ = blur_exact;
    let f = radius / 5;
    if f < 2 {
        return blur_exact_py_order(a, w, h, radius);
    }
    let (small, sw, _sh, ww, hh) = reduce_and_blur(a, w, h, radius, f);
    let mut out = vec![0f32; w * h];
    out.par_chunks_mut(w).enumerate().for_each(|(y, row)| {
        let sy = (y.min(hh.saturating_sub(1))) / f;
        for (x, v) in row.iter_mut().enumerate() {
            let sx = (x.min(ww.saturating_sub(1))) / f;
            *v = small[sy * sw + sx];
        }
    });
    out
}

/// Comme `box_blur`, mais la version réduite est agrandie par interpolation bilinéaire : pas de marches de `radius / 5` pixels dans un dégradé
/// (pour les masques et les effets de calques, où l'escalier se voit ; `box_blur` reste inchangé pour le développement).
pub fn box_blur_smooth(a: &[f32], w: usize, h: usize, radius: usize) -> Vec<f32> {
    let f = radius / 5;
    if f < 2 {
        return blur_exact_py_order(a, w, h, radius);
    }
    let (small, sw, sh, _ww, _hh) = reduce_and_blur(a, w, h, radius, f);
    if sw < 2 || sh < 2 {
        return box_blur(a, w, h, radius);
    }
    let mut out = vec![0f32; w * h];
    out.par_chunks_mut(w).enumerate().for_each(|(y, row)| {
        let fy = ((y as f32 + 0.5) / f as f32 - 0.5).clamp(0.0, (sh - 1) as f32);
        let y0 = fy.floor() as usize;
        let y1 = (y0 + 1).min(sh - 1);
        let ty = fy - y0 as f32;
        for (x, v) in row.iter_mut().enumerate() {
            let fx = ((x as f32 + 0.5) / f as f32 - 0.5).clamp(0.0, (sw - 1) as f32);
            let x0 = fx.floor() as usize;
            let x1 = (x0 + 1).min(sw - 1);
            let tx = fx - x0 as f32;
            let top = small[y0 * sw + x0] * (1.0 - tx) + small[y0 * sw + x1] * tx;
            let bot = small[y1 * sw + x0] * (1.0 - tx) + small[y1 * sw + x1] * tx;
            *v = top * (1.0 - ty) + bot * ty;
        }
    });
    out
}

#[cfg(test)]
mod smooth_tests {
    use super::*;

    #[test]
    fn smooth_blur_has_no_big_steps_where_the_plain_one_has() {
        let (w, h) = (400usize, 120usize);
        let a: Vec<f32> = (0..w * h).map(|i| if (i % w) < w / 2 { 255.0 } else { 0.0 }).collect();
        let step = |v: &[f32]| (0..w - 1).map(|x| (v[h / 2 * w + x] - v[h / 2 * w + x + 1]).abs()).fold(0f32, f32::max);
        let plain = box_blur(&a, w, h, 50);
        let smooth = box_blur_smooth(&a, w, h, 50);
        assert!(step(&plain) > 8.0, "l'escalier du flou simple : {}", step(&plain));
        assert!(step(&smooth) < 4.0, "le flou lissé ne doit pas avoir de marche : {}", step(&smooth));
        // même moyenne et mêmes valeurs aux extrémités
        assert!((smooth[h / 2 * w] - 255.0).abs() < 1.0 && smooth[h / 2 * w + w - 1].abs() < 1.0);
    }

    #[test]
    fn small_radius_is_identical() {
        let (w, h) = (30usize, 20usize);
        let a: Vec<f32> = (0..w * h).map(|i| (i * 7 % 255) as f32).collect();
        assert_eq!(box_blur(&a, w, h, 3), box_blur_smooth(&a, w, h, 3));
    }
}

#[cfg(test)]
mod scale_fidelity_tests {
    use super::*;

    /// Image analytique (marche, disque, dégradé) vue à deux tailles : le flou d'un rayon proportionnel au grand côté doit donner presque le même
    /// résultat une fois la grande version ramenée à la petite (c'est le « aperçu = export »).
    fn scene(w: usize, h: usize) -> Vec<f32> {
        (0..w * h)
            .map(|i| {
                let (x, y) = ((i % w) as f32 / w as f32, (i / w) as f32 / h as f32);
                let disc = ((x - 0.65).powi(2) + (y - 0.45).powi(2)).sqrt() < 0.18;
                let step = if x < 0.3 { 0.15 } else { 0.0 };
                0.2 + 0.4 * y + step + if disc { 0.35 } else { 0.0 }
            })
            .collect()
    }

    fn reduce(a: &[f32], w: usize, f: usize) -> (Vec<f32>, usize) {
        let (sw, sh) = (w / f, a.len() / w / f);
        let mut out = vec![0f32; sw * sh];
        for y in 0..sh {
            for x in 0..sw {
                let mut s = 0f32;
                for dy in 0..f {
                    for dx in 0..f {
                        s += a[(y * f + dy) * w + x * f + dx];
                    }
                }
                out[y * sw + x] = s / (f * f) as f32;
            }
        }
        (out, sw)
    }

    fn error(blur: fn(&[f32], usize, usize, usize) -> Vec<f32>, frac: f64) -> (f32, f32) {
        let (sw, sh) = (600usize, 400usize);
        let f = 4usize;
        let (bw, bh) = (sw * f, sh * f);
        let small = scene(sw, sh);
        let big = scene(bw, bh);
        let rs = ((sw as f64 * frac) as usize).max(2);
        let rb = ((bw as f64 * frac) as usize).max(2);
        let a = blur(&small, sw, sh, rs);
        let (b, _) = reduce(&blur(&big, bw, bh, rb), bw, f);
        let m = 2 * rb / f + 2; // on ignore les bords (le flou y est traité à part)
        let mut worst = 0f32;
        let mut sum = 0f64;
        let mut n = 0u64;
        for y in m..sh - m {
            for x in m..sw - m {
                let d = (a[y * sw + x] - b[y * sw + x]).abs();
                worst = worst.max(d);
                sum += d as f64;
                n += 1;
            }
        }
        (worst, (sum / n as f64) as f32)
    }

    #[test]
    fn smooth_blur_is_closer_to_itself_across_sizes_than_the_plain_one() {
        // mesuré : rayon 1,2 % : écart max 0,0200 (simple) → 0,0170 (lissé) ; rayon 3 % : 0,0290 → 0,0055, écart moyen 0,0020 → 0,0007
        for frac in [0.012, 0.03] {
            let (pw, pm) = error(box_blur, frac);
            let (sw_, sm) = error(box_blur_smooth, frac);
            assert!(sw_ <= pw && sm <= pm, "rayon {frac} : simple ({pw}, {pm}) lissé ({sw_}, {sm})");
        }
        let (pw, _) = error(box_blur, 0.03);
        let (sw_, _) = error(box_blur_smooth, 0.03);
        assert!(sw_ < pw / 3.0, "grand rayon : l'écart max doit tomber d'au moins les deux tiers ({pw} → {sw_})");
    }
}
