import 'package:flutter_test/flutter_test.dart';

import 'package:sursaut_essai/domain/ai_masks.dart';
import 'package:sursaut_essai/domain/crop_math.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sursaut_essai/domain/curves.dart';
import 'package:sursaut_essai/domain/histogram.dart';
import 'package:sursaut_essai/domain/lens_profiles.dart';
import 'package:sursaut_essai/domain/mask_tools.dart';
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

  test('histogramme : classes, écrêtage et échantillonnage', () {
    // image 4×2 : deux pixels noirs, deux blancs, quatre gris moyen
    final Uint8List px = Uint8List.fromList(<int>[
      0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255, 255, 255, 255, 255, 255, //
      128, 128, 128, 255, 128, 128, 128, 255, 128, 128, 128, 255, 128, 128, 128, 255,
    ]);
    final Histogram h = Histogram.of(px, 4, 2);
    expect(h.count, 8);
    expect(h.r[0], 2);
    expect(h.r[255], 2);
    expect(h.g[128], 4);
    expect(h.l[128], 4);
    expect(h.shadowClip, closeTo(0.25, 1e-9));
    expect(h.highlightClip, closeTo(0.25, 1e-9));
    expect(h.shadowsClipped, isTrue);
    expect(h.highlightsClipped, isTrue);

    // une image sans extrêmes n'allume aucune alerte
    final Histogram mid = Histogram.of(Uint8List.fromList(<int>[100, 110, 120, 255, 90, 95, 99, 255]), 2, 1);
    expect(mid.shadowsClipped, isFalse);
    expect(mid.highlightsClipped, isFalse);

    // grande image : l'échantillonnage borne le nombre de pixels lus
    final Histogram big = Histogram.of(Uint8List(2000 * 1500 * 4), 2000, 1500, maxSamples: 10000);
    expect(big.count, lessThanOrEqualTo(12000));
    expect(big.count, greaterThan(2000));

    // données incomplètes : histogramme vide, sans erreur
    expect(Histogram.of(Uint8List(4), 10, 10).count, 0);

    // courbe : hauteurs entre 0 et 1, référence jamais nulle
    final List<double> c = Histogram.curve(h.l, Histogram.reference(h.l));
    expect(c.length, 256);
    expect(c.every((double v) => v >= 0 && v <= 1), isTrue);
    expect(Histogram.reference(List<int>.filled(256, 0)), 1.0);
  });

  test('courbes prêtes à l\'emploi', () {
    int idx(String name) => kCurvePresets.indexWhere(((String, CurvePoints) p) => p.$1 == name);
    List<double> samples(String name) => curveSamples(curvePresetPoints(idx(name)));
    expect(kCurvePresets.length, 11);
    expect(isIdentityCurve(curvePresetPoints(idx('Linéaire'))), isTrue);
    for (int i = 0; i < kCurvePresets.length; i++) {
      final List<double> s = curveSamples(curvePresetPoints(i));
      expect(s.length, 256, reason: kCurvePresets[i].$1);
      expect(s.every((double v) => v >= -1e-9 && v <= 1 + 1e-9), isTrue, reason: kCurvePresets[i].$1);
    }
    expect(samples('Contraste doux')[64], lessThan(64 / 255)); // ombres plus sombres
    expect(samples('Contraste doux')[191], greaterThan(191 / 255)); // hautes lumières plus claires
    expect(samples('Contraste moyen')[64], lessThan(samples('Contraste doux')[64]));
    expect(samples('Contraste fort')[64], lessThan(samples('Contraste moyen')[64]));
    expect(samples('Éclaircir')[128], greaterThan(0.55));
    expect(samples('Assombrir')[128], lessThan(0.45));
    expect(samples('Ombres ouvertes')[38], greaterThan(38 / 255 + 0.05)); // ombres relevées
    expect(samples('Ombres ouvertes')[255], closeTo(1, 1e-6));
    expect(samples('Hautes lumières douces')[255], closeTo(0.93, 1e-6)); // blanc pur adouci
    expect(samples('Hautes lumières douces')[100], closeTo(100 / 255, 0.02)); // tons moyens intacts
    expect(samples('Film')[0], closeTo(0.05, 1e-6));
    expect(samples('Film')[255], closeTo(0.96, 1e-6));
    expect(samples('Mat (noirs relevés)')[0], closeTo(0.08, 1e-6));
    expect(samples('Inverser')[0], closeTo(1, 1e-6));
    // la copie est indépendante de la liste d'origine
    final CurvePoints c = curvePresetPoints(idx('Contraste doux'));
    c[1][1] = 0.9;
    expect(kCurvePresets[idx('Contraste doux')].$2[1][1], 0.21);
  });

  test('masques manuels : dégradé linéaire et radial', () {
    // format identique à celui du PC (moteur : MaskComp / Mask)
    final MaskMap lin = linearMask('Dégradé linéaire 1');
    expect(maskKind(lin), 'linear');
    expect(mainComp(lin)!['y0'], 0.3);
    expect(mainComp(lin)!['y1'], 0.7);
    expect(lin['amount'], 100.0);
    expect((lin['adj'] as Map<String, dynamic>).length, 12);
    expect(maskIsNeutral(lin), isTrue);
    final MaskMap rad = radialMask('Dégradé radial 1');
    expect(maskKind(rad), 'radial');
    expect(mainComp(rad)!['rx'], 0.25);
    expect(mainComp(rad)!['feather'], 0.5);

    // réglages locaux : copie, valeur lue, masque plus neutre
    final MaskMap lit = withAdj(lin, 'exposure', 1.5);
    expect(adjOf(lit, 'exposure'), 1.5);
    expect(adjOf(lin, 'exposure'), 0); // l'original ne change pas
    expect(maskIsNeutral(lit), isFalse);
    expect(kLocalKeys.length, 12);
    expect(kLocalGroups.map(((String, List<LocalParam>) g) => g.$1).toList(), <String>['LUMIÈRE', 'COULEUR', 'DÉTAIL']);

    // la première composante se modifie sans toucher au reste
    final MaskMap moved = withComp(lit, <String, dynamic>{'x0': 0.2, 'y0': 0.1});
    expect(mainComp(moved)!['x0'], 0.2);
    expect(mainComp(moved)!['x1'], 0.5);
    expect(adjOf(moved, 'exposure'), 1.5);

    // noms : on ne reprend jamais un nom déjà pris
    expect(nextMaskName(<MaskMap>[], 'Dégradé linéaire'), 'Dégradé linéaire 1');
    expect(nextMaskName(<MaskMap>[lin], 'Dégradé linéaire'), 'Dégradé linéaire 2');
    expect(nextMaskName(<MaskMap>[linearMask('Dégradé linéaire 2')], 'Dégradé linéaire'), 'Dégradé linéaire 3');

    // doublon : copie profonde, nouveau nom, léger décalage
    final MaskMap dup = duplicateMask(lit);
    expect(dup['name'], 'Dégradé linéaire 1 (copie)');
    expect(adjOf(dup, 'exposure'), 1.5);
    expect(mainComp(dup)!['x0'], closeTo(0.54, 1e-9));
    expect(mainComp(lit)!['x0'], 0.5);

    // tracé au doigt, photo 3:2
    final MaskMap drawn = linearFromDrag('L', 0.5, 0.2, 0.5, 0.6, 1.5);
    expect(mainComp(drawn)!['y0'], 0.2);
    expect(mainComp(drawn)!['y1'], 0.6);
    final MaskMap tap = linearFromDrag('L', 0.5, 0.5, 0.5, 0.505, 1.5); // trop court : défaut vertical
    expect(mainComp(tap)!['y0'], closeTo(0.3, 1e-9));
    expect(mainComp(tap)!['y1'], closeTo(0.7, 1e-9));
    // rayon = distance (en unités de hauteur) / grand côté : 0,15 de largeur × 1,5 = 0,225, grand côté 1,5 -> 0,15
    final MaskMap circle = radialFromDrag('R', 0.5, 0.5, 0.65, 0.5, 1.5);
    expect(mainComp(circle)!['rx'], closeTo(0.15, 1e-9));
    expect(mainComp(circle)!['ry'], closeTo(0.15, 1e-9));
    final MaskMap tiny = radialFromDrag('R', 0.5, 0.5, 0.5, 0.5, 1.5);
    expect(mainComp(tiny)!['rx'], 0.25); // trop petit : taille par défaut

    // les masques d'yeux restent à part
    expect(isManualMask(lin), isTrue);
    expect(isManualMask(eyeMask(<String, dynamic>{'x': 0.5, 'y': 0.5, 'r': 0.01, 'hue': 'rouge'}, 1, 'Yeux · rouge 1')), isFalse);

    // historique : annuler / rétablir ramène la liste de masques
    final RecipeHistory h = RecipeHistory(<String, double>{}, masks: <MaskMap>[]);
    h.commit(<String, double>{}, masks: <MaskMap>[lit]);
    expect(h.currentMasks.length, 1);
    h.undo();
    expect(h.currentMasks, isEmpty);
    h.redo();
    expect(adjOf(h.currentMasks.first, 'exposure'), 1.5);
  });
  test('masques manuels : plages, composantes, pipette et vue de la zone', () {
    final MaskMap lum = rangeMask('Lum', kLuminance);
    expect(maskKind(lum), kLuminance);
    expect(mainComp(lum)!['hi'], 0.4);
    expect(maskIsNeutral(lum), isTrue);
    final MaskMap col = rangeMask('Col', kColor);
    expect(mainComp(col)!['hue_range'], 30.0);
    expect(isRangeKind(kColor), isTrue);
    expect(isRangeKind(kLinear), isFalse);

    // composantes : ajouter, changer, retirer (une au moins reste)
    final MaskMap two = addComp(lum, defaultComp(kRadial, op: 'subtract'));
    expect(compsOf(two).length, 2);
    expect(compAt(two, 1)!['op'], 'subtract');
    expect(compAt(two, 5), isNull);
    final MaskMap moved = withCompAt(two, 1, <String, dynamic>{'x0': 0.2});
    expect(compAt(moved, 1)!['x0'], 0.2);
    expect(compAt(two, 1)!['x0'], 0.5); // l'original n'a pas bougé
    expect(compsOf(removeCompAt(moved, 1)).length, 1);
    expect(compsOf(removeCompAt(lum, 0)).length, 1);

    // pipette : un carré rouge pur -> teinte 0, saturation 1 ; un gris -> saturation 0
    final Uint8List px = Uint8List(4 * 4 * 4);
    for (int i = 0; i < 16; i++) {
      px[i * 4] = i < 8 ? 255 : 128;
      px[i * 4 + 1] = i < 8 ? 0 : 128;
      px[i * 4 + 2] = i < 8 ? 0 : 128;
      px[i * 4 + 3] = 255;
    }
    final (double hue, double sat) = hueSatAt(px, 4, 4, 0.5, 0.0, half: 0);
    expect(hue, closeTo(0, 1e-6));
    expect(sat, closeTo(1, 1e-6));
    final (double _, double sat2) = hueSatAt(px, 4, 4, 0.5, 1.0, half: 0);
    expect(sat2, closeTo(0, 1e-6));
    final Uint8List green = Uint8List.fromList(<int>[0, 255, 0, 255]);
    expect(hueSatAt(green, 1, 1, 0.5, 0.5).$1, closeTo(120, 1e-6));

    // vue de la zone : réglages remplacés, zone rougie ; l'original est intact
    final MaskMap zone = zoneView(withAdj(lum, 'contrast', 40));
    expect(adjOf(zone, 'exposure'), 0.6);
    expect(adjOf(zone, 'contrast'), 0);
    expect(adjOf(lum, 'exposure'), 0);
  });
  test('masques manuels : pinceau, trait continu', () {
    final MaskMap b = brushMask('Pinceau 1');
    expect(maskKind(b), kBrush);
    expect((mainComp(b)!['stroke'] as List<dynamic>), isEmpty);
    expect(mainComp(b)!['r'], kBrushDefaultR);
    expect(kMaskKindNames[kBrush], 'Pinceau');

    // un trait rapide (deux points éloignés) est complété : un point tous les 35 % du rayon
    final List<List<double>> dense = densifyStroke(<List<double>>[<double>[0.1, 0.5], <double>[0.5, 0.5]], 1.0, 0.1);
    expect(dense.first, <double>[0.1, 0.5]);
    expect(dense.length, greaterThan(8));
    for (int k = 1; k < dense.length; k++) {
      expect((dense[k][0] - dense[k - 1][0]).abs(), lessThanOrEqualTo(0.1 * 0.35 + 1e-9));
    }
    // un seul appui : un seul point
    expect(densifyStroke(<List<double>>[<double>[0.3, 0.3]], 1.5, 0.05).length, 1);
    expect(densifyStroke(<List<double>>[], 1.5, 0.05), isEmpty);

    // les points s'ajoutent à la composante, sans toucher l'original
    final MaskMap t1 = addStrokePoints(b, 0, dense);
    final MaskMap t2 = addStrokePoints(t1, 0, <List<double>>[<double>[0.9, 0.9]]);
    expect((mainComp(t2)!['stroke'] as List<dynamic>).length, dense.length + 1);
    expect((mainComp(b)!['stroke'] as List<dynamic>), isEmpty);
    // pas un pinceau : rien ne change
    final MaskMap lin = linearMask('L');
    expect(addStrokePoints(lin, 0, dense), same(lin));
  });
  test('masques d\'IA : image du masque, clé, PNG, recette', () {
    // plan 8 x 4 : moitié gauche pleine
    final Uint8List plane = Uint8List(8 * 4);
    for (int y = 0; y < 4; y++) {
      for (int x = 0; x < 4; x++) {
        plane[y * 8 + x] = 255;
      }
    }
    final String key = maskKey(plane);
    expect(key.length, 16);
    expect(maskKey(Uint8List.fromList(plane)), key); // même contenu, même clé
    final Uint8List autre = Uint8List.fromList(plane)..[31] = 128;
    expect(maskKey(autre), isNot(key));

    // PNG : aller-retour sans perte
    final Uint8List png = planeToPng(plane, 8, 4);
    final (Uint8List, int, int)? back = pngToPlane(png);
    expect(back, isNotNull);
    expect(back!.$2, 8);
    expect(back.$3, 4);
    expect(back.$1, plane);
    expect(pngToPlane(Uint8List.fromList(<int>[1, 2, 3])), isNull);

    // réduction : plus petit que la limite = inchangé ; plus grand = ramené à la limite
    expect(fitPlane(plane, 8, 4).$2, 8);
    final Uint8List big = Uint8List(40 * 20)..fillRange(0, 40 * 20, 200);
    final (Uint8List, int, int) small = fitPlane(big, 40, 20, maxSide: 10);
    expect(small.$2, 10);
    expect(small.$3, 5);
    expect(small.$1.length, 50);
    expect(small.$1.every((int v) => (v - 200).abs() <= 1), isTrue);

    // le masque d'IA suit le format du PC : composante bitmap avec clé, png et origine
    final MaskMap m = bitmapMask(name: 'Sujet 1', key: key, pngBase64: planeToBase64(plane, 8, 4), what: 'subject');
    expect(maskKind(m), kBitmap);
    expect(mainComp(m)!['key'], key);
    expect((mainComp(m)!['ai'] as Map<String, dynamic>)['what'], 'subject');
    expect(m['invert'], false);
    expect(bitmapMask(name: 'F', key: key, pngBase64: 'x', what: 'background', invert: true)['invert'], true);
    expect(maskIsNeutral(m), isTrue);
    expect(isManualMask(m), isTrue);

    // le moteur ne reçoit que la clé : le PNG est retiré, l'original n'est pas touché
    expect(bitmapComps(<dynamic>[m]).length, 1);
    final List<dynamic> propre = withoutPngs(<dynamic>[m]);
    expect(mainComp(propre.first as Map<String, dynamic>)!.containsKey('png'), isFalse);
    expect(mainComp(propre.first as Map<String, dynamic>)!['key'], key);
    expect(mainComp(m)!.containsKey('png'), isTrue);
    // un masque sans image garde le même contenu
    final MaskMap lin = linearMask('L');
    expect(withoutPngs(<dynamic>[lin]).first, equals(lin));
    // copie et enregistrement : le PNG suit
    expect(mainComp(duplicateMask(m))!['png'], mainComp(m)!['png']);
  });
}
