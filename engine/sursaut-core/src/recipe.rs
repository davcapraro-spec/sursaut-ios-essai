// SPDX-License-Identifier: GPL-3.0-or-later
//! La recette : mêmes champs et même JSON que `Recipe` côté Python (clés inconnues ignorées).
use serde::{Deserialize, Serialize};

pub const HSL_COLORS: [&str; 8] = ["red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"];
pub const CURVE_FIELDS: [&str; 4] = ["curve", "curve_red", "curve_green", "curve_blue"];

fn identity() -> Vec<[f64; 2]> {
    vec![[0.0, 0.0], [1.0, 1.0]]
}
fn one() -> f64 {
    1.0
}
fn fifty() -> f64 {
    50.0
}
fn twenty_five() -> f64 {
    25.0
}

/// Une retouche de tache : cible (x, y), rayon r, source (sx, sy) ; positions en fractions de la photo originale, rayon en fraction du grand côté.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct Spot {
    pub x: f64,
    pub y: f64,
    pub r: f64,
    pub sx: f64,
    pub sy: f64,
    pub mode: String, // "heal" (corriger), "clone" ou "ai" (génératif : traité hors du moteur, par un modèle ONNX)
    pub feather: f64, // 0..1 : largeur du bord progressif
    pub opacity: f64, // 0..1
    /// Pinceau : centres des disques du trait (fractions de la photo). Vide = retouche circulaire en (x, y).
    pub stroke: Vec<[f64; 2]>,
}

impl Default for Spot {
    fn default() -> Self {
        Spot { x: 0.5, y: 0.5, r: 0.01, sx: 0.55, sy: 0.5, mode: "heal".to_string(), feather: 0.5, opacity: 1.0, stroke: Vec::new() }
    }
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct Hsl {
    pub hsl_hue_red: f64,
    pub hsl_sat_red: f64,
    pub hsl_lum_red: f64,
    pub hsl_hue_orange: f64,
    pub hsl_sat_orange: f64,
    pub hsl_lum_orange: f64,
    pub hsl_hue_yellow: f64,
    pub hsl_sat_yellow: f64,
    pub hsl_lum_yellow: f64,
    pub hsl_hue_green: f64,
    pub hsl_sat_green: f64,
    pub hsl_lum_green: f64,
    pub hsl_hue_aqua: f64,
    pub hsl_sat_aqua: f64,
    pub hsl_lum_aqua: f64,
    pub hsl_hue_blue: f64,
    pub hsl_sat_blue: f64,
    pub hsl_lum_blue: f64,
    pub hsl_hue_purple: f64,
    pub hsl_sat_purple: f64,
    pub hsl_lum_purple: f64,
    pub hsl_hue_magenta: f64,
    pub hsl_sat_magenta: f64,
    pub hsl_lum_magenta: f64,
}

impl Hsl {
    /// Réglages [teinte, saturation, luminance] de chacune des 8 familles de couleurs.
    pub fn bands(&self) -> [[f64; 3]; 8] {
        [
            [self.hsl_hue_red, self.hsl_sat_red, self.hsl_lum_red],
            [self.hsl_hue_orange, self.hsl_sat_orange, self.hsl_lum_orange],
            [self.hsl_hue_yellow, self.hsl_sat_yellow, self.hsl_lum_yellow],
            [self.hsl_hue_green, self.hsl_sat_green, self.hsl_lum_green],
            [self.hsl_hue_aqua, self.hsl_sat_aqua, self.hsl_lum_aqua],
            [self.hsl_hue_blue, self.hsl_sat_blue, self.hsl_lum_blue],
            [self.hsl_hue_purple, self.hsl_sat_purple, self.hsl_lum_purple],
            [self.hsl_hue_magenta, self.hsl_sat_magenta, self.hsl_lum_magenta],
        ]
    }

    pub fn is_neutral(&self) -> bool {
        self.bands().iter().all(|b| b.iter().all(|v| *v == 0.0))
    }
}

/// Color Grading : une teinte (0..360°), une saturation (0..100) et une luminosité (−100..100) pour les ombres,
/// les tons moyens, les hautes lumières et l'ensemble de l'image ; `blending` (0..100) règle le recouvrement
/// des zones et `balance` (−100..100) le point de bascule entre ombres et hautes lumières.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct Grading {
    pub cg_shadows_hue: f64,
    pub cg_shadows_sat: f64,
    pub cg_shadows_lum: f64,
    pub cg_mid_hue: f64,
    pub cg_mid_sat: f64,
    pub cg_mid_lum: f64,
    pub cg_high_hue: f64,
    pub cg_high_sat: f64,
    pub cg_high_lum: f64,
    pub cg_global_hue: f64,
    pub cg_global_sat: f64,
    pub cg_global_lum: f64,
    pub cg_blending: f64,
    pub cg_balance: f64,
}

impl Default for Grading {
    fn default() -> Self {
        Grading {
            cg_shadows_hue: 0.0, cg_shadows_sat: 0.0, cg_shadows_lum: 0.0,
            cg_mid_hue: 0.0, cg_mid_sat: 0.0, cg_mid_lum: 0.0,
            cg_high_hue: 0.0, cg_high_sat: 0.0, cg_high_lum: 0.0,
            cg_global_hue: 0.0, cg_global_sat: 0.0, cg_global_lum: 0.0,
            cg_blending: 50.0, cg_balance: 0.0,
        }
    }
}

impl Grading {
    /// Rien à faire : aucune zone n'a de saturation ni de luminosité (la teinte seule ne change rien).
    pub fn is_neutral(&self) -> bool {
        [self.cg_shadows_sat, self.cg_shadows_lum, self.cg_mid_sat, self.cg_mid_lum,
         self.cg_high_sat, self.cg_high_lum, self.cg_global_sat, self.cg_global_lum].iter().all(|v| *v == 0.0)
    }

    /// Réglages [teinte, saturation, luminosité] de : ombres, tons moyens, hautes lumières, global.
    pub fn zones(&self) -> [[f64; 3]; 4] {
        [
            [self.cg_shadows_hue, self.cg_shadows_sat, self.cg_shadows_lum],
            [self.cg_mid_hue, self.cg_mid_sat, self.cg_mid_lum],
            [self.cg_high_hue, self.cg_high_sat, self.cg_high_lum],
            [self.cg_global_hue, self.cg_global_sat, self.cg_global_lum],
        ]
    }
}

/// Corrections d'objectif manuelles (comme l'onglet « Manuel » de Lightroom), appliquées en tout premier sur la photo entière.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct Lens {
    /// −100..100 : + corrige une distorsion en barillet (bords étirés vers l'extérieur), − une distorsion en coussinet.
    pub lens_distortion: f64,
    /// 50..150 (100 = taille d'origine) : agrandit l'image pour cacher les bords vides laissés par la correction.
    pub lens_scale: f64,
    /// −100..100 : aberration chromatique latérale, rouge / cyan (le canal rouge est agrandi ou réduit d'au plus 1 %).
    pub lens_ca_red: f64,
    /// −100..100 : idem pour le canal bleu (jaune).
    pub lens_ca_blue: f64,
    /// −100..100 : + éclaircit les coins, − les assombrit.
    pub lens_vignette: f64,
    /// 0..100 : distance du centre où commence l'effet (plus haut = seulement tout au bord).
    pub lens_vignette_mid: f64,
    /// Profil automatique de l'objectif (base Lensfun) : quatre tables radiales, échantillonnées de 0 (centre) à 1 (coin) ; absent = aucun profil.
    pub lens_profile: Option<LensProfile>,
}

/// Tables radiales d'un profil d'objectif. Chaque table est vide (non utilisée) ou contient au moins 2 valeurs régulièrement
/// espacées sur le rayon normalisé (rayon / demi-diagonale). Elles se combinent avec les curseurs manuels.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct LensProfile {
    /// Rayon source / rayon de sortie : corrige la distorsion (1 = aucune).
    pub geo: Vec<f32>,
    /// Même rapport pour le canal rouge par rapport au vert (aberration chromatique latérale).
    pub ca_r: Vec<f32>,
    /// Idem pour le canal bleu.
    pub ca_b: Vec<f32>,
    /// Gain multiplicatif de luminosité (vignetage ; 1 = aucun).
    pub vig: Vec<f32>,
}

impl Default for Lens {
    fn default() -> Self {
        Lens { lens_distortion: 0.0, lens_scale: 100.0, lens_ca_red: 0.0, lens_ca_blue: 0.0, lens_vignette: 0.0, lens_vignette_mid: 50.0, lens_profile: None }
    }
}

impl Lens {
    pub fn is_neutral(&self) -> bool {
        self.lens_distortion == 0.0 && self.lens_scale == 100.0 && self.lens_ca_red == 0.0 && self.lens_ca_blue == 0.0 && self.lens_vignette == 0.0 && self.lens_profile.is_none()
    }
}

/// Une composante de masque. Les champs utiles dépendent de `kind` :
/// `linear` (x0,y0 → x1,y1 : plein effet en (x0,y0), nul en (x1,y1)), `radial` (centre x0,y0 ; rayons rx, ry ; angle ; feather),
/// `brush` (stroke, r, feather), `luminance` (lo, hi, smooth), `color` (hue, hue_range, sat_min), `bitmap` (key : image d'IA).
/// Positions en fractions de la photo originale ; rayons en fraction de son grand côté.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct MaskComp {
    pub kind: String,
    /// `add` (ajouter), `subtract` (soustraire) ou `intersect` (intersecter) avec ce qui précède
    pub op: String,
    pub invert: bool,
    pub x0: f64,
    pub y0: f64,
    pub x1: f64,
    pub y1: f64,
    pub rx: f64,
    pub ry: f64,
    pub angle: f64,
    pub feather: f64,
    pub r: f64,
    pub stroke: Vec<[f64; 2]>,
    pub lo: f64,
    pub hi: f64,
    pub smooth: f64,
    pub hue: f64,
    pub hue_range: f64,
    pub sat_min: f64,
    pub key: String,
    /// agrandir (+) ou réduire (−) la zone des composantes « pinceau » et « image d'IA » : −1 .. +1 (0 : inchangée)
    pub grow: f64,
}

impl Default for MaskComp {
    fn default() -> Self {
        MaskComp {
            kind: "linear".into(), op: "add".into(), invert: false, x0: 0.5, y0: 0.3, x1: 0.5, y1: 0.7, rx: 0.2, ry: 0.2, angle: 0.0,
            feather: 0.5, r: 0.02, stroke: Vec::new(), lo: 0.0, hi: 1.0, smooth: 0.3, hue: 0.0, hue_range: 30.0, sat_min: 0.1, key: String::new(), grow: 0.0,
        }
    }
}

/// Réglages locaux d'un masque (mêmes unités que les réglages globaux).
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct LocalAdj {
    pub exposure: f64,
    pub contrast: f64,
    pub highlights: f64,
    pub shadows: f64,
    pub temperature: f64,
    pub tint: f64,
    pub saturation: f64,
    pub vibrance: f64,
    /// Détail local (mêmes algorithmes que les réglages globaux de l'étage « detail » et de « denoise »)
    pub clarity: f64,
    pub texture: f64,
    /// netteté : 0..100 (rayon et détail du réglage global par défaut)
    pub sharpen: f64,
    /// réduction du bruit : 0..100 (luminosité et couleur ensemble)
    pub denoise: f64,
}

/// Un masque : composantes empilées + réglages locaux.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct Mask {
    pub name: String,
    pub enabled: bool,
    pub invert: bool,
    /// 0..100 : opacité du masque
    pub amount: f64,
    pub comps: Vec<MaskComp>,
    pub adj: LocalAdj,
}

impl Default for Mask {
    fn default() -> Self {
        Mask { name: String::new(), enabled: true, invert: false, amount: 100.0, comps: Vec::new(), adj: LocalAdj::default() }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct Recipe {
    pub exposure: f64,
    pub temperature: f64,
    pub tint: f64,
    pub highlights: f64,
    pub shadows: f64,
    pub contrast: f64,
    pub vibrance: f64,
    pub saturation: f64,
    /// Noir et blanc : l'image devient grise ; la luminosité de chaque famille de couleurs (mélangeur) éclaircit ou assombrit son gris.
    pub bw: bool,
    pub whites: f64,
    pub blacks: f64,
    pub texture: f64,
    pub clarity: f64,
    pub dehaze: f64,
    pub crop_left: f64,
    pub crop_top: f64,
    #[serde(default = "one")]
    pub crop_right: f64,
    #[serde(default = "one")]
    pub crop_bottom: f64,
    pub angle: f64,
    /// perspective verticale, -100..100 : > 0 resserre le bas (redresse un bâtiment photographié d'en bas)
    pub persp_v: f64,
    /// perspective horizontale, -100..100 : > 0 resserre le côté droit (redresse une façade vue de la gauche)
    pub persp_h: f64,
    /// grain : quantité 0..100
    pub grain_amount: f64,
    /// grain : taille 0..100 (25 = fin)
    pub grain_size: f64,
    /// grain : rugosité 0..100 (0 = doux, 100 = granuleux)
    pub grain_roughness: f64,
    /// lueur : quantité 0..100
    pub glow_amount: f64,
    /// lueur : rayon du halo 0..100
    pub glow_radius: f64,
    /// lueur : seuil 0..100 (haut = seulement les sources de lumière, bas = toute l'image)
    pub glow_threshold: f64,
    /// vignetage artistique (après recadrage) -100..100 : négatif assombrit les bords, positif les éclaircit
    pub vig_amount: f64,
    /// vignetage : point médian 0..100 (part du centre épargnée)
    pub vig_mid: f64,
    /// vignetage : arrondi -100..100 (-100 suit le cadre, +100 cercle)
    pub vig_round: f64,
    /// vignetage : progressivité 0..100
    pub vig_feather: f64,
    /// calibration : teinte des ombres -100..100 (+ = magenta)
    pub calib_shadow_tint: f64,
    /// calibration : teinte du primaire rouge -100..100
    pub calib_red_hue: f64,
    /// calibration : saturation du primaire rouge -100..100
    pub calib_red_sat: f64,
    /// calibration : teinte du primaire vert -100..100
    pub calib_green_hue: f64,
    /// calibration : saturation du primaire vert -100..100
    pub calib_green_sat: f64,
    /// calibration : teinte du primaire bleu -100..100
    pub calib_blue_hue: f64,
    /// calibration : saturation du primaire bleu -100..100
    pub calib_blue_sat: f64,
    /// noir et blanc par canaux : poids du rouge -100..100 (0 = luminance)
    pub bw_red: f64,
    /// noir et blanc par canaux : poids du vert -100..100
    pub bw_green: f64,
    /// noir et blanc par canaux : poids du bleu -100..100
    pub bw_blue: f64,
    pub sharpen_amount: f64,
    #[serde(default = "one")]
    pub sharpen_radius: f64,
    pub sharpen_masking: f64,
    #[serde(default = "twenty_five")]
    pub sharpen_detail: f64,
    pub denoise_luma: f64,
    pub denoise_color: f64,
    #[serde(default = "fifty")]
    pub denoise_luma_detail: f64,
    pub denoise_luma_contrast: f64,
    #[serde(default = "fifty")]
    pub denoise_color_detail: f64,
    #[serde(default = "fifty")]
    pub denoise_color_smooth: f64,
    #[serde(flatten)]
    pub hsl: Hsl,
    #[serde(flatten)]
    pub grading: Grading,
    #[serde(flatten)]
    pub lens: Lens,
    pub spots: Vec<Spot>,
    pub masks: Vec<Mask>,
    #[serde(default = "identity")]
    pub curve: Vec<[f64; 2]>,
    #[serde(default = "identity")]
    pub curve_red: Vec<[f64; 2]>,
    #[serde(default = "identity")]
    pub curve_green: Vec<[f64; 2]>,
    #[serde(default = "identity")]
    pub curve_blue: Vec<[f64; 2]>,
    pub schema: u32,
}

impl Default for Recipe {
    fn default() -> Self {
        Recipe {
            exposure: 0.0, temperature: 0.0, tint: 0.0, highlights: 0.0, shadows: 0.0, contrast: 0.0,
            vibrance: 0.0, saturation: 0.0, bw: false, whites: 0.0, blacks: 0.0, texture: 0.0, clarity: 0.0, dehaze: 0.0,
            crop_left: 0.0, crop_top: 0.0, crop_right: 1.0, crop_bottom: 1.0, angle: 0.0, persp_v: 0.0, persp_h: 0.0, glow_amount: 0.0, glow_radius: 40.0, glow_threshold: 60.0, grain_amount: 0.0, grain_size: 25.0, grain_roughness: 50.0, vig_amount: 0.0, vig_mid: 50.0, vig_round: 0.0, vig_feather: 50.0, calib_shadow_tint: 0.0, calib_red_hue: 0.0, calib_red_sat: 0.0, calib_green_hue: 0.0, calib_green_sat: 0.0, calib_blue_hue: 0.0, calib_blue_sat: 0.0, bw_red: 0.0, bw_green: 0.0, bw_blue: 0.0,
            sharpen_amount: 0.0, sharpen_radius: 1.0, sharpen_masking: 0.0, sharpen_detail: 25.0, denoise_luma: 0.0, denoise_color: 0.0,
            denoise_luma_detail: 50.0, denoise_luma_contrast: 0.0, denoise_color_detail: 50.0, denoise_color_smooth: 50.0, hsl: Hsl::default(), grading: Grading::default(), lens: Lens::default(), spots: vec![], masks: vec![],
            curve: identity(), curve_red: identity(), curve_green: identity(), curve_blue: identity(), schema: 1,
        }
    }
}

impl Recipe {
    pub fn from_json(text: &str) -> Result<Recipe, String> {
        let mut r: Recipe = serde_json::from_str(text).map_err(|e| format!("recette illisible : {e}"))?;
        r.curve = crate::curve::normalize(&r.curve);
        r.curve_red = crate::curve::normalize(&r.curve_red);
        r.curve_green = crate::curve::normalize(&r.curve_green);
        r.curve_blue = crate::curve::normalize(&r.curve_blue);
        Ok(r)
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string_pretty(self).unwrap()
    }

    /// Rectangle de recadrage borné et cohérent (taille minimale 2 %).
    pub fn crop_rect(&self) -> (f64, f64, f64, f64) {
        let l = self.crop_left.clamp(0.0, 0.98);
        let t = self.crop_top.clamp(0.0, 0.98);
        let rt = self.crop_right.max(l + 0.02).min(1.0);
        let b = self.crop_bottom.max(t + 0.02).min(1.0);
        (l, t, rt, b)
    }
}
