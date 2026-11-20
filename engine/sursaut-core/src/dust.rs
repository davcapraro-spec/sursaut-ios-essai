// SPDX-License-Identifier: GPL-3.0-or-later
//! Détection automatique de la poussière du capteur : taches sombres, rondes et molles, qui se détachent d'un fond lisse (ciel, mur…).
//! Travaille sur la luminosité d'une image réduite (≤ ~3000 px de long) ; renvoie des candidats classés par « score ».
//! Le score est le contraste de la tache rapporté au bruit de son entourage : le curseur de sensibilité de l'interface ne fait que filtrer par score.
//!
//! Méthode (voir ARCHITECTURE.md §26) :
//! 1. luminosité lissée 3×3 ; fond = flou large (rayon 2 % du grand côté) ; haute fréquence `hp` = lissée − fond ;
//! 2. bruit local = écart moyen de `hp` (plafonné à 8) sur la même fenêtre ; seuil de détection = max(3, 2,75 × bruit) ;
//! 3. pixels sous −seuil regroupés en composantes connexes ; on garde celles qui sont assez grosses (≥ 14 px, ≤ cercle de 2 % du grand côté),
//!    compactes (rapport d'aspect ≤ 2,2, remplissage ≥ 40 % du disque) ;
//! 4. contraste = luminosité de l'anneau (1,8 à 2,8 rayons) − luminosité de la tache ; score = contraste / max(écart-type de l'anneau, bruit local) ;
//! 5. zones texturées (bruit local > 3 niveaux) écartées.
use crate::blur::box_blur;

#[derive(Clone, Debug, PartialEq)]
pub struct Dust {
    pub x: f64,        // centre, fraction de la largeur
    pub y: f64,        // centre, fraction de la hauteur
    pub r: f64,        // rayon couvrant la tache et son bord mou, fraction du grand côté
    pub score: f64,    // contraste / bruit de l'entourage
    pub contrast: f64, // écart de luminosité (0..255) entre l'entourage et la tache
}

const MIN_SCORE: f32 = 3.0;
const MIN_CONTRAST: f32 = 3.0;
const MAX_CANDIDATES: usize = 400;
const MAX_TEXTURE: f32 = 3.0; // bruit local maximal (niveaux de gris 0..255, après lissage 3×3)

/// `rgb` : u8 (hauteur × largeur × 3).
pub fn detect(rgb: &[u8], w: usize, h: usize) -> Vec<Dust> {
    if w < 32 || h < 32 || rgb.len() < w * h * 3 {
        return Vec::new();
    }
    let long = w.max(h) as f32;
    let luma: Vec<f32> = (0..w * h).map(|i| 0.2126 * rgb[i * 3] as f32 + 0.7152 * rgb[i * 3 + 1] as f32 + 0.0722 * rgb[i * 3 + 2] as f32).collect();
    let smooth = box_blur(&luma, w, h, 1); // 3×3 : calme le grain sans effacer une tache de plus de 3 px
    let r_bg = ((long * 0.02) as usize).max(8);
    let bg = box_blur(&smooth, w, h, r_bg);
    let hp: Vec<f32> = (0..w * h).map(|i| smooth[i] - bg[i]).collect();
    let abs_hp: Vec<f32> = hp.iter().map(|v| v.abs().min(8.0)).collect(); // plafonné : la tache elle-même ne doit pas gonfler le bruit estimé autour d'elle
    let noise = box_blur(&abs_hp, w, h, r_bg); // écart moyen local : grand dans les zones texturées
    let thr: Vec<f32> = noise.iter().map(|n| (2.2 * n * 1.25).max(MIN_CONTRAST)).collect();

    let max_r = long * 0.02;
    let max_area = (std::f32::consts::PI * max_r * max_r) as usize;
    let min_area = 14usize;
    let mut seen = vec![false; w * h];
    let mut stack: Vec<usize> = Vec::new();
    let mut out: Vec<Dust> = Vec::new();
    for start in 0..w * h {
        if seen[start] || hp[start] >= -thr[start] {
            continue;
        }
        // composante connexe (4 voisins)
        seen[start] = true;
        stack.clear();
        stack.push(start);
        let (mut area, mut sx, mut sy, mut sum) = (0usize, 0f64, 0f64, 0f64);
        let (mut x0, mut x1, mut y0, mut y1) = (w, 0usize, h, 0usize);
        let mut too_big = false;
        let mut members: Vec<usize> = Vec::new();
        while let Some(i) = stack.pop() {
            let (x, y) = (i % w, i / w);
            area += 1;
            sx += x as f64;
            sy += y as f64;
            sum += luma[i] as f64;
            x0 = x0.min(x);
            x1 = x1.max(x);
            y0 = y0.min(y);
            y1 = y1.max(y);
            if area > max_area {
                too_big = true;
            }
            if !too_big {
                members.push(i);
            }
            let mut push = |j: usize| {
                if !seen[j] && hp[j] < -thr[j] {
                    seen[j] = true;
                    stack.push(j);
                }
            };
            if x > 0 {
                push(i - 1);
            }
            if x + 1 < w {
                push(i + 1);
            }
            if y > 0 {
                push(i - w);
            }
            if y + 1 < h {
                push(i + w);
            }
        }
        if too_big || area < min_area {
            continue;
        }
        let (bw, bh) = ((x1 - x0 + 1) as f32, (y1 - y0 + 1) as f32);
        let aspect = bw.max(bh) / bw.min(bh);
        let half = bw.max(bh) / 2.0;
        let fill = area as f32 / (std::f32::consts::PI * half * half);
        if aspect > 2.2 || fill < 0.4 {
            continue; // trait, cheveu, contour : pas une tache ronde
        }
        let (cx, cy) = ((sx / area as f64) as f32, (sy / area as f64) as f32);
        let inner = (sum / area as f64) as f32;
        let r_eq = ((area as f32 / std::f32::consts::PI).sqrt()).max(half);
        // entourage : anneau de 1,8 à 2,8 rayons, échantillonné en spirale
        let (mut rs, mut rs2, mut n) = (0f32, 0f32, 0f32);
        for k in 0..64 {
            let t = (k as f32 + 0.5) / 64.0;
            let rad = r_eq * (1.8 + 1.0 * t);
            let ang = k as f32 * 2.399_963;
            let (px, py) = ((cx + rad * ang.cos()).round() as isize, (cy + rad * ang.sin()).round() as isize);
            if px >= 0 && py >= 0 && (px as usize) < w && (py as usize) < h {
                let l = smooth[py as usize * w + px as usize];
                rs += l;
                rs2 += l * l;
                n += 1.0;
            }
        }
        if n < 20.0 {
            continue;
        }
        let ring_mean = rs / n;
        let ring_std = (rs2 / n - ring_mean * ring_mean).max(0.0).sqrt();
        let contrast = ring_mean - inner;
        // le bruit local (écart moyen sur une large fenêtre) borne par le bas la variation de l'entourage : un petit anneau la sous-estime
        let local = noise[(cy.round() as usize).min(h - 1) * w + (cx.round() as usize).min(w - 1)] * 1.25;
        if local > MAX_TEXTURE {
            continue; // zone texturée (feuillage, grain fort) : la poussière n'y est pas fiable à détecter, et elle s'y voit à peine
        }
        let score = contrast / ring_std.max(local).max(1.5);
        if contrast < MIN_CONTRAST || score < MIN_SCORE {
            continue;
        }
        out.push(Dust {
            x: (cx as f64 + 0.5) / w as f64,
            y: (cy as f64 + 0.5) / h as f64,
            r: ((r_eq * 1.35 + 1.5) / long) as f64,
            score: score as f64,
            contrast: contrast as f64,
        });
    }
    out.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal));
    out.truncate(MAX_CANDIDATES);
    out
}

/// Ajuste un clic manuel sur une tache : cherche, autour de (x, y), le point le plus sombre par rapport à son entourage, puis mesure la tache
/// (région plus sombre que la moitié de sa profondeur). `r_hint` : rayon réglé par l'utilisateur (fraction du grand côté), qui borne la recherche.
/// Renvoie (x, y, r) en fractions de la photo, ou `None` si rien de net n'est trouvé près du clic.
pub fn refine(rgb: &[u8], w: usize, h: usize, x: f64, y: f64, r_hint: f64) -> Option<(f64, f64, f64)> {
    if w < 16 || h < 16 || rgb.len() < w * h * 3 {
        return None;
    }
    let long = w.max(h) as f32;
    let hint = ((r_hint as f32) * long).max(3.0);
    let search = (hint * 2.5).max(12.0);
    let half = (search * 2.0).ceil() as isize;
    let (cx, cy) = ((x as f32 * w as f32) as isize, (y as f32 * h as f32) as isize);
    let (x0, y0) = ((cx - half).max(0), (cy - half).max(0));
    let (x1, y1) = ((cx + half).min(w as isize - 1), (cy + half).min(h as isize - 1));
    let (ww, wh) = ((x1 - x0 + 1) as usize, (y1 - y0 + 1) as usize);
    if ww < 8 || wh < 8 {
        return None;
    }
    let mut luma = vec![0f32; ww * wh];
    for yy in 0..wh {
        for xx in 0..ww {
            let k = ((y0 as usize + yy) * w + x0 as usize + xx) * 3;
            luma[yy * ww + xx] = 0.2126 * rgb[k] as f32 + 0.7152 * rgb[k + 1] as f32 + 0.0722 * rgb[k + 2] as f32;
        }
    }
    let smooth = box_blur(&luma, ww, wh, 1);
    let bg = box_blur(&smooth, ww, wh, ((half as usize) / 2).max(4));
    let hp: Vec<f32> = (0..ww * wh).map(|i| smooth[i] - bg[i]).collect();
    // point le plus sombre dans le disque de recherche (léger avantage au plus proche du clic)
    let (lx, ly) = ((cx - x0) as f32, (cy - y0) as f32);
    let mut best: Option<(f32, usize)> = None;
    for yy in 0..wh {
        for xx in 0..ww {
            let d = ((xx as f32 - lx).powi(2) + (yy as f32 - ly).powi(2)).sqrt();
            if d > search {
                continue;
            }
            let v = hp[yy * ww + xx] + 0.5 * d / search;
            if best.map_or(true, |b| v < b.0) {
                best = Some((v, yy * ww + xx));
            }
        }
    }
    let (_, seed) = best?;
    let depth = hp[seed];
    let noise = hp.iter().map(|v| v.abs().min(8.0)).sum::<f32>() / hp.len() as f32;
    if depth > -2.0f32.max(3.0 * noise) {
        return None; // rien de net (ou zone trop bruitée pour fiabiliser) : l'appelant garde la taille réglée
    }
    let limit = depth * 0.5;
    let mut seen = vec![false; ww * wh];
    let mut stack = vec![seed];
    seen[seed] = true;
    let (mut area, mut sx, mut sy) = (0usize, 0f64, 0f64);
    let max_area = (std::f32::consts::PI * (hint * 3.0).powi(2)) as usize;
    while let Some(i) = stack.pop() {
        let (px, py) = (i % ww, i / ww);
        area += 1;
        sx += px as f64;
        sy += py as f64;
        if area > max_area {
            return None; // région trop grande : ce n'est pas la tache visée (dégradé, ombre…)
        }
        let mut push = |j: usize| {
            if !seen[j] && hp[j] < limit {
                seen[j] = true;
                stack.push(j);
            }
        };
        if px > 0 {
            push(i - 1);
        }
        if px + 1 < ww {
            push(i + 1);
        }
        if py > 0 {
            push(i - ww);
        }
        if py + 1 < wh {
            push(i + ww);
        }
    }
    if area < 4 {
        return None;
    }
    let r_eq = (area as f32 / std::f32::consts::PI).sqrt();
    let (mx, my) = (sx / area as f64 + x0 as f64 + 0.5, sy / area as f64 + y0 as f64 + 0.5);
    let r = ((r_eq * 1.35 + 1.5).max(3.0) / long) as f64;
    Some((mx / w as f64, my / h as f64, r))
}

/// Comme `refine`, mais pour un OBJET (lune, lampadaire, câble, poubelle…) à retirer avec l'IA : sombre ou clair, et avec son halo.
/// Un remplissage IA qui ne couvre que le cœur d'un objet lumineux prolonge son halo et laisse une « tache » : le trou doit englober tout ce qui
/// dépasse du fond. Fond = médiane de la bordure de la fenêtre ; objet = pixels connexes qui s'écartent du fond d'au moins 12 % de l'écart maximal.
/// Renvoie (x, y, r) en fractions de la photo, ou `None` si rien de net n'est trouvé près du clic.
pub fn refine_object(rgb: &[u8], w: usize, h: usize, x: f64, y: f64, r_hint: f64) -> Option<(f64, f64, f64)> {
    if w < 16 || h < 16 || rgb.len() < w * h * 3 {
        return None;
    }
    let long = w.max(h) as f32;
    let hint = ((r_hint as f32) * long).max(3.0);
    let search = (hint * 2.5).max(long * 0.02).max(12.0);
    let half = ((hint * 10.0).max(long * 0.14)).ceil() as isize;
    let (cx, cy) = ((x as f32 * w as f32) as isize, (y as f32 * h as f32) as isize);
    let (x0, y0) = ((cx - half).max(0), (cy - half).max(0));
    let (x1, y1) = ((cx + half).min(w as isize - 1), (cy + half).min(h as isize - 1));
    let (ww, wh) = ((x1 - x0 + 1) as usize, (y1 - y0 + 1) as usize);
    if ww < 16 || wh < 16 {
        return None;
    }
    let mut luma = vec![0f32; ww * wh];
    for yy in 0..wh {
        for xx in 0..ww {
            let k = ((y0 as usize + yy) * w + x0 as usize + xx) * 3;
            luma[yy * ww + xx] = 0.2126 * rgb[k] as f32 + 0.7152 * rgb[k + 1] as f32 + 0.0722 * rgb[k + 2] as f32;
        }
    }
    let smooth = box_blur(&luma, ww, wh, 1);
    // fond : médiane des pixels de la bordure de la fenêtre (robuste à une lampe ou un arbre qui l'effleure)
    let mut border: Vec<f32> = Vec::new();
    for xx in 0..ww {
        border.push(smooth[xx]);
        border.push(smooth[(wh - 1) * ww + xx]);
    }
    for yy in 0..wh {
        border.push(smooth[yy * ww]);
        border.push(smooth[yy * ww + ww - 1]);
    }
    border.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let bg = border[border.len() / 2];
    let hp: Vec<f32> = smooth.iter().map(|v| v - bg).collect();
    let (lx, ly) = ((cx - x0) as f32, (cy - y0) as f32);
    let mut best: Option<(f32, usize)> = None;
    for yy in 0..wh {
        for xx in 0..ww {
            let d = ((xx as f32 - lx).powi(2) + (yy as f32 - ly).powi(2)).sqrt();
            if d > search {
                continue;
            }
            let v = hp[yy * ww + xx].abs() - 0.5 * d / search;
            if best.map_or(true, |b| v > b.0) {
                best = Some((v, yy * ww + xx));
            }
        }
    }
    let (_, seed) = best?;
    let depth = hp[seed];
    if depth.abs() < 6.0 {
        return None;
    }
    let sign = depth.signum();
    let limit = depth.abs() * 0.12;
    let mut seen = vec![false; ww * wh];
    let mut stack = vec![seed];
    seen[seed] = true;
    let (mut area, mut sx, mut sy) = (0usize, 0f64, 0f64);
    let max_area = (std::f32::consts::PI * (long * 0.10).powi(2)) as usize;
    while let Some(i) = stack.pop() {
        let (px, py) = (i % ww, i / ww);
        area += 1;
        sx += px as f64;
        sy += py as f64;
        if area > max_area {
            return None; // dépasse 10 % du grand côté de rayon : ce n'est pas un objet (ciel, dégradé)
        }
        let mut push = |j: usize| {
            if !seen[j] && hp[j] * sign > limit {
                seen[j] = true;
                stack.push(j);
            }
        };
        if px > 0 {
            push(i - 1);
        }
        if px + 1 < ww {
            push(i + 1);
        }
        if py > 0 {
            push(i - ww);
        }
        if py + 1 < wh {
            push(i + ww);
        }
    }
    if area < 4 {
        return None;
    }
    let r_eq = (area as f32 / std::f32::consts::PI).sqrt();
    let (mx, my) = (sx / area as f64 + x0 as f64 + 0.5, sy / area as f64 + y0 as f64 + 0.5);
    let r = ((r_eq * 1.15 + 2.0).max(3.0) / long) as f64;
    Some((mx / w as f64, my / h as f64, r))
}
