import 'dart:convert';
import 'dart:math' as math;

/// Masques locaux de la recette (clé `masks` du fichier `.sursaut.json`, même format que le PC).
/// Positions en fractions de la photo originale. Ici : la partie commune (copie, comparaison, tri)
/// et les corrections d'yeux rouges, qui sont de simples masques (comme `eyeshine.eye_mask` du PC).
typedef MaskMap = Map<String, dynamic>;

/// Nom commun à tous les masques d'yeux (le PC reconnaît ses masques d'yeux à ce préfixe).
const String kEyeMaskPrefix = 'Yeux · ';

/// Couleur minimale (Lab) d'un reflet pour être corrigé d'office : mèches, reflets de cheveux et néons restent en dessous.
const double kEyeAutoMinChroma = 45;

/// Un œil trouvé à moins de 1,5 rayon d'une correction existante est déjà corrigé.
const double kEyeNearby = 1.5;

/// Teinte (degrés) de chaque couleur de reflet, comme le sélecteur de couleur des masques.
const Map<String, double> kEyeHue = <String, double>{'rouge': 0, 'jaune': 50, 'vert': 120, 'bleu': 215};

/// Copie profonde (l'historique garde des copies, jamais des références).
List<MaskMap> copyMasks(List<MaskMap> masks) =>
    (jsonDecode(jsonEncode(masks)) as List<dynamic>).map((Object? e) => Map<String, dynamic>.of(e as Map<String, dynamic>)).toList();

bool masksEqual(List<MaskMap> a, List<MaskMap> b) => a.length == b.length && jsonEncode(a) == jsonEncode(b);

/// Sépare les masques du reste des clés inconnues d'un fichier de réglages.
(List<MaskMap>, Map<String, dynamic>) splitMasks(Map<String, dynamic> extra) {
  final Map<String, dynamic> rest = Map<String, dynamic>.of(extra);
  final Object? raw = rest.remove('masks');
  final List<MaskMap> out = <MaskMap>[
    if (raw is List<dynamic>)
      for (final Object? e in raw)
        if (e is Map<String, dynamic>) Map<String, dynamic>.of(e),
  ];
  return (out, rest);
}

bool isEyeMask(MaskMap m) => '${m['name'] ?? ''}'.startsWith(kEyeMaskPrefix);

/// La correction d'un reflet de pupille [eye] (`x`, `y`, `r`, `hue`) : un disque sur la pupille, limité à la couleur du reflet
/// (le reflet blanc et la peau, peu saturés, ne sont pas touchés), qui perd sa couleur et une partie de sa clarté.
/// [strength] 0..1 règle l'opacité du masque.
MaskMap eyeMask(Map<String, dynamic> eye, double strength, String name) {
  final double reach = math.max((eye['r'] as num).toDouble(), 0.002) * 1.6;
  return <String, dynamic>{
    'name': name,
    'enabled': true,
    'invert': false,
    'amount': 100.0 * strength.clamp(0.0, 1.0),
    'comps': <Map<String, dynamic>>[
      <String, dynamic>{
        'kind': 'radial',
        'op': 'add',
        'x0': (eye['x'] as num).toDouble(),
        'y0': (eye['y'] as num).toDouble(),
        'rx': reach,
        'ry': reach,
        'angle': 0.0,
        'feather': 0.6,
      },
      <String, dynamic>{
        'kind': 'color',
        'op': 'intersect',
        'hue': kEyeHue['${eye['hue']}'] ?? 0.0,
        'hue_range': 80.0,
        'sat_min': 0.3,
      },
    ],
    'adj': <String, dynamic>{'saturation': -100.0, 'exposure': -1.6},
  };
}

/// Les yeux de [found] qui méritent une correction : assez colorés, et pas déjà corrigés par un masque d'œil de [masks].
/// Renvoie aussi le nombre de reflets écartés parce que trop pâles.
(List<Map<String, dynamic>>, int) freshEyes(List<Map<String, dynamic>> found, List<MaskMap> masks) {
  final List<Map<String, dynamic>> strong = <Map<String, dynamic>>[
    for (final Map<String, dynamic> e in found)
      if ((e['chroma'] as num).toDouble() >= kEyeAutoMinChroma) e,
  ];
  final List<(double, double, double)> have = <(double, double, double)>[];
  for (final MaskMap m in masks) {
    if (!isEyeMask(m)) continue;
    final Object? comps = m['comps'];
    if (comps is! List<dynamic>) continue;
    for (final Object? c in comps) {
      if (c is Map<String, dynamic> && c['kind'] == 'radial') {
        have.add(((c['x0'] as num).toDouble(), (c['y0'] as num).toDouble(), math.max((c['rx'] as num).toDouble(), 1e-4) / 1.6));
      }
    }
  }
  final List<Map<String, dynamic>> fresh = <Map<String, dynamic>>[];
  for (final Map<String, dynamic> e in strong) {
    final double ex = (e['x'] as num).toDouble(), ey = (e['y'] as num).toDouble(), er = (e['r'] as num).toDouble();
    bool done = false;
    for (final (double, double, double) h in have) {
      final double near = kEyeNearby * math.max(er, h.$3);
      if ((ex - h.$1).abs() < near && (ey - h.$2).abs() < near) {
        done = true;
        break;
      }
    }
    if (!done) fresh.add(e);
  }
  return (fresh, found.length - strong.length);
}
