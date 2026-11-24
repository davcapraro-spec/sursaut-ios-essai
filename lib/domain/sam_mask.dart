import 'dart:math' as math;
import 'dart:typed_data';

import 'body_parts.dart';

/// Plan 8 bits (pw x ph) d'une sélection SAM 2.1.
///
/// [logits] : size x size valeurs avant sigmoïde. Elles couvrent TOUTE la photo (SAM reçoit la photo étirée en 1024 x 1024),
/// ou seulement la zone [crop] = [x0, y0, x1, y1] (fractions de la photo) quand SAM a relu cette zone en gros plan : ce qui est
/// hors de la zone est alors « en dehors ». Les valeurs sont interpolées en bilinéaire, passées par la sigmoïde, recalées sur les
/// bords de la photo par le filtre guidé (si [guide], plan gris pw x ph), puis contrastées autour de 50 %.
Uint8List samPlane({
  required Float32List logits,
  required int size,
  required int pw,
  required int ph,
  Uint8List? guide,
  List<double>? crop,
}) {
  final Float64List up = Float64List(pw * ph);
  if (size <= 0 || logits.length < size * size || pw <= 0 || ph <= 0) return Uint8List(pw * ph);
  final bool zoom = crop != null && crop.length == 4 && crop[2] > crop[0] && crop[3] > crop[1];
  final double cx0 = zoom ? crop[0] : 0, cy0 = zoom ? crop[1] : 0;
  final double cw = zoom ? crop[2] - crop[0] : 1, ch = zoom ? crop[3] - crop[1] : 1;
  for (int y = 0; y < ph; y++) {
    final double v = (y + 0.5) / ph;
    final double fy = ((v - cy0) / ch * size - 0.5).clamp(0.0, size - 1.0).toDouble();
    final bool outY = zoom && (v < cy0 || v > cy0 + ch);
    final int y0 = fy.floor(), y1 = math.min(y0 + 1, size - 1);
    final double ty = fy - y0;
    for (int x = 0; x < pw; x++) {
      final double u = (x + 0.5) / pw;
      if (outY || (zoom && (u < cx0 || u > cx0 + cw))) {
        up[y * pw + x] = 0;
        continue;
      }
      final double fx = ((u - cx0) / cw * size - 0.5).clamp(0.0, size - 1.0).toDouble();
      final int x0 = fx.floor(), x1 = math.min(x0 + 1, size - 1);
      final double tx = fx - x0;
      final double a = logits[y0 * size + x0] * (1 - tx) + logits[y0 * size + x1] * tx;
      final double b = logits[y1 * size + x0] * (1 - tx) + logits[y1 * size + x1] * tx;
      final double l = a * (1 - ty) + b * ty;
      up[y * pw + x] = 1 / (1 + math.exp(-l.clamp(-30.0, 30.0).toDouble()));
    }
  }
  Float64List soft = up;
  if (guide != null && guide.length >= pw * ph) {
    final Float64List g = Float64List(pw * ph);
    for (int i = 0; i < g.length; i++) {
      g[i] = guide[i] / 255;
    }
    final int r = math.max(2, (pw * cw / size * 1.5).round());
    soft = guidedFilter(g, up, pw, ph, r, 1e-3);
  }
  final Uint8List out = Uint8List(pw * ph);
  for (int i = 0; i < out.length; i++) {
    final double t = ((soft[i] - 0.35) / 0.3).clamp(0.0, 1.0).toDouble();
    out[i] = (255 * t * t * (3 - 2 * t)).round();
  }
  return out;
}

/// Zone [x0, y0, x1, y1] (fractions de la photo) qui contient la sélection du plan (valeurs > 127) avec une marge de [margin]
/// (part de la taille de la sélection), ou null si le plan est vide. La zone a au moins [minSide] de la photo de côté.
List<double>? samCropOf(Uint8List plane, int pw, int ph, {double margin = 0.12, double minSide = 0.08}) {
  int x0 = pw, y0 = ph, x1 = -1, y1 = -1;
  for (int y = 0; y < ph; y++) {
    for (int x = 0; x < pw; x++) {
      if (plane[y * pw + x] > 127) {
        if (x < x0) x0 = x;
        if (x > x1) x1 = x;
        if (y < y0) y0 = y;
        if (y > y1) y1 = y;
      }
    }
  }
  if (x1 < 0) return null;
  final double w = (x1 - x0 + 1) / pw, h = (y1 - y0 + 1) / ph;
  final double cw = math.max(minSide, w * (1 + 2 * margin)), chh = math.max(minSide, h * (1 + 2 * margin));
  final double cx = (x0 + x1 + 1) / 2 / pw, cy = (y0 + y1 + 1) / 2 / ph;
  double a0 = cx - cw / 2, b0 = cy - chh / 2, a1 = cx + cw / 2, b1 = cy + chh / 2;
  if (a0 < 0) {
    a1 -= a0;
    a0 = 0;
  }
  if (b0 < 0) {
    b1 -= b0;
    b0 = 0;
  }
  if (a1 > 1) {
    a0 -= a1 - 1;
    a1 = 1;
  }
  if (b1 > 1) {
    b0 -= b1 - 1;
    b1 = 1;
  }
  return <double>[math.max(0.0, a0), math.max(0.0, b0), math.min(1.0, a1), math.min(1.0, b1)];
}

/// Les points [x, y, étiquette] ramenés dans la zone [crop] (fractions) ; ceux qui sont hors de la zone sont écartés.
List<List<double>> samPointsInCrop(List<List<double>> pts, List<double> crop) {
  final double w = crop[2] - crop[0], h = crop[3] - crop[1];
  return <List<double>>[
    for (final List<double> q in pts)
      if (q[0] >= crop[0] && q[0] <= crop[2] && q[1] >= crop[1] && q[1] <= crop[3])
        <double>[(q[0] - crop[0]) / w, (q[1] - crop[1]) / h, q[2]],
  ];
}

/// Les points [x, y, 1 ou 0] d'un masque fait par SAM (champ `ai` de sa composante), ou null si ce n'est pas un masque SAM.
List<List<double>>? samPointsOf(Object? ai) {
  if (ai is! Map<String, dynamic> || '${ai['what']}' != 'sam') return null;
  final Object? pts = ai['points'];
  if (pts is! List<dynamic> || pts.isEmpty) return null;
  final List<List<double>> out = <List<double>>[];
  for (final dynamic q in pts) {
    if (q is! List<dynamic> || q.length < 3 || q[0] is! num || q[1] is! num || q[2] is! num) return null;
    out.add(<double>[(q[0] as num).toDouble(), (q[1] as num).toDouble(), (q[2] as num).toDouble()]);
  }
  return out;
}
