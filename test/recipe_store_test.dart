import 'package:flutter_test/flutter_test.dart';

import 'package:sursaut_essai/engine/recipe_store.dart';

void main() {
  test('annuler / rétablir', () {
    final RecipeHistory h = RecipeHistory(<String, double>{'a': 0});
    expect(h.canUndo, isFalse);
    h.commit(<String, double>{'a': 10});
    h.commit(<String, double>{'a': 20});
    expect(h.undo(), <String, double>{'a': 10});
    expect(h.undo(), <String, double>{'a': 0});
    expect(h.undo(), isNull);
    expect(h.redo(), <String, double>{'a': 10});
    h.commit(<String, double>{'a': 5}); // coupe la branche rétablir
    expect(h.canRedo, isFalse);
    expect(h.current, <String, double>{'a': 5});
  });

  test('état identique ignoré, limite respectée', () {
    final RecipeHistory h = RecipeHistory(<String, double>{'a': 0}, limit: 3);
    h.commit(<String, double>{'a': 0});
    expect(h.canUndo, isFalse);
    for (int i = 1; i <= 10; i++) {
      h.commit(<String, double>{'a': i.toDouble()});
    }
    int n = 0;
    while (h.undo() != null) {
      n++;
    }
    expect(n, 2);
  });

  test('sidecar : lecture, conservation des clés inconnues, écriture', () {
    const List<String> keys = <String>['exposure', 'contrast'];
    final SidecarData? d = SidecarData.parse(
        '{"exposure":0.5,"crop_left":0.1,"preset":"x","contrast":0}', keys);
    expect(d, isNotNull);
    expect(d!.values, <String, double>{'exposure': 0.5, 'contrast': 0});
    expect(d.extra.keys.toSet(), <String>{'crop_left', 'preset'});
    final String out = d.encode(<String, double>{'exposure': 1.0, 'contrast': 0}, keys);
    expect(out.contains('"exposure": 1.0'), isTrue);
    expect(out.contains('contrast'), isFalse);
    expect(out.contains('crop_left'), isTrue);
  });

  test('sidecar invalide', () {
    expect(SidecarData.parse('pas du json', <String>['a']), isNull);
    expect(SidecarData.parse('[1,2]', <String>['a']), isNull);
  });
}
