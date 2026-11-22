import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sursaut_essai/features/diagnostics/engine_bench_page.dart';

void main() {
  testWidgets('le test automatique signale un moteur absent sans planter',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: EngineBenchPage()));
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('MOTEUR ABSENT'), findsOneWidget);
  });
}
