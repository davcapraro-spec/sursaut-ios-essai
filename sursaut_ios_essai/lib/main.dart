import 'package:flutter/material.dart';

import 'common/theme.dart';
import 'features/develop/develop_page.dart';

void main() {
  runApp(const SursautApp());
}

/// Coque de l'application d'essai (étape 0).
class SursautApp extends StatelessWidget {
  const SursautApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sursaut iPad (essai)',
      debugShowCheckedModeBanner: false,
      theme: sursautDarkTheme(),
      home: const DevelopPage(),
    );
  }
}
