// SPDX-License-Identifier: GPL-3.0-or-later
//! Outils de sélection : baguette magique (zone de couleur proche) et agrandissement / réduction d'une sélection.
//! Les sélections sont des plans 8 bits (0 = hors sélection, 255 = sélectionné).
use rayon::prelude::*;

/// Baguette magique : les pixels dont la couleur est proche de celle du pixel (`x`, `y`).
/// `tolerance` (0..255) : écart maximal sur chacun des trois canaux. `contiguous` : seulement la zone reliée au point cliqué (4 voisins) ;
/// sinon tous les pixels de la photo qui ressemblent à celui-là. Retourne `None` si le point est hors de l'image.
pub fn magic_wand(rgb: &[u8], w: usize, h: usize, x: usize, y: usize, tolerance: u8, contiguous: bool) -> Option<Vec<u8>> {
    assert_eq!(rgb.len(), w * h * 3);
    if x >= w || y >= h {
        return None;
    }
    let seed = [rgb[(y * w + x) * 3], rgb[(y * w + x) * 3 + 1], rgb[(y * w + x) * 3 + 2]];
    let close = |i: usize| (0..3).all(|c| rgb[i * 3 + c].abs_diff(seed[c]) <= tolerance);
    let mut out = vec![0u8; w * h];
    if !contiguous {
        out.par_iter_mut().enumerate().for_each(|(i, o)| {
            if close(i) {
                *o = 255;
            }
        });
        return Some(out);
    }
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
    Some(out)
}

/// Agrandit (`radius` > 0) ou réduit (`radius` < 0) une sélection de `|radius|` pixels (filtre carré, deux passes).
pub fn grow_shrink(mask: &[u8], w: usize, h: usize, radius: i32) -> Vec<u8> {
    assert_eq!(mask.len(), w * h);
    if radius == 0 || w == 0 || h == 0 {
        return mask.to_vec();
    }
    let r = radius.unsigned_abs() as usize;
    let grow = radius > 0;
    let pick = |a: u8, b: u8| if grow { a.max(b) } else { a.min(b) };
    let init = if grow { 0u8 } else { 255u8 };
    // passe horizontale
    let mut tmp = vec![0u8; w * h];
    tmp.par_chunks_mut(w).zip(mask.par_chunks(w)).for_each(|(o, row)| {
        for x in 0..w {
            let (a, b) = (x.saturating_sub(r), (x + r).min(w - 1));
            o[x] = row[a..=b].iter().fold(init, |m, &v| pick(m, v));
        }
    });
    // passe verticale
    let mut out = vec![0u8; w * h];
    out.par_chunks_mut(w).enumerate().for_each(|(y, o)| {
        let (a, b) = (y.saturating_sub(r), (y + r).min(h - 1));
        for x in 0..w {
            o[x] = (a..=b).fold(init, |m, yy| pick(m, tmp[yy * w + x]));
        }
    });
    out
}

/// Maximum glissant sur une ligne, fenêtre `[x − hw, x + hw]` (file monotone : coût constant par pixel).
fn row_max(row: &[u8], out: &mut [u8], hw: usize) {
    use std::collections::VecDeque;
    let w = row.len();
    let mut dq: VecDeque<usize> = VecDeque::new();
    let mut next = 0usize;
    for x in 0..w {
        let hi = (x + hw).min(w - 1);
        while next <= hi {
            while let Some(&b) = dq.back() {
                if row[b] <= row[next] {
                    dq.pop_back();
                } else {
                    break;
                }
            }
            dq.push_back(next);
            next += 1;
        }
        while let Some(&f) = dq.front() {
            if f + hw < x {
                dq.pop_front();
            } else {
                break;
            }
        }
        out[x] = row[*dq.front().unwrap()];
    }
}

/// Dilatation circulaire d'un plan 8 bits : chaque pixel prend le maximum des pixels à moins de `radius` pixels (disque, pas carré).
/// Sert au contour des calques (traits, lueurs). Pour éroder, passer le plan inversé puis inverser le résultat.
pub fn disk_grow(plane: &[u8], w: usize, h: usize, radius: f32) -> Vec<u8> {
    assert_eq!(plane.len(), w * h);
    let r = radius.max(0.0);
    if r < 0.5 || w == 0 || h == 0 {
        return plane.to_vec();
    }
    let ri = r.floor() as i64;
    let mut out = plane.to_vec();
    let mut hmax = vec![0u8; w * h];
    // demi-largeur de la ligne à l'écart vertical dy ; une même demi-largeur sert à plusieurs écarts : un seul passage horizontal chacune
    let half = |dy: i64| ((r * r - (dy * dy) as f32).max(0.0)).sqrt().floor() as usize;
    for hw in (0..=half(0)).rev() {
        let dys: Vec<i64> = (-ri..=ri).filter(|&dy| half(dy) == hw).collect();
        if dys.is_empty() {
            continue;
        }
        hmax.par_chunks_mut(w).zip(plane.par_chunks(w)).for_each(|(o, row)| row_max(row, o, hw));
        for dy in dys {
            out.par_chunks_mut(w).enumerate().for_each(|(y, o)| {
                let yy = y as i64 + dy;
                if yy < 0 || yy >= h as i64 {
                    return;
                }
                let src = &hmax[yy as usize * w..yy as usize * w + w];
                for x in 0..w {
                    if src[x] > o[x] {
                        o[x] = src[x];
                    }
                }
            });
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 6 × 4 : moitié gauche rouge, moitié droite bleue, un pixel rouge isolé à droite.
    fn two_colours() -> (Vec<u8>, usize, usize) {
        let (w, h) = (6, 4);
        let mut v = Vec::new();
        for y in 0..h {
            for x in 0..w {
                let c: [u8; 3] = if x < 3 || (x == 5 && y == 0) { [250, 10, 10] } else { [10, 10, 250] };
                v.extend_from_slice(&c);
            }
        }
        (v, w, h)
    }

    #[test]
    fn wand_picks_the_connected_area_only() {
        let (img, w, h) = two_colours();
        let m = magic_wand(&img, w, h, 1, 1, 20, true).unwrap();
        assert_eq!(m.iter().filter(|&&v| v == 255).count(), 12);                     // la moitié gauche, pas le pixel rouge isolé
        assert_eq!(m[5], 0);
        assert_eq!(m[0], 255);
    }

    #[test]
    fn wand_non_contiguous_picks_every_similar_pixel() {
        let (img, w, h) = two_colours();
        let m = magic_wand(&img, w, h, 1, 1, 20, false).unwrap();
        assert_eq!(m.iter().filter(|&&v| v == 255).count(), 13);                     // + le pixel rouge isolé
        assert_eq!(m[5], 255);
    }

    #[test]
    fn wand_tolerance_widens_the_selection_and_edges_are_safe() {
        let (img, w, h) = two_colours();
        assert_eq!(magic_wand(&img, w, h, 0, 0, 0, true).unwrap().iter().filter(|&&v| v == 255).count(), 12);
        assert_eq!(magic_wand(&img, w, h, 0, 0, 255, true).unwrap().iter().filter(|&&v| v == 255).count(), w * h);   // tolérance maximale : tout
        assert!(magic_wand(&img, w, h, 6, 0, 10, true).is_none());                    // hors de l'image
        assert!(magic_wand(&img, w, h, 0, 4, 10, false).is_none());
    }

    #[test]
    fn grow_and_shrink_a_square() {
        let (w, h) = (9, 9);
        let mut m = vec![0u8; w * h];
        for y in 3..6 {
            for x in 3..6 {
                m[y * w + x] = 255;
            }
        }
        let g = grow_shrink(&m, w, h, 1);
        assert_eq!(g.iter().filter(|&&v| v == 255).count(), 25);                      // 3 × 3 → 5 × 5
        let s = grow_shrink(&g, w, h, -1);
        assert_eq!(s, m);                                                             // et on revient à 3 × 3
        assert_eq!(grow_shrink(&m, w, h, -2).iter().filter(|&&v| v == 255).count(), 0);   // trop réduit : plus rien
        assert_eq!(grow_shrink(&m, w, h, 0), m);
        let edge = vec![255u8; w * h];
        assert_eq!(grow_shrink(&edge, w, h, -2), edge);                               // une sélection pleine ne rétrécit pas aux bords de la photo
    }

    #[test]
    fn disk_grow_makes_a_disk() {
        let (w, h) = (41, 41);
        let mut m = vec![0u8; w * h];
        m[20 * w + 20] = 255;
        let g = disk_grow(&m, w, h, 8.0);
        let area = g.iter().filter(|&&v| v == 255).count() as f32;
        assert!((area - std::f32::consts::PI * 64.0).abs() < 25.0, "aire {area}");
        assert_eq!(g[20 * w + 28], 255);                    // sur l'axe, à 8 pixels
        assert_eq!(g[20 * w + 29], 0);
        assert_eq!(g[(20 + 7) * w + 20 + 7], 0);            // la diagonale (9,9 px) reste dehors : ce n'est pas un carré
        assert_eq!(disk_grow(&m, w, h, 0.0), m);
        let full = vec![255u8; 9];
        assert_eq!(disk_grow(&full, 3, 3, 5.0), full);
    }
}
