// SPDX-License-Identifier: GPL-3.0-or-later
//! Réglages de calques de réglage et de remplissage qui ne sont pas dans la recette de développement :
//! table de correspondance (niveaux, négatif, isohélie), seuil, filtre photo, courbe de dégradé, teinte / saturation / luminosité,
//! et génération de dégradés. Tout travaille sur des tampons 8 bits en espace d'affichage (sRGB).
use rayon::prelude::*;

/// Applique trois tables de 256 entrées (rouge, vert, bleu : `lut` = 768 octets) à une image RGB.
pub fn apply_lut(rgb: &mut [u8], lut: &[u8]) {
    assert_eq!(lut.len(), 768);
    rgb.par_chunks_mut(3).for_each(|p| {
        for c in 0..3 {
            p[c] = lut[c * 256 + p[c] as usize];
        }
    });
}

#[inline]
fn luminance(p: &[u8]) -> f32 {
    0.299 * p[0] as f32 + 0.587 * p[1] as f32 + 0.114 * p[2] as f32
}

/// Seuil : noir sous `level` (0..255), blanc à partir de là, d'après la luminance.
pub fn threshold(rgb: &mut [u8], level: u8) {
    rgb.par_chunks_mut(3).for_each(|p| {
        let v = if luminance(p) >= level as f32 { 255 } else { 0 };
        p.fill(v);
    });
}

/// Filtre photo : l'image est filtrée par la couleur `color` (comme un filtre devant l'objectif), à la densité `density` (0..1) ;
/// avec `preserve_luminosity`, la luminosité de chaque pixel est conservée.
pub fn photo_filter(rgb: &mut [u8], color: [u8; 3], density: f32, preserve_luminosity: bool) {
    let mx = color[0].max(color[1]).max(color[2]).max(1) as f32;
    let tint = [color[0] as f32 / mx, color[1] as f32 / mx, color[2] as f32 / mx];
    let density = density.clamp(0.0, 1.0);
    rgb.par_chunks_mut(3).for_each(|p| {
        let orig = [p[0] as f32, p[1] as f32, p[2] as f32];
        let mut f = [orig[0] * tint[0], orig[1] * tint[1], orig[2] * tint[2]];
        if preserve_luminosity {
            let lf = 0.299 * f[0] + 0.587 * f[1] + 0.114 * f[2];
            let lo = 0.299 * orig[0] + 0.587 * orig[1] + 0.114 * orig[2];
            if lf > 0.5 {
                let k = lo / lf;
                f = [f[0] * k, f[1] * k, f[2] * k];
            }
        }
        for c in 0..3 {
            p[c] = (orig[c] + (f[c] - orig[c]) * density).clamp(0.0, 255.0).round() as u8;
        }
    });
}

/// Courbe de dégradé : la luminance de chaque pixel choisit une couleur dans `lut` (256 couleurs RGB = 768 octets, du noir au blanc).
pub fn gradient_map(rgb: &mut [u8], lut: &[u8]) {
    assert_eq!(lut.len(), 768);
    rgb.par_chunks_mut(3).for_each(|p| {
        let i = luminance(p).round().clamp(0.0, 255.0) as usize;
        p.copy_from_slice(&lut[i * 3..i * 3 + 3]);
    });
}

fn rgb_to_hsl(r: f32, g: f32, b: f32) -> (f32, f32, f32) {
    let mx = r.max(g).max(b);
    let mn = r.min(g).min(b);
    let l = (mx + mn) / 2.0;
    let d = mx - mn;
    if d < 1e-6 {
        return (0.0, 0.0, l);
    }
    let s = d / (1.0 - (2.0 * l - 1.0).abs());
    let h = if mx == r {
        ((g - b) / d).rem_euclid(6.0)
    } else if mx == g {
        (b - r) / d + 2.0
    } else {
        (r - g) / d + 4.0
    };
    (h * 60.0, s, l)
}

fn hsl_to_rgb(h: f32, s: f32, l: f32) -> [f32; 3] {
    let c = (1.0 - (2.0 * l - 1.0).abs()) * s;
    let hp = h.rem_euclid(360.0) / 60.0;
    let x = c * (1.0 - (hp % 2.0 - 1.0).abs());
    let (r, g, b) = match hp as u32 {
        0 => (c, x, 0.0),
        1 => (x, c, 0.0),
        2 => (0.0, c, x),
        3 => (0.0, x, c),
        4 => (x, 0.0, c),
        _ => (c, 0.0, x),
    };
    let m = l - c / 2.0;
    [r + m, g + m, b + m]
}

/// Teinte / saturation / luminosité globales, comme Photoshop : `hue` en degrés (−180..180), `sat` et `light` de −1 à +1
/// (saturation −1 = gris, +1 = doublée ; luminosité −1 = noir, +1 = blanc).
pub fn hue_sat_lum(rgb: &mut [u8], hue: f32, sat: f32, light: f32) {
    rgb.par_chunks_mut(3).for_each(|p| {
        let (h, s, l) = rgb_to_hsl(p[0] as f32 / 255.0, p[1] as f32 / 255.0, p[2] as f32 / 255.0);
        let s2 = if sat >= 0.0 { (s * (1.0 + sat)).min(1.0) } else { s * (1.0 + sat) };
        let l2 = if light >= 0.0 { l + (1.0 - l) * light } else { l * (1.0 + light) };
        let o = hsl_to_rgb(h + hue, s2, l2);
        for c in 0..3 {
            p[c] = (o[c].clamp(0.0, 1.0) * 255.0 + 0.5) as u8;
        }
    });
}

/// Une étape d'un dégradé : position 0..1 et couleur RGBA.
pub type Stop = (f32, [u8; 4]);

fn color_at(stops: &[Stop], t: f32) -> [f32; 4] {
    let t = t.clamp(0.0, 1.0);
    if stops.is_empty() {
        return [0.0; 4];
    }
    if t <= stops[0].0 {
        let c = stops[0].1;
        return [c[0] as f32, c[1] as f32, c[2] as f32, c[3] as f32];
    }
    for w in stops.windows(2) {
        let (t0, c0) = (w[0].0, w[0].1);
        let (t1, c1) = (w[1].0, w[1].1);
        if t <= t1 {
            let k = if t1 > t0 { (t - t0) / (t1 - t0) } else { 1.0 };
            let mut o = [0.0; 4];
            for c in 0..4 {
                o[c] = c0[c] as f32 + (c1[c] as f32 - c0[c] as f32) * k;
            }
            return o;
        }
    }
    let c = stops[stops.len() - 1].1;
    [c[0] as f32, c[1] as f32, c[2] as f32, c[3] as f32]
}

/// Les 256 couleurs RGB d'un dégradé (pour `gradient_map`).
pub fn gradient_lut(stops: &[Stop]) -> Vec<u8> {
    let mut out = Vec::with_capacity(768);
    for i in 0..256 {
        let c = color_at(stops, i as f32 / 255.0);
        out.extend([c[0].round() as u8, c[1].round() as u8, c[2].round() as u8]);
    }
    out
}

/// Image de dégradé RGBA (`w * h * 4`). `kind` : linear, radial, reflected, angle, diamond. `angle` en degrés (0 = de gauche à droite,
/// 90 = de haut en bas) ; `scale` en pour cent (100 = le dégradé couvre l'image) ; `reverse` inverse le sens.
pub fn gradient_image(w: usize, h: usize, kind: &str, angle: f32, scale: f32, reverse: bool, stops: &[Stop]) -> Vec<u8> {
    let (wf, hf) = (w as f32, h as f32);
    let a = angle.to_radians();
    let (ca, sa) = (a.cos(), a.sin());
    let scale = (scale / 100.0).max(0.01);
    let extent = (wf * ca.abs() + hf * sa.abs()).max(1.0) * scale;
    let radius = ((wf * wf + hf * hf).sqrt() / 2.0).max(1.0) * scale;
    let mut out = vec![0u8; w * h * 4];
    out.par_chunks_mut(w * 4).enumerate().for_each(|(j, row)| {
        for i in 0..w {
            let dx = i as f32 + 0.5 - wf / 2.0;
            let dy = j as f32 + 0.5 - hf / 2.0;
            let mut t = match kind {
                "radial" => (dx * dx + dy * dy).sqrt() / radius,
                "reflected" => ((dx * ca + dy * sa) / extent).abs() * 2.0,
                "angle" => ((dy.atan2(dx) - a) / std::f32::consts::TAU).rem_euclid(1.0),
                "diamond" => (dx.abs() / (wf / 2.0).max(1.0) + dy.abs() / (hf / 2.0).max(1.0)) / 2.0 / scale,
                _ => 0.5 + (dx * ca + dy * sa) / extent,
            };
            if reverse {
                t = 1.0 - t;
            }
            let c = color_at(stops, t);
            for k in 0..4 {
                row[i * 4 + k] = c[k].round().clamp(0.0, 255.0) as u8;
            }
        }
    });
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lut_threshold_and_gradient_map() {
        let mut lut = Vec::new();
        for _ in 0..3 {
            lut.extend((0..=255u8).rev());
        }
        let mut px = vec![10u8, 200, 255];
        apply_lut(&mut px, &lut);
        assert_eq!(px, vec![245, 55, 0]);
        let mut t = vec![100u8, 100, 100, 200, 200, 200];
        threshold(&mut t, 128);
        assert_eq!(t, vec![0, 0, 0, 255, 255, 255]);
        let stops: Vec<Stop> = vec![(0.0, [0, 0, 255, 255]), (1.0, [255, 0, 0, 255])];
        let glut = gradient_lut(&stops);
        assert_eq!(&glut[0..3], &[0, 0, 255]);
        assert_eq!(&glut[765..768], &[255, 0, 0]);
        let mut g = vec![0u8, 0, 0, 255, 255, 255];
        gradient_map(&mut g, &glut);
        assert_eq!(g, vec![0, 0, 255, 255, 0, 0]);
    }

    #[test]
    fn photo_filter_tints_and_can_keep_luminosity() {
        let mut p = vec![128u8, 128, 128];
        photo_filter(&mut p, [236, 138, 0], 1.0, false);                  // filtre orange (85)
        assert!(p[0] > p[1] && p[1] > p[2]);
        let mut q = vec![128u8, 128, 128];
        photo_filter(&mut q, [236, 138, 0], 1.0, true);
        let lq = 0.299 * q[0] as f32 + 0.587 * q[1] as f32 + 0.114 * q[2] as f32;
        assert!((lq - 128.0).abs() < 3.0);
        let mut z = vec![50u8, 60, 70];
        photo_filter(&mut z, [255, 0, 0], 0.0, false);
        assert_eq!(z, vec![50, 60, 70]);                                   // densité nulle : rien
    }

    #[test]
    fn hue_sat_lum_behaves_like_photoshop() {
        let mut red = vec![255u8, 0, 0];
        hue_sat_lum(&mut red, 120.0, 0.0, 0.0);
        assert!(red[1] > 240 && red[0] < 10 && red[2] < 10);               // rouge + 120° = vert
        let mut gray = vec![200u8, 100, 50];
        hue_sat_lum(&mut gray, 0.0, -1.0, 0.0);
        assert!((gray[0] as i32 - gray[1] as i32).abs() <= 1 && (gray[1] as i32 - gray[2] as i32).abs() <= 1);
        let mut dark = vec![100u8, 100, 100];
        hue_sat_lum(&mut dark, 0.0, 0.0, -1.0);
        assert_eq!(dark, vec![0, 0, 0]);
        let mut light = vec![100u8, 100, 100];
        hue_sat_lum(&mut light, 0.0, 0.0, 1.0);
        assert_eq!(light, vec![255, 255, 255]);
        let mut same = vec![30u8, 90, 200];
        hue_sat_lum(&mut same, 0.0, 0.0, 0.0);
        assert!(same.iter().zip([30u8, 90, 200]).all(|(a, b)| (*a as i32 - b as i32).abs() <= 1));
    }

    #[test]
    fn gradients() {
        let stops: Vec<Stop> = vec![(0.0, [0, 0, 0, 255]), (1.0, [255, 255, 255, 255])];
        let g = gradient_image(11, 3, "linear", 0.0, 100.0, false, &stops);
        let at = |x: usize, y: usize| g[(y * 11 + x) * 4];
        assert!(at(0, 1) < 20 && at(10, 1) > 235 && (at(5, 1) as i32 - 128).abs() < 12);
        assert!(at(3, 0) == at(3, 2));                                       // horizontal : constant sur une colonne
        let r = gradient_image(11, 3, "linear", 0.0, 100.0, true, &stops);
        assert!(r[0] > 235);                                                 // inversé
        let v = gradient_image(3, 11, "linear", 90.0, 100.0, false, &stops);
        assert!(v[0] < 20 && v[(10 * 3) * 4] > 235);                         // de haut en bas
        let rad = gradient_image(21, 21, "radial", 0.0, 100.0, false, &stops);
        assert!(rad[(10 * 21 + 10) * 4] < 10 && rad[0] > 230);               // centre noir, coin blanc
        let refl = gradient_image(21, 3, "reflected", 0.0, 100.0, false, &stops);
        assert!(refl[10 * 4] < 10 && refl[0] > 230 && refl[20 * 4] > 230);   // miroir : centre → bords
        for kind in ["angle", "diamond"] {
            let k = gradient_image(8, 8, kind, 0.0, 100.0, false, &stops);
            assert_eq!(k.len(), 8 * 8 * 4);
        }
        let alpha: Vec<Stop> = vec![(0.0, [255, 0, 0, 0]), (1.0, [255, 0, 0, 255])];
        let a = gradient_image(11, 1, "linear", 0.0, 100.0, false, &alpha);
        assert!(a[3] < 20 && a[43] > 235);                                   // dégradé vers le transparent
    }
}


/// Table 3D (`n` × `n` × `n` × 3 flottants, rangés b + n*(g + n*r)) appliquée à `src` (r, v, b flottants). L'entrée est lue après `encode` (puissance
/// 1/gamma, pour répartir les nœuds de la table sur toute la dynamique) et bornée à [0, 1] ; interpolation trilinéaire.
/// La sortie est en 16 bits (valeurs de la table 0..1).
pub fn apply_lut3d(src: &[f32], n: usize, lut: &[f32], gamma: f32, scale: f32) -> Vec<u16> {
    use rayon::prelude::*;
    assert_eq!(lut.len(), n * n * n * 3);
    let inv = 1.0 / gamma;
    let nm = (n - 1) as f32;
    let mut out = vec![0u16; src.len()];
    out.par_chunks_mut(3 * 4096).zip(src.par_chunks(3 * 4096)).for_each(|(o, s)| {
        for (po, ps) in o.chunks_exact_mut(3).zip(s.chunks_exact(3)) {
            let mut idx = [0usize; 3];
            let mut fr = [0f32; 3];
            for c in 0..3 {
                let v = (ps[c] * scale).max(0.0).powf(inv).min(1.0) * nm;
                let i = (v as usize).min(n - 2);
                idx[c] = i;
                fr[c] = v - i as f32;
            }
            let at = |dr: usize, dg: usize, db: usize, c: usize| lut[(((idx[2] + db) + n * ((idx[1] + dg) + n * (idx[0] + dr))) * 3) + c];
            for c in 0..3 {
                let c00 = at(0, 0, 0, c) * (1.0 - fr[2]) + at(0, 0, 1, c) * fr[2];
                let c01 = at(0, 1, 0, c) * (1.0 - fr[2]) + at(0, 1, 1, c) * fr[2];
                let c10 = at(1, 0, 0, c) * (1.0 - fr[2]) + at(1, 0, 1, c) * fr[2];
                let c11 = at(1, 1, 0, c) * (1.0 - fr[2]) + at(1, 1, 1, c) * fr[2];
                let c0 = c00 * (1.0 - fr[1]) + c01 * fr[1];
                let c1 = c10 * (1.0 - fr[1]) + c11 * fr[1];
                let v = c0 * (1.0 - fr[0]) + c1 * fr[0];
                po[c] = (v.clamp(0.0, 1.0) * 65535.0 + 0.5) as u16;
            }
        }
    });
    out
}
