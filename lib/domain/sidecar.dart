import 'dart:convert';

/// Lecture / écriture du fichier `.sursaut.json` (même format que le PC :
/// un objet JSON à plat, clés absentes = valeurs par défaut, clés inconnues ignorées
/// par le moteur mais CONSERVÉES ici pour ne rien perdre d'un réglage fait sur PC).
class SidecarData {
  SidecarData(this.values, this.extra);

  /// Fichier vide (photo jamais retouchée).
  factory SidecarData.empty() => SidecarData(<String, double>{}, <String, dynamic>{});

  final Map<String, double> values;
  final Map<String, dynamic> extra;

  bool get isEmpty => values.isEmpty && extra.isEmpty;

  /// Lit [text]. [keys] = réglages que cet écran sait modifier.
  /// Renvoie null si le texte n'est pas un objet JSON valide.
  static SidecarData? parse(String text, Iterable<String> keys) {
    final Object? raw;
    try {
      raw = jsonDecode(text);
    } catch (_) {
      return null;
    }
    if (raw is! Map<String, dynamic>) return null;
    final Set<String> known = keys.toSet();
    final Map<String, double> values = <String, double>{};
    final Map<String, dynamic> extra = <String, dynamic>{};
    raw.forEach((String k, dynamic v) {
      if (known.contains(k) && v is num) {
        values[k] = v.toDouble();
      } else {
        extra[k] = v;
      }
    });
    return SidecarData(values, extra);
  }

  /// Recette complète envoyée au moteur : clés inconnues + réglages.
  Map<String, dynamic> recipe(Map<String, double> current) =>
      <String, dynamic>{...extra, ...current};

  /// Texte à écrire : les clés inconnues d'abord, puis les réglages différents de leur défaut.
  String encode(Map<String, double> current, Iterable<String> keys,
      {Map<String, double> defaults = const <String, double>{}}) {
    final Map<String, dynamic> out = <String, dynamic>{...extra};
    for (final String k in keys) {
      final double def = defaults[k] ?? 0;
      final double v = current[k] ?? def;
      if (v != def) {
        out[k] = v;
      } else {
        out.remove(k);
      }
    }
    return const JsonEncoder.withIndent('  ').convert(out);
  }
}
