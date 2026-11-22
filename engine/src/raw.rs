//! Lecture d'un RAW par LibRaw (étape 3a) : métadonnées, développement rapide (demi-taille)
//! et complet (démosaïquage DHT), image d'aperçu RGBA 8 bits, temps et mémoire mesurés.
//!
//! Étape 3a : on prouve que LibRaw se compile et tourne sur l'iPad. La couleur fine (balance des
//! blancs, matrice, profil .dcp) viendra à l'étape 3b ; ici : balance des blancs de l'appareil,
//! sRGB 8 bits, aucune retouche automatique.

use libraw_sys as lr;
use std::ffi::{c_char, c_int, CStr, CString};
use std::time::Instant;

pub struct RawInfo {
    pub make: String,
    pub model: String,
    pub lens: String,
    pub iso: f32,
    pub shutter: f32,
    pub aperture: f32,
    pub focal_len: f32,
    pub timestamp: i64,
    pub raw_width: i32,
    pub raw_height: i32,
    pub width: i32,
    pub height: i32,
    pub colors: i32,
    pub cam_mul: [f32; 4],
    pub maximum: i32,
    pub file_bytes: u64,
}

#[derive(Clone, Default)]
pub struct Timing {
    pub mode: &'static str,
    pub open_ms: u128,
    pub unpack_ms: u128,
    pub process_ms: u128,
    pub convert_ms: u128,
    pub total_ms: u128,
    pub full_w: u32,
    pub full_h: u32,
    pub out_w: u32,
    pub out_h: u32,
    pub peak_rss_mb: f64,
    pub look: &'static str,
    pub headroom: f64,
    /// Moyennes (échelle 0..255) de 8×8 zones × 3 canaux, avant réduction : sert à comparer avec le PC.
    pub grid: Vec<f32>,
}

pub struct RawFile {
    path: CString,
    pub info: RawInfo,
    pub last: Option<Timing>,
    preview: Vec<u8>,
    json: CString,
}

fn cstr(p: *const c_char) -> String {
    if p.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(p) }.to_string_lossy().trim().to_string()
}

fn err_text(code: c_int) -> String {
    let s = cstr(unsafe { lr::libraw_strerror(code) });
    format!("LibRaw : {s} (code {code})")
}

/// Mémoire maximale utilisée par le processus depuis son démarrage, en Mo.
pub fn peak_rss_mb() -> f64 {
    let mut ru: libc::rusage = unsafe { std::mem::zeroed() };
    if unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut ru) } != 0 {
        return -1.0;
    }
    let raw = ru.ru_maxrss as f64;
    // macOS / iOS : octets ; Linux / Android : kilo-octets.
    if cfg!(any(target_os = "macos", target_os = "ios")) {
        raw / 1_048_576.0
    } else {
        raw / 1024.0
    }
}

/// Un contexte LibRaw fermé automatiquement, même en cas d'erreur ou de panique.
struct Ctx(*mut lr::libraw_data_t);
impl Drop for Ctx {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { lr::libraw_close(self.0) };
        }
    }
}

fn open_ctx(path: &CStr) -> Result<Ctx, String> {
    let p = unsafe { lr::libraw_init(0) };
    if p.is_null() {
        return Err("LibRaw : initialisation impossible (mémoire)".into());
    }
    let ctx = Ctx(p);
    let code = unsafe { lr::libraw_open_file(ctx.0, path.as_ptr()) };
    if code != 0 {
        return Err(err_text(code));
    }
    Ok(ctx)
}

fn read_info(ctx: &Ctx, file_bytes: u64) -> RawInfo {
    unsafe {
        let ip = lr::libraw_get_iparams(ctx.0);
        let lens = lr::libraw_get_lensinfo(ctx.0);
        let other = lr::libraw_get_imgother(ctx.0);
        let mut cam_mul = [0f32; 4];
        for (i, c) in cam_mul.iter_mut().enumerate() {
            *c = lr::libraw_get_cam_mul(ctx.0, i as c_int);
        }
        RawInfo {
            make: cstr((*ip).make.as_ptr()),
            model: cstr((*ip).model.as_ptr()),
            lens: cstr((*lens).Lens.as_ptr()),
            iso: (*other).iso_speed,
            shutter: (*other).shutter,
            aperture: (*other).aperture,
            focal_len: (*other).focal_len,
            timestamp: (*other).timestamp as i64,
            raw_width: lr::libraw_get_raw_width(ctx.0),
            raw_height: lr::libraw_get_raw_height(ctx.0),
            width: lr::libraw_get_iwidth(ctx.0),
            height: lr::libraw_get_iheight(ctx.0),
            colors: (*ip).colors,
            cam_mul,
            maximum: lr::libraw_get_color_maximum(ctx.0),
            file_bytes,
        }
    }
}

/// Réduit une image RGB 8 bits (`w`×`h`) à `max_side` pixels de grand côté exactement (moyenne par aire, poids
/// fractionnaires) et la convertit en RGBA. `max_side` = 0 ou image déjà assez petite : pas de réduction.
/// Le travail se fait ligne de sortie par ligne de sortie : pas de grande image intermédiaire.
pub fn rgb_to_rgba_scaled(rgb: &[u8], w: usize, h: usize, max_side: usize) -> (Vec<u8>, usize, usize) {
    let longest = w.max(h);
    if max_side == 0 || longest <= max_side {
        let mut out = vec![255u8; w * h * 4];
        for i in 0..w * h {
            out[i * 4] = rgb[i * 3];
            out[i * 4 + 1] = rgb[i * 3 + 1];
            out[i * 4 + 2] = rgb[i * 3 + 2];
        }
        return (out, w, h);
    }
    let scale = max_side as f64 / longest as f64;
    let ow = ((w as f64 * scale).round() as usize).clamp(1, w);
    let oh = ((h as f64 * scale).round() as usize).clamp(1, h);
    let mut out = vec![255u8; ow * oh * 4];
    // Poids horizontaux : pour chaque colonne de sortie, les colonnes sources touchées et leur part.
    let mut hx: Vec<(usize, Vec<f32>)> = Vec::with_capacity(ow);
    for ox in 0..ow {
        let x0 = ox as f64 * w as f64 / ow as f64;
        let x1 = (ox + 1) as f64 * w as f64 / ow as f64;
        let first = x0.floor() as usize;
        let last = (x1.ceil() as usize).min(w);
        let mut ws = Vec::with_capacity(last - first);
        let mut tot = 0.0f64;
        for sx in first..last {
            let wt = ((sx + 1) as f64).min(x1) - (sx as f64).max(x0);
            let wt = wt.max(0.0);
            tot += wt;
            ws.push(wt as f32);
        }
        let inv = if tot > 0.0 { (1.0 / tot) as f32 } else { 0.0 };
        for v in ws.iter_mut() {
            *v *= inv;
        }
        hx.push((first, ws));
    }
    let mut acc = vec![0f32; w * 3];
    for oy in 0..oh {
        let y0 = oy as f64 * h as f64 / oh as f64;
        let y1 = (oy + 1) as f64 * h as f64 / oh as f64;
        let first = y0.floor() as usize;
        let last = (y1.ceil() as usize).min(h);
        acc.iter_mut().for_each(|v| *v = 0.0);
        let mut tot = 0.0f64;
        for sy in first..last {
            let wt = (((sy + 1) as f64).min(y1) - (sy as f64).max(y0)).max(0.0);
            tot += wt;
            let wf = wt as f32;
            let row = &rgb[sy * w * 3..(sy + 1) * w * 3];
            for (a, &v) in acc.iter_mut().zip(row.iter()) {
                *a += wf * v as f32;
            }
        }
        let invy = if tot > 0.0 { (1.0 / tot) as f32 } else { 0.0 };
        for (ox, (fx, ws)) in hx.iter().enumerate() {
            let mut sum = [0f32; 3];
            for (k, &wt) in ws.iter().enumerate() {
                let i = (fx + k) * 3;
                sum[0] += wt * acc[i];
                sum[1] += wt * acc[i + 1];
                sum[2] += wt * acc[i + 2];
            }
            let o = (oy * ow + ox) * 4;
            out[o] = (sum[0] * invy + 0.5).clamp(0.0, 255.0) as u8;
            out[o + 1] = (sum[1] * invy + 0.5).clamp(0.0, 255.0) as u8;
            out[o + 2] = (sum[2] * invy + 0.5).clamp(0.0, 255.0) as u8;
        }
    }
    (out, ow, oh)
}

fn esc(s: &str) -> String {
    let mut o = String::with_capacity(s.len() + 2);
    for c in s.chars() {
        match c {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            c if (c as u32) < 0x20 => o.push(' '),
            c => o.push(c),
        }
    }
    o
}

/// Rendus de base du PC (`sursaut/imageio.py`, `BASE_LOOKS`) : (exposition en IL, contraste). 0 = neutre (aucune courbe).
pub fn look_params(look: i32) -> (&'static str, Option<(f64, f64)>) {
    match look {
        1 => ("doux", Some((0.8, 0.45))),
        2 => ("appareil", Some((1.66, 1.0))),
        _ => ("neutre", None),
    }
}

fn s2l(c: f64) -> f64 {
    if c <= 0.04045 { c / 12.92 } else { ((c + 0.055) / 1.055).powf(2.4) }
}

fn l2s(v: f64) -> f64 {
    let v = v.clamp(0.0, 1.0);
    if v <= 0.0031308 { v * 12.92 } else { 1.055 * v.powf(1.0 / 2.4) - 0.055 }
}

/// Table 65536 entrées du rendu de base (même formule que `base_lut` du PC) ; `headroom` ≥ 1 arrondi à 3 décimales.
pub fn base_lut(ev: f64, contrast: f64, headroom: f64) -> Vec<u16> {
    let hr = ((headroom.max(1.0)) * 1000.0).round() / 1000.0;
    let g = 2f64.powf(ev);
    (0..65536u32)
        .map(|i| {
            let x = i as f64 / 65535.0;
            let mut v = s2l(x) * hr * g;
            v = v * (1.0 + v / (hr * g)) / (1.0 + v); // épaule douce (Reinhard étendu)
            let mut y = l2s(v);
            y += contrast * (y * y * (3.0 - 2.0 * y) - y); // courbe en S
            (y * 65535.0).round().clamp(0.0, 65535.0) as u16
        })
        .collect()
}

/// Applique la table (si présente) aux valeurs 16 bits, mesure les moyennes de 8×8 zones (échelle 0..255) et passe en 8 bits.
fn look_to_8bit(src: &[u16], w: usize, h: usize, lut: Option<&[u16]>) -> (Vec<u8>, Vec<f32>) {
    let mut out = vec![0u8; w * h * 3];
    let mut sums = [0u64; 8 * 8 * 3];
    let mut cnt = [0u64; 8 * 8];
    for y in 0..h {
        let gy = (y * 8 / h.max(1)).min(7);
        for x in 0..w {
            let gx = (x * 8 / w.max(1)).min(7);
            let cell = gy * 8 + gx;
            cnt[cell] += 1;
            let i = (y * w + x) * 3;
            for c in 0..3 {
                let v = match lut {
                    Some(l) => l[src[i + c] as usize],
                    None => src[i + c],
                };
                sums[cell * 3 + c] += v as u64;
                out[i + c] = ((v as u32 * 255 + 32767) / 65535) as u8;
            }
        }
    }
    let grid = (0..192)
        .map(|k| {
            let n = cnt[k / 3].max(1) as f64;
            (sums[k] as f64 / n / 257.0) as f32
        })
        .collect();
    (out, grid)
}

/// Rendu de base seul, sans LibRaw : sert aux tests.
pub fn look_to_8bit_for_tests(src: &[u16], w: usize, h: usize, lut: Option<&[u16]>) -> (Vec<u8>, Vec<f32>) {
    look_to_8bit(src, w, h, lut)
}

impl RawFile {
    pub fn open(path: &str) -> Result<RawFile, String> {
        let cpath = CString::new(path).map_err(|_| "chemin invalide".to_string())?;
        let size = std::fs::metadata(path).map(|m| m.len()).map_err(|e| format!("fichier illisible : {e}"))?;
        let ctx = open_ctx(&cpath)?;
        let info = read_info(&ctx, size);
        drop(ctx);
        let mut f = RawFile { path: cpath, info, last: None, preview: Vec::new(), json: CString::default() };
        f.rebuild_json();
        Ok(f)
    }

    /// Développe le RAW : `half` = demi-taille (sans démosaïquage, rapide) ou complet (DHT).
    /// L'aperçu RGBA est réduit à `max_side` pixels au plus (0 = pleine taille).
    pub fn develop(&mut self, half: bool, max_side: u32, look: i32) -> Result<(), String> {
        let t_all = Instant::now();
        let (look_name, look_p) = look_params(look);
        let mut t = Timing { mode: if half { "demi-taille" } else { "complet DHT" }, look: look_name, ..Default::default() };
        // Hautes lumières (comme le PC) : mode Blend, qui sort plus sombre d'un facteur max(wb)/min(wb) ; la table le compense.
        let mul = &self.info.cam_mul[..3];
        let mn = mul.iter().cloned().fold(f32::INFINITY, f32::min);
        let mx = mul.iter().cloned().fold(0.0f32, f32::max);
        let blend = look_p.is_some() && mn > 0.0 && mn.is_finite() && mx.is_finite();
        let headroom = if blend { (mx / mn) as f64 } else { 1.0 };
        t.headroom = headroom;

        let t0 = Instant::now();
        let ctx = open_ctx(&self.path)?;
        t.open_ms = t0.elapsed().as_millis();
        t.full_w = unsafe { lr::libraw_get_iwidth(ctx.0) }.max(0) as u32;
        t.full_h = unsafe { lr::libraw_get_iheight(ctx.0) }.max(0) as u32;

        unsafe {
            lr::libraw_set_output_bps(ctx.0, 16);
            lr::libraw_set_gamma(ctx.0, 0, 1.0 / 2.4);
            lr::libraw_set_gamma(ctx.0, 1, 12.92);
            lr::libraw_set_output_color(ctx.0, 1); // sRGB
            lr::libraw_set_no_auto_bright(ctx.0, 1);
            lr::libraw_set_highlight(ctx.0, if blend { 2 } else { 0 });
            let p = &mut (*ctx.0).params;
            p.use_camera_wb = 1;
            p.half_size = if half { 1 } else { 0 };
            p.user_qual = 11; // DHT
        }

        let t1 = Instant::now();
        let code = unsafe { lr::libraw_unpack(ctx.0) };
        if code != 0 {
            return Err(err_text(code));
        }
        t.unpack_ms = t1.elapsed().as_millis();

        let t2 = Instant::now();
        let code = unsafe { lr::libraw_dcraw_process(ctx.0) };
        if code != 0 {
            return Err(err_text(code));
        }
        t.process_ms = t2.elapsed().as_millis();

        let t3 = Instant::now();
        let mut ec: c_int = 0;
        let img = unsafe { lr::libraw_dcraw_make_mem_image(ctx.0, &mut ec) };
        if img.is_null() || ec != 0 {
            return Err(if ec != 0 { err_text(ec) } else { "LibRaw : image développée introuvable".into() });
        }
        let res = unsafe {
            let im = &*img;
            let (w, h) = (im.width as usize, im.height as usize);
            if im.bits != 16 || im.colors != 3 || im.data_size as usize != w * h * 6 {
                Err(format!(
                    "LibRaw : image inattendue ({} bits, {} canaux, {} octets pour {}×{}) — disposition des champs à vérifier",
                    im.bits, im.colors, im.data_size, w, h
                ))
            } else {
                let src = std::slice::from_raw_parts(im.data.as_ptr() as *const u16, w * h * 3);
                let lut = look_p.map(|(ev, c)| base_lut(ev, c, headroom));
                let (rgb8, grid) = look_to_8bit(src, w, h, lut.as_deref());
                t.grid = grid;
                Ok(rgb_to_rgba_scaled(&rgb8, w, h, max_side as usize))
            }
        };
        unsafe { lr::libraw_dcraw_clear_mem(img) };
        let (rgba, ow, oh) = res?;
        t.convert_ms = t3.elapsed().as_millis();
        t.out_w = ow as u32;
        t.out_h = oh as u32;
        drop(ctx);
        t.total_ms = t_all.elapsed().as_millis();
        t.peak_rss_mb = peak_rss_mb();
        self.preview = rgba;
        self.last = Some(t);
        self.rebuild_json();
        Ok(())
    }

    pub fn preview(&self) -> &[u8] {
        &self.preview
    }

    pub fn json_ptr(&self) -> *const c_char {
        self.json.as_ptr()
    }

    fn rebuild_json(&mut self) {
        let i = &self.info;
        let ver = cstr(unsafe { lr::libraw_version() });
        let mut s = format!(
            "{{\"libraw\":\"{}\",\"make\":\"{}\",\"model\":\"{}\",\"lens\":\"{}\",\"iso\":{},\"shutter\":{},\"aperture\":{},\"focal_len\":{},\"timestamp\":{},\"raw_width\":{},\"raw_height\":{},\"width\":{},\"height\":{},\"colors\":{},\"cam_mul\":[{},{},{},{}],\"maximum\":{},\"file_bytes\":{}",
            esc(&ver), esc(&i.make), esc(&i.model), esc(&i.lens), i.iso, i.shutter, i.aperture, i.focal_len, i.timestamp,
            i.raw_width, i.raw_height, i.width, i.height, i.colors,
            i.cam_mul[0], i.cam_mul[1], i.cam_mul[2], i.cam_mul[3], i.maximum, i.file_bytes
        );
        if let Some(t) = &self.last {
            s.push_str(&format!(
                ",\"last\":{{\"mode\":\"{}\",\"open_ms\":{},\"unpack_ms\":{},\"process_ms\":{},\"convert_ms\":{},\"total_ms\":{},\"full_w\":{},\"full_h\":{},\"out_w\":{},\"out_h\":{},\"peak_rss_mb\":{:.1},\"look\":\"{}\",\"headroom\":{:.4},\"grid\":[{}]}}",
                t.mode, t.open_ms, t.unpack_ms, t.process_ms, t.convert_ms, t.total_ms, t.full_w, t.full_h, t.out_w, t.out_h, t.peak_rss_mb,
                t.look, t.headroom,
                t.grid.iter().map(|g| format!("{:.1}", g)).collect::<Vec<_>>().join(",")
            ));
        }
        s.push('}');
        self.json = CString::new(s).unwrap_or_default();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn table_de_base_blanc_et_noir_conserves() {
        let l = base_lut(1.66, 1.0, 2.0);
        assert_eq!(l[0], 0);
        assert_eq!(l[65535], 65535);
        assert!(l.windows(2).all(|p| p[0] <= p[1]), "la table doit être croissante");
    }

    #[test]
    fn table_appareil_valeur_connue() {
        // Gris moyen sRGB 0,5 : calcul à la main de la formule du PC (headroom 1, +1,66 IL, contraste 1).
        let l = base_lut(1.66, 1.0, 1.0);
        let v = l[32768] as f64 / 65535.0;
        assert!(v > 0.7 && v < 0.95, "{v}");
    }

    #[test]
    fn grille_et_passage_8_bits() {
        let src = vec![65535u16; 16 * 16 * 3];
        let (o, g) = look_to_8bit_for_tests(&src, 16, 16, None);
        assert!(o.iter().all(|&v| v == 255));
        assert_eq!(g.len(), 192);
        assert!(g.iter().all(|&v| (v - 255.0).abs() < 0.01));
    }

    #[test]
    fn reduction_par_blocs() {
        // 4×2 pixels RGB, réduction à 2 pixels de grand côté : facteur 2.
        let rgb: Vec<u8> = (0..4 * 2 * 3).map(|i| (i * 10) as u8).collect();
        let (out, w, h) = rgb_to_rgba_scaled(&rgb, 4, 2, 2);
        assert_eq!((w, h), (2, 1));
        assert_eq!(out.len(), 2 * 4);
        assert_eq!(out[3], 255);
        // Premier pixel de sortie : moyenne des pixels (0,0) (1,0) (0,1) (1,1), canal R.
        let r = [rgb[0], rgb[3], rgb[12], rgb[15]].iter().map(|&v| v as u32).sum::<u32>() as f32 / 4.0;
        assert!((out[0] as f32 - r).abs() <= 1.0, "{} contre {}", out[0], r);
    }

    #[test]
    fn reduction_a_la_taille_exacte() {
        // 7028×4688 -> grand côté 2752 : rapport non entier, taille de sortie exacte, image unie conservée.
        let (w, h) = (700usize, 470usize);
        let rgb = vec![120u8; w * h * 3];
        let (out, ow, oh) = rgb_to_rgba_scaled(&rgb, w, h, 275);
        assert_eq!(ow, 275);
        assert_eq!(oh, ((470.0f64 * 275.0 / 700.0).round()) as usize);
        assert!(out.chunks(4).all(|p| p[0] == 120 && p[1] == 120 && p[2] == 120 && p[3] == 255));
    }

    #[test]
    fn pas_de_reduction_si_deja_petit() {
        let rgb = vec![7u8; 3 * 3 * 3];
        let (out, w, h) = rgb_to_rgba_scaled(&rgb, 3, 3, 0);
        assert_eq!((w, h), (3, 3));
        assert_eq!(&out[..4], &[7, 7, 7, 255]);
    }

    #[test]
    fn fichier_absent_donne_une_erreur() {
        assert!(RawFile::open("/chemin/qui/n/existe/pas.arw").is_err());
    }

    #[test]
    fn echappement_json() {
        assert_eq!(esc("a\"b\\c\n"), "a\\\"b\\\\c ");
    }

    /// Essai sur un vrai RAW : `ARW=/chemin/photo.ARW cargo test --release -- --nocapture`.
    #[test]
    fn lecture_d_un_vrai_raw_si_fourni() {
        let Ok(path) = std::env::var("ARW") else { return };
        let mut f = RawFile::open(&path).expect("ouverture");
        assert!(f.info.width > 1000 && f.info.height > 1000);
        for half in [true, false] {
            f.develop(half, 1500, 2).expect("développement");
            let t = f.last.clone().unwrap();
            eprintln!("{} : {} ms ({}×{} -> {}×{}), pic {:.0} Mo", t.mode, t.total_ms, t.full_w, t.full_h, t.out_w, t.out_h, t.peak_rss_mb);
            assert_eq!(f.preview().len(), (t.out_w * t.out_h * 4) as usize);
        }
    }
}
