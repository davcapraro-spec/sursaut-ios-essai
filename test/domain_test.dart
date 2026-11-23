import 'package:flutter_test/flutter_test.dart';

import 'package:sursaut_essai/domain/crop_math.dart';
import 'dart:convert';
import 'dart:io';

import 'package:sursaut_essai/domain/curves.dart';
import 'package:sursaut_essai/domain/lens_profiles.dart';
import 'package:sursaut_essai/domain/masks.dart';
import 'package:sursaut_essai/domain/develop_params.dart';
import 'package:sursaut_essai/domain/photo_key.dart';
import 'package:sursaut_essai/domain/recipe_history.dart';
import 'package:sursaut_essai/domain/shoot_info.dart';
import 'package:sursaut_essai/domain/sidecar.dart';
import 'package:sursaut_essai/domain/spots.dart';

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
    expect(v.length, kDevelopParams.length + kHslParams.length + kDetailParams.length + kLensParams.length + kCropDefaults.length);
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

  test('profil d\'objectif : nom comparable et interpolation', () {
    expect(normalizeLensName('Sony FE 24-70mm f/2.8 GM II'), normalizeLensName('FE 24-70mm F2.8 GM II'));
    final Map<String, dynamic> db = <String, dynamic>{
      'lenses': <dynamic>[
        <String, dynamic>{
          'maker': 'Sony',
          'model': 'FE 50mm f/1.8',
          'min_focal': 50.0,
          'focals': <dynamic>[50.0],
          'geo': <String, dynamic>{'50.0': <dynamic>[1.0, 1.02]},
          'ca_r': <String, dynamic>{'50.0': <dynamic>[1.0, 1.0]},
          'ca_b': <String, dynamic>{'50.0': <dynamic>[1.0, 1.0]},
        },
        <String, dynamic>{
          'maker': 'Zoom',
          'model': '20-40mm',
          'min_focal': 20.0,
          'focals': <dynamic>[20.0, 40.0],
          'geo': <String, dynamic>{
            '20.0': <dynamic>[1.0, 1.1],
            '40.0': <dynamic>[1.0, 1.3]
          },
        },
      ],
    };
    expect(findLens(db, 'sony FE 50 mm F1.8'), isNotNull); // marque et espaces ignorés
    expect(findLens(db, 'FE 85mm F1.8'), isNull);
    expect(findLens(db, 'FE 50mm F1.8'), isNotNull);
    expect(findLens(db, null), isNull);
    final Map<String, dynamic> p = lensProfileFor(db, 'Zoom 20-40mm', 30, 2.8)!;
    expect((p['geo'] as List<dynamic>)[1], closeTo(1.2, 1e-9));
    expect(p.containsKey('vig'), isFalse);
    expect(describeLensProfile(p), '20-40mm : distorsion'); // le nom est le modèle, sans la marque
  });

  test('profil d\'objectif : la vraie base trouve le FE 24-70 mm GM II', () {
    final Map<String, dynamic> db =
        jsonDecode(File('assets/lens_profiles.json').readAsStringSync()) as Map<String, dynamic>;
    final Map<String, dynamic>? p = lensProfileFor(db, 'FE 24-70mm F2.8 GM II', 66, 5.6);
    expect(p, isNotNull);
    expect((p!['geo'] as List<dynamic>).length, greaterThan(10));
    expect((p['ca_r'] as List<dynamic>).isNotEmpty, isTrue);
  });

  test('retouches : création, séparation du fichier, historique', () {
    final Spot a = newSpot(x: 0.2, y: 0.3, r: 0.01, sx: 0.25, sy: 0.3);
    expect(a['mode'], 'heal');
    final Spot b = newSpot(
        x: 0, y: 0, r: 0.02, sx: 0.5, sy: 0.5, mode: 'inconnu', stroke: <List<double>>[<double>[0.4, 0.4], <double>[0.5, 0.5]]);
    expect(b['mode'], 'heal');
    expect(b['x'], 0.4);
    final (List<Spot> spots, Map<String, dynamic> rest) =
        splitSpots(<String, dynamic>{'autre': 1, 'spots': <dynamic>[a, b]});
    expect(spots.length, 2);
    expect(rest.containsKey('spots'), isFalse);
    expect(rest['autre'], 1);
    final RecipeHistory h = RecipeHistory(<String, double>{'a': 0});
    h.commit(<String, double>{'a': 0}, spots: spots);
    expect(h.canUndo, isTrue);
    expect(h.currentSpots.length, 2);
    h.undo();
    expect(h.currentSpots, isEmpty);
    h.redo();
    expect(h.currentSpots.length, 2);
    h.currentSpots.first['x'] = 0.9; // copie : l'historique ne change pas
    expect(h.currentSpots.first['x'], 0.2);
  });

  test('poussière : seuil de sensibilité et retouches existantes', () {
    expect(dustThreshold(85), closeTo(3.9, 1e-9));
    expect(dustThreshold(100), closeTo(3.0, 1e-9));
    final List<Map<String, dynamic>> dust = <Map<String, dynamic>>[
      <String, dynamic>{'x': 0.5, 'y': 0.5, 'r': 0.005, 'score': 6.0, 'contrast': 10.0},
      <String, dynamic>{'x': 0.2, 'y': 0.2, 'r': 0.005, 'score': 3.5, 'contrast': 8.0},
      <String, dynamic>{'x': 0.8, 'y': 0.8, 'r': 0.005, 'score': 5.0, 'contrast': 9.0},
    ];
    final List<Spot> have = <Spot>[newSpot(x: 0.8, y: 0.8, r: 0.01, sx: 0.7, sy: 0.7)];
    // sensibilité 85 (seuil 3,9) : la 2e est trop faible, la 3e est déjà retouchée
    expect(keptDust(dust, have, 85, 1000, 800).length, 1);
    // sensibilité 100 (seuil 3) : la 2e est retenue aussi
    expect(keptDust(dust, have, 100, 1000, 800).length, 2);
  });

  test('informations de prise de vue : mise en forme', () {
    expect(formatShutter(0.004), '1/250 s');
    expect(formatShutter(0.5), '0,5 s');
    expect(formatShutter(2), '2 s');
    expect(formatShutter(0), '');
    expect(formatShotTime(1795357920), '22/11/2026 14:32');
    final List<String> l = shootLines(<String, dynamic>{
      'make': 'Sony',
      'model': 'ILCE-7M4',
      'lens': 'FE 24-70mm F2.8 GM II',
      'iso': 4000,
      'shutter': 0.004,
      'aperture': 5.6,
      'focal_len': 66.0,
      'timestamp': 0,
    });
    expect(l[0], 'Sony ILCE-7M4 · FE 24-70mm F2.8 GM II');
    expect(l[1], '66 mm · f/5,6 · 1/250 s · ISO 4000');
    expect(shootLines(<String, dynamic>{}), <String>['', '']);
  });

  test('réduction du bruit automatique d\'après l\'ISO (même courbe que le PC)', () {
    expect(suggestDenoiseAmount(null), isNull);
    expect(suggestDenoiseAmount(100), 0);
    expect(suggestDenoiseAmount(400), 0);
    expect(suggestDenoiseAmount(800), 22);
    expect(suggestDenoiseAmount(1600), 44);
    expect(suggestDenoiseAmount(4000), 73);
    expect(suggestDenoiseAmount(25600), 100);
    expect(noiseAdvice(800), isNull);
    expect(noiseAdvice(4000), isNotNull);
  });

  test('yeux rouges : masque, doublons et historique', () {
    final MaskMap m = eyeMask(<String, dynamic>{'x': 0.4, 'y': 0.3, 'r': 0.01, 'hue': 'vert'}, 0.5, '${kEyeMaskPrefix}vert 1');
    expect(isEyeMask(m), isTrue);
    expect(m['amount'], 50.0);
    final List<dynamic> comps = m['comps'] as List<dynamic>;
    expect((comps[0] as Map<String, dynamic>)['rx'], closeTo(0.016, 1e-9));
    expect((comps[1] as Map<String, dynamic>)['hue'], 120.0);
    expect(isEyeMask(<String, dynamic>{'name': 'Dégradé ciel'}), isFalse);

    // le masque se range dans le fichier et en ressort intact, à côté des masques du PC
    final Map<String, dynamic> extra = <String, dynamic>{
      'masks': <dynamic>[m, <String, dynamic>{'name': 'Ciel', 'comps': <dynamic>[]}],
      'autre': 1,
    };
    final (List<MaskMap> masks, Map<String, dynamic> rest) = splitMasks(extra);
    expect(masks.length, 2);
    expect(rest.containsKey('masks'), isFalse);
    expect(rest['autre'], 1);
    expect(masksEqual(masks, copyMasks(masks)), isTrue);

    // un œil déjà corrigé n'est pas corrigé deux fois ; un reflet pâle est écarté
    final List<Map<String, dynamic>> found = <Map<String, dynamic>>[
      <String, dynamic>{'x': 0.4, 'y': 0.3, 'r': 0.01, 'hue': 'vert', 'score': 1.0, 'chroma': 70.0},
      <String, dynamic>{'x': 0.6, 'y': 0.3, 'r': 0.01, 'hue': 'vert', 'score': 0.9, 'chroma': 66.0},
      <String, dynamic>{'x': 0.8, 'y': 0.7, 'r': 0.01, 'hue': 'rouge', 'score': 0.4, 'chroma': 35.0},
    ];
    final (List<Map<String, dynamic>> fresh, int weak) = freshEyes(found, masks);
    expect(fresh.length, 1);
    expect(fresh.first['x'], 0.6);
    expect(weak, 1);

    // annuler / rétablir ramène les masques
    final RecipeHistory h = RecipeHistory(<String, double>{'a': 0});
    expect(h.currentMasks, isEmpty);
    h.commit(<String, double>{'a': 0}, masks: masks);
    expect(h.canUndo, isTrue);
    expect(h.currentMasks.length, 2);
    h.undo();
    expect(h.currentMasks, isEmpty);
    h.redo();
    expect(h.currentMasks.length, 2);
  });
}
