import 'package:flutter/material.dart';

import '../common/theme.dart';
import 'home_page.dart';

/// Coque de l'application : thème, navigation de départ.
class SursautApp extends StatelessWidget {
  const SursautApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sursaut iPad',
      debugShowCheckedModeBanner: false,
      theme: sursautDarkTheme(),
      home: const HomePage(),
    );
  }
}
