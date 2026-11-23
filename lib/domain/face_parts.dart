import 'dart:math' as math;
import 'dart:typed_data';

/// Zones d'un visage (peau, yeux, sourcils, lèvres) dessinées à partir des repères de Vision (iPadOS).
///
/// Les points sont des suites x, y, x, y… en fractions de la photo (origine en haut à gauche).

/// Les parties proposées, avec leur nom affiché.
const Map<String, String> kFacePartNames = <String, String>{
  'skin': 'Peau du visage',
  'eyes': 'Yeux',
  'brows': 'Sourcils',
  'lips': 'Lèvres',
};

/// Une zone : des polygones à remplir, puis des polygones à retirer.
class PartShape {
  const PartShape(this.add, this.sub);

  final List<List<double>> add;
  final List<List<double>> sub;
}

/// Le polygone agrandi (ou réduit) de [k] autour de son centre.
List<double> scalePoly(List<double> pts, double k) {
  final int n = pts.length ~/ 2;
  if (n == 0) return <double>[];
  double cx = 0, cy = 0;
  for (int i = 0; i < n; i++) {
    cx += pts[2 * i];
    cy += pts[2 * i + 1];
  }
  cx /= n;
  cy /= n;
  return <double>[
    for (int i = 0; i < n; i++) ...<double>[cx + (pts[2 * i] - cx) * k, cy + (pts[2 * i + 1] - cy) * k],
  ];
}

/// Un trait (suite de points) épaissi de [half] vers le haut et vers le bas : devient un polygone.
List<double> thickLine(List<double> pts, double half) {
  final int n = pts.length ~/ 2;
  if (n < 2) return <double>[];
  return <double>[
    for (int i = 0; i < n; i++) ...<double>[pts[2 * i], pts[2 * i + 1] - half],
    for (int i = n - 1; i >= 0; i--) ...<double>[pts[2 * i], pts[2 * i + 1] + half],
  ];
}

/// Le contour du visage de Vision s'arrête vers les tempes : on le prolonge vers le haut pour couvrir le front.
List<double> foreheadFace(List<double> contour, List<double> brows) {
  final int n = contour.length ~/ 2;
  if (n < 3 || brows.length < 4) return <double>[];
  double browTop = 1, chin = 0;
  for (int i = 1; i < brows.length; i += 2) {
    browTop = math.min(browTop, brows[i]);
  }
  for (int i = 1; i < contour.length; i += 2) {
    chin = math.max(chin, contour[i]);
  }
  final double top = math.max(0.0, browTop - (chin - browTop) * 0.45);
  final double xa = contour[0], xb = contour[2 * n - 2];
  final double ia = xa + (xb - xa) * 0.1, ib = xb - (xb - xa) * 0.1;
  return <double>[...contour, ib, top, ia, top];
}

/// La zone de la partie [part] pour un visage décrit par ses repères (`box` = x0, y0, x1, y1 ; `leftEye`, `rightEye`,
/// `leftBrow`, `rightBrow`, `outerLips`, `innerLips`, `contour`). Null s'il manque les repères nécessaires.
PartShape? partShape(Map<String, List<double>> f, String part) {
  List<double> g(String k) => f[k] ?? const <double>[];
  List<List<double>> solid(List<List<double>> l) => <List<double>>[
        for (final List<double> p in l)
          if (p.length >= 6) p,
      ];
  final List<double> box = g('box');
  if (box.length < 4) return null;
  final double half = (box[3] - box[1]) * 0.035;
  PartShape? shape;
  if (part == 'eyes') {
    shape = PartShape(solid(<List<double>>[scalePoly(g('leftEye'), 1.4), scalePoly(g('rightEye'), 1.4)]), const <List<double>>[]);
  } else if (part == 'brows') {
    shape = PartShape(solid(<List<double>>[thickLine(g('leftBrow'), half), thickLine(g('rightBrow'), half)]), const <List<double>>[]);
  } else if (part == 'lips') {
    shape = PartShape(solid(<List<double>>[g('outerLips')]), solid(<List<double>>[g('innerLips')]));
  } else if (part == 'skin') {
    final List<double> brows = <double>[...g('leftBrow'), ...g('rightBrow')];
    shape = PartShape(
      solid(<List<double>>[foreheadFace(g('contour'), brows)]),
      solid(<List<double>>[
        scalePoly(g('leftEye'), 1.7),
        scalePoly(g('rightEye'), 1.7),
        thickLine(g('leftBrow'), half * 1.6),
        thickLine(g('rightBrow'), half * 1.6),
        scalePoly(g('outerLips'), 1.15),
      ]),
    );
  }
  if (shape == null || shape.add.isEmpty) return null;
  return shape;
}

void _fill(Uint8List plane, int w, int h, List<double> pts, int value) {
  final int n = pts.length ~/ 2;
  if (n < 3) return;
  final List<double> xs = <double>[];
  for (int y = 0; y < h; y++) {
    final double fy = (y + 0.5) / h;
    xs.clear();
    for (int i = 0; i < n; i++) {
      final int j = (i + 1) % n;
      final double y0 = pts[2 * i + 1], y1 = pts[2 * j + 1];
      if ((y0 <= fy && y1 > fy) || (y1 <= fy && y0 > fy)) {
        final double t = (fy - y0) / (y1 - y0);
        xs.add(pts[2 * i] + t * (pts[2 * j] - pts[2 * i]));
      }
    }
    xs.sort();
    for (int k = 0; k + 1 < xs.length; k += 2) {
      final int a = (xs[k] * w).round().clamp(0, w).toInt();
      final int b = (xs[k + 1] * w).round().clamp(0, w).toInt();
      for (int x = a; x < b; x++) {
        plane[y * w + x] = value;
      }
    }
  }
}

/// L'image de la zone : 255 dans les polygones à remplir, puis 0 dans ceux à retirer.
Uint8List fillShape(int w, int h, PartShape s) {
  final Uint8List plane = Uint8List(w * h);
  for (final List<double> p in s.add) {
    _fill(plane, w, h, p, 255);
  }
  for (final List<double> p in s.sub) {
    _fill(plane, w, h, p, 0);
  }
  return plane;
}

/// Adoucit les bords : flou moyen de rayon [r] pixels (deux passes). Une zone uniforme reste inchangée.
Uint8List blurPlane(Uint8List src, int w, int h, int r) {
  if (r <= 0) return Uint8List.fromList(src);
  Uint8List pass(Uint8List a, bool horizontal) {
    final Uint8List out = Uint8List(a.length);
    final int len = horizontal ? w : h;
    final int lines = horizontal ? h : w;
    for (int l = 0; l < lines; l++) {
      int sum = 0, from = 0, to = -1;
      for (int i = 0; i < len; i++) {
        final int lo = math.max(0, i - r), hi = math.min(len - 1, i + r);
        while (to < hi) {
          to++;
          sum += a[horizontal ? l * w + to : to * w + l];
        }
        while (from < lo) {
          sum -= a[horizontal ? l * w + from : from * w + l];
          from++;
        }
        out[horizontal ? l * w + i : i * w + l] = (sum / (hi - lo + 1)).round();
      }
    }
    return out;
  }

  return pass(pass(pass(pass(src, true), false), true), false);
}
