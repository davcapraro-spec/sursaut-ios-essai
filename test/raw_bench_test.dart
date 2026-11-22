import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sursaut_essai/features/diagnostics/raw_bench_page.dart';

void main() {
  testWidgets('l\'écran de lecture RAW s\'affiche et invite à choisir un fichier',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: RawBenchPage()));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Choisir un RAW'), findsOneWidget);
    expect(find.textContaining('Touchez'), findsOneWidget);
  });
}
