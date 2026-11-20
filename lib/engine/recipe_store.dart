import 'dart:convert';

/// Historique annuler/rétablir d'une recette (réglages numériques à plat).
///
/// Chaque entrée est une copie complète des valeurs. Seules les validations
/// (fin de glissement, double-tap, chargement) créent une entrée : un glissement
/// complet = une seule étape d'annulation.
class RecipeHistory {
  RecipeHistory(Map<String, double> initial, {this.limit = 200})
      : _states = <Map<String, double>>[Map<String, double>.of(initial)];

  final int limit;
  final List<Map<String, double>> _states;
  int _pos = 0;

  Map<String, double> get current => Map<String, double>.of(_states[_pos]);
  bool get canUndo => _pos > 0;
  bool get canRedo => _pos < _states.length - 1;

  /// Enregistre un nouvel état. Sans effet s'il est identique à l'état courant.
  void commit(Map<String, double> values) {
    if (_same(_states[_pos], values)) return;
    _states.removeRange(_pos + 1, _states.length);
    _states.add(Map<String, double>.of(values));
    if (_states.length > limit) {
      _states.removeAt(0);
    }
    _pos = _states.length - 1;
  }

  Map<String, double>? undo() {
    if (!canUndo) return null;
    _pos--;
    return current;
  }

  Map<String, double>? redo() {
    if (!canRedo) return null;
    _pos++;
    return current;
  }

  static bool _same(Map<String, double> a, Map<String, double> b) {
    if (a.length != b.length) return false;
    for (final MapEntry<String, double> e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }
}

/// Lecture / écriture du fichier `.sursaut.json` (même format que le PC :
/// un objet JSON à plat, clés absentes = valeurs par défaut, clés inconnues ignorées
/// par le moteur mais CONSERVÉES ici pour ne rien perdre d'un réglage fait sur PC).
class SidecarData {
  SidecarData(this.values, this.extra);
  final Map<String, double> values;
  final Map<String, dynamic> extra;

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

  /// Texte à écrire : les clés inconnues d'abord, puis les réglages à valeur non nulle.
  String encode(Map<String, double> current, Iterable<String> keys) {
    final Map<String, dynamic> out = <String, dynamic>{...extra};
    for (final String k in keys) {
      final double v = current[k] ?? 0;
      if (v != 0) {
        out[k] = v;
      } else {
        out.remove(k);
      }
    }
    return const JsonEncoder.withIndent('  ').convert(out);
  }
}

/// Identifiant stable d'une photo, calculé sur son contenu (et non sur son nom :
/// iPadOS donne un nom temporaire différent à chaque import depuis la bibliothèque).
/// Empreinte FNV-1a 64 bits sur les dimensions et un échantillon régulier des pixels.
String photoKey(List<int> rgba, int w, int h) {
  const int prime = 0x100000001b3;
  int hash = 0xcbf29ce484222325;
  void mix(int v) {
    hash = (hash ^ (v & 0xFF)) * prime;
  }

  for (final int v in <int>[w, h, w >> 8, h >> 8]) {
    mix(v);
  }
  const int step = 97;
  for (int i = 0; i < rgba.length; i += step) {
    mix(rgba[i]);
  }
  return 'photo_${hash.toUnsigned(64).toRadixString(16).padLeft(16, '0')}';
}
