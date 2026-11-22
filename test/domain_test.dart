import 'package:flutter_test/flutter_test.dart';

import 'package:sursaut_essai/domain/crop_math.dart';
import 'package:sursaut_essai/domain/curves.dart';
import 'package:sursaut_essai/domain/develop_params.dart';
import 'package:sursaut_essai/domain/photo_key.dart';
import 'package:sursaut_essai/domain/recipe_history.dart';
import 'package:sursaut_essai/domain/sidecar.dart';

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

  test('sidecar : valeur par défaut non nulle (cadre plein) non écrite', () {
    final SidecarData d = SidecarData.empty();
    expect(d.isEmpty, isTrue);
    final Iterable<String> keys = defaultValues().keys;
    expect(d.encode(defaultValues(), keys, defaults: kParamDefaults), '{}');
    final Map<String, double> cut = defaultValues()
      ..['crop_left'] = 0.1
      ..['crop_right'] = 0.9;
    final String out = d.encode(cut, keys, defaults: kParamDefaults);
    expect(out.contains('"crop_left": 0.1'), isTrue);
    expect(out.contains('"crop_right": 0.9'), isTrue);
    expect(out.contains('crop_top'), isFalse);
  });

  test('recette envoyée au moteur : clés inconnues + réglages', () {
    final SidecarData d =
        SidecarData(<String, double>{}, <String, dynamic>{'preset': 'x'});
    expect(d.recipe(<String, double>{'exposure': 1}),
        <String, dynamic>{'preset': 'x', 'exposure': 1.0});
  });

  test('valeurs par défaut', () {
    final Map<String, double> v = defaultValues();
    expect(v['exposure'], 0);
    expect(v['crop_right'], 1);
    expect(v.length, kDevelopParams.length + kHslParams.length + kDetailParams.length + kCropDefaults.length);
    expect(defaultOf('crop_bottom'), 1);
    expect(defaultOf('angle'), 0);
  });

  test('photoKey : stable pour le même contenu, différent sinon', () {
    final List<int> a = List<int>.generate(4000, (int i) => i % 251);
    final List<int> b = List<int>.of(a)..[97 * 5] = 7;
    expect(photoKey(a, 40, 25), photoKey(List<int>.of(a), 40, 25));
    expect(photoKey(a, 40, 25), isNot(photoKey(b, 40, 25)));
    expect(photoKey(a, 40, 25), isNot(photoKey(a, 25, 40)));
  });

  test('cadre à rapport imposé : bon rapport, reste dans l\'image', () {
    // Image 3000×2000 (3:2). Cadre plein, on impose 1:1.
    final CropBox sq = fitAspect(CropBox.full, 1.0, 3000, 2000);
    expect((sq.width * 3000) / (sq.height * 2000), closeTo(1.0, 1e-9));
    expect(sq.left >= 0 && sq.top >= 0 && sq.right <= 1 && sq.bottom <= 1, isTrue);
    // 16:9 depuis le cadre plein : toute la largeur, hauteur réduite.
    final CropBox wide = fitAspect(CropBox.full, 16 / 9, 3000, 2000);
    expect((wide.width * 3000) / (wide.height * 2000), closeTo(16 / 9, 1e-9));
    expect(wide.width, closeTo(1.0, 1e-9));
    // Portrait 2:3 : toute la hauteur.
    final CropBox tall = fitAspect(CropBox.full, 2 / 3, 3000, 2000);
    expect(tall.height, closeTo(1.0, 1e-9));
  });

  test('courbe : identité, points, spline monotone', () {
    expect(isIdentityCurve(identityCurve()), isTrue);
    final List<double> id = curveSamples(identityCurve(), size: 5);
    expect(id[0], closeTo(0, 1e-9));
    expect(id[2], closeTo(0.5, 1e-9));
    expect(id[4], closeTo(1, 1e-9));
    final (CurvePoints a, int i) = addCurvePoint(identityCurve(), 0.5, 0.7);
    expect(i, 1);
    expect(a.length, 3);
    final List<double> s = curveSamples(a, size: 101);
    expect(s[50], closeTo(0.7, 1e-9));
    for (int k = 1; k < s.length; k++) {
      expect(s[k] >= s[k - 1] - 1e-12, isTrue);
    }
    final CurvePoints moved = moveCurvePoint(a, 1, 0.9, 0.2);
    expect(moved[1][0], lessThan(1));
    expect(moveCurvePoint(a, 0, 0.5, 0.3)[0], <double>[0, 0.3]);
    expect(removeCurvePoint(a, 1).length, 2);
    expect(removeCurvePoint(a, 0).length, 3);
  });

  test('courbes : lecture et écriture dans la recette', () {
    final (Map<String, CurvePoints> c, Map<String, dynamic> rest) = splitCurves(<String, dynamic>{
      'curve': <dynamic>[<dynamic>[0, 0], <dynamic>[0.5, 0.6], <dynamic>[1, 1]],
      'curve_red': <dynamic>[<dynamic>[0, 0], <dynamic>[1, 1]],
      'preset': 'x',
    });
    expect(c.keys, <String>['rvb']);
    expect(rest, <String, dynamic>{'preset': 'x'});
    final Map<String, dynamic> j = curvesToJson(c);
    expect(j.keys, <String>['curve']);
    expect(curvesToJson(<String, CurvePoints>{'rvb': identityCurve()}), isEmpty);
  });

  test('historique : les courbes sont annulables', () {
    final RecipeHistory h = RecipeHistory(<String, double>{'a': 0});
    final Map<String, CurvePoints> c = <String, CurvePoints>{
      'rvb': <List<double>>[<double>[0, 0], <double>[0.5, 0.7], <double>[1, 1]],
    };
    h.commit(<String, double>{'a': 0}, curves: c);
    expect(h.canUndo, isTrue);
    expect(h.currentCurves['rvb']!.length, 3);
    h.undo();
    expect(h.currentCurves, isEmpty);
    h.redo();
    expect(h.currentCurves['rvb']![1], <double>[0.5, 0.7]);
  });
}
