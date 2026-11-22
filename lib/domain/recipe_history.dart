import 'curves.dart';

/// Historique annuler/rétablir d'une recette : réglages numériques à plat + courbes de tonalité.
///
/// Chaque entrée est une copie complète. Seules les validations (fin de glissement,
/// double-tap, chargement) créent une entrée : un glissement complet = une seule étape d'annulation.
class RecipeHistory {
  RecipeHistory(Map<String, double> initial,
      {Map<String, CurvePoints> curves = const <String, CurvePoints>{}, this.limit = 200})
      : _states = <_State>[_State(Map<String, double>.of(initial), _copyCurves(curves))];

  final int limit;
  final List<_State> _states;
  int _pos = 0;

  Map<String, double> get current => Map<String, double>.of(_states[_pos].values);
  Map<String, CurvePoints> get currentCurves => _copyCurves(_states[_pos].curves);
  bool get canUndo => _pos > 0;
  bool get canRedo => _pos < _states.length - 1;

  /// Enregistre un nouvel état. Sans effet s'il est identique à l'état courant.
  void commit(Map<String, double> values,
      {Map<String, CurvePoints> curves = const <String, CurvePoints>{}}) {
    final _State s = _states[_pos];
    if (_same(s.values, values) && curvesEqual(s.curves, curves)) return;
    _states.removeRange(_pos + 1, _states.length);
    _states.add(_State(Map<String, double>.of(values), _copyCurves(curves)));
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

  static Map<String, CurvePoints> _copyCurves(Map<String, CurvePoints> c) => <String, CurvePoints>{
        for (final MapEntry<String, CurvePoints> e in c.entries)
          e.key: <List<double>>[for (final List<double> p in e.value) <double>[p[0], p[1]]],
      };
}

class _State {
  _State(this.values, this.curves);
  final Map<String, double> values;
  final Map<String, CurvePoints> curves;
}
