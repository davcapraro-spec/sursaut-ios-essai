import 'dart:math' as math;

// Informations de prise de vue lues dans le RAW, mises en forme pour l'affichage.

/// Vitesse : « 1/250 s », « 0,5 s », « 2 s ». Vide si inconnue.
String formatShutter(num? seconds) {
  if (seconds == null || seconds <= 0) return '';
  if (seconds < 0.4) return '1/${(1 / seconds).round()} s';
  final double v = seconds.toDouble();
  final String t = v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1).replaceAll('.', ',');
  return '$t s';
}

/// Date de prise de vue « 22/11/2026 14:32 ». LibRaw donne l'heure de l'appareil sans fuseau : on l'affiche telle quelle.
String formatShotTime(num? epochSeconds) {
  if (epochSeconds == null || epochSeconds <= 0) return '';
  final DateTime d = DateTime.fromMillisecondsSinceEpoch(epochSeconds.round() * 1000, isUtc: true);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
}

/// Lignes d'information : [0] boîtier + objectif, [1] réglages de prise de vue + date. Les valeurs inconnues sont omises.
List<String> shootLines(Map<String, dynamic> info) {
  String text(String k) => '${info[k] ?? ''}'.trim();
  num? number(String k) => info[k] is num ? info[k] as num : null;
  final String make = text('make'), model = text('model');
  final String body = model.isEmpty
      ? make
      : (make.isNotEmpty && !model.toLowerCase().startsWith(make.toLowerCase()) ? '$make $model' : model);
  final String lens = text('lens');
  final num? focal = number('focal_len'), ap = number('aperture'), iso = number('iso');
  final String f = ap != null && ap > 0
      ? 'f/${ap == ap.roundToDouble() ? ap.round() : ap.toStringAsFixed(1).replaceAll('.', ',')}'
      : '';
  final List<String> second = <String>[
    if (focal != null && focal > 0) '${focal.round()} mm',
    if (f.isNotEmpty) f,
    if (formatShutter(number('shutter')).isNotEmpty) formatShutter(number('shutter')),
    if (iso != null && iso > 0) 'ISO ${iso.round()}',
    if (formatShotTime(number('timestamp')).isNotEmpty) formatShotTime(number('timestamp')),
  ];
  return <String>[
    <String>[if (body.isNotEmpty) body, if (lens.isNotEmpty) lens].join(' · '),
    second.join(' · '),
  ];
}

/// Le curseur unique de réduction du bruit règle la couleur à 80 % de la luminosité (comme le PC).
const double kDenoiseColorRatio = 0.8;

/// Quantité de réduction du bruit proposée d'après l'ISO (même courbe que le PC) : rien jusqu'à 400,
/// puis +28 par cran (ISO ×2), plafonné à 100. Null si l'ISO est inconnu.
int? suggestDenoiseAmount(num? iso) {
  if (iso == null || iso <= 0) return null;
  final double v = 28.0 * (math.log(iso / 400.0) / math.ln2);
  return v.clamp(0.0, 100.0).round();
}

/// Conseil (jamais appliqué tout seul) à partir de l'ISO 1000 ; null en dessous ou si l'ISO est inconnu.
String? noiseAdvice(num? iso) {
  if (iso == null || iso < 1000) return null;
  return 'ISO ${iso.round()} : une réduction du bruit peut aider (bouton Auto ci-dessous).';
}
