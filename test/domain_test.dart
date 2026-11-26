import 'package:flutter_test/flutter_test.dart';

import 'package:sursaut_essai/common/app_version.dart';
import 'package:sursaut_essai/domain/ai_masks.dart';
import 'package:sursaut_essai/domain/body_parts.dart';
import 'package:sursaut_essai/domain/sam_mask.dart';
import 'package:sursaut_essai/domain/face_parts.dart';
import 'package:sursaut_essai/domain/crop_math.dart';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:io';
import 'dart:typed_data';

import 'package:sursaut_essai/domain/camera_format.dart';
import 'package:sursaut_essai/domain/curves.dart';
import 'package:sursaut_essai/domain/histogram.dart';
import 'package:sursaut_essai/domain/lama_prep.dart';
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

  test('le numéro de version affiché est celui de pubspec.yaml', () {
    final String pubspec = File('pubspec.yaml').readAsStringSync();
    final RegExpMatch? m = RegExp(r'^version:\s*(\d+\.\d+\.\d+)\+', multiLine: true).firstMatch(pubspec);
    expect(m, isNotNull);
    expect(kAppVersion, m!.group(1));
  });
  test('parties du visage : zones remplies à partir des repères', () {
    // carré du quart au trois-quarts d'une image de 8 x 8 : 4 lignes x 4 colonnes
    const List<double> carre = <double>[0.25, 0.25, 0.75, 0.25, 0.75, 0.75, 0.25, 0.75];
    final Uint8List plein = fillShape(8, 8, const PartShape(<List<double>>[carre], <List<double>>[]));
    expect(plein.where((int v) => v == 255).length, 16);
    expect(plein[3 * 8 + 3], 255);
    expect(plein[0], 0);
    // un trou retiré au milieu : colonnes 3 et 4, lignes 3 et 4
    const List<double> trou = <double>[0.375, 0.375, 0.625, 0.375, 0.625, 0.625, 0.375, 0.625];
    final Uint8List perce = fillShape(8, 8, const PartShape(<List<double>>[carre], <List<double>>[trou]));
    expect(perce.where((int v) => v == 255).length, 12);
    expect(perce[3 * 8 + 3], 0);
    // agrandi deux fois autour de son centre
    final List<double> grand = scalePoly(carre, 2);
    expect(grand[0], closeTo(0.0, 1e-9));
    expect(grand[2], closeTo(1.0, 1e-9));
    // un trait devient un polygone de 2 x n points
    expect(thickLine(<double>[0.1, 0.5, 0.2, 0.5, 0.3, 0.5], 0.02).length, 12);
    expect(thickLine(<double>[0.1, 0.5], 0.02), isEmpty);
    // un flou ne change pas une zone uniforme
    final Uint8List fond = Uint8List(40)..fillRange(0, 40, 100);
    expect(blurPlane(fond, 8, 5, 2).every((int v) => v == 100), isTrue);
    // il adoucit un bord : la valeur de la frontière passe entre 0 et 255
    final Uint8List doux = blurPlane(plein, 8, 8, 1);
    expect(doux[3 * 8 + 1] > 0 && doux[3 * 8 + 1] < 255, isTrue);
    // sans repères, pas de zone
    expect(partShape(<String, List<double>>{}, 'eyes'), isNull);
    final PartShape? yeux = partShape(<String, List<double>>{
      'box': <double>[0.2, 0.2, 0.6, 0.7],
      'leftEye': <double>[0.3, 0.3, 0.35, 0.28, 0.4, 0.3, 0.35, 0.32],
      'rightEye': <double>[0.45, 0.3, 0.5, 0.28, 0.55, 0.3, 0.5, 0.32],
    }, 'eyes');
    expect(yeux, isNotNull);
    expect(yeux!.add.length, 2);
    expect(kFacePartNames.keys, containsAll(<String>['skin', 'eyes', 'brows', 'lips']));
  });
  test('contours du visage : courbes lissées, sourcils effilés, front en arc', () {
    // une courbe fermée lissée passe par ses points de départ et a `steps` fois plus de points
    const List<double> carre = <double>[0.2, 0.2, 0.8, 0.2, 0.8, 0.8, 0.2, 0.8];
    final List<double> lisse = smoothClosed(carre, steps: 4);
    expect(lisse.length, 4 * 4 * 2);
    expect(lisse[0], closeTo(0.2, 1e-9));
    expect(lisse[1], closeTo(0.2, 1e-9));
    // une courbe ouverte garde ses deux extrémités
    final List<double> ouvert = smoothOpen(<double>[0.1, 0.5, 0.2, 0.4, 0.3, 0.5], steps: 4);
    expect(ouvert.length, 18);
    expect(ouvert[16], closeTo(0.3, 1e-9));
    expect(ouvert[17], closeTo(0.5, 1e-9));
    // un sourcil : épais (2 x demi-épaisseur) au milieu, 30 % aux bouts
    final List<double> sourcil = taperLine(<double>[0.1, 0.5, 0.2, 0.4, 0.3, 0.5], 0.02);
    expect(sourcil.length, 52);
    expect(sourcil[39] - sourcil[13], closeTo(0.04, 1e-9));
    expect(sourcil[51] - sourcil[1], closeTo(0.012, 1e-9));
    expect(taperLine(<double>[0.1, 0.5], 0.02), isEmpty);

    // un visage de 17 points de contour (d'une tempe à l'autre par le menton), dans les deux sens
    final List<double> contour = <double>[
      for (int i = 0; i <= 16; i++) ...<double>[
        0.5 + 0.14 * math.cos(math.pi * 0.08 + i * math.pi * 0.84 / 16),
        0.45 + 0.2 * math.sin(math.pi * 0.08 + i * math.pi * 0.84 / 16),
      ],
    ];
    final List<double> inverse = <double>[
      for (int i = contour.length ~/ 2 - 1; i >= 0; i--) ...<double>[contour[2 * i], contour[2 * i + 1]],
    ];
    const List<double> gSourcil = <double>[0.40, 0.42, 0.43, 0.405, 0.47, 0.41];
    const List<double> dSourcil = <double>[0.53, 0.41, 0.57, 0.405, 0.60, 0.42];
    for (final List<double> sens in <List<double>>[contour, inverse]) {
      final List<double> front = foreheadFace(sens, <double>[...gSourcil, ...dSourcil]);
      expect(front.length, (17 + 13) * 2);
      double haut = 1;
      for (int i = 1; i < front.length; i += 2) {
        haut = math.min(haut, front[i]);
      }
      expect(haut, closeTo(0.29475, 1e-6)); // le front monte au-dessus des sourcils, quel que soit le sens du contour
      final PartShape? peau = partShape(<String, List<double>>{
        'box': <double>[0.36, 0.29, 0.64, 0.65],
        'contour': sens,
        'leftBrow': gSourcil,
        'rightBrow': dSourcil,
        'leftEye': <double>[0.41, 0.46, 0.43, 0.45, 0.46, 0.46, 0.43, 0.47],
        'rightEye': <double>[0.54, 0.46, 0.57, 0.45, 0.59, 0.46, 0.57, 0.47],
        'outerLips': <double>[0.45, 0.62, 0.5, 0.60, 0.55, 0.62, 0.5, 0.65],
      }, 'skin');
      expect(peau, isNotNull);
      final Uint8List plan = fillShape(200, 200, peau!);
      expect(plan[110 * 200 + 88], 255); // la joue
      expect(plan[68 * 200 + 100], 255); // le front
      expect(plan[92 * 200 + 86], 0); // le trou de l'œil
      expect(plan[124 * 200 + 100], 0); // le trou de la bouche
      expect(plan[100 * 200 + 20], 0); // hors du visage
    }
  });
  test('parties du corps : zone gardée seulement si elle touche la personne', () {
    const int w = 2000, h = 1000;
    final CropSquare crop = bodyCrop(450 / w, 225 / h, 550 / w, 375 / h, w, h);
    expect(crop.side, 900);
    expect(crop.x0, 50);
    expect(crop.y0, 45);
    const int size = 256;
    final double sc = size / crop.side;
    final Uint8List probs = Uint8List(kBodyClasses * size * size);
    for (int i = 0; i < size * size; i++) {
      probs[i] = 255; // fond partout
    }
    void fill(int cls, int x0, int y0, int x1, int y1) {
      for (int y = ((y0 - crop.y0) * sc).floor(); y < ((y1 - crop.y0) * sc).floor(); y++) {
        for (int x = ((x0 - crop.x0) * sc).floor(); x < ((x1 - crop.x0) * sc).floor(); x++) {
          if (x < 0 || y < 0 || x >= size || y >= size) continue;
          for (int k = 0; k < kBodyClasses; k++) {
            probs[k * size * size + y * size + x] = k == cls ? 255 : 0;
          }
        }
      }
    }

    fill(1, 440, 180, 560, 260); // cheveux de la personne
    fill(4, 400, 400, 600, 700); // vêtements de la personne
    fill(1, 700, 180, 780, 260); // cheveux d'une autre personne
    const int pw = 1000, ph = 500;
    int at(Uint8List plane, double x, double y) => plane[(y * ph / h).toInt() * pw + (x * pw / w).toInt()];

    final List<double> ancHair = partAnchor('hair', 450 / w, 225 / h, 550 / w, 375 / h, w, h);
    expect(ancHair[0], closeTo(420, 1e-9));
    expect(ancHair[1], closeTo(120, 1e-9));
    expect(ancHair[2], closeTo(580, 1e-9));
    expect(ancHair[3], closeTo(300, 1e-9));
    final Uint8List hair = bodyPartPlane(
        probs: probs, size: size, cls: kBodyPartClass['hair']!, crop: crop, anchor: ancHair, pw: pw, ph: ph, imgW: w, imgH: h);
    expect(at(hair, 500, 220), 255); // ses cheveux
    expect(at(hair, 740, 220), 0); // ceux du voisin, écartés
    expect(at(hair, 500, 300), 0); // le visage
    expect(at(hair, 500, 500), 0); // les vêtements

    final Uint8List clothes = bodyPartPlane(
        probs: probs,
        size: size,
        cls: kBodyPartClass['clothes']!,
        crop: crop,
        anchor: partAnchor('clothes', 450 / w, 225 / h, 550 / w, 375 / h, w, h),
        pw: pw,
        ph: ph,
        imgW: w,
        imgH: h);
    expect(at(clothes, 500, 500), 255);
    expect(at(clothes, 500, 300), 0);
    // rien de cette classe près de la personne : zone vide
    final Uint8List none = bodyPartPlane(
        probs: probs, size: size, cls: kBodyPartClass['bodyskin']!, crop: crop, anchor: partAnchor('bodyskin', 450 / w, 225 / h, 550 / w, 375 / h, w, h), pw: pw, ph: ph, imgW: w, imgH: h);
    expect(none.every((int v) => v == 0), isTrue);
  });
  test('parties du corps : découpe serrée, filtre guidé, partage entre deux personnes', () {
    // cheveux : carré serré sur la tête ; vêtements : carré large (valeurs vérifiées par un calcul de référence)
    final CropSquare tete = bodyCrop(450 / 2000, 225 / 1000, 550 / 2000, 375 / 1000, 2000, 1000, part: 'hair');
    expect(tete.side, 420); // max(150 x 2,8 ; 100 x 2,6)
    expect(tete.x0, 290); // 500 - 210
    expect(tete.y0, inInclusiveRange(82, 83)); // 225 - 150 x 0,95 = 82,5 : l'arrondi dépend des décimales
    // le filtre guidé ramène un bord flou (à 18) sur le bord de l'image guide (à 20)
    const int w = 40, h = 8;
    final Float64List guide = Float64List(w * h), p = Float64List(w * h);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        guide[y * w + x] = x >= 20 ? 1 : 0;
        p[y * w + x] = ((x - 16) / 4).clamp(0.0, 1.0).toDouble();
      }
    }
    final Float64List q = guidedFilter(guide, p, w, h, 5, 1e-3);
    expect(q[3 * w + 12], closeTo(0.0668, 0.002));
    expect(q[3 * w + 18], closeTo(0.2714, 0.002));
    expect(q[3 * w + 20], closeTo(0.9978, 0.002));
    expect(q[3 * w + 25], closeTo(0.9997, 0.002));
    // gris : 2 x 2 pixels uniformes
    final Uint8List rgba = Uint8List.fromList(<int>[for (int i = 0; i < 4; i++) ...<int>[100, 100, 100, 255]]);
    expect(grayPlane(rgba, 2, 2, 2, 2).every((int v) => v == 100), isTrue);

    // deux personnes côte à côte : une zone de vêtements continue est partagée à mi-chemin entre leurs visages
    const int iw = 2000, ih = 1000;
    final CropSquare crop = bodyCrop(450 / iw, 225 / ih, 550 / iw, 375 / ih, iw, ih);
    const int size = 256;
    final double sc = size / crop.side;
    final Uint8List probs = Uint8List(kBodyClasses * size * size);
    for (int i = 0; i < size * size; i++) {
      probs[i] = 0;
    }
    for (int y = 0; y < size; y++) {
      for (int x = 0; x < size; x++) {
        final int i = y * size + x;
        final double px = crop.x0 + (x + 0.5) / sc, py = crop.y0 + (y + 0.5) / sc;
        final bool cloth = py >= 420 && py <= 700 && px >= 350 && px <= 750;
        probs[(cloth ? 4 : 0) * size * size + i] = 255;
      }
    }
    const int pw = 1000, ph = 500;
    final List<double> anchor0 = partAnchor('clothes', 450 / iw, 225 / ih, 550 / iw, 375 / ih, iw, ih);
    final List<double> anchor1 = partAnchor('clothes', 590 / iw, 225 / ih, 690 / iw, 375 / ih, iw, ih);
    Uint8List run(Uint8List pr, int self) => bodyPartPlane(
        probs: pr,
        size: size,
        cls: 4,
        crop: crop,
        anchor: self == 0 ? anchor0 : anchor1,
        pw: pw,
        ph: ph,
        imgW: iw,
        imgH: ih,
        faces: <List<double>>[
          <double>[500, 300, 100], // la personne choisie : centre x, centre y, largeur
          <double>[640, 300, 100], // son voisin, 140 pixels à droite
        ],
        anchors: <List<double>>[anchor0, anchor1],
        self: self);
    int at(Uint8List plane, double x, double y) => plane[(y * ph / ih).toInt() * pw + (x * pw / iw).toInt()];
    // une zone continue qui touche les deux personnes ne peut pas être répartie : écartée (pas de bande verticale)
    expect(run(probs, 0).every((int v) => v == 0), isTrue);
    expect(run(probs, 1).every((int v) => v == 0), isTrue);
    // deux zones séparées : chacune va à la personne dont le visage est le plus proche
    final Uint8List two = Uint8List(kBodyClasses * size * size);
    for (int y = 0; y < size; y++) {
      for (int x = 0; x < size; x++) {
        final double px = crop.x0 + (x + 0.5) / sc, py = crop.y0 + (y + 0.5) / sc;
        final bool cloth = py >= 420 && py <= 700 && ((px >= 420 && px <= 520) || (px >= 620 && px <= 720));
        two[(cloth ? 4 : 0) * size * size + y * size + x] = 255;
      }
    }
    final Uint8List mine = run(two, 0);
    expect(at(mine, 470, 560), 255);
    expect(at(mine, 670, 560), 0);
    final Uint8List other = run(two, 1);
    expect(at(other, 670, 560), 255);
    expect(at(other, 470, 560), 0);
  });

  test('cheveux de têtes collées : une zone commune est répartie entre les deux têtes', () {
    const int size = 256, iw = 2000, ih = 1000, pw = 1000, ph = 500;
    const CropSquare crop = CropSquare(400, 100, 512);
    final double sc = size / crop.side;
    final Uint8List probs = Uint8List(kBodyClasses * size * size);
    for (int y = 0; y < size; y++) {
      for (int x = 0; x < size; x++) {
        final double px = crop.x0 + (x + 0.5) / sc, py = crop.y0 + (y + 0.5) / sc;
        final bool hair = py >= 200 && py <= 260 && px >= 440 && px <= 700;
        probs[(hair ? 1 : 0) * size * size + y * size + x] = 255;
      }
    }
    final List<double> a0 = <double>[400, 150, 580, 330], a1 = <double>[560, 150, 740, 330];
    Uint8List run(int self) => bodyPartPlane(
        probs: probs,
        size: size,
        cls: 1,
        crop: crop,
        anchor: self == 0 ? a0 : a1,
        pw: pw,
        ph: ph,
        imgW: iw,
        imgH: ih,
        faces: <List<double>>[<double>[500, 300, 100], <double>[640, 300, 100]],
        anchors: <List<double>>[a0, a1],
        self: self);
    int at(Uint8List plane, double x, double y) => plane[(y * ph / ih).toInt() * pw + (x * pw / iw).toInt()];
    final Uint8List m0 = run(0), m1 = run(1);
    expect(at(m0, 470, 230), 255);
    expect(at(m0, 690, 230), 0);
    expect(at(m1, 690, 230), 255);
    expect(at(m1, 470, 230), 0);
    // même si le cadre du visage est décalé et que la zone ne touche pas l'ancre : les cheveux sont trouvés par la tête la plus proche
    final Uint8List lost = bodyPartPlane(
        probs: probs,
        size: size,
        cls: 1,
        crop: crop,
        anchor: <double>[0, 0, 10, 10],
        pw: pw,
        ph: ph,
        imgW: iw,
        imgH: ih,
        faces: <List<double>>[<double>[500, 330, 120], <double>[640, 300, 100]],
        self: 0);
    expect(at(lost, 470, 230), 255);
    expect(at(lost, 690, 230), 0);
  });

  test('nettoyage d\'une soustraction : bandes fines et petits îlots supprimés', () {
    const int pw = 100, ph = 60;
    final Uint8List pl = Uint8List(pw * ph);
    void rect(int x0, int y0, int x1, int y1) {
      for (int y = y0; y < y1; y++) {
        for (int x = x0; x < x1; x++) {
          pl[y * pw + x] = 255;
        }
      }
    }

    rect(40, 10, 80, 50); // le vrai corps
    rect(20, 28, 40, 34); // bande fine qui dépasse du corps (6 pixels de large)
    rect(85, 20, 95, 30); // petit îlot séparé
    final Uint8List c = cleanPlane(pl, pw, ph, 3);
    expect(c[30 * pw + 60], 255);
    expect(c[30 * pw + 41], 255); // le coin du corps est gardé
    expect(c[30 * pw + 25], 0); // la bande fine a disparu
    expect(c[25 * pw + 90], 0);
    expect(cleanPlane(pl, pw, ph, 0), same(pl)); // rayon nul : inchangé
  });

  test('fermeture : les petits trous sont bouchés, les zones éloignées restent séparées', () {
    const int pw = 100, ph = 60;
    final Uint8List pl = Uint8List(pw * ph);
    void rect(int x0, int y0, int x1, int y1, int v) {
      for (int y = y0; y < y1; y++) {
        for (int x = x0; x < x1; x++) {
          pl[y * pw + x] = v;
        }
      }
    }

    rect(10, 10, 40, 50, 255); // zone avec un trou
    rect(20, 25, 23, 28, 0); // trou de 3 pixels (une fleur de la combinaison)
    rect(70, 10, 90, 50, 255); // autre zone, à 30 pixels
    final Uint8List c = closePlane(pl, pw, ph, 3);
    expect(c[26 * pw + 21], 255); // trou bouché
    expect(c[30 * pw + 55], 0); // l'espace entre les zones reste vide
    expect(c[30 * pw + 25], 255);
    expect(closePlane(pl, pw, ph, 0), same(pl));
  });

  test('peau du corps par la couleur : étend les taches du modèle sur la couleur du visage, pas sur le reste', () {
    const int size = 64;
    final Uint8List cmap = Uint8List(size * size);
    final Uint8List rgba = Uint8List(size * size * 4);
    for (int y = 0; y < size; y++) {
      for (int x = 0; x < size; x++) {
        final int o = (y * size + x) * 4;
        rgba[o + 3] = 255;
        rgba[o] = 90;
        rgba[o + 1] = 90;
        rgba[o + 2] = 90;
      }
    }
    void paint(int x, int y, int cls, List<int> c) {
      final int i = y * size + x;
      cmap[i] = cls;
      rgba[i * 4] = c[0];
      rgba[i * 4 + 1] = c[1];
      rgba[i * 4 + 2] = c[2];
    }

    const List<int> peau = <int>[205, 150, 125], bleu = <int>[40, 60, 200];
    for (int y = 5; y < 25; y++) {
      for (int x = 20; x < 40; x++) {
        paint(x, y, 3, peau); // visage
      }
    }
    for (int x = 10; x < 13; x++) {
      paint(x, 40, 2, peau); // tache reconnue par le modèle
    }
    for (int x = 13; x < 19; x++) {
      paint(x, 40, 4, peau); // main que le modèle a classée en vêtements
    }
    for (int x = 19; x < 25; x++) {
      paint(x, 40, 4, bleu); // vrai vêtement
    }
    final Uint8List? k = skinKeep(cmap, size, const CropSquare(0, 0, size), rgba, size, size, <double>[30, 15, 20]);
    expect(k, isNotNull);
    expect(k![40 * size + 11], 1);
    expect(k[40 * size + 16], 1); // étendue sur la couleur de la peau
    expect(k[40 * size + 22], 0); // pas sur le bleu
    expect(k[15 * size + 30], 0); // le visage lui-même n'en fait pas partie
    // un visage trop petit pour calibrer : pas de résultat
    expect(skinKeep(cmap, size, const CropSquare(0, 0, size), rgba, size, size, <double>[5, 60, 4]), isNull);
  });

  test('silhouette SAM plausible : visage dedans, autres dehors, vrai corps dessous', () {
    const int pw = 100, ph = 100;
    final List<double> face = <double>[0.4, 0.1, 0.5, 0.2];
    final List<List<double>> others = <List<double>>[<double>[0.7, 0.1, 0.8, 0.2]];
    Uint8List box(int x0, int y0, int x1, int y1) {
      final Uint8List p = Uint8List(pw * ph);
      for (int y = y0; y < y1; y++) {
        for (int x = x0; x < x1; x++) {
          p[y * pw + x] = 255;
        }
      }
      return p;
    }

    expect(samPersonPlausible(box(30, 5, 60, 80), pw, ph, face, others), isTrue);
    expect(samPersonPlausible(box(30, 5, 85, 80), pw, ph, face, others), isFalse); // couvre le visage d'un autre
    expect(samPersonPlausible(box(42, 12, 48, 30), pw, ph, face, others), isFalse); // bande étroite, pas de vrai corps
    expect(samPersonPlausible(box(60, 5, 90, 80), pw, ph, face, others), isFalse); // ne couvre pas son visage
    // un trou au centre du visage (lunettes) ne gêne pas
    final Uint8List trou = box(30, 5, 60, 80);
    for (int y = 14; y < 17; y++) {
      for (int x = 44; x < 47; x++) {
        trou[y * pw + x] = 0;
      }
    }
    expect(samPersonPlausible(trou, pw, ph, face, others), isTrue);
    // une silhouette qui recouvre celle d'une autre personne déjà acceptée est refusée
    expect(samPersonPlausible(box(30, 5, 60, 80), pw, ph, face, others, accepted: <Uint8List>[box(30, 20, 60, 80)]), isFalse);
  });

  test('plans : rééchantillonnage et réunion', () {
    final Uint8List src = Uint8List.fromList(<int>[0, 255, 0, 255]);
    final Uint8List big = resamplePlane(src, 2, 2, 4, 4);
    expect(big.length, 16);
    expect(big[0], 0);
    expect(big[3], 255);
    final Uint8List a = Uint8List.fromList(<int>[10, 200, 0]);
    unionPlanes(a, Uint8List.fromList(<int>[50, 100, 7]));
    expect(a, <int>[50, 200, 7]);
  });

  test('SAM : logits -> plan couvrant toute la photo', () {
    const int n = 8;
    final Float32List l = Float32List(n * n);
    for (int y = 0; y < n; y++) {
      for (int x = 0; x < n; x++) {
        l[y * n + x] = (x >= 2 && x < 6 && y >= 2 && y < 6) ? 8.0 : -8.0;
      }
    }
    final Uint8List p = samPlane(logits: l, size: n, pw: 64, ph: 32);
    expect(p.length, 64 * 32);
    expect(p[16 * 64 + 32], 255); // centre : dans l'objet
    expect(p[0], 0); // coin : en dehors
    expect(p[16 * 64 + 63], 0); // bord droit : en dehors
    // sans guide ni logits : plan vide de la bonne taille
    expect(samPlane(logits: Float32List(0), size: 8, pw: 4, ph: 4).length, 16);
  });

  test('SAM : points d\'un masque repris pour le modifier', () {
    final Map<String, dynamic> ai = <String, dynamic>{
      'what': 'sam',
      'points': <dynamic>[
        <dynamic>[0.25, 0.5, 1],
        <dynamic>[0.75, 0.5, 0.0],
      ],
    };
    final List<List<double>>? pts = samPointsOf(ai);
    expect(pts, isNotNull);
    expect(pts!.length, 2);
    expect(pts[0], <double>[0.25, 0.5, 1.0]);
    expect(pts[1][2], 0.0);
    expect(samPointsOf(<String, dynamic>{'what': 'person', 'points': <dynamic>[]}), isNull);
    expect(samPointsOf(<String, dynamic>{'what': 'sam', 'points': <dynamic>[<dynamic>[0.1, 0.2]]}), isNull);
    expect(samPointsOf(null), isNull);
  });

  test('SAM : zone de relecture en gros plan', () {
    // carré plein au centre d'un plan 100 x 100
    final Uint8List pl = Uint8List(100 * 100);
    for (int y = 40; y < 60; y++) {
      for (int x = 30; x < 50; x++) {
        pl[y * 100 + x] = 255;
      }
    }
    final List<double>? c = samCropOf(pl, 100, 100);
    expect(c, isNotNull);
    expect(c![0], lessThan(0.30));
    expect(c[2], greaterThan(0.50));
    expect(c[1], lessThan(0.40));
    expect(c[3], greaterThan(0.60));
    expect(samCropOf(Uint8List(100 * 100), 100, 100), isNull);
    // points : celui qui est dans la zone est ramené dans [0, 1], l'autre est écarté
    final List<List<double>> pts = samPointsInCrop(
      <List<double>>[<double>[0.4, 0.5, 1], <double>[0.9, 0.9, 0]],
      <double>[0.3, 0.4, 0.5, 0.6],
    );
    expect(pts.length, 1);
    expect(pts[0][0], closeTo(0.5, 1e-9));
    expect(pts[0][1], closeTo(0.5, 1e-9));
    expect(pts[0][2], 1.0);
    // plan avec zone : hors zone = 0, dans la zone = objet
    const int n = 8;
    final Float32List l = Float32List(n * n)..fillRange(0, n * n, 8.0);
    final Uint8List z = samPlane(logits: l, size: n, pw: 40, ph: 40, crop: <double>[0.25, 0.25, 0.75, 0.75]);
    expect(z[20 * 40 + 20], 255);
    expect(z[2 * 40 + 2], 0);
  });

  test('SAM : 16 points au plus, avec au moins un point dans l\'objet', () {
    final List<List<double>> many = <List<double>>[
      <double>[0.5, 0.5, 1],
      for (int i = 0; i < 22; i++) <double>[0.1, 0.1, 0],
    ];
    final List<List<double>> out = samLimitPoints(many);
    expect(out.length, kSamMaxPoints);
    expect(out.any((List<double> q) => q[2] >= 0.5), isTrue);
    final List<List<double>> few = <List<double>>[<double>[0.2, 0.2, 1]];
    expect(samLimitPoints(few).length, 1);
  });

  group('LaMa : préparation de la fenêtre 512', () {
    test('une photo unie donne une fenêtre unie, le dépassement est noir', () {
      final Uint8List px = Uint8List(100 * 100 * 4);
      for (int i = 0; i < 100 * 100; i++) {
        px[i * 4] = 200;
        px[i * 4 + 1] = 100;
        px[i * 4 + 2] = 50;
        px[i * 4 + 3] = 255;
      }
      final Uint8List w = lamaCrop(px, 100, 100, 0, 0, 100);
      expect(w.length, kLamaSide * kLamaSide * 4);
      final int mid = (256 * kLamaSide + 256) * 4;
      expect(w[mid], 200);
      expect(w[mid + 1], 100);
      expect(w[mid + 2], 50);
      expect(w[mid + 3], 255);
      final Uint8List out = lamaCrop(px, 100, 100, -1000, -1000, 100);
      expect(out[mid], 0);
    });
    test('l\'ellipse couvre à peu près pi x rx x ry pixels', () {
      final Uint8List m = lamaEllipseMask(256, 256, 70, 100);
      int n = 0;
      for (final int v in m) {
        if (v == 255) n++;
      }
      expect((n - math.pi * 70 * 100).abs() < 400, isTrue);
      expect(m[256 * kLamaSide + 256], 255);
      expect(m[0], 0);
    });
    test('la zone à remplir est grisée, le reste est intact', () {
      final Uint8List img = Uint8List(kLamaSide * kLamaSide * 4)..fillRange(0, kLamaSide * kLamaSide * 4, 10);
      final Uint8List m = lamaEllipseMask(256, 256, 20, 20);
      final Uint8List g = lamaShowHole(img, m);
      expect(g[(256 * kLamaSide + 256) * 4], 128);
      expect(g[0], 10);
    });
  });

  group('Réglages de l\'appareil', () {
    test('ISO, ouverture, vitesse : codages vérifiés sur l\'A7 IV', () {
      expect(formatIso(100), '100');
      expect(formatIso(0xFFFFFF), 'AUTO');
      expect(formatIso(0x1000000 | 3200), '3200');
      expect(formatAperture(0x276), 'ƒ/6,3');
      expect(formatAperture(0x230), 'ƒ/5,6');
      expect(formatAperture(400), 'ƒ/4');
      expect(formatShutterCode(0x10064), '1/100');
      expect(formatShutterCode(0x1007D), '1/125');
      expect(formatShutterCode((5 << 16) | 10), '0,5"');
      expect(formatShutterCode((30 << 16) | 1), '30"');
      expect(formatShutterCode(0), '—');
    });

    test('mode d\'exposition : codes relevés sur l\'A7 IV', () {
      expect(formatExposureMode(0x1), 'M');
      expect(formatExposureMode(0x10002), 'P');
      expect(formatExposureMode(0x20003), 'A');
      expect(formatExposureMode(0x30004), 'S');
      expect(formatExposureMode(0x48000), 'Auto');
      expect(formatExposureMode(0x50001), '0x50001');
    });

    test('batterie et valeur brute', () {
      expect(batteryPercent(87), 87);
      expect(batteryPercent(0xFF), -1);
      expect(formatRaw(0x11), '0x11');
    });

    test('choix voisins et tri', () {
      final List<int> iso = sortedChoices(kPropIso, <int>[200, 0xFFFFFF, 100, 400, 100]);
      expect(iso, <int>[0xFFFFFF, 100, 200, 400]);
      final List<int> sh = sortedChoices(kPropShutter, <int>[0x1007D, 0x10064, (2 << 16) | 1]);
      expect(sh, <int>[0x1007D, 0x10064, (2 << 16) | 1]);
      expect(neighborChoice(iso, 200, 1), 400);
      expect(neighborChoice(iso, 200, -1), 100);
      expect(neighborChoice(iso, 400, 1), isNull);
      expect(neighborChoice(iso, 999, 1), isNull);
      expect(neighborChoice(<int>[], 1, 1), isNull);
    });
  });
}
