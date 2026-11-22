import 'dart:math' as math;

/// Profil automatique d'un objectif (distorsion, franges colorées, vignetage).
///
/// Même calcul que `sursaut/lens_profiles.py` du PC : les tables viennent de la base Lensfun
/// (CC BY-SA 3.0), réduites à des tables radiales. On retrouve l'objectif d'après le nom écrit
/// dans la photo, puis on interpole les tables à la focale et à l'ouverture de la prise de vue.
/// Le résultat est le dictionnaire `lens_profile` de la recette, appliqué par le moteur.

/// Nom comparable : sans marque Sony, sans code entre parenthèses, sans espaces ni barres
/// (« Sony FE 50 mm f/1.8 » = « FE 50mm F1.8 »).
String normalizeLensName(String name) {
  String n = name.toLowerCase().replaceAll(RegExp(r'\(.*?\)'), '');
  n = n.replaceFirst(RegExp(r'^\s*sony\s+'), '');
  return n.replaceAll(RegExp(r'[\s_/]+'), '');
}

/// Entrée de la base pour l'objectif nommé dans la photo, ou null.
Map<String, dynamic>? findLens(Map<String, dynamic> database, String? name) {
  if (name == null || name.trim().isEmpty) return null;
  final String wanted = normalizeLensName(name);
  final Object? lenses = database['lenses'];
  if (lenses is! List) return null;
  for (final Object? e in lenses) {
    if (e is! Map<String, dynamic>) continue;
    final String maker = '${e['maker']}';
    final String model = '${e['model']}';
    final String key = normalizeLensName(maker.toLowerCase() == 'sony' ? model : '$maker $model');
    if (key == wanted) return e; // la première entrée gagne, comme sur le PC
  }
  return null;
}

List<double> _toDoubles(Object? v) =>
    <double>[for (final Object? x in (v as List<dynamic>)) (x as num).toDouble()];

List<double> _lerpTables(List<double> a, List<double> b, double t) =>
    <double>[for (int i = 0; i < math.min(a.length, b.length); i++) a[i] * (1 - t) + b[i] * t];

/// (bas, haut, t) : les deux valeurs calibrées qui encadrent x (hors plage : la plus proche, t = 0).
(double, double, double) _bracket(List<double> values, double x) {
  final List<double> vs = List<double>.of(values)..sort();
  if (x <= vs.first) return (vs.first, vs.first, 0);
  if (x >= vs.last) return (vs.last, vs.last, 0);
  for (int i = 0; i < vs.length - 1; i++) {
    final double lo = vs[i], hi = vs[i + 1];
    if (lo <= x && x <= hi) return (lo, hi, hi > lo ? (x - lo) / (hi - lo) : 0);
  }
  return (vs.last, vs.last, 0);
}

List<double> _byFocal(Map<String, dynamic> tables, double focal) {
  final Map<double, List<double>> keyed = <double, List<double>>{
    for (final MapEntry<String, dynamic> e in tables.entries) double.parse(e.key): _toDoubles(e.value),
  };
  final (double lo, double hi, double t) = _bracket(keyed.keys.toList(), focal);
  return _lerpTables(keyed[lo]!, keyed[hi]!, t);
}

double _log2(double x) => math.log(x) / math.ln2;

/// Gain de vignetage à (focale, ouverture) : interpolation en log de l'ouverture, puis en focale.
List<double> _vignetting(List<dynamic> combos, double focal, double aperture) {
  final Map<double, List<Map<String, dynamic>>> perFocal = <double, List<Map<String, dynamic>>>{};
  for (final Object? c in combos) {
    final Map<String, dynamic> m = c as Map<String, dynamic>;
    perFocal.putIfAbsent((m['focal'] as num).toDouble(), () => <Map<String, dynamic>>[]).add(m);
  }
  List<double> atFocal(double f) {
    final Map<double, List<double>> cs = <double, List<double>>{
      for (final Map<String, dynamic> c in perFocal[f]!) (c['aperture'] as num).toDouble(): _toDoubles(c['gain']),
    };
    final (double lo, double hi, double t) =
        _bracket(<double>[for (final double a in cs.keys) _log2(a)], _log2(math.max(aperture, 0.1)));
    double nearest(double target) {
      double best = cs.keys.first;
      for (final double a in cs.keys) {
        if ((_log2(a) - target).abs() < (_log2(best) - target).abs()) best = a;
      }
      return best;
    }
    return _lerpTables(cs[nearest(lo)]!, cs[nearest(hi)]!, t);
  }

  final (double lo, double hi, double t) = _bracket(perFocal.keys.toList(), focal);
  return _lerpTables(atFocal(lo), atFocal(hi), t);
}

double _r5(double v) => double.parse(v.toStringAsFixed(5));

/// Tables du profil pour cette prise de vue. Sans focale connue, la plus courte focale calibrée
/// sert de repère (objectifs fixes : la seule).
Map<String, dynamic> buildLensProfile(Map<String, dynamic> entry, double? focal, double? aperture) {
  final double f = (focal != null && focal > 0)
      ? focal
      : ((entry['min_focal'] as num?)?.toDouble() ??
          ((entry['focals'] as List<dynamic>?)?.first as num?)?.toDouble() ??
          50);
  final Map<String, dynamic> out = <String, dynamic>{'name': entry['model']};
  if (entry.containsKey('geo')) {
    out['geo'] = _byFocal(entry['geo'] as Map<String, dynamic>, f).map(_r5).toList();
  }
  if (entry.containsKey('ca_r')) {
    out['ca_r'] = _byFocal(entry['ca_r'] as Map<String, dynamic>, f).map(_r5).toList();
    out['ca_b'] = _byFocal(entry['ca_b'] as Map<String, dynamic>, f).map(_r5).toList();
  }
  final Object? vig = entry['vig'];
  if (vig is List && vig.isNotEmpty && aperture != null && aperture > 0) {
    out['vig'] = _vignetting(vig, f, aperture).map(_r5).toList();
  }
  return out;
}

/// Profil pour la photo, ou null si l'objectif n'est pas dans la base.
Map<String, dynamic>? lensProfileFor(
    Map<String, dynamic> database, String? lensName, double? focal, double? aperture) {
  final Map<String, dynamic>? entry = findLens(database, lensName);
  return entry == null ? null : buildLensProfile(entry, focal, aperture);
}

/// Texte court : ce que le profil corrige.
String describeLensProfile(Map<String, dynamic> profile) {
  final List<String> parts = <String>[
    if ((profile['geo'] as List<dynamic>?)?.isNotEmpty ?? false) 'distorsion',
    if ((profile['ca_r'] as List<dynamic>?)?.isNotEmpty ?? false) 'franges colorées',
    if ((profile['vig'] as List<dynamic>?)?.isNotEmpty ?? false) 'vignetage',
  ];
  return '${profile['name'] ?? '?'} : ${parts.isEmpty ? 'aucune correction' : parts.join(', ')}';
}
