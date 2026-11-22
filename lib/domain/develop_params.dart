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
  DevelopParam('sharpen_amount', 'Netteté (gain)', 0, 100),
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

/// Valeurs par défaut non nulles : le cadre de recadrage couvre toute l'image.
const Map<String, double> kCropDefaults = <String, double>{
  'crop_left': 0,
  'crop_top': 0,
  'crop_right': 1,
  'crop_bottom': 1,
};

/// Valeur d'un réglage « à zéro » (absent de la recette = valeur par défaut).
double defaultOf(String key) => kCropDefaults[key] ?? 0;

/// Tous les réglages à leur valeur par défaut.
Map<String, double> defaultValues() => <String, double>{
      for (final DevelopParam p in kDevelopParams) p.key: 0,
      for (final DevelopParam p in kHslParams) p.key: 0,
      ...kCropDefaults,
    };
