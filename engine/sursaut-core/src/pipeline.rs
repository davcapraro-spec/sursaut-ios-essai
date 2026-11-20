// SPDX-License-Identifier: GPL-3.0-or-later
//! Le pipeline avec cache par étage : la clé d'un étage cumule les paramètres de tous les étages précédents.
use std::sync::Arc;

use rayon::prelude::*;

use crate::color::{self, decode_lut16, decode_lut8};
use crate::image::Image;
use crate::recipe::Recipe;
use crate::stages;

type Img = Arc<Image>;
type StageFn = fn(&Img, &Recipe) -> Img;

const STAGES: [(&str, StageFn); 10] = [
    ("lens", stages::lens),
    ("spots", crate::spots::apply_spots),
    ("geometry", stages::geometry),
    ("wb_exposure", stages::wb_exposure),
    ("tone_regions", stages::tone_regions),
    ("contrast_curve", stages::contrast_curve),
    ("denoise", stages::denoise),
    ("detail", stages::detail),
    ("color", stages::color_stage),
    ("local", stages::local_and_finish),
];

/// Noms des étages, dans l'ordre d'exécution.
pub fn stage_names() -> Vec<&'static str> {
    STAGES.iter().map(|(n, _)| *n).collect()
}

fn stage_key(i: usize, r: &Recipe) -> String {
    let pts = |p: &Vec<[f64; 2]>| format!("{p:?}");
    match i {
        0 => format!("{:?}", r.lens),
        1 => format!("{:?}", r.spots),
        2 => format!("{} {} {} {} {} {} {}", r.crop_left, r.crop_top, r.crop_right, r.crop_bottom, r.angle, r.persp_v, r.persp_h),
        3 => format!("{} {} {} {} {} {} {} {} {} {}", r.exposure, r.temperature, r.tint, r.calib_shadow_tint, r.calib_red_hue, r.calib_red_sat, r.calib_green_hue, r.calib_green_sat, r.calib_blue_hue, r.calib_blue_sat),
        4 => format!("{} {}", r.highlights, r.shadows),
        5 => format!("{} {} {} {} {} {} {}", r.whites, r.blacks, r.contrast, pts(&r.curve), pts(&r.curve_red), pts(&r.curve_green), pts(&r.curve_blue)),
        6 => format!("{} {} {} {} {} {}", r.denoise_luma, r.denoise_color, r.denoise_luma_detail, r.denoise_luma_contrast, r.denoise_color_detail, r.denoise_color_smooth),
        7 => format!("{} {} {} {} {} {} {}", r.dehaze, r.clarity, r.texture, r.sharpen_amount, r.sharpen_radius, r.sharpen_masking, r.sharpen_detail),
        8 => format!("{} {} {} {:?} {:?} {} {} {} {} {}", r.vibrance, r.saturation, r.bw, r.hsl.bands(), r.grading.zones(), r.grading.cg_blending, r.grading.cg_balance, r.bw_red, r.bw_green, r.bw_blue),
        _ => format!("{:?} {} {} {} {} {} {} {} {} {} {}", r.masks, r.glow_amount, r.glow_radius, r.glow_threshold, r.grain_amount, r.grain_size, r.grain_roughness, r.vig_amount, r.vig_mid, r.vig_round, r.vig_feather),
    }
}

pub struct Pipeline {
    linear: Img,
    /// Taille de la source (reste valable après `render_banded` avec libération de la source).
    src_size: (usize, usize),
    use_cache: bool,
    cache: Vec<Option<(String, Img)>>,
    /// Étages recalculés lors du dernier rendu (comme `last_recomputed` côté Python).
    pub last_recomputed: Vec<&'static str>,
}

impl Pipeline {
    fn from_linear(linear: Image, use_cache: bool) -> Pipeline {
        Pipeline { src_size: (linear.w, linear.h), linear: Arc::new(linear), use_cache, cache: vec![None; STAGES.len()], last_recomputed: vec![] }
    }

    pub fn from_u8(w: usize, h: usize, rgb: &[u8], use_cache: bool) -> Pipeline {
        assert_eq!(rgb.len(), w * h * 3);
        let lut = decode_lut8();
        Self::from_linear(Image::new(w, h, rgb.par_iter().map(|&v| lut[v as usize]).collect()), use_cache)
    }

    pub fn from_u16(w: usize, h: usize, rgb: &[u16], use_cache: bool) -> Pipeline {
        assert_eq!(rgb.len(), w * h * 3);
        let lut = decode_lut16();
        Self::from_linear(Image::new(w, h, rgb.par_iter().map(|&v| lut[v as usize]).collect()), use_cache)
    }

    pub fn size(&self) -> (usize, usize) {
        self.src_size
    }

    /// Vide le cache des étages : à faire quand un calcul précédent a été interrompu par une panique (le cache pourrait être à moitié écrit). La source n'est pas touchée.
    pub fn reset_cache(&mut self) {
        self.cache = vec![None; STAGES.len()];
        self.last_recomputed.clear();
    }

    pub fn result_size(&self, r: &Recipe) -> (usize, usize) {
        stages::output_size(self.src_size.0, self.src_size.1, r)
    }

    /// La source a-t-elle été libérée par `render_banded` ? (le moteur ne peut plus rendre : il faut le recréer)
    pub fn is_spent(&self) -> bool {
        self.linear.w == 0
    }

    /// Rendu par bandes horizontales, pour les très grandes photos : les trois premiers étages (objectif, retouche des taches, géométrie) passent sur
    /// la photo entière, les suivants bande par bande, avec une marge qui rend le résultat identique au rendu entier (à l'arrondi près). La mémoire
    /// n'est plus celle d'une dizaine d'images entières, mais d'une photo + une bande.
    /// `target_px` : nombre de pixels visé pour une bande avec ses marges. `release` : libère la copie flottante de la source dès la géométrie faite
    /// (le moteur est alors « épuisé » : `is_spent`). Renvoie `None`, sans rien toucher, si la recette contient un masque avec détail local.
    pub fn render_banded<T: Copy + Default + Send + Sync>(
        &mut self, r: &Recipe, target_px: usize, release: bool, conv: impl Fn(f32) -> T + Sync,
    ) -> Option<(usize, usize, Vec<T>)> {
        if crate::masks::needs_detail(r) {
            return None;
        }
        assert!(!self.is_spent(), "render_banded : la source a déjà été libérée");
        self.last_recomputed = STAGES.iter().map(|(n, _)| *n).collect();
        let mut g = self.linear.clone();
        for (_, f) in STAGES.iter().take(3) {
            g = f(&g, r);
        }
        if release {
            self.linear = Arc::new(Image { w: 0, h: 0, data: Vec::new() });
        }
        let (w, h) = (g.w, g.h);
        let halo = stages::band_halo(r, w.max(h));
        let rows = (target_px / w.max(1)).saturating_sub(2 * halo).max(256).min(h);
        let mut out: Vec<T> = vec![T::default(); w * h * 3];
        let mut y0 = 0;
        while y0 < h {
            let y1 = (y0 + rows).min(h);
            let (e0, e1) = (y0.saturating_sub(halo), (y1 + halo).min(h));
            let mut band: Img = Arc::new(Image { w, h: e1 - e0, data: g.data[e0 * w * 3..e1 * w * 3].to_vec() });
            let tile = stages::Tile { full_w: w, full_h: h, y0: e0 };
            stages::with_tile(tile, || {
                for (_, f) in STAGES.iter().skip(3) {
                    band = f(&band, r);
                }
            });
            let src = &band.data[(y0 - e0) * w * 3..(y1 - e0) * w * 3];
            out[y0 * w * 3..y1 * w * 3].par_iter_mut().zip(src.par_iter()).for_each(|(o, &v)| *o = conv(v));
            y0 = y1;
        }
        Some((w, h, out))
    }

    /// Comme `render_u8`, par bandes (voir `render_banded`).
    pub fn render_banded_u8(&mut self, r: &Recipe, target_px: usize, release: bool) -> Option<(usize, usize, Vec<u8>)> {
        self.render_banded(r, target_px, release, |v| (v.clamp(0.0, 1.0) * 255.0 + 0.5) as u8)
    }

    /// Comme `render_u16`, par bandes (voir `render_banded`).
    pub fn render_banded_u16(&mut self, r: &Recipe, target_px: usize, release: bool) -> Option<(usize, usize, Vec<u16>)> {
        self.render_banded(r, target_px, release, |v| (v.clamp(0.0, 1.0) * 65535.0 + 0.5) as u16)
    }

    /// Rendu float32 [0,1] en sRGB d'affichage.
    pub fn render_float(&mut self, r: &Recipe) -> Img {
        self.render_stages(r, STAGES.len())
    }

    /// Valeur (0..1) du masque `index` sur l'image recadrée, telle qu'elle est juste avant les réglages locaux.
    pub fn render_mask(&mut self, r: &Recipe, index: usize) -> (usize, usize, Vec<f32>) {
        let before = self.render_stages(r, STAGES.len() - 1);
        (before.w, before.h, crate::masks::render_mask(&before, r, index))
    }

    fn render_stages(&mut self, r: &Recipe, count: usize) -> Img {
        assert!(!self.is_spent(), "La source de ce moteur a été libérée par un rendu par bandes : recréez le moteur.");
        let mut data = self.linear.clone();
        let mut key = String::new();
        self.last_recomputed.clear();
        for (i, (name, f)) in STAGES.iter().enumerate().take(count) {
            key.push_str(name);
            key.push(':');
            key.push_str(&stage_key(i, r));
            key.push('|');
            let hit = if self.use_cache { self.cache[i].as_ref().filter(|(k, _)| *k == key).map(|(_, v)| v.clone()) } else { None };
            data = match hit {
                Some(v) => v,
                None => {
                    let v = f(&data, r);
                    self.last_recomputed.push(name);
                    if self.use_cache {
                        self.cache[i] = Some((key.clone(), v.clone()));
                    }
                    v
                }
            };
        }
        if Arc::ptr_eq(&data, &self.linear) {
            let enc = color::encode_table();
            let d: Vec<f32> = data.data.par_iter().map(|&v| color::linear_to_srgb(enc, v)).collect();
            data = Arc::new(Image { w: data.w, h: data.h, data: d });
        }
        data
    }

    pub fn render_u8(&mut self, r: &Recipe) -> (usize, usize, Vec<u8>) {
        let o = self.render_float(r);
        (o.w, o.h, o.data.par_iter().map(|&v| (v.clamp(0.0, 1.0) * 255.0 + 0.5) as u8).collect())
    }

    pub fn render_u16(&mut self, r: &Recipe) -> (usize, usize, Vec<u16>) {
        let o = self.render_float(r);
        (o.w, o.h, o.data.par_iter().map(|&v| (v.clamp(0.0, 1.0) * 65535.0 + 0.5) as u16).collect())
    }
}

#[cfg(test)]
mod banded_tests {
    use super::*;

    /// Image de test : dégradés, un peu de bruit déterministe et un motif, pour que tous les flous aient quelque chose à faire.
    fn photo(w: usize, h: usize) -> Vec<u8> {
        let mut v = Vec::with_capacity(w * h * 3);
        let mut s: u32 = 12345;
        for y in 0..h {
            for x in 0..w {
                s = s.wrapping_mul(1664525).wrapping_add(1013904223);
                let noise = ((s >> 24) as i32 - 128) / 12;
                let base = [x * 255 / w, y * 255 / h, ((x / 40 + y / 40) % 2) * 160 + 40];
                for b in base {
                    v.push((b as i32 + noise).clamp(0, 255) as u8);
                }
            }
        }
        v
    }

    fn recipe(json: &str) -> Recipe {
        Recipe::from_json(json).expect("recette valide")
    }

    fn check(json: &str, w: usize, h: usize, max_diff: i32) {
        let r = recipe(json);
        let px = photo(w, h);
        let (fw, fh, full) = Pipeline::from_u8(w, h, &px, false).render_u8(&r);
        // cible minuscule : le minimum de 256 rangées par bande s'applique, donc plusieurs bandes
        let (bw, bh, banded) = Pipeline::from_u8(w, h, &px, false).render_banded_u8(&r, 1, false).expect("rendu par bandes possible");
        assert_eq!((fw, fh), (bw, bh));
        assert_eq!(full.len(), banded.len());
        let worst = full.iter().zip(&banded).map(|(a, b)| (*a as i32 - *b as i32).abs()).max().unwrap();
        let wrong = full.iter().zip(&banded).filter(|(a, b)| a != b).count();
        assert!(worst <= max_diff && wrong * 20 < full.len(), "écart max {worst}, {wrong} valeurs différentes sur {}", full.len());
    }

    #[test]
    fn banded_matches_full_without_blurs() {
        check(r#"{"exposure":0.4,"contrast":20,"saturation":15,"vig_amount":-40,"grain_amount":30}"#, 300, 700, 1);
    }

    #[test]
    fn banded_matches_full_with_every_blur() {
        check(
            r#"{"dehaze":25,"clarity":40,"texture":30,"sharpen_amount":60,"denoise_luma":30,"denoise_color":20,"vig_amount":-30,"grain_amount":20}"#,
            300, 900, 2,
        );
    }

    #[test]
    fn banded_matches_full_with_crop_angle_and_masks() {
        check(
            r#"{"angle":3.0,"crop_left":0.05,"crop_top":0.1,"crop_right":0.95,"crop_bottom":0.9,"clarity":20,
               "masks":[{"comps":[{"kind":"radial","x0":0.5,"y0":0.5,"rx":0.3,"ry":0.2,"feather":0.3}],"adj":{"exposure":0.8,"saturation":20}},
                        {"comps":[{"kind":"linear","x0":0.5,"y0":0.2,"x1":0.5,"y1":0.7}],"adj":{"exposure":-0.6}}]}"#,
            300, 900, 2,
        );
    }

    #[test]
    fn banded_declines_local_detail_masks_and_release_spends_the_engine() {
        let px = photo(64, 48);
        let with_detail = recipe(r#"{"masks":[{"comps":[{"kind":"radial","x0":0.5,"y0":0.5,"rx":0.3,"ry":0.3}],"adj":{"clarity":30}}]}"#);
        let mut p = Pipeline::from_u8(64, 48, &px, false);
        assert!(p.render_banded_u8(&with_detail, 1, true).is_none());
        assert!(!p.is_spent(), "refus : la source n'est pas touchée");
        let r = recipe(r#"{"exposure":0.2}"#);
        assert!(p.render_banded_u8(&r, 1, true).is_some());
        assert!(p.is_spent());
        assert_eq!(p.size(), (64, 48));
    }

    #[test]
    fn halo_is_zero_without_blurs_and_grows_with_them() {
        assert_eq!(stages::band_halo(&Recipe::default(), 9000), 0);
        let r = recipe(r#"{"clarity":10}"#);
        assert!(stages::band_halo(&r, 9000) >= 3 * 108);
        let all = recipe(r#"{"dehaze":10,"clarity":10,"texture":10,"sharpen_amount":10,"denoise_luma":10,"denoise_color":50}"#);
        assert!(stages::band_halo(&all, 9000) > stages::band_halo(&r, 9000));
    }
}

#[cfg(test)]
mod conversion_tests {
    use super::*;

    /// Les conversions d'entrée et de sortie, passées en parallèle, donnent exactement les valeurs de la formule d'origine (en série).
    #[test]
    fn parallel_conversions_match_the_serial_formulas() {
        let (w, h) = (37usize, 23usize);
        let rgb8: Vec<u8> = (0..w * h * 3).map(|i| (i * 7 % 256) as u8).collect();
        let lut8 = decode_lut8();
        let want8: Vec<f32> = rgb8.iter().map(|&v| lut8[v as usize]).collect();
        assert_eq!(Pipeline::from_u8(w, h, &rgb8, false).linear.data, want8);
        let rgb16: Vec<u16> = (0..w * h * 3).map(|i| (i * 911 % 65536) as u16).collect();
        let lut16 = decode_lut16();
        let want16: Vec<f32> = rgb16.iter().map(|&v| lut16[v as usize]).collect();
        assert_eq!(Pipeline::from_u16(w, h, &rgb16, false).linear.data, want16);

        let r = Recipe::from_json(r#"{"exposure":0.3,"contrast":10}"#).expect("recette valide");
        let mut p = Pipeline::from_u8(w, h, &rgb8, false);
        let (ow, oh, out8) = p.render_u8(&r);
        let (_, _, out16) = p.render_u16(&r);
        let f = p.render_float(&r);
        assert_eq!((ow, oh), (f.w, f.h));
        let w8: Vec<u8> = f.data.iter().map(|&v| (v.clamp(0.0, 1.0) * 255.0 + 0.5) as u8).collect();
        let w16: Vec<u16> = f.data.iter().map(|&v| (v.clamp(0.0, 1.0) * 65535.0 + 0.5) as u16).collect();
        assert_eq!(out8, w8);
        assert_eq!(out16, w16);
    }

    #[test]
    fn reset_cache_forces_a_full_recompute_with_the_same_result() {
        let (w, h) = (40usize, 30usize);
        let rgb: Vec<u8> = (0..w * h * 3).map(|i| (i * 13 % 256) as u8).collect();
        let r = Recipe::from_json(r#"{"exposure":0.5,"clarity":20}"#).expect("recette valide");
        let mut p = Pipeline::from_u8(w, h, &rgb, true);
        let first = p.render_u8(&r);
        p.render_u8(&r);
        assert!(p.last_recomputed.is_empty(), "deuxième rendu identique : tout vient du cache");
        p.reset_cache();
        assert_eq!(p.render_u8(&r), first);
        assert!(!p.last_recomputed.is_empty(), "après le vidage du cache, les étages sont recalculés");
    }
}
