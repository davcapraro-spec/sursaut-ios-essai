import 'dart:math' as math;
import 'dart:typed_data';

/// Parties du corps d'une personne (cheveux, peau du corps, vêtements), à partir des classes données par le modèle
/// « selfie multiclasse » (code natif). Partie pure : découpe autour du visage, choix de la zone qui touche cette personne,
/// remise à l'échelle de la photo.

/// Les parties proposées, avec leur nom affiché.
const Map<String, String> kBodyPartNames = <String, String>{
  'hair': 'Cheveux',
  'clothes': 'Vêtements',
  'bodyskin': 'Peau du corps',
};

/// Numéro de classe du modèle : 0 fond, 1 cheveux, 2 peau du corps, 3 peau du visage, 4 vêtements, 5 autres.
const Map<String, int> kBodyPartClass = <String, int>{'hair': 1, 'bodyskin': 2, 'clothes': 4};

/// Nombre de classes du modèle.
const int kBodyClasses = 6;

/// Carré de la photo envoyé au modèle (en pixels ; il peut dépasser la photo).
class CropSquare {
  const CropSquare(this.x0, this.y0, this.side);

  final int x0, y0, side;
}

/// Le carré autour d'une personne, d'après son visage (cadre en fractions de la photo). Pour les cheveux, il est serré sur la
/// tête (le modèle travaille en 256 x 256 : plus la découpe est petite, plus ses pixels sont fins) ; pour les vêtements et la
/// peau du corps, il couvre la tête et le haut du corps.
CropSquare bodyCrop(double fx0, double fy0, double fx1, double fy1, int w, int h, {String part = 'clothes'}) {
  final double faceH = (fy1 - fy0) * h, faceW = (fx1 - fx0) * w;
  final double cx = (fx0 + fx1) / 2 * w;
  if (part == 'hair') {
    final int side = math.max(64, math.max(faceH * 2.8, faceW * 2.6).round());
    return CropSquare((cx - side / 2).round(), (fy0 * h - faceH * 0.95).round(), side);
  }
  final int side = math.max(64, math.max(faceH * 6, faceW * 4.5).round());
  return CropSquare((cx - side / 2).round(), (fy0 * h - faceH * 1.2).round(), side);
}

/// Image en niveaux de gris de la photo ([w] x [h], RGBA) remise à l'échelle [pw] x [ph] (moyenne de quelques points par pixel).
Uint8List grayPlane(Uint8List rgba, int w, int h, int pw, int ph) {
  final Uint8List out = Uint8List(pw * ph);
  if (rgba.length < w * h * 4 || pw <= 0 || ph <= 0) return out;
  final int kx = math.max(1, math.min(4, (w / pw).ceil())), ky = math.max(1, math.min(4, (h / ph).ceil()));
  for (int y = 0; y < ph; y++) {
    for (int x = 0; x < pw; x++) {
      double acc = 0;
      for (int j = 0; j < ky; j++) {
        final int sy = (((y + (j + 0.5) / ky) * h) / ph).floor().clamp(0, h - 1).toInt();
        for (int i = 0; i < kx; i++) {
          final int sx = (((x + (i + 0.5) / kx) * w) / pw).floor().clamp(0, w - 1).toInt();
          final int o = (sy * w + sx) * 4;
          acc += 0.299 * rgba[o] + 0.587 * rgba[o + 1] + 0.114 * rgba[o + 2];
        }
      }
      out[y * pw + x] = (acc / (kx * ky)).round().clamp(0, 255).toInt();
    }
  }
  return out;
}

/// Moyenne de [a] ([w] x [h]) sur une fenêtre de rayon [r] (tronquée aux bords), par image intégrale.
Float64List _boxMean(Float64List a, int w, int h, int r) {
  final int iw = w + 1;
  final Float64List sum = Float64List(iw * (h + 1));
  for (int y = 0; y < h; y++) {
    double row = 0;
    for (int x = 0; x < w; x++) {
      row += a[y * w + x];
      sum[(y + 1) * iw + x + 1] = sum[y * iw + x + 1] + row;
    }
  }
  final Float64List out = Float64List(w * h);
  for (int y = 0; y < h; y++) {
    final int y0 = math.max(0, y - r), y1 = math.min(h, y + r + 1);
    for (int x = 0; x < w; x++) {
      final int x0 = math.max(0, x - r), x1 = math.min(w, x + r + 1);
      final double total = sum[y1 * iw + x1] - sum[y0 * iw + x1] - sum[y1 * iw + x0] + sum[y0 * iw + x0];
      out[y * w + x] = total / ((x1 - x0) * (y1 - y0));
    }
  }
  return out;
}

/// Filtre guidé (He et al.) : recale les bords de [p] (valeurs de 0 à 1) sur ceux de l'image [guide] (valeurs de 0 à 1),
/// toutes deux de [w] x [h]. [r] : rayon en pixels ; [eps] : régularisation.
Float64List guidedFilter(Float64List guide, Float64List p, int w, int h, int r, double eps) {
  final int n = w * h;
  final Float64List ip = Float64List(n), ii = Float64List(n);
  for (int i = 0; i < n; i++) {
    ip[i] = guide[i] * p[i];
    ii[i] = guide[i] * guide[i];
  }
  final Float64List mI = _boxMean(guide, w, h, r), mp = _boxMean(p, w, h, r);
  final Float64List mIp = _boxMean(ip, w, h, r), mII = _boxMean(ii, w, h, r);
  final Float64List a = Float64List(n), b = Float64List(n);
  for (int i = 0; i < n; i++) {
    final double cov = mIp[i] - mI[i] * mp[i];
    final double variance = mII[i] - mI[i] * mI[i];
    a[i] = cov / (variance + eps);
    b[i] = mp[i] - a[i] * mI[i];
  }
  final Float64List ma = _boxMean(a, w, h, r), mb = _boxMean(b, w, h, r);
  final Float64List q = Float64List(n);
  for (int i = 0; i < n; i++) {
    q[i] = (ma[i] * guide[i] + mb[i]).clamp(0.0, 1.0).toDouble();
  }
  return q;
}

/// Où chercher la partie près du visage : rectangle [x0, y0, x1, y1] en pixels de la photo. Seules les zones de la partie
/// qui touchent ce rectangle sont gardées (les cheveux ou les vêtements d'une autre personne sont écartés).
List<double> partAnchor(String part, double fx0, double fy0, double fx1, double fy1, int w, int h) {
  final double x0 = fx0 * w, x1 = fx1 * w, y0 = fy0 * h, y1 = fy1 * h;
  final double fw = x1 - x0, fh = y1 - y0;
  switch (part) {
    case 'hair':
      return <double>[x0 - 0.3 * fw, y0 - 0.7 * fh, x1 + 0.3 * fw, y0 + 0.5 * fh];
    case 'clothes':
      return <double>[x0 - 0.4 * fw, y1 + 0.3 * fh, x1 + 0.4 * fw, y1 + 1.8 * fh];
    default:
      return <double>[x0 - 0.6 * fw, y1 - 0.1 * fh, x1 + 0.6 * fw, y1 + 1.2 * fh];
  }
}

/// L'image de la partie [cls] (255 dedans, 0 dehors, bords adoucis), de [pw] x [ph] octets pour une photo de [imgW] x [imgH].
///
/// [probs] : [kBodyClasses] plans de [size] x [size] octets (probabilité x 255) du carré [crop]. Une zone de la classe
/// n'est gardée que si elle touche [anchor] (pixels de la photo). [guide] : la photo en niveaux de gris, [pw] x [ph] ; si elle
/// est donnée, les bords sont recalés dessus (filtre guidé, rayon = 1,5 pixel du modèle). [faces] : pour chaque personne de la photo,
/// [centre x, largeur du visage] en pixels ; chaque pixel de la zone va à la personne dont l'axe (centre du visage) est le plus proche,
/// pour que la partie suive la personne choisie ([self]) et pas son voisin.
Uint8List bodyPartPlane({
  required Uint8List probs,
  required int size,
  required int cls,
  required CropSquare crop,
  required List<double> anchor,
  required int pw,
  required int ph,
  required int imgW,
  required int imgH,
  Uint8List? guide,
  List<List<double>>? faces,
  int self = 0,
}) {
  final int n = size * size;
  final Uint8List out = Uint8List(pw * ph);
  if (probs.length < n * kBodyClasses || cls < 0 || cls >= kBodyClasses || crop.side <= 0) return out;
  // 1. pixels dont la classe est la plus probable
  final Uint8List isCls = Uint8List(n);
  for (int i = 0; i < n; i++) {
    int best = 0, bv = probs[i];
    for (int k = 1; k < kBodyClasses; k++) {
      final int v = probs[k * n + i];
      if (v > bv) {
        bv = v;
        best = k;
      }
    }
    if (best == cls) isCls[i] = 1;
  }
  // 2. zones qui touchent le rectangle voulu (parcours en largeur, 4 voisins)
  final double sc = size / crop.side;
  final int ax0 = ((anchor[0] - crop.x0) * sc).floor().clamp(0, size).toInt();
  final int ay0 = ((anchor[1] - crop.y0) * sc).floor().clamp(0, size).toInt();
  final int ax1 = ((anchor[2] - crop.x0) * sc).ceil().clamp(0, size).toInt();
  final int ay1 = ((anchor[3] - crop.y0) * sc).ceil().clamp(0, size).toInt();
  final Uint8List keep = Uint8List(n);
  final List<int> queue = <int>[];
  for (int y = ay0; y < ay1; y++) {
    for (int x = ax0; x < ax1; x++) {
      final int i = y * size + x;
      if (isCls[i] == 1 && keep[i] == 0) {
        keep[i] = 1;
        queue.add(i);
      }
    }
  }
  int head = 0;
  while (head < queue.length) {
    final int i = queue[head++];
    final int x = i % size, y = i ~/ size;
    if (x > 0 && isCls[i - 1] == 1 && keep[i - 1] == 0) {
      keep[i - 1] = 1;
      queue.add(i - 1);
    }
    if (x < size - 1 && isCls[i + 1] == 1 && keep[i + 1] == 0) {
      keep[i + 1] = 1;
      queue.add(i + 1);
    }
    if (y > 0 && isCls[i - size] == 1 && keep[i - size] == 0) {
      keep[i - size] = 1;
      queue.add(i - size);
    }
    if (y < size - 1 && isCls[i + size] == 1 && keep[i + size] == 0) {
      keep[i + size] = 1;
      queue.add(i + size);
    }
  }
  if (queue.isEmpty) return out;
  // 3. probabilité de la classe dans les zones gardées, remise à l'échelle de la photo (bilinéaire), puis contraste autour de 50 %
  final Uint8List soft = Uint8List(n);
  final List<List<double>>? all = faces;
  final bool split = all != null && all.length > 1 && self >= 0 && self < all.length;
  for (int i = 0; i < n; i++) {
    if (keep[i] != 1) continue;
    if (split) {
      final double photoX = crop.x0 + ((i % size) + 0.5) / sc;
      int owner = 0;
      double best = double.infinity;
      for (int k = 0; k < all!.length; k++) {
        final double d = (photoX - all[k][0]).abs() / math.max(1.0, all[k][1]);
        if (d < best) {
          best = d;
          owner = k;
        }
      }
      if (owner != self) continue;
    }
    soft[i] = probs[cls * n + i];
  }
  final double px = pw / imgW, py = ph / imgH;
  final int ox0 = (crop.x0 * px).floor().clamp(0, pw).toInt();
  final int ox1 = ((crop.x0 + crop.side) * px).ceil().clamp(0, pw).toInt();
  final int oy0 = (crop.y0 * py).floor().clamp(0, ph).toInt();
  final int oy1 = ((crop.y0 + crop.side) * py).ceil().clamp(0, ph).toInt();
  final int bw = ox1 - ox0, bh = oy1 - oy0;
  if (bw <= 0 || bh <= 0) return out;
  Float64List up = Float64List(bw * bh);
  for (int oy = oy0; oy < oy1; oy++) {
    final double my = ((oy + 0.5) / py - crop.y0) * sc - 0.5;
    if (my < -0.5 || my > size - 0.5) continue;
    final int iy = my.floor();
    final double ty = my - iy;
    final int ya = iy.clamp(0, size - 1).toInt(), yb = (iy + 1).clamp(0, size - 1).toInt();
    for (int ox = ox0; ox < ox1; ox++) {
      final double mx = ((ox + 0.5) / px - crop.x0) * sc - 0.5;
      if (mx < -0.5 || mx > size - 0.5) continue;
      final int ix = mx.floor();
      final double tx = mx - ix;
      final int xa = ix.clamp(0, size - 1).toInt(), xb = (ix + 1).clamp(0, size - 1).toInt();
      final double top = soft[ya * size + xa] * (1 - tx) + soft[ya * size + xb] * tx;
      final double bot = soft[yb * size + xa] * (1 - tx) + soft[yb * size + xb] * tx;
      up[(oy - oy0) * bw + (ox - ox0)] = (top * (1 - ty) + bot * ty) / 255;
    }
  }
  if (guide != null && guide.length >= pw * ph) {
    final Float64List g = Float64List(bw * bh);
    for (int oy = oy0; oy < oy1; oy++) {
      for (int ox = ox0; ox < ox1; ox++) {
        g[(oy - oy0) * bw + (ox - ox0)] = guide[oy * pw + ox] / 255;
      }
    }
    final double cell = crop.side / size * px; // taille d'un pixel du modèle dans le plan de travail
    final int r = math.max(2, (cell * 1.5).round());
    up = guidedFilter(g, up, bw, bh, r, 1e-3);
  }
  for (int oy = oy0; oy < oy1; oy++) {
    for (int ox = ox0; ox < ox1; ox++) {
      final double v = up[(oy - oy0) * bw + (ox - ox0)];
      final double t = ((v - 0.35) / 0.3).clamp(0.0, 1.0).toDouble();
      out[oy * pw + ox] = (255 * t * t * (3 - 2 * t)).round();
    }
  }
  return out;
}
