import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../engine/engine.dart';
import '../../engine/recipe_store.dart';
import 'crop_overlay.dart';
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
  _Param('angle', 'Angle (°)', -15, 15),
];

/// Valeurs par défaut non nulles : le cadre de recadrage couvre toute l'image.
const Map<String, double> _cropDefaults = <String, double>{
  'crop_left': 0,
  'crop_top': 0,
  'crop_right': 1,
  'crop_bottom': 1,
};

double _def(String key) => _cropDefaults[key] ?? 0;

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
    ..._cropDefaults,
  };

  bool _cropMode = false;
  double? _aspect; // largeur/hauteur imposée ; null = cadre libre

  late RecipeHistory _history = RecipeHistory(<String, double>{});
  SidecarData _sidecar = SidecarData(<String, double>{}, <String, dynamic>{});
  String _saveInfo = '';
  String _key = '';

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
    _key = photoKey(rgba, w, h);
    final SidecarData loaded = await _readSidecar(_key);
    setState(() {
      _srcRgba = rgba;
      _w = w;
      _h = h;
      _name = name;
      _sidecar = loaded;
      for (final String k in _values.keys.toList()) {
        _values[k] = loaded.values[k] ?? _def(k);
      }
      _cropMode = false;
      _aspect = null;
      _history = RecipeHistory(_values);
      _saveInfo = loaded.values.isNotEmpty || loaded.extra.isNotEmpty
          ? 'Réglages retrouvés'
          : '';
    });
    await _refresh();
  }

  Iterable<String> get _keys => _values.keys;

  Future<File> _sidecarFile(String name) async {
    final Directory base = await getApplicationDocumentsDirectory();
    final Directory dir = Directory('${base.path}/reglages');
    if (!await dir.exists()) await dir.create(recursive: true);
    final String safe = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return File('${dir.path}/$safe.sursaut.json');
  }

  Future<SidecarData> _readSidecar(String name) async {
    try {
      final File f = await _sidecarFile(name);
      if (await f.exists()) {
        final SidecarData? d = SidecarData.parse(await f.readAsString(), _keys);
        if (d != null) return d;
      }
    } catch (_) {}
    return SidecarData(<String, double>{}, <String, dynamic>{});
  }

  Future<void> _writeSidecar() async {
    if (_srcRgba == null) return;
    try {
      final File f = await _sidecarFile(_key);
      await f.writeAsString(_sidecar.encode(_values, _keys, defaults: _cropDefaults));
      if (mounted) setState(() => _saveInfo = 'Réglages enregistrés');
    } catch (e) {
      if (mounted) setState(() => _saveInfo = 'Enregistrement impossible : $e');
    }
  }

  /// Valide l'état actuel : une étape d'annulation + sauvegarde du fichier.
  void _commit() {
    _history.commit(_values);
    _writeSidecar();
    setState(() {});
  }

  void _applyHistory(Map<String, double>? v) {
    if (v == null) return;
    setState(() {
      for (final String k in _values.keys.toList()) {
        _values[k] = v[k] ?? _def(k);
      }
      _before = false;
    });
    _writeSidecar();
    _refresh();
  }

  Future<void> _choose() async {
    final XFile? file = await _picker.pickImage(source: ImageSource.gallery);
    if (file == null) return;
    await _openBytes(await file.readAsBytes(), file.name);
  }

  /// Ouvre une photo depuis l'app Fichiers (iCloud Drive, clé USB, dossier de l'app...).
  Future<void> _chooseFile() async {
    final FilePickerResult? res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: <String>['jpg', 'jpeg', 'png', 'heic', 'heif', 'tif', 'tiff', 'bmp', 'gif', 'webp'],
    );
    final String? path = res?.files.single.path;
    if (path == null) return;
    try {
      await _openBytes(await File(path).readAsBytes(), res!.files.single.name);
    } catch (e) {
      _say('Ouverture impossible : $e');
    }
  }

  void _say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  final GlobalKey _exportKey = GlobalKey();
  bool _exporting = false;

  /// Développe la photo avec les réglages actuels (taille de travail), l'encode en JPEG
  /// et ouvre la feuille de partage : « Enregistrer dans Fichiers », « Enregistrer l'image »
  /// (Photos), AirDrop, Mail...
  Future<void> _export() async {
    final PhotoEngine? photo = _photo;
    if (photo == null || _exporting) return;
    final RenderBox? box = _exportKey.currentContext?.findRenderObject() as RenderBox?;
    final Rect origin =
        box != null ? box.localToGlobal(Offset.zero) & box.size : const Rect.fromLTWH(0, 0, 1, 1);
    setState(() => _exporting = true);
    try {
      final Map<String, dynamic> recipe = <String, dynamic>{..._sidecar.extra, ..._values};
      final RenderResult r = await photo.render(jsonEncode(recipe));
      final Uint8List jpg = await Isolate.run(() {
        final img.Image im = img.Image.fromBytes(
            width: r.width, height: r.height, bytes: Uint8List.fromList(r.rgba).buffer, numChannels: 4,
            order: img.ChannelOrder.rgba);
        return Uint8List.fromList(img.encodeJpg(im, quality: 92));
      });
      final Directory tmp = await getTemporaryDirectory();
      String base = _name.replaceAll(RegExp(r'\.[^.]*$'), '');
      base = base.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      if (base.isEmpty) base = 'photo';
      final File out = File('${tmp.path}/${base}_sursaut.jpg');
      await out.writeAsBytes(jpg, flush: true);
      await Share.shareXFiles(<XFile>[XFile(out.path, mimeType: 'image/jpeg')],
          sharePositionOrigin: origin);
      _say('Photo développée : ${r.width}×${r.height} px, ${(jpg.length / 1e6).toStringAsFixed(1)} Mo');
    } catch (e) {
      _say('Export impossible : $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _openBytes(Uint8List bytes, String name) async {
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
        data.buffer.asUint8List(), frame.image.width, frame.image.height, name);
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

  String _recipeJson() => jsonEncode(<String, dynamic>{
        ..._sidecar.extra,
        ..._values,
        // En mode recadrage, on voit toute l'image (déjà redressée) sous le cadre.
        if (_cropMode) ..._cropDefaults,
      });

  Rect get _cropRect => Rect.fromLTRB(_values['crop_left']!, _values['crop_top']!,
      _values['crop_right']!, _values['crop_bottom']!);

  void _setCropRect(Rect r) {
    setState(() {
      _values['crop_left'] = r.left;
      _values['crop_top'] = r.top;
      _values['crop_right'] = r.right;
      _values['crop_bottom'] = r.bottom;
    });
  }

  void _enterCrop() {
    setState(() {
      _cropMode = true;
      _before = false;
    });
    _refresh();
  }

  void _leaveCrop() {
    setState(() => _cropMode = false);
    _commit();
    _refresh();
  }

  void _resetCrop() {
    setState(() {
      _aspect = null;
      _values.addAll(_cropDefaults);
    });
    _commit();
  }

  /// Impose un rapport largeur/hauteur : le plus grand cadre de ce rapport
  /// contenu dans le cadre actuel, centré sur lui.
  void _setAspect(double? a) {
    setState(() => _aspect = a);
    if (a == null) return;
    final Rect cur = _cropRect;
    final double k = _w / (a * _h); // hauteur/largeur en fractions
    double fw = cur.width < cur.height / k ? cur.width : cur.height / k;
    double fh = fw * k;
    if (fw > 1) {
      fw = 1;
      fh = k;
    }
    if (fh > 1) {
      fh = 1;
      fw = 1 / k;
    }
    double l = cur.center.dx - fw / 2;
    double t = cur.center.dy - fh / 2;
    l = l < 0 ? 0 : (l + fw > 1 ? 1 - fw : l);
    t = t < 0 ? 0 : (t + fh > 1 ? 1 - fh : t);
    _setCropRect(Rect.fromLTWH(l, t, fw, fh));
    _commit();
  }

  List<Widget> _cropControls() {
    final double orig = _w / _h;
    final List<(String, double?)> choices = <(String, double?)>[
      ('Libre', null),
      ('Original', orig),
      ('1:1', 1.0),
      ('4:3', 4 / 3),
      ('3:2', 3 / 2),
      ('16:9', 16 / 9),
    ];
    bool sel(double? a) =>
        a == null ? _aspect == null : (_aspect != null && (_aspect! - a).abs() < 1e-6);
    return <Widget>[
      Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          for (final (String label, double? a) in choices)
            ChoiceChip(
              label: Text(label),
              selected: sel(a),
              onSelected: (_) => _setAspect(a),
            ),
          IconButton(
            tooltip: 'Pivoter le cadre (portrait/paysage)',
            onPressed: _aspect == null ? null : () => _setAspect(1 / _aspect!),
            icon: const Icon(Icons.screen_rotation_alt),
          ),
          TextButton(onPressed: _resetCrop, child: const Text('Réinitialiser le cadre')),
          FilledButton(onPressed: _leaveCrop, child: const Text('Terminé')),
        ],
      ),
    ];
  }

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
    final String s = p.key == 'exposure'
        ? v.toStringAsFixed(2)
        : p.key == 'angle'
            ? v.toStringAsFixed(1)
            : v.round().toString();
    return v > 0 ? '+$s' : s.replaceFirst('-', '−');
  }

  @override
  Widget build(BuildContext context) {
    final bool ready = _srcRgba != null && _photo != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Moteur Rust (étape 2)'),
        actions: <Widget>[
          TextButton(
              onPressed: ready && !_cropMode ? _enterCrop : null,
              child: const Text('Recadrer')),
          IconButton(
              tooltip: 'Annuler',
              onPressed: ready && _history.canUndo
                  ? () => _applyHistory(_history.undo())
                  : null,
              icon: const Icon(Icons.undo)),
          IconButton(
              tooltip: 'Rétablir',
              onPressed: ready && _history.canRedo
                  ? () => _applyHistory(_history.redo())
                  : null,
              icon: const Icon(Icons.redo)),
          TextButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const EngineBenchPage())),
              child: const Text('Test auto')),
          TextButton(onPressed: _useTestImage, child: const Text('Image d\'essai')),
          PopupMenuButton<String>(
            tooltip: 'Ouvrir une photo',
            onSelected: (String v) => v == 'photos' ? _choose() : _chooseFile(),
            itemBuilder: (BuildContext context) => const <PopupMenuEntry<String>>[
              PopupMenuItem<String>(value: 'photos', child: Text('Depuis Photos')),
              PopupMenuItem<String>(value: 'files', child: Text('Depuis Fichiers')),
            ],
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Text('Ouvrir'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              key: _exportKey,
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: ready && !_cropMode && !_exporting ? _export : null,
              child: Text(_exporting ? 'Export…' : 'Exporter'),
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
                      child: Text('Touchez « Image d\'essai » ou « Ouvrir ».'))
                  : _cropMode
                      ? Padding(
                          padding: const EdgeInsets.all(12),
                          child: CropOverlay(
                            image: _shown!,
                            rect: _cropRect,
                            aspect: _aspect,
                            onChanged: _setCropRect,
                            onEnd: _commit,
                          ),
                        )
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
                              : '$_name · $_w×$_h px · rendu $_renderMs ms · '
                                  'conversion $_imageMs ms · $_saveInfo',
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
                  if (_cropMode) ..._cropControls(),
                  for (final _Param p in _params)
                    if (!_cropMode || p.key == 'angle')
                    Row(
                      children: <Widget>[
                        SizedBox(width: 130, child: Text(p.label)),
                        Expanded(
                          child: GestureDetector(
                            onDoubleTap: !ready
                                ? null
                                : () {
                                    setState(() => _values[p.key] = 0);
                                    _commit();
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
                              onChangeEnd: !ready ? null : (double _) => _commit(),
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
