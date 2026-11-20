// SPDX-License-Identifier: GPL-3.0-or-later
/// Image RVB entrelacée en float32 (hauteur × largeur × 3).
#[derive(Clone, Debug)]
pub struct Image {
    pub w: usize,
    pub h: usize,
    pub data: Vec<f32>,
}

impl Image {
    pub fn new(w: usize, h: usize, data: Vec<f32>) -> Self {
        assert_eq!(data.len(), w * h * 3);
        Image { w, h, data }
    }
}
