import 'dart:math' as math;
import 'dart:typed_data';

/// Histogramme d'une image RGBA 8 bits : 256 classes par canal rouge, vert, bleu et pour la luminosité,
/// plus la part de pixels bouchés (un canal à 0) ou brûlés (un canal à 255).
class Histogram {
  Histogram._(this.r, this.g, this.b, this.l, this.count, this.shadowClip, this.highlightClip);

  final List<int> r;
  final List<int> g;
  final List<int> b;
  final List<int> l;

  /// Nombre de pixels comptés (l'image est échantillonnée : pas plus de [maxSamples]).
  final int count;

  /// Part (0..1) des pixels comptés qui ont au moins un canal à 0.
  final double shadowClip;

  /// Part (0..1) des pixels comptés qui ont au moins un canal à 255.
  final double highlightClip;

  /// Au-dessus de cette part de pixels, le triangle d'alerte s'allume.
  static const double clipAlert = 0.001;

  bool get shadowsClipped => shadowClip > clipAlert;
  bool get highlightsClipped => highlightClip > clipAlert;

  /// Calcule l'histogramme de [rgba] (largeur [w], hauteur [h]) en lisant au plus environ [maxSamples] pixels.
  static Histogram of(Uint8List rgba, int w, int h, {int maxSamples = 90000}) {
    final List<int> r = List<int>.filled(256, 0);
    final List<int> g = List<int>.filled(256, 0);
    final List<int> b = List<int>.filled(256, 0);
    final List<int> l = List<int>.filled(256, 0);
    if (w <= 0 || h <= 0 || rgba.length < w * h * 4) {
      return Histogram._(r, g, b, l, 0, 0, 0);
    }
    final int step = math.max(1, math.sqrt(w * h / maxSamples).ceil());
    int n = 0, dark = 0, bright = 0;
    for (int y = 0; y < h; y += step) {
      int i = y * w * 4;
      for (int x = 0; x < w; x += step, i += 4 * step) {
        final int rr = rgba[i], gg = rgba[i + 1], bb = rgba[i + 2];
        r[rr]++;
        g[gg]++;
        b[bb]++;
        l[(0.2126 * rr + 0.7152 * gg + 0.0722 * bb).round().clamp(0, 255).toInt()]++;
        n++;
        if (rr == 0 || gg == 0 || bb == 0) dark++;
        if (rr == 255 || gg == 255 || bb == 255) bright++;
      }
    }
    return Histogram._(r, g, b, l, n, n == 0 ? 0.0 : dark / n, n == 0 ? 0.0 : bright / n);
  }

  /// Hauteur de référence pour dessiner : un pic isolé (noir ou blanc pur) ne doit pas écraser le reste,
  /// donc on prend le 99,5e centile des classes, sans les deux classes extrêmes.
  static double reference(List<int> bins) {
    final List<int> inner = bins.sublist(1, 255)..sort();
    final double ref = inner[(inner.length * 0.995).floor().clamp(0, inner.length - 1).toInt()].toDouble();
    return math.max(ref, 1.0);
  }

  /// Hauteurs 0..1 d'une courbe, lissées sur 3 classes pour un tracé doux.
  static List<double> curve(List<int> bins, double ref) {
    return <double>[
      for (int i = 0; i < 256; i++)
        ((bins[math.max(i - 1, 0)] + 2 * bins[i] + bins[math.min(i + 1, 255)]) / 4 / ref).clamp(0.0, 1.0).toDouble(),
    ];
  }
}
