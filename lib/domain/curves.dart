import 'dart:math' as math;

/// Courbes de tonalité (RVB, rouge, vert, bleu) : points (x, y) entre 0 et 1, y vers le haut.
/// Même format et même calcul que le moteur du PC (`core/src/curve.rs`) : spline d'Hermite
/// monotone (Fritsch–Carlson). Le dessin de l'écran utilise ce calcul ; le rendu de la photo
/// est fait par le moteur Rust.
typedef CurvePoints = List<List<double>>;

/// Canal -> clé de la recette.
const Map<String, String> kCurveKeys = <String, String>{
  'rvb': 'curve',
  'red': 'curve_red',
  'green': 'curve_green',
  'blue': 'curve_blue',
};

const double kCurveMinGap = 1e-4;

CurvePoints identityCurve() => <List<double>>[<double>[0, 0], <double>[1, 1]];

bool isIdentityCurve(CurvePoints pts) =>
    pts.every((List<double> p) => (p[0] - p[1]).abs() < 1e-6);

/// Trie, borne à [0, 1], supprime les doublons de x et garantit des points en x = 0 et x = 1.
CurvePoints normalizeCurve(CurvePoints points) {
  final CurvePoints pts = <List<double>>[
    for (final List<double> p in points)
      <double>[p[0].clamp(0.0, 1.0), p[1].clamp(0.0, 1.0)],
  ]..sort((List<double> a, List<double> b) => a[0].compareTo(b[0]));
  final CurvePoints out = <List<double>>[];
  for (final List<double> p in pts) {
    if (out.isNotEmpty && p[0] - out.last[0] < kCurveMinGap) continue;
    out.add(p);
  }
  if (out.length < 2) return identityCurve();
  if (out.first[0] > 0) out.insert(0, <double>[0, out.first[1]]);
  if (out.last[0] < 1) out.add(<double>[1, out.last[1]]);
  return out;
}

/// Valeurs de la courbe en [size] points régulièrement répartis de 0 à 1.
List<double> curveSamples(CurvePoints points, {int size = 256}) {
  final CurvePoints pts = normalizeCurve(points);
  final int n = pts.length;
  final List<double> x = <double>[for (final List<double> p in pts) p[0]];
  final List<double> y = <double>[for (final List<double> p in pts) p[1]];
  final List<double> h = <double>[for (int i = 0; i < n - 1; i++) x[i + 1] - x[i]];
  final List<double> delta = <double>[for (int i = 0; i < n - 1; i++) (y[i + 1] - y[i]) / h[i]];
  final List<double> m = List<double>.filled(n, 0);
  m[0] = delta[0];
  m[n - 1] = delta[n - 2];
  for (int i = 1; i < n - 1; i++) {
    m[i] = delta[i - 1] * delta[i] > 0 ? (delta[i - 1] + delta[i]) / 2 : 0;
  }
  for (int k = 0; k < n - 1; k++) {
    if (delta[k] == 0) {
      m[k] = 0;
      m[k + 1] = 0;
      continue;
    }
    final double a = m[k] / delta[k];
    final double b = m[k + 1] / delta[k];
    final double s = a * a + b * b;
    if (s > 9) {
      final double t = 3 / math.sqrt(s);
      m[k] = t * a * delta[k];
      m[k + 1] = t * b * delta[k];
    }
  }
  final double step = 1.0 / (size - 1);
  return <double>[
    for (int i = 0; i < size; i++)
      () {
        final double xs = i == size - 1 ? 1.0 : i * step;
        int idx = 0;
        while (idx < n - 2 && x[idx + 1] <= xs) {
          idx++;
        }
        final double t = (xs - x[idx]) / h[idx];
        final double t2 = t * t, t3 = t2 * t;
        final double v = (2 * t3 - 3 * t2 + 1) * y[idx] +
            (t3 - 2 * t2 + t) * h[idx] * m[idx] +
            (-2 * t3 + 3 * t2) * y[idx + 1] +
            (t3 - t2) * h[idx] * m[idx + 1];
        return v.clamp(0.0, 1.0);
      }(),
  ];
}

/// Ajoute un point (ou renvoie la courbe inchangée s'il y en a déjà un à ce x). Renvoie aussi l'indice.
(CurvePoints, int) addCurvePoint(CurvePoints pts, double x, double y) {
  final CurvePoints out = <List<double>>[for (final List<double> p in pts) <double>[p[0], p[1]]];
  int i = 0;
  while (i < out.length && out[i][0] < x) {
    i++;
  }
  if (i < out.length && (out[i][0] - x).abs() < kCurveMinGap * 2) return (out, i);
  if (i > 0 && (out[i - 1][0] - x).abs() < kCurveMinGap * 2) return (out, i - 1);
  out.insert(i, <double>[x.clamp(0.0, 1.0), y.clamp(0.0, 1.0)]);
  return (out, i);
}

/// Déplace le point [i]. Les extrémités (x = 0 et x = 1) ne bougent que verticalement ;
/// un point intérieur reste entre ses voisins.
CurvePoints moveCurvePoint(CurvePoints pts, int i, double x, double y) {
  final CurvePoints out = <List<double>>[for (final List<double> p in pts) <double>[p[0], p[1]]];
  if (i < 0 || i >= out.length) return out;
  final double ny = y.clamp(0.0, 1.0);
  if (i == 0) {
    out[0] = <double>[0, ny];
  } else if (i == out.length - 1) {
    out[i] = <double>[1, ny];
  } else {
    final double lo = out[i - 1][0] + kCurveMinGap * 2;
    final double hi = out[i + 1][0] - kCurveMinGap * 2;
    out[i] = <double>[x.clamp(lo, hi), ny];
  }
  return out;
}

/// Supprime le point [i] (les deux extrémités ne se suppriment pas).
CurvePoints removeCurvePoint(CurvePoints pts, int i) {
  if (i <= 0 || i >= pts.length - 1) return pts;
  return <List<double>>[
    for (int k = 0; k < pts.length; k++)
      if (k != i) <double>[pts[k][0], pts[k][1]],
  ];
}

bool curvesEqual(Map<String, CurvePoints> a, Map<String, CurvePoints> b) {
  if (a.length != b.length) return false;
  for (final MapEntry<String, CurvePoints> e in a.entries) {
    final CurvePoints? o = b[e.key];
    if (o == null || o.length != e.value.length) return false;
    for (int i = 0; i < o.length; i++) {
      if (o[i][0] != e.value[i][0] || o[i][1] != e.value[i][1]) return false;
    }
  }
  return true;
}

/// Sépare les courbes (clés `curve`, `curve_red`...) du reste des clés lues dans le fichier de retouche.
/// Renvoie (courbes non neutres par canal « rvb/red/green/blue », autres clés).
(Map<String, CurvePoints>, Map<String, dynamic>) splitCurves(Map<String, dynamic> extra) {
  final Map<String, CurvePoints> curves = <String, CurvePoints>{};
  final Map<String, dynamic> rest = Map<String, dynamic>.of(extra);
  kCurveKeys.forEach((String channel, String key) {
    final Object? v = rest.remove(key);
    if (v is List) {
      final CurvePoints pts = <List<double>>[];
      for (final Object? p in v) {
        if (p is List && p.length >= 2 && p[0] is num && p[1] is num) {
          pts.add(<double>[(p[0] as num).toDouble(), (p[1] as num).toDouble()]);
        }
      }
      if (pts.length >= 2) {
        final CurvePoints norm = normalizeCurve(pts);
        if (!isIdentityCurve(norm)) curves[channel] = norm;
      }
    }
  });
  return (curves, rest);
}

/// Courbes à écrire dans la recette : seulement celles qui ne sont pas neutres.
Map<String, dynamic> curvesToJson(Map<String, CurvePoints> curves) => <String, dynamic>{
      for (final MapEntry<String, String> e in kCurveKeys.entries)
        if (curves[e.key] != null && !isIdentityCurve(curves[e.key]!))
          e.value: <List<double>>[for (final List<double> p in curves[e.key]!) <double>[p[0], p[1]]],
    };
