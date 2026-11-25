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

double _lin(int v) {
  final double c = v / 255;
  return c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
}

double _labF(double t) => t > 0.008856 ? math.pow(t, 1 / 3).toDouble() : 7.787 * t + 16 / 116;

Uint8List _erode4(Uint8List m, int size) {
  final Uint8List o = Uint8List(m.length);
  for (int y = 1; y < size - 1; y++) {
    for (int x = 1; x < size - 1; x++) {
      final int i = y * size + x;
      if (m[i] == 1 && m[i - 1] == 1 && m[i + 1] == 1 && m[i - size] == 1 && m[i + size] == 1) o[i] = 1;
    }
  }
  return o;
}

/// Peau du corps par la couleur : la couleur de la peau du visage de cette personne (a et b de Lab) sert de référence ; à partir des taches
/// que le modèle a reconnues comme peau du corps (mains, cou), la zone s'étend (10 pixels du modèle au plus) sur les pixels de cette couleur.
/// [cmap] : classe la plus probable de chaque pixel du modèle ; [face] : [centre x, centre y, largeur] du visage en pixels de la photo.
/// Rend null si le visage ne donne pas assez de pixels pour calibrer.
Uint8List? skinKeep(Uint8List cmap, int size, CropSquare crop, Uint8List rgba, int imgW, int imgH, List<double> face) {
  final int n = size * size;
  if (cmap.length < n || rgba.length < imgW * imgH * 4 || crop.side <= 0) return null;
  final double sc = size / crop.side;
  final Float64List ll = Float64List(n), la = Float64List(n), lb = Float64List(n);
  for (int y = 0; y < size; y++) {
    final int py = (crop.y0 + (y + 0.5) / sc).floor().clamp(0, imgH - 1).toInt();
    for (int x = 0; x < size; x++) {
      final int px = (crop.x0 + (x + 0.5) / sc).floor().clamp(0, imgW - 1).toInt();
      final int o = (py * imgW + px) * 4;
      final double r = _lin(rgba[o]), g = _lin(rgba[o + 1]), b = _lin(rgba[o + 2]);
      final double fx = _labF((0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047);
      final double fy = _labF(0.2126 * r + 0.7152 * g + 0.0722 * b);
      final double fz = _labF((0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883);
      final int i = y * size + x;
      ll[i] = 116 * fy - 16;
      la[i] = 500 * (fx - fy);
      lb[i] = 200 * (fy - fz);
    }
  }
  final double cx = (face[0] - crop.x0) * sc, cy = (face[1] - crop.y0) * sc, rad = face[2] * sc * 0.9;
  Uint8List ref = Uint8List(n);
  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      final double dx = x - cx, dy = y - cy;
      if (cmap[y * size + x] == 3 && dx * dx + dy * dy < rad * rad) ref[y * size + x] = 1;
    }
  }
  ref = _erode4(_erode4(ref, size), size);
  int cnt = 0;
  double ma = 0, mb = 0;
  for (int i = 0; i < n; i++) {
    if (ref[i] == 1) {
      cnt++;
      ma += la[i];
      mb += lb[i];
    }
  }
  if (cnt < 30) return null;
  ma /= cnt;
  mb /= cnt;
  double saa = 2, sab = 0, sbb = 2;
  for (int i = 0; i < n; i++) {
    if (ref[i] == 1) {
      final double da = la[i] - ma, db = lb[i] - mb;
      saa += da * da / cnt;
      sab += da * db / cnt;
      sbb += db * db / cnt;
    }
  }
  final double det = saa * sbb - sab * sab;
  if (det <= 1e-9) return null;
  final double iaa = sbb / det, iab = -sab / det, ibb = saa / det;
  bool cand(int i) {
    final int c = cmap[i];
    if (c == 0 || c == 1 || c == 3 || ll[i] <= 24) return false;
    final double da = la[i] - ma, db = lb[i] - mb;
    return math.sqrt(math.max(0, iaa * da * da + 2 * iab * da * db + ibb * db * db)) < 2.5;
  }

  final Uint8List keep = Uint8List(n);
  final Int16List dist = Int16List(n);
  final List<int> queue = <int>[];
  for (int i = 0; i < n; i++) {
    if (cmap[i] == 2) {
      keep[i] = 1;
      queue.add(i);
    }
  }
  int head = 0;
  while (head < queue.length) {
    final int i = queue[head++];
    if (dist[i] >= 10) continue;
    final int x = i % size, y = i ~/ size;
    void tryAt(int j) {
      if (keep[j] == 0 && cand(j)) {
        keep[j] = 1;
        dist[j] = dist[i] + 1;
        queue.add(j);
      }
    }

    if (x > 0) tryAt(i - 1);
    if (x < size - 1) tryAt(i + 1);
    if (y > 0) tryAt(i - size);
    if (y < size - 1) tryAt(i + size);
  }
  return keep;
}

/// L'image de la partie [cls] (255 dedans, 0 dehors, bords adoucis), de [pw] x [ph] octets pour une photo de [imgW] x [imgH].
///
/// [probs] : [kBodyClasses] plans de [size] x [size] octets (probabilité x 255) du carré [crop]. Une zone de la classe
/// n'est gardée que si elle touche [anchor] (pixels de la photo). [guide] : la photo en niveaux de gris, [pw] x [ph] ; si elle
/// est donnée, les bords sont recalés dessus (filtre guidé, rayon = 1,5 pixel du modèle). [faces] : pour chaque personne de la photo,
/// [centre x, centre y, largeur du visage] en pixels ; chaque zone va à la personne dont le visage est le plus proche (jamais par bandes),
/// pour que la partie suive la personne choisie ([self]). [anchors] : l'ancre de chaque personne ; des vêtements touchant plusieurs ancres sont écartés.
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
  List<List<double>>? anchors,
  Uint8List? rgba,
  int self = 0,
}) {
  final int n = size * size;
  final Uint8List out = Uint8List(pw * ph);
  if (probs.length < n * kBodyClasses || cls < 0 || cls >= kBodyClasses || crop.side <= 0) return out;
  // 1. pixels dont la classe est la plus probable
  final Uint8List isCls = Uint8List(n);
  final Uint8List cmap = Uint8List(n);
  for (int i = 0; i < n; i++) {
    int best = 0, bv = probs[i];
    for (int k = 1; k < kBodyClasses; k++) {
      final int v = probs[k * n + i];
      if (v > bv) {
        bv = v;
        best = k;
      }
    }
    cmap[i] = best;
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
  // peau du corps : le modèle ne reconnaît que quelques taches ; la zone est étendue par la couleur de la peau du visage de la personne
  bool skinMode = false;
  if (cls == kBodyPartClass['bodyskin'] && rgba != null && faces != null && self >= 0 && self < faces.length) {
    final Uint8List? sk = skinKeep(cmap, size, crop, rgba, imgW, imgH, faces[self]);
    if (sk != null) {
      keep.setAll(0, sk);
      skinMode = true;
    }
  }
  // cheveux de plusieurs personnes : chaque pixel de la classe « cheveux » va à la tête la plus proche (rayon limité à 1,8 largeur de visage, mesuré depuis le centre de la tête) ;
  // plus fiable que le choix par zones, qui dépend de la position exacte des cadres des visages
  final bool hairNear = cls == kBodyPartClass['hair'] && faces != null && faces.length > 1 && self >= 0 && self < faces.length;
  if (hairNear) {
    for (int i = 0; i < n; i++) {
      if (isCls[i] != 1) continue;
      final double phx = crop.x0 + ((i % size) + 0.5) / sc, phy = crop.y0 + ((i ~/ size) + 0.5) / sc;
      // distance brute au centre de la tête (un peu au-dessus du centre du visage : les cheveux sont surtout au-dessus) ;
      // normalisée par la largeur, elle favoriserait les grands visages et déborderait sur les cheveux des voisins
      int near = 0;
      double nd = double.infinity, own = double.infinity;
      for (int k = 0; k < faces.length; k++) {
        final double dx = phx - faces[k][0], dy = phy - (faces[k][1] - 0.3 * faces[k][2]);
        final double d = math.sqrt(dx * dx + dy * dy);
        if (k == self) own = d;
        if (d < nd) {
          nd = d;
          near = k;
        }
      }
      keep[i] = (near == self && own < 1.8 * math.max(1.0, faces[self][2])) ? 1 : 0;
    }
  }
  if (skinMode) {
    bool any = false;
    for (int i = 0; i < n && !any; i++) {
      any = keep[i] == 1;
    }
    if (!any) return out;
  } else if (hairNear) {
    bool any = false;
    for (int i = 0; i < n && !any; i++) {
      any = keep[i] == 1;
    }
    if (!any) return out;
  } else if (queue.isEmpty) {
    return out;
  }
  // 3. probabilité de la classe dans les zones gardées, remise à l'échelle de la photo (bilinéaire), puis contraste autour de 50 %
  final Uint8List soft = Uint8List(n);
  final List<List<double>>? all = faces;
  final bool split = all != null && all.length > 1 && self >= 0 && self < all.length;
  if (hairNear) {
    for (int i = 0; i < n; i++) {
      if (keep[i] == 1) soft[i] = probs[cls * n + i];
    }
  } else if (split) {
    // Attribution par zone (et non par bande verticale) : chaque zone connexe va à la personne dont le visage est le plus proche ;
    // une zone de vêtements qui touche les ancres de plusieurs personnes (corps collés) ne peut pas être répartie : elle est écartée.
    final Int32List lab = Int32List(n);
    int count = 0;
    for (int s0 = 0; s0 < n; s0++) {
      if (keep[s0] != 1 || lab[s0] != 0) continue;
      count++;
      final List<int> q = <int>[s0];
      lab[s0] = count;
      int h = 0;
      int touched = 0;
      final List<double> bd = List<double>.filled(all!.length, double.infinity);
      while (h < q.length) {
        final int i = q[h++];
        final int x = i % size, y = i ~/ size;
        final double phx = crop.x0 + (x + 0.5) / sc, phy = crop.y0 + (y + 0.5) / sc;
        for (int k = 0; k < all.length; k++) {
          final double dx = phx - all[k][0], dy = phy - all[k][1];
          final double d = math.sqrt(dx * dx + dy * dy) / math.max(1.0, all[k][2]);
          if (d < bd[k]) bd[k] = d;
          if (anchors != null && k < anchors.length) {
            final List<double> a = anchors[k];
            if (phx >= a[0] && phx < a[2] && phy >= a[1] && phy < a[3]) touched |= 1 << k;
          }
        }
        if (x > 0 && keep[i - 1] == 1 && lab[i - 1] == 0) {
          lab[i - 1] = count;
          q.add(i - 1);
        }
        if (x < size - 1 && keep[i + 1] == 1 && lab[i + 1] == 0) {
          lab[i + 1] = count;
          q.add(i + 1);
        }
        if (y > 0 && keep[i - size] == 1 && lab[i - size] == 0) {
          lab[i - size] = count;
          q.add(i - size);
        }
        if (y < size - 1 && keep[i + size] == 1 && lab[i + size] == 0) {
          lab[i + size] = count;
          q.add(i + size);
        }
      }
      // cheveux : une zone qui touche les ancres de plusieurs personnes (têtes collées) est répartie pixel par pixel, chaque pixel allant
      // à la tête la plus proche (les têtes sont rondes et séparées, contrairement aux vêtements)
      if (cls == kBodyPartClass['hair'] && (touched & (touched - 1)) != 0) {
        for (final int i in q) {
          final double phx = crop.x0 + ((i % size) + 0.5) / sc, phy = crop.y0 + ((i ~/ size) + 0.5) / sc;
          int near = 0;
          double nd = double.infinity;
          for (int k = 0; k < all.length; k++) {
            final double dx = phx - all[k][0], dy = phy - all[k][1];
            final double d = math.sqrt(dx * dx + dy * dy) / math.max(1.0, all[k][2]);
            if (d < nd) {
              nd = d;
              near = k;
            }
          }
          if (near == self) soft[i] = probs[cls * n + i];
        }
        continue;
      }
      int owner = 0;
      for (int k = 1; k < all.length; k++) {
        if (bd[k] < bd[owner]) owner = k;
      }
      final bool shared = cls == kBodyPartClass['clothes'] && (touched & (touched - 1)) != 0;
      if (owner != self || shared) continue;
      for (final int i in q) {
        soft[i] = skinMode ? 255 : probs[cls * n + i];
      }
    }
  } else {
    for (int i = 0; i < n; i++) {
      if (keep[i] == 1) soft[i] = skinMode ? 255 : probs[cls * n + i];
    }
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

/// Rééchantillonne un plan 8 bits [sw]×[sh] en [dw]×[dh] (interpolation bilinéaire).
Uint8List resamplePlane(Uint8List src, int sw, int sh, int dw, int dh) {
  if (sw == dw && sh == dh) return Uint8List.fromList(src);
  final Uint8List out = Uint8List(dw * dh);
  for (int y = 0; y < dh; y++) {
    final double fy = ((y + 0.5) * sh / dh - 0.5).clamp(0, sh - 1).toDouble();
    final int y0 = fy.floor(), y1 = math.min(y0 + 1, sh - 1);
    final double ty = fy - y0;
    for (int x = 0; x < dw; x++) {
      final double fx = ((x + 0.5) * sw / dw - 0.5).clamp(0, sw - 1).toDouble();
      final int x0 = fx.floor(), x1 = math.min(x0 + 1, sw - 1);
      final double tx = fx - x0;
      final double a = src[y0 * sw + x0] * (1 - tx) + src[y0 * sw + x1] * tx;
      final double b = src[y1 * sw + x0] * (1 - tx) + src[y1 * sw + x1] * tx;
      out[y * dw + x] = (a * (1 - ty) + b * ty).round().clamp(0, 255).toInt();
    }
  }
  return out;
}

/// Réunion (maximum) de plusieurs plans de même taille ; [into] reçoit le résultat.
void unionPlanes(Uint8List into, Uint8List other) {
  for (int i = 0; i < into.length; i++) {
    if (other[i] > into[i]) into[i] = other[i];
  }
}

Uint8List _morph(Uint8List src, int pw, int ph, int r, bool minMode) {
  final Uint8List tmp = Uint8List(pw * ph), out = Uint8List(pw * ph);
  for (int y = 0; y < ph; y++) {
    for (int x = 0; x < pw; x++) {
      int v = minMode ? 255 : 0;
      for (int k = math.max(0, x - r); k <= math.min(pw - 1, x + r); k++) {
        final int c = src[y * pw + k];
        if (minMode ? c < v : c > v) v = c;
      }
      tmp[y * pw + x] = v;
    }
  }
  for (int y = 0; y < ph; y++) {
    for (int x = 0; x < pw; x++) {
      int v = minMode ? 255 : 0;
      for (int k = math.max(0, y - r); k <= math.min(ph - 1, y + r); k++) {
        final int c = tmp[k * pw + x];
        if (minMode ? c < v : c > v) v = c;
      }
      out[y * pw + x] = v;
    }
  }
  return out;
}

/// Nettoie un plan obtenu par soustraction : une ouverture (érosion puis dilatation, carré de rayon [r]) supprime les bandes plus fines que
/// 2 x [r] + 1 pixels (résidus le long des bords des autres silhouettes), puis seules les zones d'au moins [minShare] de la plus grande sont gardées.
Uint8List cleanPlane(Uint8List plane, int pw, int ph, int r, {double minShare = 0.15}) {
  if (plane.length < pw * ph || pw <= 0 || ph <= 0 || r < 1) return plane;
  final Uint8List o = _morph(_morph(plane, pw, ph, r, true), pw, ph, r, false);
  final Int32List lab = Int32List(pw * ph);
  final List<int> sizes = <int>[0];
  for (int s0 = 0; s0 < pw * ph; s0++) {
    if (o[s0] <= 127 || lab[s0] != 0) continue;
    final int id = sizes.length;
    int count = 0;
    final List<int> q = <int>[s0];
    lab[s0] = id;
    int h = 0;
    while (h < q.length) {
      final int i = q[h++];
      count++;
      final int x = i % pw, y = i ~/ pw;
      if (x > 0 && o[i - 1] > 127 && lab[i - 1] == 0) {
        lab[i - 1] = id;
        q.add(i - 1);
      }
      if (x < pw - 1 && o[i + 1] > 127 && lab[i + 1] == 0) {
        lab[i + 1] = id;
        q.add(i + 1);
      }
      if (y > 0 && o[i - pw] > 127 && lab[i - pw] == 0) {
        lab[i - pw] = id;
        q.add(i - pw);
      }
      if (y < ph - 1 && o[i + pw] > 127 && lab[i + pw] == 0) {
        lab[i + pw] = id;
        q.add(i + pw);
      }
    }
    sizes.add(count);
  }
  int biggest = 0;
  for (final int c in sizes) {
    if (c > biggest) biggest = c;
  }
  final Uint8List out = Uint8List(pw * ph);
  for (int i = 0; i < pw * ph; i++) {
    final int l = lab[i];
    if (l != 0 && sizes[l] >= biggest * minShare) out[i] = o[i];
  }
  return out;
}
