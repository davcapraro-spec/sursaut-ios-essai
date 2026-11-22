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
