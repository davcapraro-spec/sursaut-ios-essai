// SPDX-License-Identifier: GPL-3.0-or-later
//! Masques et réglages locaux : dernier étage du moteur.
//!
//! Un masque = une pile de composantes (dégradé linéaire, dégradé radial, pinceau, plage de luminosité, plage de
//! couleur, image de masque fournie par l'IA) combinées par « ajouter / soustraire / intersecter », puis des réglages
//! (exposition, contraste…) appliqués à l'image selon la valeur du masque (0 = rien, 1 = plein effet).
//!
//! Géométrie : toutes les positions sont des fractions de la photo ORIGINALE (avant recadrage, comme les retouches
//! de taches) ; les rayons sont des fractions de son grand côté. L'étage reçoit l'image recadrée et redressée : pour
//! chaque pixel on remonte à sa position dans la photo originale avec la même transformation que `stages::geometry`.
use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};

use rayon::prelude::*;

use crate::color::{self, luma, srgb_to_linear};
use crate::image::Image;
use crate::recipe::{Mask, MaskComp, Recipe};

/// Côté long (en cases) de la grille où l'on peint les traits de pinceau.
const BRUSH_GRID: f32 = 1024.0;

/// Image de masque (0..255) fournie par Python (modèles d'IA), repérée par une clé.
pub struct Bitmap {
    pub w: usize,
    pub h: usize,
    pub data: Vec<u8>,
}

fn bitmaps() -> &'static Mutex<HashMap<String, Arc<Bitmap>>> {
    static B: OnceLock<Mutex<HashMap<String, Arc<Bitmap>>>> = OnceLock::new();
    B.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Enregistre l'image d'un masque d'IA (la clé identifie son contenu : une nouvelle détection = une nouvelle clé).
pub fn set_bitmap(key: &str, w: usize, h: usize, data: Vec<u8>) {
    assert_eq!(data.len(), w * h);
    let mut map = bitmaps().lock().unwrap_or_else(|e| e.into_inner());       // verrou non empoisonné : une panique isolée ne coupe pas les masques d'IA
    if map.len() > 64 {
        map.clear();      // garde-fou : les anciennes détections sont recalculables
    }
    map.insert(key.to_string(), Arc::new(Bitmap { w, h, data }));
}

/// Le moteur a-t-il déjà l'image de ce masque d'IA ? (Python ne la renvoie alors pas à chaque rendu.)
pub fn has_bitmap(key: &str) -> bool {
    bitmaps().lock().unwrap_or_else(|e| e.into_inner()).contains_key(key)
}

fn smooth(lo: f32, hi: f32, x: f32) -> f32 {
    if hi <= lo {
        return if x >= hi { 1.0 } else { 0.0 };
    }
    let t = ((x - lo) / (hi - lo)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

/// Repère de la photo originale (unités = hauteur de la photo) et transformation des pixels de sortie.
struct Frame {
    ow: usize,
    oh: usize,
    /// largeur / hauteur de la photo originale
    aspect: f32,
    /// grand côté (en unités de hauteur)
    long: f32,
    l: f32,
    t: f32,
    dl: f32,
    dt: f32,
    angle: bool,
    cos: f32,
    sin: f32,
    fw: f32,
    fh: f32,
}

impl Frame {
    fn new(ow: usize, oh: usize, r: &Recipe) -> Frame {
        let (l, t, rt, b) = r.crop_rect();
        let aspect = ((ow as f64 / oh as f64) * (b - t) / (rt - l)) as f32;
        let th = r.angle.to_radians();
        let k = if r.angle != 0.0 {
            let tha = th.abs();
            (1.0 / (tha.cos() + (aspect as f64).max(1.0 / aspect as f64) * tha.sin())) as f32
        } else {
            1.0
        };
        Frame {
            ow, oh, aspect, long: aspect.max(1.0),
            l: l as f32, t: t as f32, dl: (rt - l) as f32, dt: (b - t) as f32,
            angle: r.angle != 0.0, cos: th.cos() as f32, sin: th.sin() as f32,
            fw: aspect * k, fh: k,
        }
    }

    /// Position (X, Y) dans la photo originale, en unités de hauteur, du centre du pixel de sortie (i, j).
    #[inline]
    fn to_source(&self, i: usize, j: usize) -> (f32, f32) {
        let fx = self.l + (i as f32 + 0.5) / self.ow as f32 * self.dl;
        let fy = self.t + (j as f32 + 0.5) / self.oh as f32 * self.dt;
        if !self.angle {
            return (fx * self.aspect, fy);
        }
        let u = self.fw * fx - self.fw / 2.0;
        let v = self.fh * fy - self.fh / 2.0;
        (u * self.cos + v * self.sin + self.aspect / 2.0, -u * self.sin + v * self.cos + 0.5)
    }
}

/// Grille de valeurs 0..1 couvrant la photo originale (traits de pinceau ou image d'IA), lue en bilinéaire.
struct Grid {
    w: usize,
    h: usize,
    data: Vec<f32>,
}

impl Grid {
    #[inline]
    fn sample(&self, u: f32, v: f32) -> f32 {
        if !(0.0..=1.0).contains(&u) || !(0.0..=1.0).contains(&v) {
            return 0.0;
        }
        let x = (u * self.w as f32 - 0.5).clamp(0.0, (self.w - 1) as f32);
        let y = (v * self.h as f32 - 0.5).clamp(0.0, (self.h - 1) as f32);
        let (x0, y0) = (x as usize, y as usize);
        let (x1, y1) = ((x0 + 1).min(self.w - 1), (y0 + 1).min(self.h - 1));
        let (fx, fy) = (x - x0 as f32, y - y0 as f32);
        let p = |yy: usize, xx: usize| self.data[yy * self.w + xx];
        (p(y0, x0) * (1.0 - fx) + p(y0, x1) * fx) * (1.0 - fy) + (p(y1, x0) * (1.0 - fx) + p(y1, x1) * fx) * fy
    }
}

fn brush_grid(c: &MaskComp, aspect: f32, long: f32) -> Grid {
    let (gw, gh) = (((aspect / long) * BRUSH_GRID).round().max(1.0) as usize, ((1.0 / long) * BRUSH_GRID).round().max(1.0) as usize);
    let mut data = vec![0f32; gw * gh];
    let cell = BRUSH_GRID / long; // cases par unité de hauteur
    let rad = (c.r as f32 * long * cell).max(0.75);
    let inner = 1.0 - c.feather.clamp(0.0, 1.0) as f32;
    for p in &c.stroke {
        let (cx, cy) = (p[0] as f32 * aspect * cell, p[1] as f32 * cell);
        let (x0, x1) = (((cx - rad).floor().max(0.0)) as usize, ((cx + rad).ceil() as usize + 1).min(gw));
        let (y0, y1) = (((cy - rad).floor().max(0.0)) as usize, ((cy + rad).ceil() as usize + 1).min(gh));
        for y in y0..y1 {
            for x in x0..x1 {
                let d = (((x as f32 + 0.5 - cx).powi(2) + (y as f32 + 0.5 - cy).powi(2)).sqrt()) / rad;
                if d < 1.0 {
                    let v = 1.0 - smooth(inner, 1.0, d);
                    let o = &mut data[y * gw + x];
                    *o = o.max(v);
                }
            }
        }
    }
    Grid { w: gw, h: gh, data }
}

/// Flou en boîte (une passe horizontale puis verticale), rayon `r` cases, bords prolongés.
fn box_blur(g: &Grid, r: usize) -> Grid {
    let (w, h) = (g.w, g.h);
    let n = (2 * r + 1) as f32;
    let mut tmp = vec![0f32; w * h];
    for y in 0..h {
        let row = &g.data[y * w..(y + 1) * w];
        let at = |i: isize| row[i.clamp(0, w as isize - 1) as usize];
        let mut sum: f32 = (-(r as isize)..=r as isize).map(at).sum();
        for x in 0..w {
            tmp[y * w + x] = sum / n;
            sum += at(x as isize + r as isize + 1) - at(x as isize - r as isize);
        }
    }
    let mut out = vec![0f32; w * h];
    for x in 0..w {
        let at = |i: isize| tmp[i.clamp(0, h as isize - 1) as usize * w + x];
        let mut sum: f32 = (-(r as isize)..=r as isize).map(at).sum();
        for y in 0..h {
            out[y * w + x] = sum / n;
            sum += at(y as isize + r as isize + 1) - at(y as isize - r as isize);
        }
    }
    Grid { w, h, data: out }
}

/// Part de la grande dimension de la grille qui sert d'écart-type du flou : fixe l'amplitude maximale du réglage.
const GROW_SIGMA: f32 = 0.01;
/// Demi-largeur de la transition (en valeur de flou) autour du seuil : le bord reste progressif.
const GROW_SOFT: f32 = 0.12;

/// Agrandit (`grow` > 0) ou réduit (`grow` < 0) une zone : flou isotrope (trois passes en boîte ≈ gaussienne), puis seuil déplacé.
/// Un seuil de 0,5 laisse le bord où il est ; plus bas il avance, plus haut il recule. `grow` = 0 : zone inchangée.
fn grow_grid(g: Grid, grow: f32) -> Grid {
    let grow = grow.clamp(-1.0, 1.0);
    if grow == 0.0 {
        return g;
    }
    let r = ((GROW_SIGMA * g.w.max(g.h) as f32).round() as usize).max(1);
    let blurred = box_blur(&box_blur(&box_blur(&g, r), r), r);
    let t = 0.5 - 0.48 * grow;
    let (lo, hi) = ((t - GROW_SOFT).max(0.0), (t + GROW_SOFT).min(1.0));
    Grid { w: g.w, h: g.h, data: blurred.data.iter().map(|&v| smooth(lo, hi, v)).collect() }
}

fn bitmap_grid(key: &str) -> Option<Grid> {
    let b = bitmaps().lock().unwrap_or_else(|e| e.into_inner()).get(key).cloned()?;
    Some(Grid { w: b.w, h: b.h, data: b.data.iter().map(|&v| v as f32 / 255.0).collect() })
}

/// Une composante prête à être évaluée.
enum Shape {
    Linear { p0: [f32; 2], d: [f32; 2], inv_len2: f32 },
    Radial { c: [f32; 2], rx: f32, ry: f32, cos: f32, sin: f32, inner: f32 },
    Grid(Grid),
    Luminance { lo: f32, hi: f32, soft: f32 },
    Color { hue: f32, range: f32, sat_min: f32 },
    Nothing,
}

struct Comp {
    shape: Shape,
    op: u8, // 0 ajouter, 1 soustraire, 2 intersecter
    invert: bool,
}

fn build_comp(c: &MaskComp, f: &Frame) -> Comp {
    let a = f.aspect;
    let shape = match c.kind.as_str() {
        "linear" => {
            let p0 = [c.x0 as f32 * a, c.y0 as f32];
            let d = [c.x1 as f32 * a - p0[0], c.y1 as f32 - p0[1]];
            let len2 = (d[0] * d[0] + d[1] * d[1]).max(1e-9);
            Shape::Linear { p0, d, inv_len2: 1.0 / len2 }
        }
        "radial" => {
            let th = c.angle.to_radians() as f32;
            Shape::Radial {
                c: [c.x0 as f32 * a, c.y0 as f32],
                rx: (c.rx as f32 * f.long).max(1e-4),
                ry: (c.ry as f32 * f.long).max(1e-4),
                cos: th.cos(), sin: th.sin(),
                inner: 1.0 - c.feather.clamp(0.0, 1.0) as f32,
            }
        }
        "brush" => Shape::Grid(grow_grid(brush_grid(c, a, f.long), c.grow as f32)),
        "bitmap" => bitmap_grid(&c.key).map(|g| Shape::Grid(grow_grid(g, c.grow as f32))).unwrap_or(Shape::Nothing),
        "luminance" => Shape::Luminance { lo: c.lo as f32, hi: c.hi as f32, soft: c.smooth.clamp(0.0, 1.0) as f32 * 0.5 },
        "color" => Shape::Color { hue: c.hue as f32, range: (c.hue_range as f32).max(1.0), sat_min: c.sat_min as f32 },
        _ => Shape::Nothing,
    };
    Comp { shape, op: match c.op.as_str() { "subtract" => 1, "intersect" => 2, _ => 0 }, invert: c.invert }
}

fn hue_sat(r: f32, g: f32, b: f32) -> (f32, f32) {
    let mx = r.max(g).max(b);
    let mn = r.min(g).min(b);
    let chroma = mx - mn;
    if chroma < 1e-6 {
        return (0.0, 0.0);
    }
    let h = if mx == r { 60.0 * (((g - b) / chroma) % 6.0) } else if mx == g { 60.0 * ((b - r) / chroma + 2.0) } else { 60.0 * ((r - g) / chroma + 4.0) };
    (h.rem_euclid(360.0), chroma / mx)
}

impl Comp {
    /// Valeur 0..1 au point (X, Y) de la photo originale ; `px` = couleur d'affichage du pixel.
    #[inline]
    fn value(&self, x: f32, y: f32, f: &Frame, px: [f32; 3]) -> f32 {
        let v = match &self.shape {
            Shape::Linear { p0, d, inv_len2 } => {
                let t = ((x - p0[0]) * d[0] + (y - p0[1]) * d[1]) * inv_len2;
                1.0 - smooth(0.0, 1.0, t)
            }
            Shape::Radial { c, rx, ry, cos, sin, inner } => {
                let (dx, dy) = (x - c[0], y - c[1]);
                let (lx, ly) = (dx * cos + dy * sin, -dx * sin + dy * cos);
                let d = ((lx / rx).powi(2) + (ly / ry).powi(2)).sqrt();
                1.0 - smooth(*inner, 1.0, d)
            }
            Shape::Grid(g) => g.sample(x / f.aspect, y),
            Shape::Luminance { lo, hi, soft } => {
                let l = luma(px[0], px[1], px[2]);
                smooth(lo - soft, *lo, l) * (1.0 - smooth(*hi, hi + soft, l))
            }
            Shape::Color { hue, range, sat_min } => {
                let (h, s) = hue_sat(px[0], px[1], px[2]);
                let dh = ((h - hue + 540.0).rem_euclid(360.0) - 180.0).abs();
                (1.0 - smooth(range * 0.5, *range, dh)) * smooth(*sat_min * 0.5, *sat_min + 1e-3, s)
            }
            Shape::Nothing => 0.0,
        };
        if self.invert { 1.0 - v } else { v }
    }
}

/// Valeur du masque au point (X, Y) : on empile les composantes dans l'ordre.
#[inline]
fn mask_value(comps: &[Comp], invert: bool, amount: f32, x: f32, y: f32, f: &Frame, px: [f32; 3]) -> f32 {
    let mut m = 0.0f32;
    for c in comps {
        let v = c.value(x, y, f, px);
        m = match c.op {
            1 => m * (1.0 - v),
            2 => m * v,
            _ => m + v - m * v,
        };
    }
    (if invert { 1.0 - m } else { m }) * amount
}

/// Réglages d'un masque, déjà convertis en gains.
struct Adjust {
    gain: [f32; 3],      // exposition + balance des blancs, en lumière linéaire
    shadows: f32,
    highlights: f32,
    contrast: f32,
    saturation: f32,
    vibrance: f32,
    tonal: bool,
    linear: bool,
    basic: bool,
}

impl Adjust {
    fn new(m: &Mask) -> Adjust {
        let a = &m.adj;
        let (t, ti) = (a.temperature / 100.0, a.tint / 100.0);
        let e = 2.0f64.powf(a.exposure);
        let gain = [(2.0f64.powf(0.5 * t) * e) as f32, (2.0f64.powf(-0.3 * ti) * e) as f32, (2.0f64.powf(-0.5 * t) * e) as f32];
        let tonal = a.shadows != 0.0 || a.highlights != 0.0;
        Adjust {
            gain, shadows: (1.5 * a.shadows / 100.0) as f32, highlights: (1.5 * a.highlights / 100.0) as f32,
            contrast: (a.contrast / 100.0) as f32, saturation: (1.0 + a.saturation / 100.0) as f32, vibrance: (a.vibrance / 100.0) as f32,
            tonal,
            linear: tonal || a.exposure != 0.0 || a.temperature != 0.0 || a.tint != 0.0,
            basic: a.saturation != 0.0 || a.vibrance != 0.0,
        }
    }

    fn is_neutral(&self) -> bool {
        !self.linear && self.contrast == 0.0 && !self.basic
    }

    /// Pixel d'affichage (sRGB 0..1) → pixel retouché.
    fn apply(&self, px: [f32; 3], enc: &[f32]) -> [f32; 3] {
        let mut v = px;
        if self.linear {
            let lin = [srgb_to_linear(v[0]), srgb_to_linear(v[1]), srgb_to_linear(v[2])];
            let mut g = self.gain;
            if self.tonal {
                let p = luma(lin[0], lin[1], lin[2]).clamp(0.0, 1.0).sqrt();
                let boost = (self.shadows * (1.0 - p) * (1.0 - p) + self.highlights * p * p).exp2();
                g = [g[0] * boost, g[1] * boost, g[2] * boost];
            }
            for c in 0..3 {
                v[c] = color::linear_to_srgb(enc, lin[c] * g[c]);
            }
        }
        if self.contrast != 0.0 {
            for c in v.iter_mut() {
                let s = *c * *c * (3.0 - 2.0 * *c);
                *c += self.contrast * (s - *c);
            }
        }
        if self.basic {
            let l = luma(v[0], v[1], v[2]);
            let chroma = v[0].max(v[1]).max(v[2]) - v[0].min(v[1]).min(v[2]);
            let factor = (self.saturation * (1.0 + self.vibrance * (1.0 - chroma))).max(0.0);
            for c in v.iter_mut() {
                *c = l + (*c - l) * factor;
            }
        }
        [v[0].clamp(0.0, 1.0), v[1].clamp(0.0, 1.0), v[2].clamp(0.0, 1.0)]
    }
}

/// Numéro du masque à montrer en rouge (clé `zone_view` de la recette), s'il y en a un.
pub fn zone_view_index(recipe_json: &str) -> Option<usize> {
    let v: serde_json::Value = serde_json::from_str(recipe_json).ok()?;
    v.get("zone_view")?.as_u64().map(|n| n as usize)
}

/// Valeur (0..1) du masque `index` sur tout le cadre de sortie : sert à l'affichage de la superposition rouge.
pub fn render_mask(img: &Image, r: &Recipe, index: usize) -> Vec<f32> {
    let (ow, oh) = (img.w, img.h);
    let Some(m) = r.masks.get(index) else { return vec![0.0; ow * oh] };
    let f = Frame::new(ow, oh, r);
    let comps: Vec<Comp> = m.comps.iter().map(|c| build_comp(c, &f)).collect();
    let amount = (m.amount / 100.0).clamp(0.0, 1.0) as f32;
    let mut out = vec![0f32; ow * oh];
    out.par_chunks_mut(ow).enumerate().for_each(|(j, row)| {
        for (i, o) in row.iter_mut().enumerate() {
            let (x, y) = f.to_source(i, j);
            let k = (j * ow + i) * 3;
            *o = mask_value(&comps, m.invert, amount, x, y, &f, [img.data[k], img.data[k + 1], img.data[k + 2]]);
        }
    });
    out
}

/// La recette a-t-elle un masque avec un réglage de détail ? (le rendu par bandes ne sait pas le faire : il demande alors le rendu entier)
pub fn needs_detail(r: &Recipe) -> bool {
    r.masks.iter().any(|m| m.enabled && !m.comps.is_empty() && has_detail(m))
}

/// Un masque a-t-il un réglage de détail (clarté, texture, netteté, bruit) ?
fn has_detail(m: &Mask) -> bool {
    let a = &m.adj;
    a.clarity != 0.0 || a.texture != 0.0 || a.sharpen != 0.0 || a.denoise != 0.0
}

/// L'image entière avec le seul détail local d'un masque (réduction du bruit, puis clarté, texture, netteté : même ordre que les étages globaux).
fn detail_variant(img: &Arc<Image>, m: &Mask) -> Arc<Image> {
    let a = &m.adj;
    let r = Recipe {
        clarity: a.clarity, texture: a.texture, sharpen_amount: a.sharpen, denoise_luma: a.denoise, denoise_color: a.denoise, ..Recipe::default()
    };
    crate::stages::detail(&crate::stages::denoise(img, &r), &r)
}

/// L'étage : applique chaque masque actif, dans l'ordre de la liste (d'abord les réglages de couleur et de tons, puis, masque par masque, le détail local).
pub fn local_stage(img: &Arc<Image>, r: &Recipe) -> Arc<Image> {
    let enabled = || r.masks.iter().filter(|m| m.enabled && !m.comps.is_empty());
    let active: Vec<(&Mask, Adjust)> = enabled().map(|m| (m, Adjust::new(m))).filter(|(_, a)| !a.is_neutral()).collect();
    let detailed: Vec<&Mask> = enabled().filter(|m| has_detail(m)).collect();
    if active.is_empty() && detailed.is_empty() {
        return img.clone();
    }
    let (ow, oh) = (img.w, img.h);
    let tile = crate::stages::tile_of(ow, oh);
    let f = Frame::new(tile.full_w, tile.full_h, r);
    let enc = color::encode_table();
    let prepared: Vec<(Vec<Comp>, &Mask, &Adjust)> = active.iter().map(|(m, a)| (m.comps.iter().map(|c| build_comp(c, &f)).collect(), *m, a)).collect();
    let mut data = img.data.clone();
    if !prepared.is_empty() {
        data.par_chunks_mut(ow * 3).enumerate().for_each(|(j, row)| {
            for i in 0..ow {
                let (x, y) = f.to_source(i, j + tile.y0);
                let mut px = [row[i * 3], row[i * 3 + 1], row[i * 3 + 2]];
                for (comps, m, adj) in &prepared {
                    let w = mask_value(comps, m.invert, (m.amount / 100.0).clamp(0.0, 1.0) as f32, x, y, &f, px);
                    if w <= 0.0 {
                        continue;
                    }
                    let out = adj.apply(px, enc);
                    for c in 0..3 {
                        px[c] += (out[c] - px[c]) * w;
                    }
                }
                row[i * 3..i * 3 + 3].copy_from_slice(&px);
            }
        });
    }
    let mut cur = Arc::new(Image { w: ow, h: oh, data });
    for m in detailed {
        let comps: Vec<Comp> = m.comps.iter().map(|c| build_comp(c, &f)).collect();
        let amount = (m.amount / 100.0).clamp(0.0, 1.0) as f32;
        let variant = detail_variant(&cur, m);
        let mut data = cur.data.clone();
        data.par_chunks_mut(ow * 3).zip(variant.data.par_chunks(ow * 3)).enumerate().for_each(|(j, (row, var))| {
            for i in 0..ow {
                let (x, y) = f.to_source(i, j + tile.y0);
                let w = mask_value(&comps, m.invert, amount, x, y, &f, [row[i * 3], row[i * 3 + 1], row[i * 3 + 2]]);
                if w > 0.0 {
                    for c in 0..3 {
                        row[i * 3 + c] += (var[i * 3 + c] - row[i * 3 + c]) * w;
                    }
                }
            }
        });
        cur = Arc::new(Image { w: ow, h: oh, data });
    }
    cur
}
