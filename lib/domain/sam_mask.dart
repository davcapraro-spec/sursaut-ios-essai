import 'dart:math' as math;
import 'dart:typed_data';

import 'body_parts.dart';

/// Plan 8 bits (pw x ph) d'une sélection SAM 2.1.
///
/// [logits] : size x size valeurs avant sigmoïde, qui couvrent TOUTE la photo (SAM reçoit la photo étirée en 1024 x 1024).
/// Les valeurs sont interpolées en bilinéaire, passées par la sigmoïde, recalées sur les bords de la photo par le filtre guidé
/// (si [guide], plan gris pw x ph), puis contrastées autour de 50 %.
Uint8List samPlane({required Float32List logits, required int size, required int pw, required int ph, Uint8List? guide}) {
  final Float64List up = Float64List(pw * ph);
  if (size <= 0 || logits.length < size * size || pw <= 0 || ph <= 0) return Uint8List(pw * ph);
  for (int y = 0; y < ph; y++) {
    final double fy = ((y + 0.5) * size / ph - 0.5).clamp(0.0, size - 1.0).toDouble();
    final int y0 = fy.floor(), y1 = math.min(y0 + 1, size - 1);
    final double ty = fy - y0;
    for (int x = 0; x < pw; x++) {
      final double fx = ((x + 0.5) * size / pw - 0.5).clamp(0.0, size - 1.0).toDouble();
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
    final int r = math.max(2, (pw / size * 1.5).round());
    soft = guidedFilter(g, up, pw, ph, r, 1e-3);
  }
  final Uint8List out = Uint8List(pw * ph);
  for (int i = 0; i < out.length; i++) {
    final double t = ((soft[i] - 0.35) / 0.3).clamp(0.0, 1.0).toDouble();
    out[i] = (255 * t * t * (3 - 2 * t)).round();
  }
  return out;
}
