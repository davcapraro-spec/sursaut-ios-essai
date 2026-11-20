import 'package:flutter_test/flutter_test.dart';

import 'package:sursaut_essai/features/engine/engine_page.dart';
import 'package:flutter/material.dart';

void main() {
  testWidgets('l\'écran Moteur s\'affiche même sans bibliothèque Rust',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: EnginePage()));
    expect(find.textContaining('Moteur Rust'), findsWidgets);
    expect(find.text('Image d\'essai'), findsOneWidget);
  });
}
