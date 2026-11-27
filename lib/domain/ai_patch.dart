import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'lama_prep.dart';

/// Rustine de « Supprimer (IA) » : une fenêtre carrée de la photo, reconstruite par LaMa (512 x 512), posée sur la photo AVANT les réglages.
///
/// Une rustine est enregistrée en proportions de l'image (elle s'applique donc à la taille d'aperçu comme à la pleine résolution) :
/// `id`, `x0` et `y0` (coin haut gauche, parts de la largeur et de la hauteur), `s` (côté, part de la largeur), `z` (image RVBA 512 x 512,
/// l'alpha étant le fondu du bord de la zone, en PNG puis en base64).
typedef AiPatch = Map<String, dynamic>;

/// Fenêtre carrée autour de la zone, en pixels de la photo. [tooBig] : la zone dépasse ce que LaMa peut traiter d'un coup.
class AiWindow {
  const AiWindow(this.x0, this.y0, this.side, this.tooBig);
  final int x0;
  final int y0;
  final int side;
  final bool tooBig;
}

/// Contexte donné à LaMa autour de la zone (fenêtre = 1,8 fois la zone) ; la fenêtre fait au moins [kAiMinWindow] pixels.
const double kAiContext = 1.8;
const int kAiMinWindow = 160;

/// Fenêtre de LaMa pour la zone [plane] (255 = zone, taille [pw] x [ph]) d'une photo [w] x [h] ; null si la zone est vide.
AiWindow? aiWindow(Uint8List plane, int pw, int ph, int w, int h) {
  int minX = pw, minY = ph, maxX = -1, maxY = -1;
  for (int y = 0; y < ph; y++) {
    for (int x = 0; x < pw; x++) {
      if (plane[y * pw + x] > 127) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }
  if (maxX < 0) return null;
  final double bw = (maxX - minX + 1) / pw * w;
  final double bh = (maxY - minY + 1) / ph * h;
  final int limit = math.min(w, h);
  final double wanted = math.max(bw, bh) * kAiContext;
  final int side = math.max(math.min(kAiMinWindow, limit), math.min(limit, wanted.round()));
  final double cx = (minX + maxX + 1) / 2 / pw * w;
  final double cy = (minY + maxY + 1) / 2 / ph * h;
  final int x0 = (cx - side / 2).round().clamp(0, w - side).toInt();
  final int y0 = (cy - side / 2).round().clamp(0, h - side).toInt();
  return AiWindow(x0, y0, side, wanted > limit * 1.02);
}

/// Masque 512 x 512 de la fenêtre (255 = à remplir), pris dans le plan de la zone.
Uint8List aiWindowMask(Uint8List plane, int pw, int ph, int w, int h, AiWindow win) {
  final Uint8List m = Uint8List(kLamaSide * kLamaSide);
  for (int oy = 0; oy < kLamaSide; oy++) {
    final int py = ((win.y0 + (oy + 0.5) * win.side / kLamaSide) / h * ph).floor().clamp(0, ph - 1).toInt();
    for (int ox = 0; ox < kLamaSide; ox++) {
      final int px = ((win.x0 + (ox + 0.5) * win.side / kLamaSide) / w * pw).floor().clamp(0, pw - 1).toInt();
      if (plane[py * pw + px] > 127) m[oy * kLamaSide + ox] = 255;
    }
  }
  return m;
}

/// Agrandit la zone de [r] pixels (le halo et le bord de l'objet partent avec lui).
Uint8List growMask(Uint8List mask, int r) {
  if (r <= 0) return Uint8List.fromList(mask);
  const int n = kLamaSide;
  final Uint8List tmp = Uint8List(n * n);
  final Uint8List out = Uint8List(n * n);
  for (int y = 0; y < n; y++) {
    for (int x = 0; x < n; x++) {
      int v = 0;
      for (int k = math.max(0, x - r); k <= math.min(n - 1, x + r); k++) {
        if (mask[y * n + k] > 127) {
          v = 255;
          break;
        }
      }
      tmp[y * n + x] = v;
    }
  }
  for (int y = 0; y < n; y++) {
    for (int x = 0; x < n; x++) {
      int v = 0;
      for (int k = math.max(0, y - r); k <= math.min(n - 1, y + r); k++) {
        if (tmp[k * n + x] > 0) {
          v = 255;
          break;
        }
      }
      out[y * n + x] = v;
    }
  }
  return out;
}

/// Fondu du bord : le masque flouté de [r] pixels (deux passages de moyenne), 0..255.
Uint8List featherAlpha(Uint8List mask, int r) {
  const int n = kLamaSide;
  List<double> cur = <double>[for (int i = 0; i < n * n; i++) mask[i] > 127 ? 255.0 : 0.0];
  for (int pass = 0; pass < 2; pass++) {
    final List<double> a = List<double>.filled(n * n, 0);
    final List<double> b = List<double>.filled(n * n, 0);
    for (int y = 0; y < n; y++) {
      for (int x = 0; x < n; x++) {
        double s = 0;
        int c = 0;
        for (int k = math.max(0, x - r); k <= math.min(n - 1, x + r); k++) {
          s += cur[y * n + k];
          c++;
        }
        a[y * n + x] = s / c;
      }
    }
    for (int y = 0; y < n; y++) {
      for (int x = 0; x < n; x++) {
        double s = 0;
        int c = 0;
        for (int k = math.max(0, y - r); k <= math.min(n - 1, y + r); k++) {
          s += a[k * n + x];
          c++;
        }
        b[y * n + x] = s / c;
      }
    }
    cur = b;
  }
  return Uint8List.fromList(<int>[for (final double v in cur) v.round().clamp(0, 255).toInt()]);
}

/// Remet le grain de la photo dans la zone remplie : écart-type du détail fin (luminance moins sa moyenne 3 x 3) mesuré sur la couronne
/// autour de la zone, bruit à graine fixe (même résultat à chaque calcul), plafonné à [kGrainMax] niveaux.
const double kGrainMax = 6;
Uint8List matchGrain(Uint8List orig, Uint8List mask, Uint8List filled) {
  const int n = kLamaSide;
  final Uint8List near = growMask(mask, 14);
  final Uint8List tight = growMask(mask, 3);
  double luma(int i) => 0.299 * orig[i * 4] + 0.587 * orig[i * 4 + 1] + 0.114 * orig[i * 4 + 2];
  double sum = 0;
  int count = 0;
  for (int y = 1; y < n - 1; y += 2) {
    for (int x = 1; x < n - 1; x += 2) {
      final int i = y * n + x;
      if (near[i] == 0 || tight[i] > 0) continue;
      double mean = 0;
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          mean += luma(i + dy * n + dx);
        }
      }
      final double d = luma(i) - mean / 9;
      sum += d * d;
      count++;
    }
  }
  final Uint8List out = Uint8List.fromList(filled);
  if (count < 200) return out;
  final double std = math.min(kGrainMax, math.sqrt(sum / count) * 1.2);
  if (std < 0.4) return out;
  int seed = 12345;
  double rnd() {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return seed / 0x7fffffff;
  }
  for (int i = 0; i < n * n; i++) {
    if (mask[i] <= 127) continue;
    final double g = (rnd() + rnd() + rnd() + rnd() - 2) * 1.7 * std; // ≈ gaussien d'écart-type std
    for (int c = 0; c < 3; c++) {
      out[i * 4 + c] = (out[i * 4 + c] + g).round().clamp(0, 255).toInt();
    }
  }
  return out;
}

/// Construit la rustine : [filled] (RVBA 512 x 512, après remise du grain), [alpha] (fondu), fenêtre [win] sur la photo [w] x [h].
AiPatch makeAiPatch({required Uint8List filled, required Uint8List alpha, required AiWindow win, required int w, required int h, required String id}) {
  final Uint8List rgba = Uint8List.fromList(filled);
  for (int i = 0; i < kLamaSide * kLamaSide; i++) {
    rgba[i * 4 + 3] = alpha[i];
  }
  return <String, dynamic>{
    'id': id,
    'x0': win.x0 / w,
    'y0': win.y0 / h,
    's': win.side / w,
    'z': base64Encode(img.encodePng(img.Image.fromBytes(width: kLamaSide, height: kLamaSide, bytes: rgba.buffer, numChannels: 4))),
  };
}

/// Image RVBA 512 x 512 de la rustine (null si elle est illisible).
Uint8List? patchPixels(AiPatch p) {
  try {
    final img.Image? im = img.decodePng(base64Decode('${p['z']}'));
    if (im == null || im.width != kLamaSide || im.height != kLamaSide) return null;
    final Uint8List px = Uint8List(kLamaSide * kLamaSide * 4);
    int i = 0;
    for (int y = 0; y < kLamaSide; y++) {
      for (int x = 0; x < kLamaSide; x++) {
        final img.Pixel q = im.getPixel(x, y);
        px[i++] = q.r.toInt();
        px[i++] = q.g.toInt();
        px[i++] = q.b.toInt();
        px[i++] = im.numChannels >= 4 ? q.a.toInt() : 255;
      }
    }
    return px;
  } catch (_) {
    return null;
  }
}

/// Pose les rustines sur une copie de [rgba] (photo [w] x [h]) ; rend [rgba] lui-même s'il n'y en a pas.
Uint8List applyAiPatches(Uint8List rgba, int w, int h, List<AiPatch> patches) {
  if (patches.isEmpty) return rgba;
  final Uint8List out = Uint8List.fromList(rgba);
  for (final AiPatch p in patches) {
    final Uint8List? px = patchPixels(p);
    final num? fx = p['x0'] as num?, fy = p['y0'] as num?, fs = p['s'] as num?;
    if (px == null || fx == null || fy == null || fs == null) continue;
    final int x0 = (fx * w).round(), y0 = (fy * h).round(), side = (fs * w).round();
    if (side < 8) continue;
    final double k = kLamaSide / side;
    for (int y = math.max(0, y0); y < math.min(h, y0 + side); y++) {
      final double v = (y - y0 + 0.5) * k - 0.5;
      final int iy = v.floor().clamp(0, kLamaSide - 2).toInt();
      final double ty = (v - iy).clamp(0.0, 1.0).toDouble();
      for (int x = math.max(0, x0); x < math.min(w, x0 + side); x++) {
        final double u = (x - x0 + 0.5) * k - 0.5;
        final int ix = u.floor().clamp(0, kLamaSide - 2).toInt();
        final double tx = (u - ix).clamp(0.0, 1.0).toDouble();
        final int a00 = (iy * kLamaSide + ix) * 4, a10 = a00 + 4, a01 = a00 + kLamaSide * 4, a11 = a01 + 4;
        double s(int c) =>
            (px[a00 + c] * (1 - tx) + px[a10 + c] * tx) * (1 - ty) + (px[a01 + c] * (1 - tx) + px[a11 + c] * tx) * ty;
        final double alpha = s(3) / 255;
        if (alpha <= 0.002) continue;
        final int o = (y * w + x) * 4;
        for (int c = 0; c < 3; c++) {
          out[o + c] = (out[o + c] * (1 - alpha) + s(c) * alpha).round().clamp(0, 255).toInt();
        }
      }
    }
  }
  return out;
}

const String kAiPatchKey = 'ai_patches';

/// Sépare les rustines du reste d'un fichier de retouche.
(List<AiPatch>, Map<String, dynamic>) splitAiPatches(Map<String, dynamic> extra) {
  final Object? raw = extra[kAiPatchKey];
  final Map<String, dynamic> rest = Map<String, dynamic>.of(extra)..remove(kAiPatchKey);
  if (raw is! List<dynamic>) return (<AiPatch>[], rest);
  return (<AiPatch>[for (final Object? p in raw) if (p is Map<String, dynamic> && p['z'] is String) Map<String, dynamic>.of(p)], rest);
}

bool aiPatchesEqual(List<AiPatch> a, List<AiPatch> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i]['id'] != b[i]['id']) return false;
  }
  return true;
}

List<AiPatch> copyAiPatches(List<AiPatch> l) => <AiPatch>[for (final AiPatch p in l) p];
