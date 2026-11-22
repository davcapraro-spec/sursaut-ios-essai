import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sursaut_essai/app/app.dart';

void main() {
  testWidgets('l\'accueil propose les trois parties', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const SursautApp());
    expect(find.text('Développer'), findsOneWidget);
    expect(find.text('Capturer'), findsOneWidget);
    expect(find.text('Diagnostics'), findsOneWidget);
  });
}
