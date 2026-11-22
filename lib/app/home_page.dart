import 'package:flutter/material.dart';

import '../features/develop/develop_page.dart';
import '../features/diagnostics/camera_bench/camera_bench_page.dart';
import '../features/diagnostics/diagnostics_page.dart';

/// Accueil : les trois parties de l'application.
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  void _open(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('Sursaut', style: Theme.of(context).textTheme.displaySmall),
                  const SizedBox(height: 4),
                  const Text('Développement des photos et capture connectée'),
                  const SizedBox(height: 32),
                  Wrap(
                    spacing: 20,
                    runSpacing: 20,
                    children: <Widget>[
                      _Tile(
                        icon: Icons.tune,
                        title: 'Développer',
                        subtitle: 'Ouvrir une photo, la régler, la recadrer, l\'exporter',
                        onTap: () => _open(context, const DevelopPage()),
                      ),
                      _Tile(
                        icon: Icons.usb,
                        title: 'Capturer',
                        subtitle: 'Piloter l\'appareil par câble USB-C (banc d\'essai)',
                        onTap: () => _open(context, const CameraBenchPage()),
                      ),
                      _Tile(
                        icon: Icons.speed,
                        title: 'Diagnostics',
                        subtitle: 'Test du moteur, Apple Pencil, appareil photo',
                        onTap: () => _open(context, const DiagnosticsPage()),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 290,
      height: 240,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(icon, size: 36, color: Theme.of(context).colorScheme.primary),
                const Spacer(),
                Text(title, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 6),
                Text(subtitle),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
