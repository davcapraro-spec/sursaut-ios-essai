/// Réglages exposés par l'écran Développement : clé (même nom que la recette du
/// PC), libellé, bornes du curseur.
class DevelopParam {
  const DevelopParam(this.key, this.label, this.min, this.max);
  final String key;
  final String label;
  final double min;
  final double max;
}

const List<DevelopParam> kDevelopParams = <DevelopParam>[
  DevelopParam('exposure', 'Exposition (IL)', -3, 3),
  DevelopParam('contrast', 'Contraste', -100, 100),
  DevelopParam('highlights', 'Hautes lumières', -100, 100),
  DevelopParam('shadows', 'Ombres', -100, 100),
  DevelopParam('whites', 'Blancs', -100, 100),
  DevelopParam('blacks', 'Noirs', -100, 100),
  DevelopParam('temperature', 'Température', -100, 100),
  DevelopParam('tint', 'Teinte', -100, 100),
  DevelopParam('vibrance', 'Vibrance', -100, 100),
  DevelopParam('saturation', 'Saturation', -100, 100),
  DevelopParam('texture', 'Texture', -100, 100),
  DevelopParam('clarity', 'Clarté', -100, 100),
  DevelopParam('dehaze', 'Correction du voile', -100, 100),
  DevelopParam('angle', 'Angle (°)', -15, 15),
];

/// Familles de couleurs du mélangeur HSL (mêmes noms que la recette du PC : `hsl_hue_red`...).
const List<String> kHslColorKeys = <String>[
  'red', 'orange', 'yellow', 'green', 'aqua', 'blue', 'purple', 'magenta',
];
const List<String> kHslColorLabels = <String>[
  'Rouge', 'Orange', 'Jaune', 'Vert', 'Turquoise', 'Bleu', 'Violet', 'Magenta',
];

/// Couleur d'affichage de chaque famille (RVB 0xRRGGBB).
const List<int> kHslColorRgb = <int>[
  0xE5534B, 0xF2A33A, 0xE8D34A, 0x4CB36B, 0x3FB8B0, 0x4A8FE8, 0x8E6BE0, 0xD45AB0,
];

/// Les trois réglages du mélangeur : teinte, saturation, luminance.
const List<String> kHslKinds = <String>['hue', 'sat', 'lum'];
const List<String> kHslKindLabels = <String>['Teinte', 'Saturation', 'Luminance'];

String hslKey(String kind, String color) => 'hsl_${kind}_$color';

/// Les 24 réglages du mélangeur de couleurs.
final List<DevelopParam> kHslParams = <DevelopParam>[
  for (final String kind in kHslKinds)
    for (int i = 0; i < kHslColorKeys.length; i++)
      DevelopParam(hslKey(kind, kHslColorKeys[i]), kHslColorLabels[i], -100, 100),
];

/// Netteté, réduction du bruit, grain, vignetage (mêmes clés et bornes que le PC).
const List<DevelopParam> kDetailParams = <DevelopParam>[
  DevelopParam('sharpen_amount', 'Quantité', 0, 100),
  DevelopParam('sharpen_radius', 'Rayon', 0.5, 3.0),
  DevelopParam('sharpen_detail', 'Détail', 0, 100),
  DevelopParam('sharpen_masking', 'Masque (épargne le grain)', 0, 100),
  DevelopParam('denoise_luma', 'Luminosité', 0, 100),
  DevelopParam('denoise_luma_detail', 'Détail (luminosité)', 0, 100),
  DevelopParam('denoise_luma_contrast', 'Contraste (luminosité)', 0, 100),
  DevelopParam('denoise_color', 'Couleur', 0, 100),
  DevelopParam('denoise_color_detail', 'Détail (couleur)', 0, 100),
  DevelopParam('denoise_color_smooth', 'Lissage (couleur)', 0, 100),
  DevelopParam('grain_amount', 'Quantité', 0, 100),
  DevelopParam('grain_size', 'Taille', 0, 100),
  DevelopParam('grain_roughness', 'Rugosité', 0, 100),
  DevelopParam('vig_amount', 'Quantité', -100, 100),
  DevelopParam('vig_mid', 'Point médian', 0, 100),
  DevelopParam('vig_round', 'Arrondi', -100, 100),
  DevelopParam('vig_feather', 'Progressivité', 0, 100),
];

/// Valeurs par défaut non nulles : le cadre de recadrage couvre toute l'image.
const Map<String, double> kCropDefaults = <String, double>{
  'crop_left': 0,
  'crop_top': 0,
  'crop_right': 1,
  'crop_bottom': 1,
};

/// Corrections d'objectif manuelles (mêmes clés et bornes que le PC).
const List<DevelopParam> kLensParams = <DevelopParam>[
  DevelopParam('lens_distortion', 'Distorsion', -100, 100),
  DevelopParam('lens_scale', 'Échelle', 50, 150),
  DevelopParam('lens_ca_red', 'Frange rouge / cyan', -100, 100),
  DevelopParam('lens_ca_blue', 'Frange bleu / jaune', -100, 100),
  DevelopParam('lens_vignette', 'Vignetage', -100, 100),
  DevelopParam('lens_vignette_mid', 'Point médian du vignetage', 0, 100),
];

/// Toutes les valeurs par défaut qui ne sont pas zéro : le cadre plein et quelques réglages du détail
/// (mêmes valeurs que le PC : une clé absente de la recette = cette valeur).
const Map<String, double> kParamDefaults = <String, double>{
  ...kCropDefaults,
  'sharpen_radius': 1,
  'sharpen_detail': 25,
  'denoise_luma_detail': 50,
  'denoise_color_detail': 50,
  'denoise_color_smooth': 50,
  'grain_size': 25,
  'grain_roughness': 50,
  'vig_mid': 50,
  'vig_feather': 50,
  'lens_scale': 100,
  'lens_vignette_mid': 50,
};

/// Valeur d'un réglage « à zéro » (absent de la recette = valeur par défaut).
double defaultOf(String key) => kParamDefaults[key] ?? 0;

/// Tous les réglages à leur valeur par défaut.
Map<String, double> defaultValues() => <String, double>{
      for (final DevelopParam p in kDevelopParams) p.key: 0,
      for (final DevelopParam p in kHslParams) p.key: 0,
      for (final DevelopParam p in kDetailParams) p.key: defaultOf(p.key),
      for (final DevelopParam p in kLensParams) p.key: defaultOf(p.key),
      ...kCropDefaults,
    };
