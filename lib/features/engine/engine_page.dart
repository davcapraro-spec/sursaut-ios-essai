import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../engine/engine.dart';
import 'engine_bench_page.dart';

/// Étape 1 : aperçu + curseurs branchés sur le moteur Rust.
///
/// La photo choisie est ramenée à 2 752 px de grand côté (taille d'aperçu de
/// l'iPad Pro 13"), puis chaque mouvement de curseur rend l'image par le moteur.
/// L'écran affiche le temps réel de rendu : c'est la mesure demandée par
/// l'architecture (§ 5.2).
class EnginePage extends StatefulWidget {
  const EnginePage({super.key});

  @override
  State<EnginePage> createState() => _EnginePageState();
}

class _Param {
  const _Param(this.key, this.label, this.min, this.max);
  final String key;
  final String label;
  final double min;
  final double max;
}

const List<_Param> _params = <_Param>[
  _Param('exposure', 'Exposition (IL)', -3, 3),
  _Param('contrast', 'Contraste', -100, 100),
  _Param('highlights', 'Hautes lumières', -100, 100),
  _Param('shadows', 'Ombres', -100, 100),
  _Param('whites', 'Blancs', -100, 100),
  _Param('blacks', 'Noirs', -100, 100),
  _Param('temperature', 'Température', -100, 100),
  _Param('tint', 'Teinte', -100, 100),
  _Param('vibrance', 'Vibrance', -100, 100),
  _Param('saturation', 'Saturation', -100, 100),
  _Param('texture', 'Texture', -100, 100),
  _Param('clarity', 'Clarté', -100, 100),
  _Param('dehaze', 'Correction du voile', -100, 100),
  _Param('sharpen_amount', 'Netteté (gain)', 0, 100),
];

class _EnginePageState extends State<EnginePage> {
  final ImagePicker _picker = ImagePicker();
  late final EngineInfo _info;
  PhotoEngine? _photo;
  String? _error;

  Uint8List? _srcRgba;
  int _w = 0, _h = 0;
  ui.Image? _shown;
  bool _before = false;
  String _name = '';

  final Map<String, double> _values = <String, double>{
    for (final _Param p in _params) p.key: 0,
  };

  bool _busy = false;
  bool _dirty = false;
  int _renderMs = -1;
  int _imageMs = -1;

  @override
  void initState() {
    super.initState();
    _info = EngineInfo.probe();
  }

  Future<void> _useRgba(Uint8List rgba, int w, int h, String name) async {
    _photo?.close();
    _photo = null;
    _error = null;
    if (_info.version != null) {
      try {
        _photo = PhotoEngine.open(rgba, w, h);
      } catch (e) {
        _error = e.toString();
      }
    }
    setState(() {
      _srcRgba = rgba;
      _w = w;
      _h = h;
      _name = name;
      for (final _Param p in _params) {
        _values[p.key] = 0;
      }
    });
    await _refresh();
  }

  Future<void> _choose() async {
    final XFile? file = await _picker.pickImage(source: ImageSource.gallery);
    if (file == null) return;
    final Uint8List bytes = await file.readAsBytes();
    final ui.Codec probe = await ui.instantiateImageCodec(bytes);
    final ui.FrameInfo first = await probe.getNextFrame();
    final int srcW = first.image.width, srcH = first.image.height;
    first.image.dispose();
    probe.dispose();
    final ui.Codec codec = (srcW > 2752 || srcH > 2752)
        ? await ui.instantiateImageCodec(bytes,
            targetWidth: srcW >= srcH ? 2752 : null,
            targetHeight: srcH > srcW ? 2752 : null)
        : await ui.instantiateImageCodec(bytes);
    final ui.FrameInfo frame = await codec.getNextFrame();
    final ByteData? data =
        await frame.image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    if (data == null || !mounted) return;
    await _useRgba(
        data.buffer.asUint8List(), frame.image.width, frame.image.height, file.name);
  }

  /// Image d'essai sans fichier : dégradés et pastilles de couleur.
  Future<void> _useTestImage() async {
    const int w = 1600, h = 1000;
    final Uint8List px = Uint8List(w * h * 4);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final int i = (y * w + x) * 4;
        final bool patch = y > 700;
        if (patch) {
          final int k = x * 8 ~/ w;
          const List<List<int>> cols = <List<int>>[
            <int>[200, 50, 40], <int>[230, 140, 40], <int>[230, 210, 60],
            <int>[70, 160, 70], <int>[60, 160, 200], <int>[60, 70, 190],
            <int>[150, 70, 170], <int>[128, 128, 128],
          ];
          px[i] = cols[k][0];
          px[i + 1] = cols[k][1];
          px[i + 2] = cols[k][2];
        } else {
          px[i] = x * 255 ~/ w;
          px[i + 1] = y * 255 ~/ 700;
          px[i + 2] = 255 - x * 255 ~/ w;
        }
        px[i + 3] = 255;
      }
    }
    await _useRgba(px, w, h, 'Image d\'essai');
  }

  String _recipeJson() => jsonEncode(_values);

  /// Un seul rendu à la fois ; si un curseur bouge pendant le rendu, on refait
  /// un rendu avec la dernière valeur (le dernier gagne).
  Future<void> _refresh() async {
    if (_busy) {
      _dirty = true;
      return;
    }
    final PhotoEngine? photo = _photo;
    final Uint8List? src = _srcRgba;
    if (photo == null || src == null) return;
    _busy = true;
    try {
      do {
        _dirty = false;
        final Stopwatch sw = Stopwatch()..start();
        int w = _w, h = _h;
        Uint8List out = src;
        if (!_before) {
          final RenderResult r = await photo.render(_recipeJson());
          out = r.rgba;
          w = r.width;
          h = r.height;
        }
        final int renderMs = sw.elapsedMilliseconds;
        sw.reset();
        final Completer<ui.Image> done = Completer<ui.Image>();
        ui.decodeImageFromPixels(out, w, h, ui.PixelFormat.rgba8888, done.complete);
        final ui.Image img = await done.future;
        final int imageMs = sw.elapsedMilliseconds;
        if (!mounted) return;
        final ui.Image? old = _shown;
        setState(() {
          _shown = img;
          _renderMs = renderMs;
          _imageMs = imageMs;
          _error = null;
        });
        // On libère l'ancienne image seulement après le dessin de la nouvelle.
        WidgetsBinding.instance.addPostFrameCallback((_) => old?.dispose());
      } while (_dirty);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      _busy = false;
    }
  }

  @override
  void dispose() {
    _photo?.close();
    _shown?.dispose();
    super.dispose();
  }

  String _fmt(_Param p) {
    final double v = _values[p.key]!;
    if (v == 0) return '0';
    final String s = p.key == 'exposure' ? v.toStringAsFixed(2) : v.round().toString();
    return v > 0 ? '+$s' : s.replaceFirst('-', '−');
  }

  @override
  Widget build(BuildContext context) {
    final bool ready = _srcRgba != null && _photo != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Moteur Rust (étape 1)'),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const EngineBenchPage())),
              child: const Text('Test auto')),
          TextButton(onPressed: _useTestImage, child: const Text('Image d\'essai')),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _choose,
              child: const Text('Choisir une photo'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                    _error != null
                        ? 'Erreur : $_error'
                        : _info.version == null
                            ? 'Moteur Rust ABSENT : ${_info.error}'
                            : 'Moteur Rust chargé : ${_info.version}',
                    style: TextStyle(
                        color: (_error != null || _info.version == null)
                            ? Colors.redAccent
                            : Colors.greenAccent)),
              ),
            ),
            Expanded(
              child: _shown == null
                  ? const Center(
                      child: Text('Touchez « Image d\'essai » ou « Choisir une photo ».'))
                  : InteractiveViewer(
                      maxScale: 8,
                      child: Center(
                        child: RawImage(image: _shown, fit: BoxFit.contain),
                      ),
                    ),
            ),
            Container(
              color: Theme.of(context).colorScheme.surface,
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
              constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.42),
              child: SingleChildScrollView(
                child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          _srcRgba == null
                              ? ''
                              : '$_name · $_w×$_h px · rendu moteur (fil séparé) $_renderMs ms · '
                                  'conversion $_imageMs ms',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      const Text('Avant'),
                      Switch(
                        value: _before,
                        onChanged: !ready
                            ? null
                            : (bool v) {
                                setState(() => _before = v);
                                _refresh();
                              },
                      ),
                    ],
                  ),
                  for (final _Param p in _params)
                    Row(
                      children: <Widget>[
                        SizedBox(width: 130, child: Text(p.label)),
                        Expanded(
                          child: GestureDetector(
                            onDoubleTap: !ready
                                ? null
                                : () {
                                    setState(() => _values[p.key] = 0);
                                    _refresh();
                                  },
                            child: Slider(
                              value: _values[p.key]!,
                              min: p.min,
                              max: p.max,
                              onChanged: !ready
                                  ? null
                                  : (double v) {
                                      setState(() {
                                        _values[p.key] = v;
                                        _before = false;
                                      });
                                      _refresh();
                                    },
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 52,
                          child: Text(_fmt(p),
                              textAlign: TextAlign.right,
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ),
                ],
              ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
