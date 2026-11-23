//! Pont C du moteur Sursaut (`sursaut-core`) pour l'iPad.
//!
//! Dart (dart:ffi) manipule un « moteur » opaque : une photo ouverte, avec le cache par étage
//! du pipeline. Chaque rendu applique une recette JSON (identique à celle du PC) et rend une
//! image RGBA 8 bits.
//!
//!   sursaut_engine_version()                       texte de version
//!   sursaut_engine_open_rgba8(src, w, h)           ouvre une photo (RGBA 8 bits) -> moteur ou nul
//!   sursaut_engine_render(moteur, json, &w, &h)    rend -> pointeur RGBA (valable jusqu'au prochain appel) ou nul
//!   sursaut_engine_last_error()                    dernier message d'erreur (texte)
//!   sursaut_engine_close(moteur)                   libère
//!   sursaut_spot_tool(rgba, w, h, op, x, y, r, sortie)  outils de retouche : source, repérage d'une tache ou d'un objet
//!   sursaut_dust_detect(rgba, w, h)                poussière du capteur trouvée (JSON)
//!   sursaut_eyes_detect(rgba, w, h)                reflets de pupille (yeux rouges, yeux d'animaux) trouvés (JSON)
//!   sursaut_engine_keep()                          référence les fonctions (voir PencilBridgePlugin.swift)
//!
//! Lecture d'un RAW (étape 3a, LibRaw) :
//!   sursaut_raw_open(chemin)                       ouvre un fichier RAW, lit les métadonnées -> poignée ou nul
//!   sursaut_raw_info_json(raw)                     métadonnées + temps du dernier développement (JSON)
//!   sursaut_raw_develop(raw, demi, côté_max, rendu, &w, &h)  développe -> pointeur RGBA (valable jusqu'au prochain appel) ou nul
//!   sursaut_raw_close(raw)                         libère
//!
//! Un moteur ne doit être utilisé que par un appel à la fois (Dart sérialise les rendus).
//! Une panique du moteur est attrapée à la frontière : elle devient une erreur, jamais un plantage.

pub mod raw;

use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::Mutex;
use sursaut_core::{Pipeline, Recipe};

const VERSION: &[u8] = b"sursaut_engine 0.6.0 (moteur sursaut-core + LibRaw 0.21.3)\0";

static LAST_ERROR: Mutex<Option<CString>> = Mutex::new(None);

fn set_error(msg: &str) {
    let c = CString::new(msg.replace('\0', " ")).unwrap_or_default();
    if let Ok(mut g) = LAST_ERROR.lock() {
        *g = Some(c);
    }
}

pub struct Engine {
    pipe: Pipeline,
    /// Dernier rendu, en RGBA 8 bits (alpha = 255).
    out: Vec<u8>,
}

impl Engine {
    pub fn open_rgba8(rgba: &[u8], w: usize, h: usize) -> Result<Engine, String> {
        if w == 0 || h == 0 || rgba.len() != w * h * 4 {
            return Err(format!("taille d'image incohérente : {w}x{h}, {} octets", rgba.len()));
        }
        let mut rgb = Vec::with_capacity(w * h * 3);
        for p in rgba.chunks_exact(4) {
            rgb.extend_from_slice(&p[..3]);
        }
        Ok(Engine { pipe: Pipeline::from_u8(w, h, &rgb, true), out: Vec::new() })
    }

    /// Rend la photo avec la recette JSON ; renvoie (largeur, hauteur) du résultat (le recadrage peut changer la taille).
    pub fn render(&mut self, recipe_json: &str) -> Result<(usize, usize), String> {
        let recipe = if recipe_json.trim().is_empty() { Recipe::default() } else { Recipe::from_json(recipe_json)? };
        let (w, h, rgb) = self.pipe.render_u8(&recipe);
        self.out.clear();
        self.out.reserve(w * h * 4);
        for p in rgb.chunks_exact(3) {
            self.out.extend_from_slice(&[p[0], p[1], p[2], 255]);
        }
        Ok((w, h))
    }

    pub fn output(&self) -> &[u8] {
        &self.out
    }

    /// Étages recalculés par le dernier rendu (utile pour vérifier le cache).
    pub fn recomputed(&self) -> Vec<&'static str> {
        self.pipe.last_recomputed.clone()
    }
}

#[no_mangle]
pub extern "C" fn sursaut_engine_version() -> *const c_char {
    VERSION.as_ptr() as *const c_char
}

#[no_mangle]
pub extern "C" fn sursaut_engine_last_error() -> *const c_char {
    match LAST_ERROR.lock() {
        Ok(g) => match g.as_ref() {
            Some(c) => c.as_ptr(),
            None => b"\0".as_ptr() as *const c_char,
        },
        Err(_) => b"\0".as_ptr() as *const c_char,
    }
}

/// # Safety
/// `src` pointe vers `width * height * 4` octets valides.
#[no_mangle]
pub unsafe extern "C" fn sursaut_engine_open_rgba8(src: *const u8, width: u32, height: u32) -> *mut Engine {
    if src.is_null() {
        set_error("image absente");
        return std::ptr::null_mut();
    }
    let (w, h) = (width as usize, height as usize);
    let len = match w.checked_mul(h).and_then(|n| n.checked_mul(4)) {
        Some(n) => n,
        None => {
            set_error("image trop grande");
            return std::ptr::null_mut();
        }
    };
    let slice = std::slice::from_raw_parts(src, len);
    match catch_unwind(AssertUnwindSafe(|| Engine::open_rgba8(slice, w, h))) {
        Ok(Ok(e)) => Box::into_raw(Box::new(e)),
        Ok(Err(m)) => {
            set_error(&m);
            std::ptr::null_mut()
        }
        Err(_) => {
            set_error("le moteur a rencontré une erreur interne à l'ouverture");
            std::ptr::null_mut()
        }
    }
}

/// # Safety
/// `engine` vient de `sursaut_engine_open_rgba8` ; `recipe_json` est un texte terminé par un zéro (ou nul) ;
/// `out_w` et `out_h` pointent vers des entiers valides.
#[no_mangle]
pub unsafe extern "C" fn sursaut_engine_render(
    engine: *mut Engine,
    recipe_json: *const c_char,
    out_w: *mut u32,
    out_h: *mut u32,
) -> *const u8 {
    if engine.is_null() || out_w.is_null() || out_h.is_null() {
        set_error("moteur ou sortie absents");
        return std::ptr::null();
    }
    let json = if recipe_json.is_null() {
        ""
    } else {
        match CStr::from_ptr(recipe_json).to_str() {
            Ok(t) => t,
            Err(_) => {
                set_error("recette : texte non valide");
                return std::ptr::null();
            }
        }
    };
    let e = &mut *engine;
    match catch_unwind(AssertUnwindSafe(|| e.render(json))) {
        Ok(Ok((w, h))) => {
            *out_w = w as u32;
            *out_h = h as u32;
            e.output().as_ptr()
        }
        Ok(Err(m)) => {
            set_error(&m);
            std::ptr::null()
        }
        Err(_) => {
            // Le cache a pu rester à moitié écrit : on le vide (la source n'est pas touchée).
            e.pipe.reset_cache();
            set_error("le moteur a rencontré une erreur interne pendant le rendu");
            std::ptr::null()
        }
    }
}

/// # Safety
/// `engine` vient de `sursaut_engine_open_rgba8` et n'est plus utilisé ensuite (nul accepté).
#[no_mangle]
pub unsafe extern "C" fn sursaut_engine_close(engine: *mut Engine) {
    if !engine.is_null() {
        drop(Box::from_raw(engine));
    }
}

/// # Safety
/// `path` est un texte UTF-8 terminé par un zéro.
#[no_mangle]
pub unsafe extern "C" fn sursaut_raw_open(path: *const c_char) -> *mut raw::RawFile {
    if path.is_null() {
        set_error("chemin absent");
        return std::ptr::null_mut();
    }
    let p = match CStr::from_ptr(path).to_str() {
        Ok(t) => t.to_string(),
        Err(_) => {
            set_error("chemin : texte non valide");
            return std::ptr::null_mut();
        }
    };
    match catch_unwind(AssertUnwindSafe(|| raw::RawFile::open(&p))) {
        Ok(Ok(f)) => Box::into_raw(Box::new(f)),
        Ok(Err(m)) => {
            set_error(&m);
            std::ptr::null_mut()
        }
        Err(_) => {
            set_error("le moteur a rencontré une erreur interne à l'ouverture du RAW");
            std::ptr::null_mut()
        }
    }
}

/// # Safety
/// `raw` vient de `sursaut_raw_open`. Le texte rendu reste valable jusqu'au prochain développement.
#[no_mangle]
pub unsafe extern "C" fn sursaut_raw_info_json(raw: *mut raw::RawFile) -> *const c_char {
    if raw.is_null() {
        set_error("RAW absent");
        return std::ptr::null();
    }
    (*raw).json_ptr()
}

/// # Safety
/// `raw` vient de `sursaut_raw_open` ; `out_w` et `out_h` pointent vers des entiers valides.
#[no_mangle]
pub unsafe extern "C" fn sursaut_raw_develop(
    raw: *mut raw::RawFile,
    half: i32,
    max_side: u32,
    look: i32,
    out_w: *mut u32,
    out_h: *mut u32,
) -> *const u8 {
    if raw.is_null() || out_w.is_null() || out_h.is_null() {
        set_error("RAW ou sortie absents");
        return std::ptr::null();
    }
    let f = &mut *raw;
    match catch_unwind(AssertUnwindSafe(|| f.develop(half != 0, max_side, look))) {
        Ok(Ok(())) => {
            let t = f.last.clone().unwrap_or_default();
            *out_w = t.out_w;
            *out_h = t.out_h;
            f.preview().as_ptr()
        }
        Ok(Err(m)) => {
            set_error(&m);
            std::ptr::null()
        }
        Err(_) => {
            set_error("le moteur a rencontré une erreur interne pendant le développement du RAW");
            std::ptr::null()
        }
    }
}

/// # Safety
/// `raw` vient de `sursaut_raw_open` et n'est plus utilisé ensuite (nul accepté).
#[no_mangle]
pub unsafe extern "C" fn sursaut_raw_close(raw: *mut raw::RawFile) {
    if !raw.is_null() {
        drop(Box::from_raw(raw));
    }
}

static DUST_TEXT: Mutex<Option<CString>> = Mutex::new(None);
static EYES_TEXT: Mutex<Option<CString>> = Mutex::new(None);

fn rgba_to_rgb(rgba: &[u8]) -> Vec<u8> {
    let mut rgb = Vec::with_capacity(rgba.len() / 4 * 3);
    for p in rgba.chunks_exact(4) {
        rgb.extend_from_slice(&p[..3]);
    }
    rgb
}

/// Outils de retouche sur une photo RGBA 8 bits (sans état : la photo n'est pas gardée).
/// `op` : 0 = source proposée pour une tache (écrit sx, sy), 1 = repérage d'une tache sombre près du clic (x, y, rayon),
/// 2 = repérage d'un objet clair ou sombre avec son halo (x, y, rayon). x, y en fractions, r en fraction du grand côté.
/// Renvoie le nombre de valeurs écrites dans `out` (0 = rien trouvé, -1 = erreur).
///
/// # Safety
/// `rgba` pointe vers `w * h * 4` octets valides ; `out` vers au moins 3 réels.
#[no_mangle]
pub unsafe extern "C" fn sursaut_spot_tool(
    rgba: *const u8, w: u32, h: u32, op: i32, x: f64, y: f64, r: f64, out: *mut f64,
) -> i32 {
    if rgba.is_null() || out.is_null() {
        set_error("image ou sortie absente");
        return -1;
    }
    let (w, h) = (w as usize, h as usize);
    let slice = std::slice::from_raw_parts(rgba, w * h * 4);
    let res = catch_unwind(AssertUnwindSafe(|| -> Vec<f64> {
        let rgb = rgba_to_rgb(slice);
        match op {
            0 => {
                let data: Vec<f32> = rgb.iter().map(|&v| v as f32 / 255.0).collect();
                let img = sursaut_core::Image::new(w, h, data);
                let (sx, sy) = sursaut_core::spots::suggest_source(&img, x, y, r);
                vec![sx, sy]
            }
            1 => sursaut_core::dust::refine(&rgb, w, h, x, y, r).map(|(a, b, c)| vec![a, b, c]).unwrap_or_default(),
            _ => sursaut_core::dust::refine_object(&rgb, w, h, x, y, r).map(|(a, b, c)| vec![a, b, c]).unwrap_or_default(),
        }
    }));
    match res {
        Ok(v) => {
            for (i, a) in v.iter().enumerate().take(3) {
                *out.add(i) = *a;
            }
            v.len().min(3) as i32
        }
        Err(_) => {
            set_error("erreur interne dans l'outil de retouche");
            -1
        }
    }
}

/// Poussière du capteur : liste JSON `[{"x":..,"y":..,"r":..,"score":..,"contrast":..}, ...]` (classée par score).
/// Le texte reste valable jusqu'au prochain appel. Nul en cas d'erreur.
///
/// # Safety
/// `rgba` pointe vers `w * h * 4` octets valides.
#[no_mangle]
pub unsafe extern "C" fn sursaut_dust_detect(rgba: *const u8, w: u32, h: u32) -> *const c_char {
    if rgba.is_null() {
        set_error("image absente");
        return std::ptr::null();
    }
    let (w, h) = (w as usize, h as usize);
    let slice = std::slice::from_raw_parts(rgba, w * h * 4);
    let res = catch_unwind(AssertUnwindSafe(|| {
        let found = sursaut_core::dust::detect(&rgba_to_rgb(slice), w, h);
        let items: Vec<String> = found
            .iter()
            .map(|d| format!("{{\"x\":{},\"y\":{},\"r\":{},\"score\":{},\"contrast\":{}}}", d.x, d.y, d.r, d.score, d.contrast))
            .collect();
        format!("[{}]", items.join(","))
    }));
    match res {
        Ok(t) => {
            let c = CString::new(t).unwrap_or_default();
            match DUST_TEXT.lock() {
                Ok(mut g) => {
                    *g = Some(c);
                    g.as_ref().map(|c| c.as_ptr()).unwrap_or(std::ptr::null())
                }
                Err(_) => std::ptr::null(),
            }
        }
        Err(_) => {
            set_error("erreur interne dans la recherche de poussière");
            std::ptr::null()
        }
    }
}

/// Reflets de pupille : liste JSON `[{"x":..,"y":..,"r":..,"hue":"rouge","score":..,"chroma":..}, ...]` (du plus sûr au moins sûr).
/// Le texte reste valable jusqu'au prochain appel. Nul en cas d'erreur.
///
/// # Safety
/// `rgba` pointe vers `w * h * 4` octets valides.
#[no_mangle]
pub unsafe extern "C" fn sursaut_eyes_detect(rgba: *const u8, w: u32, h: u32) -> *const c_char {
    if rgba.is_null() {
        set_error("image absente");
        return std::ptr::null();
    }
    let (w, h) = (w as usize, h as usize);
    let slice = std::slice::from_raw_parts(rgba, w * h * 4);
    let res = catch_unwind(AssertUnwindSafe(|| {
        let found = sursaut_core::eyeshine::find_eyeshine(&rgba_to_rgb(slice), w, h, 8);
        let items: Vec<String> = found
            .iter()
            .map(|e| format!("{{\"x\":{},\"y\":{},\"r\":{},\"hue\":\"{}\",\"score\":{},\"chroma\":{}}}", e.x, e.y, e.r, e.hue, e.score, e.chroma))
            .collect();
        format!("[{}]", items.join(","))
    }));
    match res {
        Ok(t) => {
            let c = CString::new(t).unwrap_or_default();
            match EYES_TEXT.lock() {
                Ok(mut g) => {
                    *g = Some(c);
                    g.as_ref().map(|c| c.as_ptr()).unwrap_or(std::ptr::null())
                }
                Err(_) => std::ptr::null(),
            }
        }
        Err(_) => {
            set_error("erreur interne dans la recherche des yeux");
            std::ptr::null()
        }
    }
}

/// Confie au moteur l'image d'un masque d'IA (octets, `w * h`, 255 = dans la zone) sous la clé `key` : une composante
/// `bitmap` de la recette la cite ensuite par cette clé. Renvoie 1 si c'est fait, 0 sinon.
///
/// # Safety
/// `key` est un texte UTF-8 terminé par un zéro ; `data` pointe vers `w * h` octets valides.
#[no_mangle]
pub unsafe extern "C" fn sursaut_set_bitmap(key: *const c_char, w: u32, h: u32, data: *const u8) -> i32 {
    if key.is_null() || data.is_null() || w == 0 || h == 0 {
        set_error("image de masque absente");
        return 0;
    }
    let k = match CStr::from_ptr(key).to_str() {
        Ok(t) => t.to_string(),
        Err(_) => {
            set_error("clé de masque illisible");
            return 0;
        }
    };
    let (w, h) = (w as usize, h as usize);
    let v = std::slice::from_raw_parts(data, w * h).to_vec();
    match catch_unwind(AssertUnwindSafe(|| sursaut_core::masks::set_bitmap(&k, w, h, v))) {
        Ok(()) => 1,
        Err(_) => {
            set_error("erreur interne : image de masque refusée");
            0
        }
    }
}

/// Le moteur a-t-il déjà l'image du masque `key` ? 1 = oui, 0 = non.
///
/// # Safety
/// `key` est un texte UTF-8 terminé par un zéro.
#[no_mangle]
pub unsafe extern "C" fn sursaut_has_bitmap(key: *const c_char) -> i32 {
    if key.is_null() {
        return 0;
    }
    match CStr::from_ptr(key).to_str() {
        Ok(k) => i32::from(sursaut_core::masks::has_bitmap(k)),
        Err(_) => 0,
    }
}

/// Référence toutes les fonctions exportées : l'éditeur de liens d'iOS retire sinon celles que
/// seul Dart (dart:ffi) utilise. Appelée une fois par le code Swift. Renvoie leur nombre.
#[no_mangle]
pub extern "C" fn sursaut_engine_keep() -> u32 {
    let table: [usize; 14] = [
        sursaut_engine_version as *const () as usize,
        sursaut_engine_last_error as *const () as usize,
        sursaut_engine_open_rgba8 as *const () as usize,
        sursaut_engine_render as *const () as usize,
        sursaut_engine_close as *const () as usize,
        sursaut_raw_open as *const () as usize,
        sursaut_raw_info_json as *const () as usize,
        sursaut_raw_develop as *const () as usize,
        sursaut_raw_close as *const () as usize,
        sursaut_spot_tool as *const () as usize,
        sursaut_dust_detect as *const () as usize,
        sursaut_eyes_detect as *const () as usize,
        sursaut_set_bitmap as *const () as usize,
        sursaut_has_bitmap as *const () as usize,
    ];
    std::hint::black_box(&table);
    table.len() as u32
}

#[cfg(test)]
mod tests {
    use super::*;

    fn photo(w: usize, h: usize) -> Vec<u8> {
        let mut v = Vec::with_capacity(w * h * 4);
        for y in 0..h {
            for x in 0..w {
                v.extend_from_slice(&[(x * 255 / w) as u8, (y * 255 / h) as u8, ((x / 8 + y / 8) % 2 * 160 + 40) as u8, 255]);
            }
        }
        v
    }

    fn maxdiff(a: &[u8], b: &[u8]) -> i32 {
        a.iter().zip(b).map(|(x, y)| (*x as i32 - *y as i32).abs()).max().unwrap_or(0)
    }


    /// Les masques manuels de l'onglet « Masques » de l'iPad (même JSON que `lib/domain/mask_tools.dart`).
    fn masque(comp: &str, exposure: f64) -> String {
        format!(
            r#"{{"masks":[{{"name":"Test","enabled":true,"invert":false,"amount":100.0,"comps":[{comp}],"adj":{{"exposure":{exposure},"contrast":0.0,"highlights":0.0,"shadows":0.0,"temperature":0.0,"tint":0.0,"vibrance":0.0,"saturation":0.0,"clarity":0.0,"texture":0.0,"sharpen":0.0,"denoise":0.0}}}}]}}"#
        )
    }

    fn lum_zone(rgba: &[u8], w: usize, x0: usize, x1: usize, y0: usize, y1: usize) -> f64 {
        let mut s = 0u64;
        let mut n = 0u64;
        for y in y0..y1 {
            for x in x0..x1 {
                let p = &rgba[(y * w + x) * 4..];
                s += p[0] as u64 + p[1] as u64 + p[2] as u64;
                n += 3;
            }
        }
        s as f64 / n as f64
    }

    #[test]
    fn le_degrade_lineaire_eclaircit_le_haut_seulement() {
        let (w, h) = (96usize, 96usize);
        let src = photo(w, h);
        let mut e = Engine::open_rgba8(&src, w, h).unwrap();
        let lin = r#"{"kind":"linear","op":"add","invert":false,"x0":0.5,"y0":0.2,"x1":0.5,"y1":0.6}"#;
        e.render(&masque(lin, 2.0)).unwrap();
        let out = e.output().to_vec();
        let (top_in, top_out) = (lum_zone(&src, w, 0, w, 0, 12), lum_zone(&out, w, 0, w, 0, 12));
        let (bot_in, bot_out) = (lum_zone(&src, w, 0, w, 80, 96), lum_zone(&out, w, 0, w, 80, 96));
        assert!(top_out > top_in + 25.0, "le haut doit s'éclaircir : {top_in} -> {top_out}");
        assert!((bot_out - bot_in).abs() < 1.0, "le bas ne doit pas bouger : {bot_in} -> {bot_out}");
    }

    #[test]
    fn le_degrade_radial_agit_au_centre_et_pas_dans_les_coins() {
        let (w, h) = (96usize, 96usize);
        let src = photo(w, h);
        let mut e = Engine::open_rgba8(&src, w, h).unwrap();
        let rad = r#"{"kind":"radial","op":"add","invert":false,"x0":0.5,"y0":0.5,"rx":0.2,"ry":0.2,"angle":0.0,"feather":0.5}"#;
        e.render(&masque(rad, 2.0)).unwrap();
        let out = e.output().to_vec();
        let (c_in, c_out) = (lum_zone(&src, w, 44, 52, 44, 52), lum_zone(&out, w, 44, 52, 44, 52));
        let (k_in, k_out) = (lum_zone(&src, w, 0, 10, 0, 10), lum_zone(&out, w, 0, 10, 0, 10));
        assert!(c_out > c_in + 25.0, "le centre doit s'éclaircir : {c_in} -> {c_out}");
        assert!((k_out - k_in).abs() < 1.0, "le coin ne doit pas bouger : {k_in} -> {k_out}");
        // masque inversé : l'inverse
        let inv = masque(rad, 2.0).replace(r#""invert":false,"amount""#, r#""invert":true,"amount""#);
        e.render(&inv).unwrap();
        let out2 = e.output().to_vec();
        assert!((lum_zone(&out2, w, 44, 52, 44, 52) - c_in).abs() < 1.0);
        assert!(lum_zone(&out2, w, 0, 10, 0, 10) > k_in + 25.0);
    }

    #[test]
    fn un_masque_a_zero_ne_change_rien() {
        let (w, h) = (64usize, 64usize);
        let src = photo(w, h);
        let mut e = Engine::open_rgba8(&src, w, h).unwrap();
        let lin = r#"{"kind":"linear","op":"add","invert":false,"x0":0.5,"y0":0.2,"x1":0.5,"y1":0.6}"#;
        e.render("{}").unwrap();
        let neutre = e.output().to_vec();
        e.render(&masque(lin, 0.0)).unwrap();
        assert!(maxdiff(&neutre, e.output()) <= 1);
    }


    fn aplat(w: usize, h: usize, left: [u8; 3], right: [u8; 3]) -> Vec<u8> {
        let mut v = Vec::with_capacity(w * h * 4);
        for _ in 0..h {
            for x in 0..w {
                let c = if x < w / 2 { left } else { right };
                v.extend_from_slice(&[c[0], c[1], c[2], 255]);
            }
        }
        v
    }

    fn canal(rgba: &[u8], w: usize, x0: usize, x1: usize, c: usize) -> f64 {
        let mut s = 0u64;
        let mut n = 0u64;
        for y in 0..(rgba.len() / 4 / w) {
            for x in x0..x1 {
                s += rgba[(y * w + x) * 4 + c] as u64;
                n += 1;
            }
        }
        s as f64 / n as f64
    }

    #[test]
    fn la_plage_de_luminosite_ne_touche_que_les_tons_sombres() {
        let (w, h) = (96usize, 96usize);
        let src = photo(w, h);
        let mut e = Engine::open_rgba8(&src, w, h).unwrap();
        let lum = r#"{"kind":"luminance","op":"add","invert":false,"lo":0.0,"hi":0.4,"smooth":0.3}"#;
        e.render(&masque(lum, 2.0)).unwrap();
        let out = e.output().to_vec();
        let (d_in, d_out) = (lum_zone(&src, w, 0, 12, 0, 12), lum_zone(&out, w, 0, 12, 0, 12));
        let (c_in, c_out) = (lum_zone(&src, w, 84, 96, 84, 96), lum_zone(&out, w, 84, 96, 84, 96));
        assert!(d_out > d_in + 20.0, "les tons sombres doivent s'éclaircir : {d_in} -> {d_out}");
        assert!((c_out - c_in).abs() < 2.0, "les tons clairs ne doivent pas bouger : {c_in} -> {c_out}");
    }

    #[test]
    fn la_plage_de_couleur_ne_touche_que_la_teinte_visee() {
        let (w, h) = (64usize, 32usize);
        let src = aplat(w, h, [200, 30, 30], [30, 200, 30]);
        let mut e = Engine::open_rgba8(&src, w, h).unwrap();
        let col = r#"{"kind":"color","op":"add","invert":false,"hue":0.0,"hue_range":40.0,"sat_min":0.3}"#;
        e.render(&masque(col, -2.0)).unwrap();
        let out = e.output().to_vec();
        assert!(canal(&out, w, 0, 28, 0) < canal(&src, w, 0, 28, 0) - 40.0, "le rouge doit s'assombrir");
        assert!((canal(&out, w, 36, 64, 1) - canal(&src, w, 36, 64, 1)).abs() < 2.0, "le vert ne doit pas bouger");
    }

    #[test]
    fn limiter_a_et_soustraire_combinent_les_composantes() {
        let (w, h) = (96usize, 96usize);
        let src = photo(w, h);
        let mut e = Engine::open_rgba8(&src, w, h).unwrap();
        let lin = r#"{"kind":"radial","op":"add","invert":false,"x0":0.5,"y0":0.5,"rx":5.0,"ry":5.0,"angle":0.0,"feather":0.5}"#;
        let lum = r#"{"kind":"luminance","op":"intersect","invert":false,"lo":0.0,"hi":0.4,"smooth":0.3}"#;
        // une forme qui couvre toute la photo, limitée aux tons sombres : seul le coin sombre bouge
        e.render(&masque(&format!("{lin},{lum}"), 2.0)).unwrap();
        let out = e.output().to_vec();
        assert!(lum_zone(&out, w, 0, 12, 0, 12) > lum_zone(&src, w, 0, 12, 0, 12) + 15.0);
        assert!((lum_zone(&out, w, 84, 96, 84, 96) - lum_zone(&src, w, 84, 96, 84, 96)).abs() < 2.0);
        // la même forme moins les tons sombres : l'inverse
        let sous = lum.replace("intersect", "subtract");
        e.render(&masque(&format!("{lin},{sous}"), 2.0)).unwrap();
        let out2 = e.output().to_vec();
        assert!((lum_zone(&out2, w, 0, 12, 0, 12) - lum_zone(&src, w, 0, 12, 0, 12)).abs() < 2.0);
    }

    #[test]
    fn la_vue_de_la_zone_rougit_ce_que_le_masque_couvre() {
        let (w, h) = (64usize, 32usize);
        let src = aplat(w, h, [120, 120, 120], [120, 120, 120]);
        let mut e = Engine::open_rgba8(&src, w, h).unwrap();
        let lum = r#"{"kind":"luminance","op":"add","invert":false,"lo":0.0,"hi":1.0,"smooth":0.3}"#;
        let json = format!(
            r#"{{"masks":[{{"name":"Zone","enabled":true,"invert":false,"amount":100.0,"comps":[{lum}],"adj":{{"exposure":0.6,"temperature":100.0,"tint":100.0,"contrast":0.0,"highlights":0.0,"shadows":0.0,"vibrance":0.0,"saturation":0.0,"clarity":0.0,"texture":0.0,"sharpen":0.0,"denoise":0.0}}}}]}}"#
        );
        e.render(&json).unwrap();
        let out = e.output().to_vec();
        let (r, g, b) = (canal(&out, w, 0, w, 0), canal(&out, w, 0, w, 1), canal(&out, w, 0, w, 2));
        assert!(r > g + 25.0 && r > b + 25.0, "la zone doit dominer en rouge : {r} {g} {b}");
    }

    #[test]
    fn le_pinceau_ne_touche_que_le_trait_et_la_gomme_l_enleve() {
        let (w, h) = (64usize, 64usize);
        let src = aplat(w, h, [100, 100, 100], [100, 100, 100]);
        let mut e = Engine::open_rgba8(&src, w, h).unwrap();
        let pts: Vec<String> = (0..12).map(|i| format!("[{:.3},0.5]", 0.15 + 0.01 * i as f64)).collect();
        let pinceau = format!(r#"{{"kind":"brush","op":"add","invert":false,"stroke":[{}],"r":0.1,"feather":0.3,"grow":0.0}}"#, pts.join(","));
        e.render(&masque(&pinceau, 2.0)).unwrap();
        let out = e.output().to_vec();
        let (sous, loin) = (lum_zone(&out, w, 10, 20, 28, 36), lum_zone(&out, w, 50, 62, 28, 36));
        assert!(sous > 100.0 * 1.0 + 25.0, "sous le trait la photo doit s'éclaircir : {sous}");
        assert!((loin - 100.0).abs() < 2.0, "loin du trait rien ne doit bouger : {loin}");
        // la gomme : même trait en « soustraire » -> plus rien
        let gomme = pinceau.replacen(r#""op":"add""#, r#""op":"subtract""#, 1);
        let json = masque(&format!("{pinceau},{gomme}"), 2.0);
        e.render(&json).unwrap();
        let apres = lum_zone(e.output(), w, 10, 20, 28, 36);
        assert!((apres - 100.0).abs() < 2.0, "la gomme doit annuler le trait : {apres}");
    }

    #[test]
    fn un_masque_d_ia_confie_au_moteur_agit_la_ou_il_est_blanc() {
        let (w, h) = (64usize, 32usize);
        let src = aplat(w, h, [100, 100, 100], [100, 100, 100]);
        let mut e = Engine::open_rgba8(&src, w, h).unwrap();
        // plan de masque 16 x 8 : moitié gauche pleine, moitié droite vide
        let mut plan = vec![0u8; 16 * 8];
        for y in 0..8 {
            for x in 0..8 {
                plan[y * 16 + x] = 255;
            }
        }
        let cle = CString::new("test-ia-1").unwrap();
        assert_eq!(unsafe { sursaut_has_bitmap(cle.as_ptr()) }, 0);
        assert_eq!(unsafe { sursaut_set_bitmap(cle.as_ptr(), 16, 8, plan.as_ptr()) }, 1);
        assert_eq!(unsafe { sursaut_has_bitmap(cle.as_ptr()) }, 1);
        let comp = r#"{"kind":"bitmap","op":"add","invert":false,"key":"test-ia-1","grow":0.0}"#;
        e.render(&masque(comp, 2.0)).unwrap();
        let out = e.output().to_vec();
        let (gauche, droite) = (canal(&out, w, 2, 22, 0), canal(&out, w, 42, 62, 0));
        assert!(gauche > 100.0 + 25.0, "la moitié blanche doit s'éclaircir : {gauche}");
        assert!((droite - 100.0).abs() < 2.0, "la moitié vide ne doit pas bouger : {droite}");
        // une clé inconnue ne fait rien
        let inconnu = r#"{"kind":"bitmap","op":"add","invert":false,"key":"absent","grow":0.0}"#;
        e.render(&masque(inconnu, 2.0)).unwrap();
        assert!((canal(e.output(), w, 2, 22, 0) - 100.0).abs() < 2.0);
        // refus propres
        assert_eq!(unsafe { sursaut_set_bitmap(std::ptr::null(), 4, 4, plan.as_ptr()) }, 0);
    }

    #[test]
    fn version_et_erreur_vide() {
        let v = unsafe { CStr::from_ptr(sursaut_engine_version()) }.to_str().unwrap();
        assert!(v.starts_with("sursaut_engine 0.6.0"));
    }

    #[test]
    fn recette_neutre_redonne_la_photo_a_un_niveau() {
        let src = photo(64, 48);
        let mut e = Engine::open_rgba8(&src, 64, 48).unwrap();
        assert_eq!(e.render("{}").unwrap(), (64, 48));
        assert!(maxdiff(&src, e.output()) <= 1, "écart {}", maxdiff(&src, e.output()));
        assert!(e.output().chunks_exact(4).all(|p| p[3] == 255));
    }

    #[test]
    fn l_exposition_eclaircit_et_le_cache_sert_au_second_rendu() {
        let src = photo(64, 48);
        let mut e = Engine::open_rgba8(&src, 64, 48).unwrap();
        e.render(r#"{"exposure":1.0}"#).unwrap();
        let first = e.output().to_vec();
        let mean = |v: &[u8]| v.iter().map(|x| *x as u64).sum::<u64>() as f64 / v.len() as f64;
        assert!(mean(&first) > mean(&src) + 20.0);
        e.render(r#"{"exposure":1.0}"#).unwrap();
        assert!(e.recomputed().is_empty(), "même recette : tout vient du cache, obtenu {:?}", e.recomputed());
        assert_eq!(first, e.output());
        // Un curseur de couleur ne recalcule que l'aval.
        e.render(r#"{"exposure":1.0,"saturation":30}"#).unwrap();
        assert!(!e.recomputed().contains(&"wb_exposure"), "{:?}", e.recomputed());
    }

    #[test]
    fn le_recadrage_change_la_taille_du_resultat() {
        let src = photo(100, 80);
        let mut e = Engine::open_rgba8(&src, 100, 80).unwrap();
        let (w, h) = e.render(r#"{"crop_left":0.1,"crop_right":0.6}"#).unwrap();
        assert!(w < 100 && h == 80, "{w}x{h}");
        assert_eq!(e.output().len(), w * h * 4);
    }

    #[test]
    fn erreurs_propres_par_l_interface_c() {
        unsafe {
            assert!(sursaut_engine_open_rgba8(std::ptr::null(), 4, 4).is_null());
            let src = photo(4, 4);
            let e = sursaut_engine_open_rgba8(src.as_ptr(), 4, 4);
            assert!(!e.is_null());
            let (mut w, mut h) = (0u32, 0u32);
            let bad = CString::new("pas du json").unwrap();
            assert!(sursaut_engine_render(e, bad.as_ptr(), &mut w, &mut h).is_null());
            let msg = CStr::from_ptr(sursaut_engine_last_error()).to_str().unwrap();
            assert!(msg.contains("recette"), "{msg}");
            let good = CString::new(r#"{"exposure":0.5}"#).unwrap();
            let p = sursaut_engine_render(e, good.as_ptr(), &mut w, &mut h);
            assert!(!p.is_null() && (w, h) == (4, 4));
            sursaut_engine_close(e);
            sursaut_engine_close(std::ptr::null_mut());
            assert!(sursaut_engine_render(std::ptr::null_mut(), good.as_ptr(), &mut w, &mut h).is_null());
        }
    }

    #[test]
    fn taille_incoherente_refusee() {
        assert!(Engine::open_rgba8(&[0u8; 10], 4, 4).is_err());
        assert!(Engine::open_rgba8(&[], 0, 0).is_err());
    }

    #[test]
    fn keep_compte_les_fonctions() {
        assert_eq!(sursaut_engine_keep(), 14);
    }

    #[test]
    #[ignore]
    fn chrono_2752x2064_curseur_couleur() {
        let (w, h) = (2752usize, 2064usize);
        let src = photo(w, h);
        let mut e = Engine::open_rgba8(&src, w, h).unwrap();
        let t = std::time::Instant::now();
        e.render(r#"{"exposure":0.3,"clarity":20,"saturation":10}"#).unwrap();
        eprintln!("1er rendu complet : {:?}", t.elapsed());
        let t = std::time::Instant::now();
        e.render(r#"{"exposure":0.3,"clarity":20,"saturation":25}"#).unwrap();
        eprintln!("curseur de couleur seul : {:?} (étages : {:?})", t.elapsed(), e.recomputed());
        let t = std::time::Instant::now();
        e.render(r#"{"exposure":0.6,"clarity":20,"saturation":25}"#).unwrap();
        eprintln!("curseur d'exposition : {:?} (étages : {:?})", t.elapsed(), e.recomputed());
    }

    /// Fond lisse avec une tache sombre ronde au centre.
    fn spotted(w: usize, h: usize) -> Vec<u8> {
        let mut v = Vec::with_capacity(w * h * 4);
        for y in 0..h {
            for x in 0..w {
                let (dx, dy) = (x as f32 - w as f32 / 2.0, y as f32 - h as f32 / 2.0);
                let d = (dx * dx + dy * dy).sqrt();
                let g = if d < 6.0 { 150u8 } else { 200u8 };
                v.extend_from_slice(&[g, g, g, 255]);
            }
        }
        v
    }

    #[test]
    fn outils_de_retouche() {
        let (w, h) = (400usize, 300usize);
        let img = spotted(w, h);
        let mut out = [0f64; 3];
        // source proposée : deux fractions dans la photo
        let n = unsafe { sursaut_spot_tool(img.as_ptr(), w as u32, h as u32, 0, 0.5, 0.5, 0.02, out.as_mut_ptr()) };
        assert_eq!(n, 2);
        assert!(out[0] > 0.0 && out[0] < 1.0 && out[1] > 0.0 && out[1] < 1.0);
        // poussière : liste JSON
        let p = unsafe { sursaut_dust_detect(img.as_ptr(), w as u32, h as u32) };
        assert!(!p.is_null());
        let txt = unsafe { CStr::from_ptr(p) }.to_str().unwrap().to_string();
        assert!(txt.starts_with('['));
        // la qualité de détection est testée dans sursaut-core ; ici : l'appel rend une liste JSON valide
        assert!(txt.ends_with(']'), "{txt}");
        // yeux : liste JSON valide (la qualité est testée dans sursaut-core)
        let q = unsafe { sursaut_eyes_detect(img.as_ptr(), w as u32, h as u32) };
        assert!(!q.is_null());
        let et = unsafe { CStr::from_ptr(q) }.to_str().unwrap().to_string();
        assert!(et.starts_with('[') && et.ends_with(']'), "{et}");
        // entrée absente : erreur propre
        assert_eq!(unsafe { sursaut_spot_tool(std::ptr::null(), 1, 1, 0, 0.0, 0.0, 0.01, out.as_mut_ptr()) }, -1);
    }
}
