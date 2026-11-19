import 'package:flutter_test/flutter_test.dart';

import 'package:sursaut_essai/main.dart';

void main() {
  testWidgets('l\'écran d\'essai s\'affiche', (WidgetTester tester) async {
    await tester.pumpWidget(const SursautApp());
    expect(find.text('Choisir une photo'), findsOneWidget);
    expect(find.textContaining('Aucune photo'), findsOneWidget);
  });
}
