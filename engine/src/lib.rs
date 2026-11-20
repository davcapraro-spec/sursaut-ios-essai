//! Moteur Sursaut iPad — étape 1.
//!
//! Interface C minimale, appelée depuis Dart par `dart:ffi` :
//!   - `sursaut_engine_version`  : texte de version (preuve que la chaîne Flutter -> Rust marche) ;
//!   - `sursaut_render_rgba8`    : applique une recette JSON à une image RGBA 8 bits ;
//!   - `sursaut_engine_keep`     : référence toutes les fonctions pour que l'éditeur de liens
//!                                 iOS ne les supprime pas (appelée une fois par le code Swift).
//!
//! Le traitement se fait en lumière linéaire (sRGB -> linéaire -> réglages -> sRGB).
//! Aucune image n'est conservée entre deux appels : l'appelant fournit les deux tampons.

use serde::Deserialize;
use std::ffi::{c_char, CStr};

/// Version du moteur (texte terminé par un zéro, durée de vie statique).
const VERSION: &[u8] = b"sursaut_engine 0.1.0 (etape 1)\0";

/// Recette de l'étape 1. Les clés inconnues sont ignorées, les clés absentes valent 0
/// (règle déjà en vigueur pour la recette du PC).
#[derive(Debug, Clone, Copy, Deserialize, PartialEq)]
#[serde(default)]
pub struct Recipe {
    /// Exposition en IL (diaphragmes), -5 à +5.
    pub exposure: f32,
    /// Contraste, -100 à +100.
    pub contrast: f32,
    /// Hautes lumières, -100 à +100 (négatif = récupérer).
    pub highlights: f32,
    /// Ombres, -100 à +100 (positif = éclaircir).
    pub shadows: f32,
    /// Saturation, -100 à +100.
    pub saturation: f32,
    /// Température, -100 (froid) à +100 (chaud).
    pub temperature: f32,
}

impl Default for Recipe {
    fn default() -> Self {
        Recipe { exposure: 0.0, contrast: 0.0, highlights: 0.0, shadows: 0.0, saturation: 0.0, temperature: 0.0 }
    }
}

impl Recipe {
    fn is_identity(&self) -> bool {
        *self == Recipe::default()
    }
}

#[inline]
fn srgb_to_linear(v: f32) -> f32 {
    if v <= 0.04045 { v / 12.92 } else { ((v + 0.055) / 1.055).powf(2.4) }
}

#[inline]
fn linear_to_srgb(v: f32) -> f32 {
    if v <= 0.0031308 { v * 12.92 } else { 1.055 * v.powf(1.0 / 2.4) - 0.055 }
}

#[inline]
fn smoothstep(e0: f32, e1: f32, x: f32) -> f32 {
    let t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

const OUT_LUT_SIZE: usize = 4096;

struct Tables {
    to_linear: [f32; 256],
    to_srgb: Vec<u8>, // OUT_LUT_SIZE + 1 entrées, indexées par le linéaire [0,1]
}

impl Tables {
    fn new() -> Self {
        let mut to_linear = [0.0f32; 256];
        for (i, v) in to_linear.iter_mut().enumerate() {
            *v = srgb_to_linear(i as f32 / 255.0);
        }
        let mut to_srgb = Vec::with_capacity(OUT_LUT_SIZE + 1);
        for i in 0..=OUT_LUT_SIZE {
            let l = i as f32 / OUT_LUT_SIZE as f32;
            to_srgb.push((linear_to_srgb(l) * 255.0 + 0.5).clamp(0.0, 255.0) as u8);
        }
        Tables { to_linear, to_srgb }
    }
}

/// Traite une ligne de pixels (RGBA, 4 octets par pixel).
fn process_rows(src: &[u8], dst: &mut [u8], r: &Recipe, t: &Tables) {
    let gain = 2.0f32.powf(r.exposure);
    // Température : chauffer = plus de rouge, moins de bleu (±20 % aux extrêmes).
    let wb_r = 1.0 + 0.20 * r.temperature / 100.0;
    let wb_b = 1.0 - 0.20 * r.temperature / 100.0;
    let contrast_exp = 1.0 + 0.6 * r.contrast / 100.0;
    let sat = 1.0 + r.saturation / 100.0;
    let sh = r.shadows / 100.0;
    let hl = r.highlights / 100.0;
    const PIVOT: f32 = 0.18;

    for (s, d) in src.chunks_exact(4).zip(dst.chunks_exact_mut(4)) {
        let mut rgb = [t.to_linear[s[0] as usize], t.to_linear[s[1] as usize], t.to_linear[s[2] as usize]];
        rgb[0] *= wb_r * gain;
        rgb[1] *= gain;
        rgb[2] *= wb_b * gain;

        if sh != 0.0 || hl != 0.0 {
            let lum = 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2];
            let f = (1.0 + sh * 0.8 * (1.0 - smoothstep(0.0, 0.5, lum)))
                * (1.0 + hl * 0.5 * smoothstep(0.5, 1.0, lum));
            for c in rgb.iter_mut() {
                *c *= f;
            }
        }
        if contrast_exp != 1.0 {
            for c in rgb.iter_mut() {
                *c = if *c > 0.0 { PIVOT * (*c / PIVOT).powf(contrast_exp) } else { 0.0 };
            }
        }
        if sat != 1.0 {
            let lum = 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2];
            for c in rgb.iter_mut() {
                *c = lum + (*c - lum) * sat;
            }
        }
        for k in 0..3 {
            let l = rgb[k].clamp(0.0, 1.0);
            d[k] = t.to_srgb[(l * OUT_LUT_SIZE as f32 + 0.5) as usize];
        }
        d[3] = s[3];
    }
}

/// Rend `src` (RGBA 8 bits, `width * height * 4` octets) dans `dst` (même taille).
pub fn render(src: &[u8], dst: &mut [u8], width: usize, height: usize, recipe: &Recipe) {
    let row = width * 4;
    assert_eq!(src.len(), row * height);
    assert_eq!(dst.len(), row * height);
    if recipe.is_identity() {
        dst.copy_from_slice(src);
        return;
    }
    let tables = Tables::new();
    let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1).min(8).min(height.max(1));
    if threads <= 1 || height < 64 {
        process_rows(src, dst, recipe, &tables);
        return;
    }
    let rows_per = (height + threads - 1) / threads;
    std::thread::scope(|scope| {
        for (s, d) in src.chunks(rows_per * row).zip(dst.chunks_mut(rows_per * row)) {
            let tables = &tables;
            scope.spawn(move || process_rows(s, d, recipe, tables));
        }
    });
}

// ------------------------------------------------------------------ interface C

/// Codes de retour de `sursaut_render_rgba8`.
pub const OK: i32 = 0;
pub const ERR_NULL: i32 = 1;
pub const ERR_JSON: i32 = 2;
pub const ERR_SIZE: i32 = 3;

#[no_mangle]
pub extern "C" fn sursaut_engine_version() -> *const c_char {
    VERSION.as_ptr() as *const c_char
}

/// # Safety
/// `src` et `out` pointent vers `width * height * 4` octets valides, `recipe_json` vers un texte
/// terminé par un zéro (ou nul = recette vide). `src` et `out` peuvent être le même tampon.
#[no_mangle]
pub unsafe extern "C" fn sursaut_render_rgba8(
    src: *const u8,
    width: u32,
    height: u32,
    recipe_json: *const c_char,
    out: *mut u8,
) -> i32 {
    if src.is_null() || out.is_null() {
        return ERR_NULL;
    }
    let (w, h) = (width as usize, height as usize);
    let len = match w.checked_mul(h).and_then(|n| n.checked_mul(4)) {
        Some(n) if n > 0 => n,
        _ => return ERR_SIZE,
    };
    let recipe = if recipe_json.is_null() {
        Recipe::default()
    } else {
        let text = match CStr::from_ptr(recipe_json).to_str() {
            Ok(t) => t,
            Err(_) => return ERR_JSON,
        };
        if text.trim().is_empty() {
            Recipe::default()
        } else {
            match serde_json::from_str::<Recipe>(text) {
                Ok(r) => r,
                Err(_) => return ERR_JSON,
            }
        }
    };
    if src == out as *const u8 {
        // Même tampon : on passe par une copie de la source.
        let copy = std::slice::from_raw_parts(src, len).to_vec();
        render(&copy, std::slice::from_raw_parts_mut(out, len), w, h, &recipe);
    } else {
        render(std::slice::from_raw_parts(src, len), std::slice::from_raw_parts_mut(out, len), w, h, &recipe);
    }
    OK
}

/// Référence toutes les fonctions exportées. Le code Swift de l'application l'appelle une fois
/// au démarrage : sans cela, l'éditeur de liens d'iOS peut retirer les fonctions que seul Dart
/// (par `dart:ffi`) utilise. Renvoie le nombre de fonctions exportées.
#[no_mangle]
pub extern "C" fn sursaut_engine_keep() -> u32 {
    let table: [usize; 2] = [
        sursaut_engine_version as *const () as usize,
        sursaut_render_rgba8 as *const () as usize,
    ];
    std::hint::black_box(&table);
    table.len() as u32
}

#[cfg(test)]
mod bench {
    use super::*;
    #[test]
    #[ignore]
    fn chrono_2752x2064() {
        let (w, h) = (2752usize, 2064usize);
        let src: Vec<u8> = (0..w * h * 4).map(|i| (i * 7 % 251) as u8).collect();
        let mut out = vec![0u8; src.len()];
        let r = Recipe { exposure: 0.5, contrast: 25.0, highlights: -30.0, shadows: 40.0, saturation: 20.0, temperature: 10.0 };
        let t = std::time::Instant::now();
        render(&src, &mut out, w, h, &r);
        eprintln!("rendu {}x{} : {:?} ({} fils)", w, h, t.elapsed(), std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn gradient(w: usize, h: usize) -> Vec<u8> {
        let mut v = Vec::with_capacity(w * h * 4);
        for y in 0..h {
            for x in 0..w {
                v.extend_from_slice(&[(x * 255 / w.max(1)) as u8, (y * 255 / h.max(1)) as u8, ((x + y) % 256) as u8, 255]);
            }
        }
        v
    }

    fn run(src: &[u8], w: u32, h: u32, json: &str) -> (i32, Vec<u8>) {
        let mut out = vec![0u8; src.len()];
        let c = std::ffi::CString::new(json).unwrap();
        let code = unsafe { sursaut_render_rgba8(src.as_ptr(), w, h, c.as_ptr(), out.as_mut_ptr()) };
        (code, out)
    }

    #[test]
    fn version_est_un_texte_c() {
        let s = unsafe { CStr::from_ptr(sursaut_engine_version()) }.to_str().unwrap();
        assert!(s.starts_with("sursaut_engine 0.1.0"));
    }

    #[test]
    fn recette_vide_ne_change_rien() {
        let src = gradient(100, 80);
        let (code, out) = run(&src, 100, 80, "{}");
        assert_eq!(code, OK);
        assert_eq!(src, out);
    }

    #[test]
    fn recette_neutre_explicite_ne_change_rien_a_un_niveau_pres() {
        // Les réglages à zéro sont reconnus comme neutres (copie directe).
        let src = gradient(100, 80);
        let (_, out) = run(&src, 100, 80, r#"{"exposure":0,"contrast":0,"cle_inconnue":7}"#);
        assert_eq!(src, out);
    }

    #[test]
    fn aller_retour_des_tables_est_exact_a_un_niveau() {
        // Un réglage non nul mais infime passe par toute la chaîne : l'écart doit rester ≤ 1.
        let src = gradient(100, 80);
        let (_, out) = run(&src, 100, 80, r#"{"exposure":0.00001}"#);
        let max = src.iter().zip(&out).map(|(a, b)| (*a as i32 - *b as i32).abs()).max().unwrap();
        assert!(max <= 1, "écart max {max}");
    }

    #[test]
    fn exposition_plus_un_double_la_lumiere_lineaire() {
        // Gris moyen sRGB 118 ≈ 0.18 linéaire ; +1 IL -> 0.36 linéaire ≈ sRGB 160.
        let src = vec![118, 118, 118, 255];
        let (_, out) = run(&src, 1, 1, r#"{"exposure":1}"#);
        assert!((out[0] as i32 - 160).abs() <= 2, "obtenu {}", out[0]);
        assert_eq!(out[3], 255);
    }

    #[test]
    fn saturation_moins_cent_donne_du_gris() {
        let src = vec![200, 50, 30, 255];
        let (_, out) = run(&src, 1, 1, r#"{"saturation":-100}"#);
        assert!((out[0] as i32 - out[1] as i32).abs() <= 1 && (out[1] as i32 - out[2] as i32).abs() <= 1, "{out:?}");
    }

    #[test]
    fn temperature_chaude_monte_le_rouge_et_baisse_le_bleu() {
        let src = vec![128, 128, 128, 255];
        let (_, out) = run(&src, 1, 1, r#"{"temperature":50}"#);
        assert!(out[0] > 128 && out[2] < 128, "{out:?}");
    }

    #[test]
    fn ombres_eclaircissent_le_sombre_sans_toucher_le_clair() {
        let src = vec![30, 30, 30, 255, 240, 240, 240, 255];
        let (_, out) = run(&src, 2, 1, r#"{"shadows":100}"#);
        assert!(out[0] > 30 + 8, "{out:?}");
        assert!((out[4] as i32 - 240).abs() <= 1, "{out:?}");
    }

    #[test]
    fn plusieurs_fils_donnent_le_meme_resultat_qu_un_seul() {
        let (w, h) = (200, 300);
        let src = gradient(w, h);
        let r = Recipe { exposure: 0.4, contrast: 20.0, saturation: 15.0, ..Recipe::default() };
        let mut a = vec![0u8; src.len()];
        render(&src, &mut a, w, h, &r);
        let mut b = vec![0u8; src.len()];
        process_rows(&src, &mut b, &r, &Tables::new());
        assert_eq!(a, b);
    }

    #[test]
    fn erreurs_de_l_interface() {
        let src = gradient(4, 4);
        assert_eq!(run(&src, 4, 4, "pas du json").0, ERR_JSON);
        assert_eq!(run(&src, 0, 4, "{}").0, ERR_SIZE);
        let mut out = vec![0u8; src.len()];
        assert_eq!(unsafe { sursaut_render_rgba8(std::ptr::null(), 4, 4, std::ptr::null(), out.as_mut_ptr()) }, ERR_NULL);
    }

    #[test]
    fn meme_tampon_en_entree_et_sortie() {
        let mut buf = gradient(8, 8);
        let expected = run(&buf, 8, 8, r#"{"exposure":1}"#).1;
        let c = std::ffi::CString::new(r#"{"exposure":1}"#).unwrap();
        let p = buf.as_mut_ptr();
        assert_eq!(unsafe { sursaut_render_rgba8(p, 8, 8, c.as_ptr(), p) }, OK);
        assert_eq!(buf, expected);
    }

    #[test]
    fn keep_compte_les_fonctions() {
        assert_eq!(sursaut_engine_keep(), 2);
    }
}
