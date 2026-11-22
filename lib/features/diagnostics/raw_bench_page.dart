import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../engine/engine.dart';
import 'pc_reference.dart';

String _shutter(num s) {
  if (s <= 0) return '?';
  if (s >= 1) return '${s.toStringAsFixed(1)} s';
  return '1/${(1 / s).round()} s';
}

/// Étape 3a : lecture d'un RAW par LibRaw sur l'iPad.
///
/// Choisir un fichier RAW (ARW, DNG, CR3, NEF…) : l'écran l'ouvre, lit ses métadonnées,
/// le développe deux fois (demi-taille, puis complet avec démosaïquage DHT) en mesurant
/// seul les temps et la mémoire, affiche l'aperçu et produit un rapport à copier.
class RawBenchPage extends StatefulWidget {
  const RawBenchPage({super.key});

  @override
  State<RawBenchPage> createState() => _RawBenchPageState();
}

class _RawBenchPageState extends State<RawBenchPage> {
  final List<String> _lines = <String>[];
  bool _running = false;
  ui.Image? _shown;
  String? _lastPath;

  void _log(String text) {
    if (!mounted) return;
    setState(() => _lines.add(text));
  }

  @override
  void dispose() {
    _shown?.dispose();
    super.dispose();
  }

  Future<void> _choose() async {
    final FilePickerResult? res = await FilePicker.platform.pickFiles(type: FileType.any);
    final String? path = res?.files.single.path;
    if (path == null) return;
    _lastPath = path;
    await _run(path, res!.files.single.name);
  }

  Future<void> _show(RenderResult r) async {
    final Completer<ui.Image> c = Completer<ui.Image>();
    ui.decodeImageFromPixels(r.rgba, r.width, r.height, ui.PixelFormat.rgba8888, c.complete);
    final ui.Image img = await c.future;
    if (!mounted) {
      img.dispose();
      return;
    }
    final ui.Image? old = _shown;
    setState(() => _shown = img);
    WidgetsBinding.instance.addPostFrameCallback((_) => old?.dispose());
  }

  Future<void> _run(String path, String name) async {
    if (_running) return;
    setState(() {
      _running = true;
      _lines.clear();
    });
    _log('Sursaut iPad — lecture d\'un RAW (LibRaw)');
    _log('Date : ${DateTime.now()}');
    _log('Système : ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
    _log('Coeurs : ${Platform.numberOfProcessors}');
    final EngineInfo eng = EngineInfo.probe();
    if (eng.version == null) {
      _log('MOTEUR ABSENT : ${eng.error}');
      if (mounted) setState(() => _running = false);
      return;
    }
    _log('Moteur : ${eng.version}');
    RawFile? raw;
    try {
      raw = RawFile.open(path);
      final Map<String, dynamic> i = raw.info();
      _log('');
      _log('Fichier : $name (${((i['file_bytes'] as num) / 1e6).toStringAsFixed(1)} Mo)');
      _log('LibRaw : ${i['libraw']}');
      _log('Appareil : ${i['make']} ${i['model']}');
      _log('Objectif : ${i['lens']}');
      _log('ISO ${(i['iso'] as num).round()} · ${_shutter(i['shutter'] as num)} · '
          'f/${i['aperture']} · ${i['focal_len']} mm');
      final int ts = (i['timestamp'] as num).toInt();
      if (ts > 0) {
        _log('Prise de vue : ${DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: true)}');
      }
      _log('Image : ${i['width']}×${i['height']} px '
          '(${((i['width'] as num) * (i['height'] as num) / 1e6).toStringAsFixed(1)} Mpx), '
          'capteur ${i['raw_width']}×${i['raw_height']}');
      _log('Balance des blancs de l\'appareil (R, V, B, V2) : ${i['cam_mul']}');
      _log('Valeur maximale du capteur : ${i['maximum']}');
      for (final bool half in <bool>[true, false]) {
        _log('');
        _log(half ? '— Développement demi-taille (sans démosaïquage) —'
            : '— Développement complet (démosaïquage DHT) —');
        final Stopwatch sw = Stopwatch()..start();
        final RenderResult r = await raw.develop(half: half, maxSide: 2752, look: 2);
        final int wall = sw.elapsedMilliseconds;
        final Map<String, dynamic> last = raw.info()['last'] as Map<String, dynamic>;
        _log('Ouverture ${last['open_ms']} ms · lecture du capteur ${last['unpack_ms']} ms · '
            'traitement ${last['process_ms']} ms · conversion ${last['convert_ms']} ms');
        _log('Total moteur ${last['total_ms']} ms (mesuré côté écran : $wall ms)');
        _log('Image développée ${last['full_w']}×${last['full_h']} → aperçu ${r.width}×${r.height}');
        _log('Mémoire maximale du processus : ${last['peak_rss_mb']} Mo');
        _log('Rendu de base : ${last['look']} (marge hautes lumières ${last['headroom']})');
        final (double, double)? gap =
            comparePcGrid(name, half, last['grid'] as List<dynamic>);
        if (gap == null) {
          _log('Écart avec le PC : pas de référence pour ce fichier (envoyez-moi la GRILLE ci-dessous).');
        } else {
          _log('Écart avec le PC : moyen ${gap.$1.toStringAsFixed(2)} niveau, maximal ${gap.$2.toStringAsFixed(2)} niveau (sur 255 ; objectif ≤ 1).');
        }
        _log('GRILLE ${half ? 'demi' : 'complet'} (moyennes 8×8×3, 0..255) : ${(last['grid'] as List<dynamic>).join(',')}');
        await _show(r);
      }
      _log('');
      _log('FIN DU TEST.');
    } catch (e) {
      _log('ERREUR : $e');
    } finally {
      raw?.close();
      if (mounted) setState(() => _running = false);
    }
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
        title: const Text('Lecture d\'un RAW'),
        actions: <Widget>[
          TextButton(
              onPressed: _running || _lastPath == null
                  ? null
                  : () => _run(_lastPath!, _lastPath!.split(RegExp(r'[\\/]')).last),
              child: const Text('Relancer')),
          TextButton(
              onPressed: _lines.isEmpty ? null : _copy,
              child: const Text('Copier le rapport')),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _running ? null : _choose,
              child: const Text('Choisir un RAW'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            if (_running) const LinearProgressIndicator(),
            if (_shown != null)
              Expanded(
                flex: 3,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: InteractiveViewer(
                    maxScale: 8,
                    child: Center(child: RawImage(image: _shown, fit: BoxFit.contain)),
                  ),
                ),
              ),
            Expanded(
              flex: 2,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: SelectableText(
                    _lines.isEmpty
                        ? 'Touchez « Choisir un RAW » et sélectionnez un fichier ARW dans Fichiers.'
                        : _lines.join('\n'),
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
