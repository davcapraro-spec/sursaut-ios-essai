import 'package:flutter/material.dart';

import '../common/app_version.dart';
import '../features/capture/capture_page.dart';
import '../features/develop/develop_page.dart';
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
        child: Column(
          children: <Widget>[
            Expanded(
              child: Align(
                // Légèrement au-dessus du centre : le logo et les tuiles sont remontés.
                alignment: const Alignment(0, -0.35),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1000),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: <Widget>[
                        Center(
                          child: Stack(
                            alignment: Alignment.center,
                            children: <Widget>[
                              // Halo doré discret derrière le logo.
                              Container(
                                width: 900,
                                height: 300,
                                decoration: const BoxDecoration(
                                  gradient: RadialGradient(
                                    colors: <Color>[Color(0x2AD9A441), Color(0x00D9A441)],
                                    stops: <double>[0, 0.65],
                                  ),
                                ),
                              ),
                              Column(
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  Image.asset(
                                    'assets/logo_sursaut.png',
                                    width: 420,
                                    semanticLabel: 'Sursaut by David',
                                    errorBuilder: (BuildContext c, Object e, StackTrace? s) =>
                                        Text('Sursaut', style: Theme.of(c).textTheme.displaySmall),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 28),
                        Wrap(
                          alignment: WrapAlignment.center,
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
                              icon: Icons.photo_camera_outlined,
                              title: 'Capturer',
                              subtitle: 'Piloter l\'appareil par câble USB-C, déclencher, recevoir',
                              onTap: () => _open(
                                context,
                                CapturePage(
                                  onOpenPhoto: (BuildContext c, String path) => _open(c, DevelopPage(openPath: path)),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        OutlinedButton.icon(
                          onPressed: () => _open(context, const DiagnosticsPage()),
                          icon: const Icon(Icons.monitor_heart_outlined, size: 20),
                          label: const Text('Diagnostics'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white60,
                            side: const BorderSide(color: Color(0xFF3A3A40)),
                            shape: const StadiumBorder(),
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(bottom: 14),
              child: Text('Version $kAppVersion', style: TextStyle(fontSize: 13, color: Colors.white38)),
            ),
          ],
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
      height: 270,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: const Color(0xFF3A2C14),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(icon, size: 32, color: Theme.of(context).colorScheme.primary),
                ),
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
