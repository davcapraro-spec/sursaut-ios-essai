import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sursaut_essai/features/develop/develop_page.dart';

void main() {
  testWidgets('l\'écran Moteur s\'affiche même sans bibliothèque Rust',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: DevelopPage()));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Moteur Rust'), findsWidgets);
    expect(find.text('Image d\'essai'), findsOneWidget);
  });

  testWidgets('les panneaux Courbe et Couleur s\'affichent', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: DevelopPage()));
    await tester.pump();
    expect(find.text('TONALITÉ'), findsOneWidget);
    await tester.tap(find.text('Courbe'));
    await tester.pump();
    expect(find.text('Réinitialiser la courbe RVB'), findsOneWidget);
    await tester.tap(find.text('Couleur'));
    await tester.pump();
    expect(find.text('MÉLANGEUR DE COULEURS'), findsOneWidget);
    expect(find.text('Magenta'), findsOneWidget);
    await tester.tap(find.text('Détail'));
    await tester.pump();
    expect(find.text('RÉDUCTION DU BRUIT'), findsOneWidget);
    expect(find.text('VIGNETAGE'), findsOneWidget);
    await tester.tap(find.text('Supprimer'));
    await tester.pump();
    expect(find.text('RETOUCHE DE TACHES'), findsOneWidget);
    expect(find.text('POUSSIÈRE AUTOMATIQUE'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
