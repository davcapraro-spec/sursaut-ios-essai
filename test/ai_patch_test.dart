import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sursaut_essai/domain/ai_patch.dart';
import 'package:sursaut_essai/domain/lama_prep.dart';
import 'package:sursaut_essai/domain/recipe_history.dart';

Uint8List _solid(int w, int h, int r, int g, int b) {
  final Uint8List px = Uint8List(w * h * 4);
  for (int i = 0; i < w * h; i++) {
    px[i * 4] = r;
    px[i * 4 + 1] = g;
    px[i * 4 + 2] = b;
    px[i * 4 + 3] = 255;
  }
  return px;
}

Uint8List _block(int pw, int ph, int x0, int y0, int x1, int y1) {
  final Uint8List m = Uint8List(pw * ph);
  for (int y = y0; y < y1; y++) {
    for (int x = x0; x < x1; x++) {
      m[y * pw + x] = 255;
    }
  }
  return m;
}

void main() {
  test('fenêtre : autour de la zone, dans la photo, au moins la taille minimale', () {
    final Uint8List plane = _block(100, 100, 40, 40, 50, 50);
    final AiWindow? win = aiWindow(plane, 100, 100, 2000, 2000);
    expect(win, isNotNull);
    expect(win!.side, greaterThanOrEqualTo(kAiMinWindow));
    expect(win.x0, greaterThanOrEqualTo(0));
    expect(win.x0 + win.side, lessThanOrEqualTo(2000));
    // la zone (pixels 800..1000) est dans la fenêtre
    expect(win.x0, lessThanOrEqualTo(800));
    expect(win.x0 + win.side, greaterThanOrEqualTo(1000));
    expect(win.tooBig, isFalse);
  });

  test('fenêtre : zone vide = null ; zone énorme = fenêtre limitée à la photo et signalée', () {
    expect(aiWindow(Uint8List(100 * 100), 100, 100, 1000, 800), isNull);
    final AiWindow? win = aiWindow(_block(100, 100, 0, 0, 100, 100), 100, 100, 1000, 800);
    expect(win!.side, 800);
    expect(win.tooBig, isTrue);
  });

  test('masque de la fenêtre : la zone y est, le reste non', () {
    final Uint8List plane = _block(100, 100, 40, 40, 60, 60);
    final AiWindow win = aiWindow(plane, 100, 100, 1000, 1000)!;
    final Uint8List m = aiWindowMask(plane, 100, 100, 1000, 1000, win);
    expect(m[(kLamaSide ~/ 2) * kLamaSide + kLamaSide ~/ 2], 255);
    expect(m[0], 0);
  });

  test('agrandir la zone : les voisins du bord passent à 255', () {
    final Uint8List m = Uint8List(kLamaSide * kLamaSide);
    m[100 * kLamaSide + 100] = 255;
    final Uint8List g = growMask(m, 3);
    expect(g[100 * kLamaSide + 103], 255);
    expect(g[103 * kLamaSide + 100], 255);
    expect(g[100 * kLamaSide + 104], 0);
  });

  test('fondu : plein au centre de la zone, nul loin de la zone', () {
    final Uint8List m = Uint8List(kLamaSide * kLamaSide);
    for (int y = 200; y < 300; y++) {
      for (int x = 200; x < 300; x++) {
        m[y * kLamaSide + x] = 255;
      }
    }
    final Uint8List a = featherAlpha(m, 3);
    expect(a[250 * kLamaSide + 250], 255);
    expect(a[10 * kLamaSide + 10], 0);
  });

  test('pose d\'une rustine : l\'intérieur change, l\'extérieur ne bouge pas, sans rustine rien ne change', () {
    const int w = 400, h = 300;
    final Uint8List photo = _solid(w, h, 10, 20, 30);
    final Uint8List filled = _solid(kLamaSide, kLamaSide, 200, 100, 50);
    final Uint8List alpha = Uint8List(kLamaSide * kLamaSide)..fillRange(0, kLamaSide * kLamaSide, 255);
    final AiPatch patch = makeAiPatch(filled: filled, alpha: alpha, win: const AiWindow(100, 50, 160, false), w: w, h: h, id: 'a');
    final Uint8List out = applyAiPatches(photo, w, h, <AiPatch>[patch]);
    final int inside = (100 * w + 180) * 4;
    expect(out.sublist(inside, inside + 3), <int>[200, 100, 50]);
    final int outside = (10 * w + 10) * 4;
    expect(out.sublist(outside, outside + 3), <int>[10, 20, 30]);
    expect(photo[inside], 10, reason: 'l\'original n\'est pas modifié');
    expect(identical(applyAiPatches(photo, w, h, <AiPatch>[]), photo), isTrue);
  });

  test('la rustine vaut pour une autre taille de la même photo (proportions)', () {
    final Uint8List filled = _solid(kLamaSide, kLamaSide, 255, 0, 0);
    final Uint8List alpha = Uint8List(kLamaSide * kLamaSide)..fillRange(0, kLamaSide * kLamaSide, 255);
    final AiPatch patch = makeAiPatch(filled: filled, alpha: alpha, win: const AiWindow(100, 50, 160, false), w: 400, h: 300, id: 'b');
    final Uint8List big = applyAiPatches(_solid(800, 600, 0, 0, 0), 800, 600, <AiPatch>[patch]);
    final int p = (200 * 800 + 360) * 4; // le centre de la fenêtre, à l'échelle 2
    expect(big[p], 255);
    final int q = (20 * 800 + 20) * 4;
    expect(big[q], 0);
  });

  test('grain : une zone lisse sans voisinage texturé reste inchangée ; la sortie garde la taille', () {
    final Uint8List orig = _solid(kLamaSide, kLamaSide, 100, 100, 100);
    final Uint8List mask = Uint8List(kLamaSide * kLamaSide);
    for (int y = 200; y < 260; y++) {
      for (int x = 200; x < 260; x++) {
        mask[y * kLamaSide + x] = 255;
      }
    }
    final Uint8List filled = _solid(kLamaSide, kLamaSide, 100, 100, 100);
    final Uint8List out = matchGrain(orig, mask, filled);
    expect(out.length, filled.length);
    expect(out[(230 * kLamaSide + 230) * 4], 100);
  });

  test('fichier de retouche : les rustines sont séparées du reste et retrouvées', () {
    final AiPatch patch = <String, dynamic>{'id': 'x', 'x0': 0.1, 'y0': 0.2, 's': 0.3, 'z': 'AAAA'};
    final (List<AiPatch> got, Map<String, dynamic> rest) = splitAiPatches(<String, dynamic>{kAiPatchKey: <dynamic>[patch], 'autre': 1});
    expect(got.length, 1);
    expect(got.first['id'], 'x');
    expect(rest.containsKey(kAiPatchKey), isFalse);
    expect(rest['autre'], 1);
  });

  test('historique : une rustine gardée s\'annule et se rétablit', () {
    final AiPatch patch = <String, dynamic>{'id': 'x', 'x0': 0.1, 'y0': 0.2, 's': 0.3, 'z': 'AAAA'};
    final RecipeHistory h = RecipeHistory(<String, double>{'exposure': 0});
    h.commit(<String, double>{'exposure': 0}, patches: <AiPatch>[patch]);
    expect(h.canUndo, isTrue);
    expect(h.currentPatches.length, 1);
    h.undo();
    expect(h.currentPatches, isEmpty);
    h.redo();
    expect(h.currentPatches.length, 1);
  });
}
