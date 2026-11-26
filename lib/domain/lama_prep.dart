import 'dart:math' as math;
import 'dart:typed_data';

/// Préparation des données pour LaMa (fenêtre 512 x 512) : découpe d'un carré de la photo ramené à 512 x 512, masque en ellipse.
const int kLamaSide = 512;

/// Le carré (`x0`, `y0`, `side`, en pixels de la photo ; il peut dépasser : le dépassement est noir) ramené à 512 x 512 (RGBA, alpha 255),
/// par moyenne de plusieurs points par pixel quand on réduit, interpolation bilinéaire sinon.
Uint8List lamaCrop(Uint8List rgba, int w, int h, int x0, int y0, int side) {
  final Uint8List out = Uint8List(kLamaSide * kLamaSide * 4);
  final double scale = side / kLamaSide;
  final int k = math.max(1, math.min(4, (scale / 2).ceil()));
  final double step = scale / k;
  double texel(int x, int y, int c) => (x < 0 || y < 0 || x >= w || y >= h) ? 0 : rgba[(y * w + x) * 4 + c].toDouble();
  for (int oy = 0; oy < kLamaSide; oy++) {
    for (int ox = 0; ox < kLamaSide; ox++) {
      final List<double> acc = <double>[0, 0, 0];
      for (int sy = 0; sy < k; sy++) {
        final double fy = y0 + (oy * k + sy + 0.5) * step - 0.5;
        final int iy = fy.floor();
        final double ty = fy - iy;
        for (int sx = 0; sx < k; sx++) {
          final double fx = x0 + (ox * k + sx + 0.5) * step - 0.5;
          final int ix = fx.floor();
          final double tx = fx - ix;
          for (int c = 0; c < 3; c++) {
            final double top = texel(ix, iy, c) * (1 - tx) + texel(ix + 1, iy, c) * tx;
            final double bottom = texel(ix, iy + 1, c) * (1 - tx) + texel(ix + 1, iy + 1, c) * tx;
            acc[c] += top * (1 - ty) + bottom * ty;
          }
        }
      }
      final int o = (oy * kLamaSide + ox) * 4;
      for (int c = 0; c < 3; c++) {
        out[o + c] = (acc[c] / (k * k)).round().clamp(0, 255);
      }
      out[o + 3] = 255;
    }
  }
  return out;
}

/// Masque 512 x 512 (255 = à remplir) : une ellipse de centre (`cx`, `cy`) et de demi-axes `rx`, `ry` (en pixels de la fenêtre).
Uint8List lamaEllipseMask(double cx, double cy, double rx, double ry) {
  final Uint8List m = Uint8List(kLamaSide * kLamaSide);
  for (int y = 0; y < kLamaSide; y++) {
    for (int x = 0; x < kLamaSide; x++) {
      final double dx = (x + 0.5 - cx) / rx;
      final double dy = (y + 0.5 - cy) / ry;
      if (dx * dx + dy * dy <= 1) m[y * kLamaSide + x] = 255;
    }
  }
  return m;
}

/// La fenêtre avec la zone du masque grisée (pour montrer le trou avant le remplissage).
Uint8List lamaShowHole(Uint8List rgba, Uint8List mask) {
  final Uint8List out = Uint8List.fromList(rgba);
  for (int i = 0; i < kLamaSide * kLamaSide; i++) {
    if (mask[i] > 127) {
      out[i * 4] = 128;
      out[i * 4 + 1] = 128;
      out[i * 4 + 2] = 128;
    }
  }
  return out;
}
