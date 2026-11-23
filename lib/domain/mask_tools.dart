import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'masks.dart';

/// Masques manuels de l'onglet « Masques » : dégradé linéaire et dégradé radial (même format que le PC,
/// voir `sursaut/masks_ui.py` et `MaskComp` dans le moteur). Positions en fractions de la photo originale,
/// rayons en fraction de son grand côté. Partie pure : aucune interface ici.

/// Types de masques proposés (le libellé sert de début de nom : « Dégradé linéaire 1 »).
const String kLinear = 'linear';
const String kRadial = 'radial';
const String kBrush = 'brush';
const String kLuminance = 'luminance';
const String kColor = 'color';

const Map<String, String> kMaskKindNames = <String, String>{
  kLinear: 'Dégradé linéaire',
  kRadial: 'Dégradé radial',
  kBrush: 'Pinceau',
  kLuminance: 'Plage de luminosité',
  kColor: 'Plage de couleur',
};

/// Comment une composante se combine avec celles qui la précèdent (noms du PC).
const Map<String, String> kOpNames = <String, String>{'add': 'Ajouter', 'subtract': 'Soustraire', 'intersect': 'Limiter à'};
const Map<String, String> kOpSigns = <String, String>{'add': '＋', 'subtract': '－', 'intersect': '∩'};

/// Taille du pinceau (fraction du grand côté) : bornes et valeur de départ, comme sur le PC.
const double kBrushMinR = 0.001;
const double kBrushMaxR = 0.1;
const double kBrushDefaultR = 0.03;

/// Plages : leur zone dépend des couleurs de la photo, pas d'une forme que l'on déplace.
bool isRangeKind(String kind) => kind == kLuminance || kind == kColor;

/// Composante neutre d'un type donné (mêmes valeurs que `default_component` du PC).
Map<String, dynamic> defaultComp(String kind, {String op = 'add'}) {
  final Map<String, dynamic> base = <String, dynamic>{'kind': kind, 'op': op, 'invert': false};
  if (kind == kRadial) {
    return <String, dynamic>{...base, 'x0': 0.5, 'y0': 0.5, 'rx': 0.25, 'ry': 0.18, 'angle': 0.0, 'feather': 0.5};
  }
  if (kind == kBrush) {
    return <String, dynamic>{...base, 'stroke': <List<double>>[], 'r': kBrushDefaultR, 'feather': 0.5, 'grow': 0.0};
  }
  if (kind == kLuminance) return <String, dynamic>{...base, 'lo': 0.0, 'hi': 0.4, 'smooth': 0.3};
  if (kind == kColor) return <String, dynamic>{...base, 'hue': 0.0, 'hue_range': 30.0, 'sat_min': 0.1};
  return <String, dynamic>{...base, 'x0': 0.5, 'y0': 0.3, 'x1': 0.5, 'y1': 0.7};
}

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

/// Toutes les composantes du masque, dans l'ordre.
List<Map<String, dynamic>> compsOf(MaskMap m) {
  final Object? comps = m['comps'];
  return <Map<String, dynamic>>[
    if (comps is List<dynamic>)
      for (final Object? e in comps)
        if (e is Map<String, dynamic>) e,
  ];
}

/// La composante d'indice [i], ou null.
Map<String, dynamic>? compAt(MaskMap m, int i) {
  final List<Map<String, dynamic>> l = compsOf(m);
  return i >= 0 && i < l.length ? l[i] : null;
}

/// Copie du masque avec des valeurs changées dans la composante d'indice [i].
MaskMap withCompAt(MaskMap m, int i, Map<String, dynamic> changes) {
  final List<Map<String, dynamic>> l = compsOf(m);
  if (i < 0 || i >= l.length) return m;
  l[i] = <String, dynamic>{...l[i], ...changes};
  return <String, dynamic>{...m, 'comps': l};
}

/// Copie du masque avec une composante de plus à la fin.
MaskMap addComp(MaskMap m, Map<String, dynamic> comp) =>
    <String, dynamic>{...m, 'comps': <Map<String, dynamic>>[...compsOf(m), comp]};

/// Copie du masque sans la composante [i] (un masque garde toujours au moins une composante).
MaskMap removeCompAt(MaskMap m, int i) {
  final List<Map<String, dynamic>> l = compsOf(m);
  if (l.length <= 1 || i < 0 || i >= l.length) return m;
  l.removeAt(i);
  return <String, dynamic>{...m, 'comps': l};
}

/// Masque pinceau vide (le tracé vient ensuite, au doigt).
MaskMap brushMask(String name) => <String, dynamic>{
      'name': name,
      'enabled': true,
      'invert': false,
      'amount': 100.0,
      'comps': <Map<String, dynamic>>[defaultComp(kBrush)],
      'adj': _blankAdj(),
    };

/// Points d'un trait du doigt complétés pour qu'il reste continu : un point tous les 35 % du rayon (comme le PC).
/// [aspect] = largeur / hauteur de la photo, [r] = rayon en fraction du grand côté.
List<List<double>> densifyStroke(List<List<double>> pts, double aspect, double r) {
  if (pts.isEmpty) return <List<double>>[];
  final double long = math.max(aspect, 1.0); // grand côté, en unités de hauteur
  final double step = math.max(r * long * 0.35, 0.0005);
  final List<List<double>> out = <List<double>>[<double>[pts.first[0], pts.first[1]]];
  for (int i = 1; i < pts.length; i++) {
    final List<double> a = out.last, b = pts[i];
    final double dx = (b[0] - a[0]) * aspect, dy = b[1] - a[1];
    final double dist = math.sqrt(dx * dx + dy * dy);
    if (dist < step) continue;
    final int n = (dist / step).floor();
    for (int k = 1; k <= n; k++) {
      out.add(<double>[a[0] + (b[0] - a[0]) * k * step / dist, a[1] + (b[1] - a[1]) * k * step / dist]);
    }
  }
  return out;
}

/// Copie du masque dont la composante pinceau [i] a reçu les points [pts] en plus.
MaskMap addStrokePoints(MaskMap m, int i, List<List<double>> pts) {
  final Map<String, dynamic>? c = compAt(m, i);
  if (c == null || '${c['kind']}' != kBrush) return m;
  final Object? old = c['stroke'];
  final List<List<double>> all = <List<double>>[
    if (old is List<dynamic>)
      for (final Object? p in old)
        if (p is List<dynamic> && p.length >= 2) <double>[(p[0] as num).toDouble(), (p[1] as num).toDouble()],
    for (final List<double> p in pts) <double>[p[0], p[1]],
  ];
  return withCompAt(m, i, <String, dynamic>{'stroke': all});
}

/// Masque d'une plage (luminosité ou couleur) sur toute la photo.
MaskMap rangeMask(String name, String kind) => <String, dynamic>{
      'name': name,
      'enabled': true,
      'invert': false,
      'amount': 100.0,
      'comps': <Map<String, dynamic>>[defaultComp(kind)],
      'adj': _blankAdj(),
    };

/// Teinte (degrés, 0..360) et saturation (0..1) de la couleur moyenne d'un petit carré de [rgba] autour du point
/// (fx, fy) (fractions de la photo) : la pipette. Même calcul que le moteur (teinte et saturation HSV).
(double, double) hueSatAt(Uint8List rgba, int w, int h, double fx, double fy, {int half = 3}) {
  if (w <= 0 || h <= 0 || rgba.length < w * h * 4) return (0, 0);
  final int cx = (fx * (w - 1)).round().clamp(0, w - 1).toInt(), cy = (fy * (h - 1)).round().clamp(0, h - 1).toInt();
  double r = 0, g = 0, b = 0;
  int n = 0;
  for (int y = math.max(0, cy - half); y <= math.min(h - 1, cy + half); y++) {
    for (int x = math.max(0, cx - half); x <= math.min(w - 1, cx + half); x++) {
      final int i = (y * w + x) * 4;
      r += rgba[i];
      g += rgba[i + 1];
      b += rgba[i + 2];
      n++;
    }
  }
  if (n == 0) return (0, 0);
  r /= n * 255;
  g /= n * 255;
  b /= n * 255;
  final double mx = math.max(r, math.max(g, b)), mn = math.min(r, math.min(g, b));
  final double chroma = mx - mn;
  if (chroma < 1e-6) return (0, 0);
  final double hue = mx == r
      ? 60 * (((g - b) / chroma) % 6)
      : mx == g
          ? 60 * ((b - r) / chroma + 2)
          : 60 * ((r - g) / chroma + 4);
  return (((hue % 360) + 360) % 360, chroma / mx);
}

/// Le même masque, dessiné pour être vu : la zone ressort en rouge clair (et les réglages du masque ne s'appliquent plus).
/// Sert à « Voir la zone du masque » ; jamais enregistré.
MaskMap zoneView(MaskMap m) => <String, dynamic>{
      ...m,
      'enabled': true,
      'adj': <String, dynamic>{for (final String k in kLocalKeys) k: 0.0, 'exposure': 0.6, 'temperature': 100.0, 'tint': 100.0},
    };

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
