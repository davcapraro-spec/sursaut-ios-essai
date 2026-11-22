import 'dart:convert';
import 'dart:math' as math;

/// Retouches de taches (onglet « Supprimer ») : mêmes champs que le PC (`new_spot`).
/// Positions en fractions de la photo originale ; rayon en fraction de son grand côté.
typedef Spot = Map<String, dynamic>;

/// Une retouche. Avec [stroke] (trait de pinceau), la retouche suit le trait ; sinon c'est le cercle (x, y).
Spot newSpot({
  required double x,
  required double y,
  required double r,
  required double sx,
  required double sy,
  String mode = 'heal',
  double feather = 0.5,
  double opacity = 1.0,
  List<List<double>>? stroke,
}) {
  final Spot s = <String, dynamic>{
    'x': x,
    'y': y,
    'r': r,
    'sx': sx,
    'sy': sy,
    'mode': (mode == 'heal' || mode == 'clone') ? mode : 'heal',
    'feather': feather,
    'opacity': opacity,
  };
  if (stroke != null && stroke.isNotEmpty) {
    s['stroke'] = <List<double>>[for (final List<double> p in stroke) <double>[p[0], p[1]]];
    s['x'] = stroke.first[0];
    s['y'] = stroke.first[1];
  }
  return s;
}

/// Copie profonde (l'historique garde des copies, jamais des références).
List<Spot> copySpots(List<Spot> spots) =>
    (jsonDecode(jsonEncode(spots)) as List<dynamic>).map((Object? e) => Map<String, dynamic>.of(e as Map<String, dynamic>)).toList();

bool spotsEqual(List<Spot> a, List<Spot> b) => a.length == b.length && jsonEncode(a) == jsonEncode(b);

/// Sépare les retouches du reste des clés inconnues d'un fichier de réglages.
(List<Spot>, Map<String, dynamic>) splitSpots(Map<String, dynamic> extra) {
  final Map<String, dynamic> rest = Map<String, dynamic>.of(extra);
  final Object? raw = rest.remove('spots');
  final List<Spot> out = <Spot>[
    if (raw is List<dynamic>)
      for (final Object? e in raw)
        if (e is Map<String, dynamic>) Map<String, dynamic>.of(e),
  ];
  return (out, rest);
}

/// Sensibilité 0..100 → score minimal de la poussière (85 → 3,9 par défaut ; 100 → 3).
double dustThreshold(int sensitivity) => 9.0 - 0.06 * sensitivity;

/// Candidates assez nettes et pas déjà retouchées (même règle que le PC).
List<Map<String, dynamic>> keptDust(
    List<Map<String, dynamic>> dust, List<Spot> spots, int sensitivity, int w, int h) {
  final double thr = dustThreshold(sensitivity);
  final double longSide = math.max(w, h).toDouble();
  return <Map<String, dynamic>>[
    for (final Map<String, dynamic> d in dust)
      if ((d['score'] as num) >= thr &&
          !spots.any((Spot s) {
            final double dx = ((d['x'] as num) - (s['x'] as num)).toDouble() * w;
            final double dy = ((d['y'] as num) - (s['y'] as num)).toDouble() * h;
            final double rr = math.max((d['r'] as num).toDouble(), (s['r'] as num).toDouble()) * longSide;
            return dx * dx + dy * dy < rr * rr;
          }))
        d,
  ];
}
