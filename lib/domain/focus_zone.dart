/// Zone où le point de mise au point peut être placé, apprise en touchant près des bords.
///
/// L'appareil ne donne pas toujours sa zone (propriété 0xD267 absente sur l'A7 IV de David, 27/11/2026). Quand on touche près d'un bord
/// et que le cadre revenu de l'appareil s'arrête plus à l'intérieur, la position où il s'arrête est la limite de cette zone.
/// Les valeurs sont sur la grille 640 x 480 de l'appareil.
class FocusZone {
  const FocusZone({this.xMin, this.yMin, this.xMax, this.yMax});

  final int? xMin;
  final int? yMin;
  final int? xMax;
  final int? yMax;

  bool get known => xMin != null || yMin != null || xMax != null || yMax != null;

  /// Zone complète : les limites apprises, ou le bord de la grille pour les côtés pas encore appris.
  List<int> asArea() => <int>[xMin ?? 0, yMin ?? 0, xMax ?? 639, yMax ?? 479];

  FocusZone copyWith({int? xMin, int? yMin, int? xMax, int? yMax}) =>
      FocusZone(xMin: xMin ?? this.xMin, yMin: yMin ?? this.yMin, xMax: xMax ?? this.xMax, yMax: yMax ?? this.yMax);
}

/// Part de l'image (de chaque côté) où un toucher compte comme « près du bord ».
const double kEdgeBand = 0.2;

/// Écart minimal (part de l'image) entre le point demandé et le cadre revenu pour conclure que l'appareil a limité le déplacement.
const double kClampGap = 0.02;

/// Compare le point demandé ([tx], [ty], parts de l'image 0..1) au centre du cadre revenu de l'appareil ([cx], [cy]) :
/// si le toucher était près d'un bord et que le cadre s'est arrêté plus à l'intérieur (sans dépasser la moitié de l'image),
/// la position du cadre devient la limite de ce côté. Rend la zone mise à jour.
FocusZone learnFocusZone(FocusZone zone, {required double tx, required double ty, required double cx, required double cy}) {
  FocusZone z = zone;
  if (tx < kEdgeBand && cx > tx + kClampGap && cx < 0.5) z = z.copyWith(xMin: (cx * 639).round());
  if (tx > 1 - kEdgeBand && cx < tx - kClampGap && cx > 0.5) z = z.copyWith(xMax: (cx * 639).round());
  if (ty < kEdgeBand && cy > ty + kClampGap && cy < 0.5) z = z.copyWith(yMin: (cy * 479).round());
  if (ty > 1 - kEdgeBand && cy < ty - kClampGap && cy > 0.5) z = z.copyWith(yMax: (cy * 479).round());
  return z;
}
