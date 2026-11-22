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
      ...kCropDefaults,
    };
