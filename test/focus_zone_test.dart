import 'package:flutter_test/flutter_test.dart';
import 'package:sursaut_essai/domain/focus_zone.dart';

void main() {
  test('zone inconnue : toute la grille', () {
    expect(const FocusZone().known, isFalse);
    expect(const FocusZone().asArea(), <int>[0, 0, 639, 479]);
  });

  test('toucher près du bord gauche, cadre arrêté plus à l\'intérieur : limite gauche apprise', () {
    final FocusZone z = learnFocusZone(const FocusZone(), tx: 0.0, ty: 0.5, cx: 0.15, cy: 0.5);
    expect(z.xMin, (0.15 * 639).round());
    expect(z.xMax, isNull);
    expect(z.yMin, isNull);
    expect(z.known, isTrue);
  });

  test('toucher près du bord droit et du bas : limites droite et basse apprises', () {
    final FocusZone z = learnFocusZone(const FocusZone(), tx: 1.0, ty: 1.0, cx: 0.85, cy: 0.8);
    expect(z.xMax, (0.85 * 639).round());
    expect(z.yMax, (0.8 * 479).round());
    expect(z.xMin, isNull);
  });

  test('cadre arrivé au point demandé : rien appris', () {
    final FocusZone z = learnFocusZone(const FocusZone(), tx: 0.0, ty: 0.0, cx: 0.01, cy: 0.01);
    expect(z.known, isFalse);
  });

  test('toucher au milieu : rien appris, même si le cadre n\'a pas bougé', () {
    final FocusZone z = learnFocusZone(const FocusZone(), tx: 0.5, ty: 0.5, cx: 0.2, cy: 0.2);
    expect(z.known, isFalse);
  });

  test('un cadre passé de l\'autre côté du milieu n\'est pas pris pour une limite', () {
    final FocusZone z = learnFocusZone(const FocusZone(), tx: 0.1, ty: 0.5, cx: 0.7, cy: 0.5);
    expect(z.xMin, isNull);
  });

  test('les limites déjà apprises sont gardées', () {
    final FocusZone a = learnFocusZone(const FocusZone(), tx: 0.0, ty: 0.5, cx: 0.15, cy: 0.5);
    final FocusZone b = learnFocusZone(a, tx: 1.0, ty: 0.5, cx: 0.85, cy: 0.5);
    expect(b.xMin, a.xMin);
    expect(b.xMax, (0.85 * 639).round());
  });

  test('un cadre vu hors de la zone supposée l\'élargit', () {
    final List<int> a = widenArea(<int>[40, 30, 600, 450], cx: 0.03, cy: 0.99);
    expect(a, <int>[(0.03 * 639).round(), 30, 600, (0.99 * 479).round()]);
  });

  test('un cadre dans la zone : rien ne change', () {
    expect(widenArea(<int>[40, 30, 600, 450], cx: 0.5, cy: 0.5), <int>[40, 30, 600, 450]);
  });
}
