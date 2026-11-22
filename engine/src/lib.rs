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

const VERSION: &[u8] = b"sursaut_engine 0.4.1 (moteur sursaut-core + LibRaw 0.21.3)\0";

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

/// Référence toutes les fonctions exportées : l'éditeur de liens d'iOS retire sinon celles que
/// seul Dart (dart:ffi) utilise. Appelée une fois par le code Swift. Renvoie leur nombre.
#[no_mangle]
pub extern "C" fn sursaut_engine_keep() -> u32 {
    let table: [usize; 9] = [
        sursaut_engine_version as *const () as usize,
        sursaut_engine_last_error as *const () as usize,
        sursaut_engine_open_rgba8 as *const () as usize,
        sursaut_engine_render as *const () as usize,
        sursaut_engine_close as *const () as usize,
        sursaut_raw_open as *const () as usize,
        sursaut_raw_info_json as *const () as usize,
        sursaut_raw_develop as *const () as usize,
        sursaut_raw_close as *const () as usize,
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

    #[test]
    fn version_et_erreur_vide() {
        let v = unsafe { CStr::from_ptr(sursaut_engine_version()) }.to_str().unwrap();
        assert!(v.starts_with("sursaut_engine 0.4.1"));
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
        assert_eq!(sursaut_engine_keep(), 9);
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
}
