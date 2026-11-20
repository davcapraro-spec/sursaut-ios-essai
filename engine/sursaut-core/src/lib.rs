// SPDX-License-Identifier: GPL-3.0-or-later
//! sursaut-core — le moteur de développement de Sursaut by David.
//!
//! Même chaîne d'étages que la version Python (`sursaut/pipeline.py`) :
//! lens → spots → geometry → wb_exposure → tone_regions → contrast_curve → denoise → detail → color → local (masques).
//! La recette JSON est identique : un fichier écrit par l'une est lu par l'autre.
pub mod adjust;
pub mod blur;
pub mod color;
pub mod curve;
pub mod dust;
pub mod image;
pub mod layers;
pub mod masks;
pub mod paint;
pub mod pipeline;
pub mod recipe;
pub mod selection;
pub mod spots;
pub mod stages;

pub use image::Image;
pub use pipeline::Pipeline;
pub use recipe::Recipe;
