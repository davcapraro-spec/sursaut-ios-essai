/// Rectangle de recadrage en fractions (0..1) de l'image redressée, comme
/// `crop_left/top/right/bottom` du moteur.
class CropBox {
  const CropBox(this.left, this.top, this.right, this.bottom);

  static const CropBox full = CropBox(0, 0, 1, 1);

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;
  double get centerX => (left + right) / 2;
  double get centerY => (top + bottom) / 2;
}

/// Plus grand cadre de rapport [aspect] (largeur/hauteur en pixels) contenu dans
/// [cur], centré sur lui, pour une image de [imageW]×[imageH] pixels.
CropBox fitAspect(CropBox cur, double aspect, int imageW, int imageH) {
  final double k = imageW / (aspect * imageH); // hauteur/largeur en fractions
  double fw = cur.width < cur.height / k ? cur.width : cur.height / k;
  double fh = fw * k;
  if (fw > 1) {
    fw = 1;
    fh = k;
  }
  if (fh > 1) {
    fh = 1;
    fw = 1 / k;
  }
  double l = cur.centerX - fw / 2;
  double t = cur.centerY - fh / 2;
  l = l < 0 ? 0 : (l + fw > 1 ? 1 - fw : l);
  t = t < 0 ? 0 : (t + fh > 1 ? 1 - fh : t);
  return CropBox(l, t, l + fw, t + fh);
}
