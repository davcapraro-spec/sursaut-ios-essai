import 'package:flutter/material.dart';

import 'camera_bench/camera_bench_page.dart';
import 'engine_bench_page.dart';
import 'pencil_bench/pencil_bench_page.dart';

/// Outils de mesure : ce que l'iPad, le moteur, le Pencil et l'appareil font réellement.
class DiagnosticsPage extends StatelessWidget {
  const DiagnosticsPage({super.key});

  void _open(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Diagnostics')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: <Widget>[
          ListTile(
            leading: const Icon(Icons.speed),
            title: const Text('Test automatique du moteur'),
            subtitle: const Text('Mesure la vitesse du moteur sur cet iPad et produit un rapport à copier'),
            onTap: () => _open(context, const EngineBenchPage()),
          ),
          ListTile(
            leading: const Icon(Icons.edit),
            title: const Text('Banc Apple Pencil'),
            subtitle: const Text('Pression, inclinaison, roulis, survol, serrage'),
            onTap: () => _open(context, const PencilBenchPage()),
          ),
          ListTile(
            leading: const Icon(Icons.usb),
            title: const Text('Banc Appareil'),
            subtitle: const Text('Lecture et écriture des réglages, déclenchement, aperçu'),
            onTap: () => _open(context, const CameraBenchPage()),
          ),
        ],
      ),
    );
  }
}
