// SPDX-License-Identifier: GPL-3.0-or-later
//! Fusion de calques : empile des images (RGBA, placées au pixel près) sur une image de base, avec mode de fusion,
//! opacité et masque de calque. Calcul dans l'espace d'affichage (sRGB), comme Photoshop par défaut.
//!
//! La transformation des calques (taille, rotation) est faite en amont : ici chaque calque est déjà à sa taille finale
//! et posé en (x, y) dans le repère de l'image de base (x, y peuvent être négatifs ou dépasser : la partie hors cadre est ignorée).
use rayon::prelude::*;

/// Mode de fusion d'un calque avec ce qu'il y a dessous.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Blend {
    Normal,
    Multiply,
    Screen,
    Overlay,
    SoftLight,
    HardLight,
    Darken,
    Lighten,
    Difference,
    Add,
    ColorDodge,
    ColorBurn,
    LinearBurn,
    Exclusion,
    VividLight,
    LinearLight,
    PinLight,
    HardMix,
    Subtract,
    Divide,
    Hue,
    Saturation,
    Color,
    Luminosity,
    DarkerColor,
    LighterColor,
}

impl Blend {
    /// Nom du mode (celui de l'interface et du fichier de document) → mode ; `None` s'il est inconnu.
    pub fn from_name(name: &str) -> Option<Blend> {
        Some(match name {
            "normal" => Blend::Normal,
            "multiply" => Blend::Multiply,
            "screen" => Blend::Screen,
            "overlay" => Blend::Overlay,
            "soft_light" => Blend::SoftLight,
            "hard_light" => Blend::HardLight,
            "darken" => Blend::Darken,
            "lighten" => Blend::Lighten,
            "difference" => Blend::Difference,
            "add" => Blend::Add,
            "color_dodge" => Blend::ColorDodge,
            "color_burn" => Blend::ColorBurn,
            "linear_burn" => Blend::LinearBurn,
            "exclusion" => Blend::Exclusion,
            "vivid_light" => Blend::VividLight,
            "linear_light" => Blend::LinearLight,
            "pin_light" => Blend::PinLight,
            "hard_mix" => Blend::HardMix,
            "subtract" => Blend::Subtract,
            "divide" => Blend::Divide,
            "hue" => Blend::Hue,
            "saturation" => Blend::Saturation,
            "color" => Blend::Color,
            "luminosity" => Blend::Luminosity,
            "darker_color" => Blend::DarkerColor,
            "lighter_color" => Blend::LighterColor,
            _ => return None,
        })
    }

    /// Résultat du mode pour un canal : `b` = dessous, `s` = calque (0..1).
    #[inline]
    fn channel(self, b: f32, s: f32) -> f32 {
        match self {
            Blend::Normal => s,
            Blend::Multiply => b * s,
            Blend::Screen => 1.0 - (1.0 - b) * (1.0 - s),
            Blend::Overlay => Blend::HardLight.channel(s, b),
            Blend::HardLight => {
                if s <= 0.5 {
                    2.0 * b * s
                } else {
                    1.0 - 2.0 * (1.0 - b) * (1.0 - s)
                }
            }
            Blend::SoftLight => {
                if s <= 0.5 {
                    b - (1.0 - 2.0 * s) * b * (1.0 - b)
                } else {
                    let d = if b <= 0.25 { ((16.0 * b - 12.0) * b + 4.0) * b } else { b.sqrt() };
                    b + (2.0 * s - 1.0) * (d - b)
                }
            }
            Blend::Darken => b.min(s),
            Blend::Lighten => b.max(s),
            Blend::Difference => (b - s).abs(),
            Blend::Add => (b + s).min(1.0),
            Blend::ColorDodge => {
                if b <= 0.0 {
                    0.0
                } else if s >= 1.0 {
                    1.0
                } else {
                    (b / (1.0 - s)).min(1.0)
                }
            }
            Blend::ColorBurn => {
                if b >= 1.0 {
                    1.0
                } else if s <= 0.0 {
                    0.0
                } else {
                    1.0 - ((1.0 - b) / s).min(1.0)
                }
            }
            Blend::LinearBurn => (b + s - 1.0).max(0.0),
            Blend::Exclusion => b + s - 2.0 * b * s,
            Blend::VividLight => {
                if s <= 0.5 {
                    Blend::ColorBurn.channel(b, 2.0 * s)
                } else {
                    Blend::ColorDodge.channel(b, 2.0 * (s - 0.5))
                }
            }
            Blend::LinearLight => (b + 2.0 * s - 1.0).clamp(0.0, 1.0),
            Blend::PinLight => {
                if s < 0.5 {
                    b.min(2.0 * s)
                } else {
                    b.max(2.0 * (s - 0.5))
                }
            }
            Blend::HardMix => {
                if b + s >= 1.0 {
                    1.0
                } else {
                    0.0
                }
            }
            Blend::Subtract => (b - s).max(0.0),
            Blend::Divide => {
                if s <= 0.0 {
                    1.0
                } else {
                    (b / s).min(1.0)
                }
            }
            // les modes non séparables passent par `mix`
            Blend::Hue | Blend::Saturation | Blend::Color | Blend::Luminosity | Blend::DarkerColor | Blend::LighterColor => s,
        }
    }

    /// Résultat du mode pour un pixel (trois canaux). Les modes séparables agissent canal par canal ; les autres regardent la couleur
    /// entière (formules du W3C « Compositing and Blending »).
    #[inline]
    pub fn mix(self, b: [f32; 3], s: [f32; 3]) -> [f32; 3] {
        match self {
            Blend::Hue => set_lum(set_sat(s, sat(b)), lum(b)),
            Blend::Saturation => set_lum(set_sat(b, sat(s)), lum(b)),
            Blend::Color => set_lum(s, lum(b)),
            Blend::Luminosity => set_lum(b, lum(s)),
            Blend::DarkerColor => {
                if lum(s) < lum(b) {
                    s
                } else {
                    b
                }
            }
            Blend::LighterColor => {
                if lum(s) > lum(b) {
                    s
                } else {
                    b
                }
            }
            _ => [self.channel(b[0], s[0]), self.channel(b[1], s[1]), self.channel(b[2], s[2])],
        }
    }
}

#[inline]
fn lum(c: [f32; 3]) -> f32 {
    0.3 * c[0] + 0.59 * c[1] + 0.11 * c[2]
}

fn clip_color(c: [f32; 3]) -> [f32; 3] {
    let l = lum(c);
    let n = c[0].min(c[1]).min(c[2]);
    let x = c[0].max(c[1]).max(c[2]);
    let mut o = c;
    if n < 0.0 {
        for v in o.iter_mut() {
            *v = l + (*v - l) * l / (l - n);
        }
    }
    if x > 1.0 {
        for v in o.iter_mut() {
            *v = l + (*v - l) * (1.0 - l) / (x - l);
        }
    }
    o
}

fn set_lum(c: [f32; 3], l: f32) -> [f32; 3] {
    let d = l - lum(c);
    clip_color([c[0] + d, c[1] + d, c[2] + d])
}

fn sat(c: [f32; 3]) -> f32 {
    c[0].max(c[1]).max(c[2]) - c[0].min(c[1]).min(c[2])
}

fn set_sat(c: [f32; 3], s: f32) -> [f32; 3] {
    let mx = c[0].max(c[1]).max(c[2]);
    let mn = c[0].min(c[1]).min(c[2]);
    if mx <= mn {
        return [0.0; 3];
    }
    let k = s / (mx - mn);
    [(c[0] - mn) * k, (c[1] - mn) * k, (c[2] - mn) * k]
}

/// Un calque prêt à être posé.
pub struct Layer<'a> {
    pub w: usize,
    pub h: usize,
    /// RGBA 8 bits, `w * h * 4` octets (alpha non prémultiplié)
    pub rgba: &'a [u8],
    pub x: i64,
    pub y: i64,
    /// 0..1
    pub opacity: f32,
    pub blend: Blend,
    /// masque de calque (`w * h` octets, 255 = visible) ou `None`
    pub mask: Option<&'a [u8]>,
}

/// Pose les calques, du premier (le plus bas) au dernier, sur `base` (`bw * bh * 3` octets RGB).
pub fn composite(base: &mut [u8], bw: usize, bh: usize, layers: &[Layer]) {
    assert_eq!(base.len(), bw * bh * 3);
    for l in layers {
        assert_eq!(l.rgba.len(), l.w * l.h * 4);
        if let Some(m) = l.mask {
            assert_eq!(m.len(), l.w * l.h);
        }
        let op = l.opacity.clamp(0.0, 1.0);
        if op <= 0.0 {
            continue;
        }
        base.par_chunks_mut(bw * 3).enumerate().for_each(|(j, row)| {
            let ly = j as i64 - l.y;
            if ly < 0 || ly >= l.h as i64 {
                return;
            }
            let ly = ly as usize;
            let x0 = l.x.max(0);
            let x1 = (l.x + l.w as i64).min(bw as i64);
            for i in x0..x1 {
                let lx = (i - l.x) as usize;
                let k = ly * l.w + lx;
                let mut a = l.rgba[k * 4 + 3] as f32 / 255.0 * op;
                if let Some(m) = l.mask {
                    a *= m[k] as f32 / 255.0;
                }
                if a <= 0.0 {
                    continue;
                }
                let o = i as usize * 3;
                let b = [row[o] as f32 / 255.0, row[o + 1] as f32 / 255.0, row[o + 2] as f32 / 255.0];
                let s = [l.rgba[k * 4] as f32 / 255.0, l.rgba[k * 4 + 1] as f32 / 255.0, l.rgba[k * 4 + 2] as f32 / 255.0];
                let m = l.blend.mix(b, s);
                for c in 0..3 {
                    let r = b[c] + (m[c] - b[c]) * a;
                    row[o + c] = (r.clamp(0.0, 1.0) * 255.0 + 0.5) as u8;
                }
            }
        });
    }
}

/// Comme `composite`, mais la base est elle-même transparente (RGBA 8 bits, `bw * bh * 4` octets, alpha non prémultiplié) :
/// c'est ce qui permet les groupes isolés, la fusion de calques et les calques d'écrêtage. Formule de composition du W3C :
/// αr = αs + αb(1 − αs) ; Cr = [(1 − αs)·αb·Cb + αs·((1 − αb)·Cs + αb·B(Cb, Cs))] / αr.
pub fn composite_rgba(base: &mut [u8], bw: usize, bh: usize, layers: &[Layer]) {
    assert_eq!(base.len(), bw * bh * 4);
    for l in layers {
        assert_eq!(l.rgba.len(), l.w * l.h * 4);
        if let Some(m) = l.mask {
            assert_eq!(m.len(), l.w * l.h);
        }
        let op = l.opacity.clamp(0.0, 1.0);
        if op <= 0.0 {
            continue;
        }
        base.par_chunks_mut(bw * 4).enumerate().for_each(|(j, row)| {
            let ly = j as i64 - l.y;
            if ly < 0 || ly >= l.h as i64 {
                return;
            }
            let ly = ly as usize;
            let x0 = l.x.max(0);
            let x1 = (l.x + l.w as i64).min(bw as i64);
            for i in x0..x1 {
                let k = ly * l.w + (i - l.x) as usize;
                let mut a_s = l.rgba[k * 4 + 3] as f32 / 255.0 * op;
                if let Some(m) = l.mask {
                    a_s *= m[k] as f32 / 255.0;
                }
                if a_s <= 0.0 {
                    continue;
                }
                let o = i as usize * 4;
                let a_b = row[o + 3] as f32 / 255.0;
                let cb = [row[o] as f32 / 255.0, row[o + 1] as f32 / 255.0, row[o + 2] as f32 / 255.0];
                let cs = [l.rgba[k * 4] as f32 / 255.0, l.rgba[k * 4 + 1] as f32 / 255.0, l.rgba[k * 4 + 2] as f32 / 255.0];
                let a_r = a_s + a_b * (1.0 - a_s);
                let m = if a_b > 0.0 { l.blend.mix(cb, cs) } else { cs };
                for c in 0..3 {
                    let v = ((1.0 - a_s) * a_b * cb[c] + a_s * ((1.0 - a_b) * cs[c] + a_b * m[c])) / a_r;
                    row[o + c] = (v.clamp(0.0, 1.0) * 255.0 + 0.5) as u8;
                }
                row[o + 3] = (a_r.clamp(0.0, 1.0) * 255.0 + 0.5) as u8;
            }
        });
    }
}

/// Un calque 16 bits prêt à être posé (même rôle que `Layer`, mais RGBA et masque sur 16 bits).
pub struct Layer16<'a> {
    pub w: usize,
    pub h: usize,
    /// RGBA 16 bits, `w * h * 4` valeurs (alpha non prémultiplié, 65535 = opaque)
    pub rgba: &'a [u16],
    pub x: i64,
    pub y: i64,
    /// 0..1
    pub opacity: f32,
    pub blend: Blend,
    /// masque de calque (`w * h` valeurs 16 bits, 65535 = visible) ou `None`
    pub mask: Option<&'a [u16]>,
}

/// Comme `composite_rgba`, mais sur 16 bits (`bw * bh * 4` valeurs, 0..65535) : les arrondis intermédiaires ne se font plus sur 256 niveaux,
/// ce qui évite les bandes quand un réglage relève fortement des ombres lisses. Même formule de composition, même calcul en flottant.
pub fn composite_rgba16(base: &mut [u16], bw: usize, bh: usize, layers: &[Layer16]) {
    assert_eq!(base.len(), bw * bh * 4);
    const K: f32 = 65535.0;
    for l in layers {
        assert_eq!(l.rgba.len(), l.w * l.h * 4);
        if let Some(m) = l.mask {
            assert_eq!(m.len(), l.w * l.h);
        }
        let op = l.opacity.clamp(0.0, 1.0);
        if op <= 0.0 {
            continue;
        }
        base.par_chunks_mut(bw * 4).enumerate().for_each(|(j, row)| {
            let ly = j as i64 - l.y;
            if ly < 0 || ly >= l.h as i64 {
                return;
            }
            let ly = ly as usize;
            let x0 = l.x.max(0);
            let x1 = (l.x + l.w as i64).min(bw as i64);
            for i in x0..x1 {
                let k = ly * l.w + (i - l.x) as usize;
                let mut a_s = l.rgba[k * 4 + 3] as f32 / K * op;
                if let Some(m) = l.mask {
                    a_s *= m[k] as f32 / K;
                }
                if a_s <= 0.0 {
                    continue;
                }
                let o = i as usize * 4;
                let a_b = row[o + 3] as f32 / K;
                let cb = [row[o] as f32 / K, row[o + 1] as f32 / K, row[o + 2] as f32 / K];
                let cs = [l.rgba[k * 4] as f32 / K, l.rgba[k * 4 + 1] as f32 / K, l.rgba[k * 4 + 2] as f32 / K];
                let a_r = a_s + a_b * (1.0 - a_s);
                let m = if a_b > 0.0 { l.blend.mix(cb, cs) } else { cs };
                for c in 0..3 {
                    let v = ((1.0 - a_s) * a_b * cb[c] + a_s * ((1.0 - a_b) * cs[c] + a_b * m[c])) / a_r;
                    row[o + c] = (v.clamp(0.0, 1.0) * K + 0.5) as u16;
                }
                row[o + 3] = (a_r.clamp(0.0, 1.0) * K + 0.5) as u16;
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn solid(w: usize, h: usize, rgba: [u8; 4]) -> Vec<u8> {
        (0..w * h).flat_map(|_| rgba).collect()
    }

    fn one(base_v: u8, layer: [u8; 4], blend: Blend, opacity: f32) -> u8 {
        let mut base = vec![base_v; 3];
        let rgba = solid(1, 1, layer);
        composite(&mut base, 1, 1, &[Layer { w: 1, h: 1, rgba: &rgba, x: 0, y: 0, opacity, blend, mask: None }]);
        base[0]
    }

    #[test]
    fn normal_opaque_replaces_and_opacity_mixes() {
        assert_eq!(one(100, [200, 200, 200, 255], Blend::Normal, 1.0), 200);
        assert_eq!(one(100, [200, 200, 200, 255], Blend::Normal, 0.5), 150);
        assert_eq!(one(100, [200, 200, 200, 255], Blend::Normal, 0.0), 100);
        assert_eq!(one(100, [200, 200, 200, 0], Blend::Normal, 1.0), 100);         // calque transparent : rien
        assert_eq!(one(100, [200, 200, 200, 128], Blend::Normal, 1.0), 150);       // alpha du calque (≈ 50 %)
    }

    #[test]
    fn classic_blend_modes() {
        assert_eq!(one(255, [128, 128, 128, 255], Blend::Multiply, 1.0), 128);     // blanc × gris = gris
        assert_eq!(one(0, [128, 128, 128, 255], Blend::Screen, 1.0), 128);         // noir écran gris = gris
        assert_eq!(one(255, [128, 128, 128, 255], Blend::Screen, 1.0), 255);
        assert_eq!(one(100, [50, 50, 50, 255], Blend::Darken, 1.0), 50);
        assert_eq!(one(100, [50, 50, 50, 255], Blend::Lighten, 1.0), 100);
        assert_eq!(one(100, [160, 160, 160, 255], Blend::Difference, 1.0), 60);
        assert_eq!(one(200, [100, 100, 100, 255], Blend::Add, 1.0), 255);           // plafonné
        // incrustation : un gris moyen dessous ne change pas ; un calque clair éclaircit, un calque sombre assombrit
        assert!((one(128, [128, 128, 128, 255], Blend::Overlay, 1.0) as i32 - 128).abs() <= 1);
        assert!(one(100, [200, 200, 200, 255], Blend::Overlay, 1.0) > 100);
        assert!(one(100, [60, 60, 60, 255], Blend::Overlay, 1.0) < 100);
        // lumière douce : un gris moyen n'a aucun effet, plus doux que l'incrustation
        assert_eq!(one(100, [128, 128, 128, 255], Blend::SoftLight, 1.0), 100);
        let soft = one(100, [220, 220, 220, 255], Blend::SoftLight, 1.0);
        assert!(soft > 100 && soft < one(100, [220, 220, 220, 255], Blend::Overlay, 1.0));
        assert!(one(100, [220, 220, 220, 255], Blend::HardLight, 1.0) > 100);
    }

    #[test]
    fn layer_mask_and_position() {
        let (bw, bh) = (4, 3);
        let mut base = vec![0u8; bw * bh * 3];
        let rgba = solid(2, 2, [255, 255, 255, 255]);
        let mask = [255u8, 0, 255, 0];                                              // seule la colonne de gauche du calque est visible
        composite(&mut base, bw, bh, &[Layer { w: 2, h: 2, rgba: &rgba, x: 1, y: 1, opacity: 1.0, blend: Blend::Normal, mask: Some(&mask) }]);
        let px = |x: usize, y: usize| base[(y * bw + x) * 3];
        assert_eq!((px(1, 1), px(2, 1), px(1, 2), px(2, 2)), (255, 0, 255, 0));
        assert_eq!((px(0, 0), px(3, 2), px(0, 1)), (0, 0, 0));                      // le reste est intact
    }

    #[test]
    fn layer_partly_outside_the_frame_is_clipped_without_panic() {
        let (bw, bh) = (3, 3);
        let mut base = vec![0u8; bw * bh * 3];
        let rgba = solid(4, 4, [255, 255, 255, 255]);
        composite(&mut base, bw, bh, &[Layer { w: 4, h: 4, rgba: &rgba, x: -2, y: -2, opacity: 1.0, blend: Blend::Normal, mask: None }]);
        let px = |x: usize, y: usize| base[(y * bw + x) * 3];
        assert_eq!((px(0, 0), px(1, 1), px(2, 2), px(2, 0)), (255, 255, 0, 0));      // couvre x, y ∈ {0, 1}
        let mut b2 = vec![7u8; bw * bh * 3];
        composite(&mut b2, bw, bh, &[Layer { w: 2, h: 2, rgba: &solid(2, 2, [255; 4]), x: 10, y: 10, opacity: 1.0, blend: Blend::Normal, mask: None }]);
        assert!(b2.iter().all(|&v| v == 7));                                        // entièrement hors cadre : rien
    }

    #[test]
    fn extra_blend_modes() {
        assert_eq!(one(200, [100, 100, 100, 255], Blend::LinearBurn, 1.0), 45);        // 200 + 100 − 255
        assert_eq!(one(100, [100, 100, 100, 255], Blend::Subtract, 1.0), 0);
        assert_eq!(one(200, [100, 100, 100, 255], Blend::Subtract, 1.0), 100);
        assert_eq!(one(100, [200, 200, 200, 255], Blend::Divide, 1.0), 128);           // 100 / 200 → 0,5
        assert_eq!(one(100, [0, 0, 0, 255], Blend::Divide, 1.0), 255);
        assert_eq!(one(255, [255, 255, 255, 255], Blend::Exclusion, 1.0), 0);
        assert_eq!(one(0, [200, 200, 200, 255], Blend::Exclusion, 1.0), 200);
        assert!(one(100, [128, 128, 128, 255], Blend::ColorDodge, 1.0) > 100);
        assert!(one(200, [128, 128, 128, 255], Blend::ColorBurn, 1.0) < 200);
        assert_eq!(one(200, [255, 255, 255, 255], Blend::ColorDodge, 1.0), 255);
        assert_eq!(one(0, [200, 200, 200, 255], Blend::ColorDodge, 1.0), 0);
        assert_eq!(one(100, [0, 0, 0, 255], Blend::ColorBurn, 1.0), 0);
        assert_eq!(one(100, [200, 200, 200, 255], Blend::HardMix, 1.0), 255);
        assert_eq!(one(100, [100, 100, 100, 255], Blend::HardMix, 1.0), 0);
        assert_eq!(one(100, [50, 50, 50, 255], Blend::PinLight, 1.0), 100.min(100));
        assert!(one(100, [200, 200, 200, 255], Blend::VividLight, 1.0) > 100);
        assert!(one(100, [200, 200, 200, 255], Blend::LinearLight, 1.0) > 100);
        assert_eq!(one(100, [30, 30, 30, 255], Blend::DarkerColor, 1.0), 30);
        assert_eq!(one(100, [30, 30, 30, 255], Blend::LighterColor, 1.0), 100);
    }

    #[test]
    fn non_separable_modes_keep_the_right_component() {
        let f = |c: [u8; 3]| [c[0] as f32 / 255.0, c[1] as f32 / 255.0, c[2] as f32 / 255.0];
        // Couleur : luminosité du dessous, teinte et saturation du calque
        let r = Blend::Color.mix(f([128, 128, 128]), f([255, 0, 0]));
        assert!(r[0] > r[1] && (lum(r) - 128.0 / 255.0).abs() < 0.01);
        // Luminosité : couleur du dessous, luminosité du calque
        let r = Blend::Luminosity.mix(f([255, 0, 0]), f([128, 128, 128]));
        assert!(r[0] > r[1] && (lum(r) - 128.0 / 255.0).abs() < 0.01);
        // Teinte sur un gris : la saturation du dessous (nulle) est gardée
        let r = Blend::Hue.mix(f([128, 128, 128]), f([255, 0, 0]));
        assert!((r[0] - r[1]).abs() < 0.01 && (r[1] - r[2]).abs() < 0.01);
        // Saturation : un calque gris désature le dessous
        let r = Blend::Saturation.mix(f([255, 0, 0]), f([128, 128, 128]));
        assert!(sat(r) < 0.01);
        let r = Blend::Color.mix(f([250, 250, 250]), f([255, 0, 0]));
        assert!(r.iter().all(|v| (0.0..=1.0).contains(v)));
    }

    #[test]
    fn rgba_base_follows_the_w3c_formula() {
        let layer = solid(1, 1, [200, 50, 10, 128]);
        let mk = |data: &'static [u8], blend| Layer { w: 1, h: 1, rgba: data, x: 0, y: 0, opacity: 1.0, blend, mask: None };
        let leaked: &'static [u8] = Box::leak(layer.into_boxed_slice());
        // base opaque : même résultat que `composite`
        let mut rgb = vec![100u8; 3];
        let mut rgba = vec![100u8, 100, 100, 255];
        composite(&mut rgb, 1, 1, &[mk(leaked, Blend::Multiply)]);
        composite_rgba(&mut rgba, 1, 1, &[mk(leaked, Blend::Multiply)]);
        assert_eq!(&rgba[..3], &rgb[..]);
        assert_eq!(rgba[3], 255);
        // base transparente : le calque est posé tel quel (rien dessous à fusionner)
        let mut empty = vec![0u8; 4];
        composite_rgba(&mut empty, 1, 1, &[mk(leaked, Blend::Multiply)]);
        assert_eq!(empty, vec![200, 50, 10, 128]);
        // deux demi-opacités : alpha = 0,5 + 0,5 × 0,5 = 0,75
        let mut e2 = vec![0u8; 4];
        let half: &'static [u8] = Box::leak(solid(1, 1, [255, 255, 255, 128]).into_boxed_slice());
        composite_rgba(&mut e2, 1, 1, &[mk(half, Blend::Normal), mk(half, Blend::Normal)]);
        assert!((e2[3] as i32 - 192).abs() <= 1 && e2[0] == 255);
    }

    #[test]
    fn rgba16_matches_the_8_bit_result_and_keeps_the_finer_levels() {
        let up = |v: u8| v as u16 * 257;
        // mêmes situations qu'en 8 bits : le résultat 16 bits, ramené sur 8 bits, doit être le même (à 1 niveau près)
        for (b, s, a, blend) in [(100u8, 200u8, 255u8, Blend::Normal), (100, 200, 128, Blend::Normal), (200, 100, 255, Blend::Multiply), (100, 160, 255, Blend::Difference), (128, 220, 255, Blend::SoftLight)] {
            let mut b8 = vec![b, b, b, 255];
            let l8 = solid(1, 1, [s, s, s, a]);
            composite_rgba(&mut b8, 1, 1, &[Layer { w: 1, h: 1, rgba: &l8, x: 0, y: 0, opacity: 1.0, blend, mask: None }]);
            let mut b16 = vec![up(b), up(b), up(b), 65535];
            let l16 = vec![up(s), up(s), up(s), up(a)];
            composite_rgba16(&mut b16, 1, 1, &[Layer16 { w: 1, h: 1, rgba: &l16, x: 0, y: 0, opacity: 1.0, blend, mask: None }]);
            let back = ((b16[0] as f32) / 257.0).round() as i32;
            assert!((back - b8[0] as i32).abs() <= 1, "{blend:?} {b} {s} {a} : 8 bits {} contre 16 bits {}", b8[0], back);
            assert_eq!(b16[3], 65535);
        }
        // un niveau entre deux niveaux 8 bits survit : 50 % entre 100 et 101 donne 100,5 (impossible en 8 bits)
        let mut base = vec![up(100), up(100), up(100), 65535];
        let l = vec![up(101), up(101), up(101), 65535];
        composite_rgba16(&mut base, 1, 1, &[Layer16 { w: 1, h: 1, rgba: &l, x: 0, y: 0, opacity: 0.5, blend: Blend::Normal, mask: None }]);
        assert!((base[0] as i32 - 25829).abs() <= 1, "attendu 25 828,5 : {}", base[0]);
        assert!(base[0] % 257 != 0, "le résultat doit tomber entre deux niveaux 8 bits");
        // base transparente : le calque est posé tel quel ; hors cadre : rien
        let mut empty = vec![0u16; 4];
        let l2 = vec![50000u16, 100, 7, 32768];
        composite_rgba16(&mut empty, 1, 1, &[Layer16 { w: 1, h: 1, rgba: &l2, x: 0, y: 0, opacity: 1.0, blend: Blend::Multiply, mask: None }]);
        assert_eq!(empty, vec![50000, 100, 7, 32768]);
        let mut far = vec![9u16; 4];
        composite_rgba16(&mut far, 1, 1, &[Layer16 { w: 1, h: 1, rgba: &l2, x: 5, y: 5, opacity: 1.0, blend: Blend::Normal, mask: None }]);
        assert_eq!(far, vec![9, 9, 9, 9]);
    }

    #[test]
    fn layers_stack_in_order_and_names_parse() {
        let mut base = vec![0u8; 3];
        let a = solid(1, 1, [255, 0, 0, 255]);
        let b = solid(1, 1, [0, 255, 0, 128]);
        let mk = |rgba| Layer { w: 1, h: 1, rgba, x: 0, y: 0, opacity: 1.0, blend: Blend::Normal, mask: None };
        composite(&mut base, 1, 1, &[mk(&a), mk(&b)]);
        assert_eq!(base, vec![127, 128, 0]);                                         // rouge puis vert à 50 % par-dessus
        for n in ["normal", "multiply", "screen", "overlay", "soft_light", "hard_light", "darken", "lighten", "difference", "add", "color_dodge", "color_burn", "linear_burn", "exclusion", "vivid_light", "linear_light", "pin_light", "hard_mix", "subtract", "divide", "hue", "saturation", "color", "luminosity", "darker_color", "lighter_color"] {
            assert!(Blend::from_name(n).is_some(), "{n}");
        }
        assert!(Blend::from_name("inconnu").is_none());
    }
}
