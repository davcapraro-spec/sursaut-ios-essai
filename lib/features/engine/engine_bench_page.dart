import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../engine/engine.dart';

/// Photo synthétique (dégradés, motif, bruit déterministe) : donne du travail à tous les étages.
Uint8List _syntheticPhoto(int w, int h) {
  final Uint8List px = Uint8List(w * h * 4);
  int s = 12345;
  int i = 0;
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      s = (s * 1664525 + 1013904223) & 0xFFFFFFFF;
      final int noise = ((s >> 24) - 128) ~/ 12;
      final int r = x * 255 ~/ w + noise;
      final int g = y * 255 ~/ h + noise;
      final int b = (((x ~/ 40 + y ~/ 40) % 2) * 160 + 40) + noise;
      px[i++] = r < 0 ? 0 : (r > 255 ? 255 : r);
      px[i++] = g < 0 ? 0 : (g > 255 ? 255 : g);
      px[i++] = b < 0 ? 0 : (b > 255 ? 255 : b);
      px[i++] = 255;
    }
  }
  return px;
}

Uint8List _photoTask(List<int> size) => _syntheticPhoto(size[0], size[1]);

const List<(String, String)> _steps = <(String, String)>[
  ('Premier rendu (tous les étages)', '{"exposure":0.3}'),
  ('Même recette (tout vient du cache)', '{"exposure":0.3}'),
  ('Saturation +30', '{"exposure":0.3,"saturation":30}'),
  ('Saturation +45', '{"exposure":0.3,"saturation":45}'),
  ('Exposition +0,6', '{"exposure":0.6,"saturation":45}'),
  ('Contraste +25', '{"exposure":0.6,"saturation":45,"contrast":25}'),
  ('Hautes lumières -40, ombres +40',
      '{"exposure":0.6,"saturation":45,"contrast":25,"highlights":-40,"shadows":40}'),
  ('Température +20',
      '{"exposure":0.6,"saturation":45,"contrast":25,"highlights":-40,"shadows":40,"temperature":20}'),
  ('Clarté +40',
      '{"exposure":0.6,"saturation":45,"contrast":25,"highlights":-40,"shadows":40,"temperature":20,"clarity":40}'),
  ('Texture +40',
      '{"exposure":0.6,"saturation":45,"contrast":25,"highlights":-40,"shadows":40,"temperature":20,"clarity":40,"texture":40}'),
  ('Voile +30',
      '{"exposure":0.6,"saturation":45,"contrast":25,"highlights":-40,"shadows":40,"temperature":20,"clarity":40,"texture":40,"dehaze":30}'),
  ('Netteté +60',
      '{"exposure":0.6,"saturation":45,"contrast":25,"highlights":-40,"shadows":40,"temperature":20,"clarity":40,"texture":40,"dehaze":30,"sharpen_amount":60}'),
  ('Recadrage + redressement 3°',
      '{"exposure":0.6,"saturation":45,"contrast":25,"clarity":40,"crop_left":0.05,"crop_top":0.1,"crop_right":0.95,"crop_bottom":0.9,"angle":3.0}'),
];

/// Test automatique : mesure le moteur sur l'iPad, sans que l'utilisateur ait à toucher un curseur.
class EngineBenchPage extends StatefulWidget {
  const EngineBenchPage({super.key});

  @override
  State<EngineBenchPage> createState() => _EngineBenchPageState();
}

class _EngineBenchPageState extends State<EngineBenchPage> {
  final List<String> _lines = <String>[];
  bool _running = false;

  void _log(String text) {
    if (!mounted) return;
    setState(() => _lines.add(text));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _pass(int w, int h) async {
    _log('');
    _log('— Image de ${w}x$h px (${(w * h / 1e6).toStringAsFixed(1)} Mpx) —');
    final Stopwatch sw = Stopwatch()..start();
    final Uint8List photo = await Isolate.run(() => _photoTask(<int>[w, h]));
    _log('Fabrication de l\'image d\'essai : ${sw.elapsedMilliseconds} ms');
    sw.reset();
    final PhotoEngine engine = PhotoEngine.open(photo, w, h);
    _log('Ouverture dans le moteur : ${sw.elapsedMilliseconds} ms');
    try {
      for (final (String label, String json) in _steps) {
        sw.reset();
        final RenderResult r = await engine.render(json);
        _log('$label : ${sw.elapsedMilliseconds} ms (résultat ${r.width}x${r.height})');
      }
    } finally {
      engine.close();
    }
  }

  Future<void> _run() async {
    if (_running) return;
    setState(() {
      _running = true;
      _lines.clear();
    });
    _log('Sursaut iPad — test automatique du moteur');
    _log('Date : ${DateTime.now()}');
    _log('Système : ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
    _log('Coeurs : ${Platform.numberOfProcessors}');
    final EngineInfo info = EngineInfo.probe();
    if (info.version == null) {
      _log('MOTEUR ABSENT : ${info.error}');
    } else {
      _log('Moteur : ${info.version}');
      try {
        await _pass(2752, 2064); // taille d'aperçu de l'iPad Pro 13"
        await _pass(1600, 1200); // taille d'aperçu du PC, pour comparer
        _log('');
        _log('FIN DU TEST.');
      } catch (e) {
        _log('ERREUR : $e');
      }
    }
    if (mounted) setState(() => _running = false);
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _lines.join('\n')));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Rapport copié : collez-le dans Claude.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Test automatique du moteur'),
        actions: <Widget>[
          TextButton(
              onPressed: _running ? null : _run, child: const Text('Relancer')),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _lines.isEmpty ? null : _copy,
              child: const Text('Copier le rapport'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            if (_running) const LinearProgressIndicator(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: SelectableText(
                    _lines.join('\n'),
                    style: const TextStyle(fontFamily: 'Menlo', fontSize: 13),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
