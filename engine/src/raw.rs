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

/// Réduit une image RGB 8 bits (`w`×`h`) à `max_side` pixels au plus (moyenne par blocs) et
/// la convertit en RGBA. `max_side` = 0 : pas de réduction.
pub fn rgb_to_rgba_scaled(rgb: &[u8], w: usize, h: usize, max_side: usize) -> (Vec<u8>, usize, usize) {
    let longest = w.max(h);
    let f = if max_side == 0 || longest <= max_side { 1 } else { (longest + max_side - 1) / max_side };
    let (ow, oh) = ((w / f).max(1), (h / f).max(1));
    let mut out = vec![255u8; ow * oh * 4];
    for oy in 0..oh {
        for ox in 0..ow {
            let mut acc = [0u32; 3];
            let mut n = 0u32;
            for dy in 0..f {
                let y = oy * f + dy;
                if y >= h {
                    break;
                }
                for dx in 0..f {
                    let x = ox * f + dx;
                    if x >= w {
                        break;
                    }
                    let i = (y * w + x) * 3;
                    acc[0] += rgb[i] as u32;
                    acc[1] += rgb[i + 1] as u32;
                    acc[2] += rgb[i + 2] as u32;
                    n += 1;
                }
            }
            let o = (oy * ow + ox) * 4;
            let n = n.max(1);
            out[o] = (acc[0] / n) as u8;
            out[o + 1] = (acc[1] / n) as u8;
            out[o + 2] = (acc[2] / n) as u8;
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
    pub fn develop(&mut self, half: bool, max_side: u32) -> Result<(), String> {
        let t_all = Instant::now();
        let mut t = Timing { mode: if half { "demi-taille" } else { "complet DHT" }, ..Default::default() };

        let t0 = Instant::now();
        let ctx = open_ctx(&self.path)?;
        t.open_ms = t0.elapsed().as_millis();
        t.full_w = unsafe { lr::libraw_get_iwidth(ctx.0) }.max(0) as u32;
        t.full_h = unsafe { lr::libraw_get_iheight(ctx.0) }.max(0) as u32;

        unsafe {
            lr::libraw_set_output_bps(ctx.0, 8);
            lr::libraw_set_output_color(ctx.0, 1); // sRGB
            lr::libraw_set_no_auto_bright(ctx.0, 1);
            lr::libraw_set_highlight(ctx.0, 0);
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
            if im.bits != 8 || im.colors != 3 || im.data_size as usize != w * h * 3 {
                Err(format!(
                    "LibRaw : image inattendue ({} bits, {} canaux, {} octets pour {}×{}) — disposition des champs à vérifier",
                    im.bits, im.colors, im.data_size, w, h
                ))
            } else {
                let rgb = std::slice::from_raw_parts(im.data.as_ptr(), w * h * 3);
                Ok(rgb_to_rgba_scaled(rgb, w, h, max_side as usize))
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
                ",\"last\":{{\"mode\":\"{}\",\"open_ms\":{},\"unpack_ms\":{},\"process_ms\":{},\"convert_ms\":{},\"total_ms\":{},\"full_w\":{},\"full_h\":{},\"out_w\":{},\"out_h\":{},\"peak_rss_mb\":{:.1}}}",
                t.mode, t.open_ms, t.unpack_ms, t.process_ms, t.convert_ms, t.total_ms, t.full_w, t.full_h, t.out_w, t.out_h, t.peak_rss_mb
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
    fn reduction_par_blocs() {
        // 4×2 pixels RGB, réduction à 2 pixels de grand côté : facteur 2.
        let rgb: Vec<u8> = (0..4 * 2 * 3).map(|i| (i * 10) as u8).collect();
        let (out, w, h) = rgb_to_rgba_scaled(&rgb, 4, 2, 2);
        assert_eq!((w, h), (2, 1));
        assert_eq!(out.len(), 2 * 4);
        assert_eq!(out[3], 255);
        // Premier pixel de sortie : moyenne des pixels (0,0) (1,0) (0,1) (1,1), canal R.
        let r = [rgb[0], rgb[3], rgb[12], rgb[15]].iter().map(|&v| v as u32).sum::<u32>() / 4;
        assert_eq!(out[0] as u32, r);
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
            f.develop(half, 1500).expect("développement");
            let t = f.last.clone().unwrap();
            eprintln!("{} : {} ms ({}×{} -> {}×{}), pic {:.0} Mo", t.mode, t.total_ms, t.full_w, t.full_h, t.out_w, t.out_h, t.peak_rss_mb);
            assert_eq!(f.preview().len(), (t.out_w * t.out_h * 4) as usize);
        }
    }
}
