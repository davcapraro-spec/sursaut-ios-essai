import 'dart:convert';
import 'dart:math' as math;

import 'masks.dart';

/// Masques manuels de l'onglet « Masques » : dégradé linéaire et dégradé radial (même format que le PC,
/// voir `sursaut/masks_ui.py` et `MaskComp` dans le moteur). Positions en fractions de la photo originale,
/// rayons en fraction de son grand côté. Partie pure : aucune interface ici.

/// Types de masques proposés (le libellé sert de début de nom : « Dégradé linéaire 1 »).
const String kLinear = 'linear';
const String kRadial = 'radial';

const Map<String, String> kMaskKindNames = <String, String>{
  kLinear: 'Dégradé linéaire',
  kRadial: 'Dégradé radial',
};

/// Un réglage local (clé du moteur, libellé, bornes, pas d'affichage) : mêmes bornes que `LOCAL_LABELS` du PC.
class LocalParam {
  const LocalParam(this.key, this.label, this.min, this.max, {this.decimals = 0});
  final String key;
  final String label;
  final double min;
  final double max;
  final int decimals;
}

/// Réglages locaux regroupés comme dans l'écran (titre du groupe, réglages).
const List<(String, List<LocalParam>)> kLocalGroups = <(String, List<LocalParam>)>[
  (
    'LUMIÈRE',
    <LocalParam>[
      LocalParam('exposure', 'Exposition (IL)', -5, 5, decimals: 2),
      LocalParam('contrast', 'Contraste', -100, 100),
      LocalParam('highlights', 'Hautes lumières', -100, 100),
      LocalParam('shadows', 'Ombres', -100, 100),
    ],
  ),
  (
    'COULEUR',
    <LocalParam>[
      LocalParam('temperature', 'Température', -100, 100),
      LocalParam('tint', 'Teinte', -100, 100),
      LocalParam('vibrance', 'Vibrance', -100, 100),
      LocalParam('saturation', 'Saturation', -100, 100),
    ],
  ),
  (
    'DÉTAIL',
    <LocalParam>[
      LocalParam('clarity', 'Clarté', -100, 100),
      LocalParam('texture', 'Texture', -100, 100),
      LocalParam('sharpen', 'Netteté', 0, 100),
      LocalParam('denoise', 'Réduction du bruit', 0, 100),
    ],
  ),
];

/// Les douze réglages locaux, à zéro.
List<String> get kLocalKeys => <String>[
      for (final (String, List<LocalParam>) g in kLocalGroups)
        for (final LocalParam p in g.$2) p.key,
    ];

Map<String, dynamic> _blankAdj() => <String, dynamic>{for (final String k in kLocalKeys) k: 0.0};

/// Longueur minimale (fraction de la photo) d'un dégradé linéaire tracé au doigt ; en dessous, on prend le défaut du PC.
const double kLinearMinLength = 0.03;

/// Rayon minimal (fraction du grand côté) d'un dégradé radial tracé au doigt.
const double kRadialMinRadius = 0.01;

/// Dégradé linéaire : plein effet en (x0, y0), nul en (x1, y1).
MaskMap linearMask(String name, {double x0 = 0.5, double y0 = 0.3, double x1 = 0.5, double y1 = 0.7}) => <String, dynamic>{
      'name': name,
      'enabled': true,
      'invert': false,
      'amount': 100.0,
      'comps': <Map<String, dynamic>>[
        <String, dynamic>{'kind': kLinear, 'op': 'add', 'invert': false, 'x0': x0, 'y0': y0, 'x1': x1, 'y1': y1},
      ],
      'adj': _blankAdj(),
    };

/// Dégradé radial : centre (x0, y0), rayons rx et ry (fractions du grand côté), angle en degrés, contour progressif 0..1.
MaskMap radialMask(
  String name, {
  double x0 = 0.5,
  double y0 = 0.5,
  double rx = 0.25,
  double ry = 0.18,
  double angle = 0,
  double feather = 0.5,
}) =>
    <String, dynamic>{
      'name': name,
      'enabled': true,
      'invert': false,
      'amount': 100.0,
      'comps': <Map<String, dynamic>>[
        <String, dynamic>{
          'kind': kRadial,
          'op': 'add',
          'invert': false,
          'x0': x0,
          'y0': y0,
          'rx': rx,
          'ry': ry,
          'angle': angle,
          'feather': feather,
        },
      ],
      'adj': _blankAdj(),
    };

/// Nom libre suivant : « Dégradé linéaire 1 », puis 2…, sans reprendre un nom déjà pris.
String nextMaskName(List<MaskMap> masks, String base) {
  final Set<String> used = <String>{for (final MaskMap m in masks) '${m['name'] ?? ''}'};
  int n = masks.where((MaskMap m) => '${m['name'] ?? ''}'.startsWith(base)).length + 1;
  while (used.contains('$base $n')) {
    n++;
  }
  return '$base $n';
}

/// Première composante du masque (celle que l'on déplace à l'écran), ou null.
Map<String, dynamic>? mainComp(MaskMap m) {
  final Object? comps = m['comps'];
  if (comps is List<dynamic> && comps.isNotEmpty && comps.first is Map<String, dynamic>) {
    return comps.first as Map<String, dynamic>;
  }
  return null;
}

/// Type de la première composante (`linear`, `radial`, …) ou ''.
String maskKind(MaskMap m) => '${mainComp(m)?['kind'] ?? ''}';

/// Un masque que l'onglet « Masques » sait afficher et régler : pas un masque d'yeux (réglé dans « Supprimer »).
bool isManualMask(MaskMap m) => !isEyeMask(m);

double _num(Object? v, double fallback) => v is num ? v.toDouble() : fallback;

/// Valeur d'un réglage local (0 s'il est absent).
double adjOf(MaskMap m, String key) {
  final Object? a = m['adj'];
  return a is Map<String, dynamic> ? _num(a[key], 0) : 0;
}

/// Copie du masque avec un réglage local changé.
MaskMap withAdj(MaskMap m, String key, double value) {
  final Object? a = m['adj'];
  final Map<String, dynamic> adj = a is Map<String, dynamic> ? Map<String, dynamic>.of(a) : _blankAdj();
  adj[key] = value;
  return <String, dynamic>{...m, 'adj': adj};
}

/// Copie du masque avec une valeur de sa première composante changée (position, rayon, angle, contour…).
MaskMap withComp(MaskMap m, Map<String, dynamic> changes) {
  final Object? comps = m['comps'];
  final List<dynamic> list = comps is List<dynamic> ? List<dynamic>.of(comps) : <dynamic>[];
  if (list.isEmpty || list.first is! Map<String, dynamic>) return m;
  list[0] = <String, dynamic>{...(list.first as Map<String, dynamic>), ...changes};
  return <String, dynamic>{...m, 'comps': list};
}

/// Le masque change-t-il quelque chose à la photo ? (tous les réglages à zéro = non)
bool maskIsNeutral(MaskMap m) => kLocalKeys.every((String k) => adjOf(m, k) == 0);

/// Copie profonde du masque, nommée « … (copie) » et légèrement décalée pour se voir à côté de l'original.
MaskMap duplicateMask(MaskMap m) {
  final MaskMap c = (jsonDecode(jsonEncode(m)) as Map<String, dynamic>);
  c['name'] = '${m['name'] ?? ''} (copie)';
  final Map<String, dynamic>? comp = mainComp(c);
  if (comp != null) {
    for (final String k in <String>['x0', 'x1']) {
      if (comp[k] is num) comp[k] = ((comp[k] as num).toDouble() + 0.04).clamp(0.0, 1.0).toDouble();
    }
    for (final String k in <String>['y0', 'y1']) {
      if (comp[k] is num) comp[k] = ((comp[k] as num).toDouble() + 0.04).clamp(0.0, 1.0).toDouble();
    }
  }
  return c;
}

/// Dégradé linéaire tracé du doigt posé en (ax, ay) au doigt levé en (bx, by) (fractions de la photo).
/// Trop court : le défaut du PC (vertical, du haut vers le bas) centré sur le point de départ.
MaskMap linearFromDrag(String name, double ax, double ay, double bx, double by, double aspect) {
  final double dx = (bx - ax) * aspect, dy = by - ay;
  if (math.sqrt(dx * dx + dy * dy) < kLinearMinLength) {
    return linearMask(name, x0: ax, y0: (ay - 0.2).clamp(0.0, 1.0).toDouble(), x1: ax, y1: (ay + 0.2).clamp(0.0, 1.0).toDouble());
  }
  return linearMask(name, x0: ax, y0: ay, x1: bx, y1: by);
}

/// Dégradé radial tracé du centre (ax, ay) jusqu'à un point du bord (bx, by) : un cercle dont le rayon est la distance
/// (en fraction du grand côté de la photo, `aspect` = largeur / hauteur). Trop court : la taille par défaut du PC.
MaskMap radialFromDrag(String name, double ax, double ay, double bx, double by, double aspect) {
  final double long = math.max(aspect, 1.0);
  final double dx = (bx - ax) * aspect, dy = by - ay;
  final double r = math.sqrt(dx * dx + dy * dy) / long;
  if (r < kRadialMinRadius) return radialMask(name, x0: ax, y0: ay);
  return radialMask(name, x0: ax, y0: ay, rx: r, ry: r);
}
