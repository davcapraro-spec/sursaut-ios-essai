import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../engine/engine.dart';
import '../../domain/crop_math.dart';
import '../../domain/curves.dart';
import '../../domain/develop_params.dart';
import '../../domain/lens_profiles.dart';
import '../../domain/masks.dart';
import '../../domain/shoot_info.dart';
import '../../domain/photo_key.dart';
import '../../domain/recipe_history.dart';
import '../../domain/spots.dart';
import '../../domain/sidecar.dart';
import 'crop_overlay.dart';
import 'curve_editor.dart';
import 'spot_overlay.dart';

/// Écran Développement : aperçu rendu par le moteur Rust, curseurs, recadrage,
/// annuler/rétablir, sauvegarde `.sursaut.json`, ouverture (Photos, Fichiers) et export.
///
/// La photo est ramenée à 2 752 px de grand côté (taille d'aperçu de l'iPad Pro 13").
/// L'écran ne calcule aucune image : il demande le rendu au moteur. Les règles
/// (réglages, historique, fichier de retouche, calcul du cadre) sont dans `domain/`.
class DevelopPage extends StatefulWidget {
  const DevelopPage({super.key});

  @override
  State<DevelopPage> createState() => _DevelopPageState();
}

/// Compression JPEG dans un fil séparé. Fonction autonome : elle ne reçoit que les
/// pixels, pour que le fil n'emporte pas l'écran ni le moteur (non copiables).
Future<Uint8List> _encodeJpeg(Uint8List rgba, int w, int h) {
  return Isolate.run(() {
    final img.Image im = img.Image.fromBytes(
        width: w,
        height: h,
        bytes: Uint8List.fromList(rgba).buffer,
        numChannels: 4,
        order: img.ChannelOrder.rgba);
    return Uint8List.fromList(img.encodeJpg(im, quality: 92));
  });
}

class _DevelopPageState extends State<DevelopPage> {
  late final EngineInfo _info;
  PhotoEngine? _photo;
  String? _error;

  Uint8List? _srcRgba;
  int _w = 0, _h = 0;
  ui.Image? _shown;
  bool _before = false;
  String _name = '';

  /// RAW ouvert (étape 3c) : gardé pour développer à pleine taille à l'export.
  RawFile? _raw;
  int _rawToken = 0;
  String _loading = '';

  final Map<String, double> _values = <String, double>{
    for (final DevelopParam p in kDevelopParams) p.key: 0,
    for (final DevelopParam p in kHslParams) p.key: 0,
    for (final DevelopParam p in kDetailParams) p.key: defaultOf(p.key),
    for (final DevelopParam p in kLensParams) p.key: defaultOf(p.key),
    ...kCropDefaults,
  };

  /// Courbes de tonalité non neutres, par canal ('rvb', 'red', 'green', 'blue').
  Map<String, CurvePoints> _curves = <String, CurvePoints>{};
  String _tool = 'basic'; // basic | curve | color | detail | lens | spots

  /// Objectif lu dans le RAW (nom, focale, ouverture) et profil trouvé dans la base, s'il existe.
  String? _lensName;
  double? _lensFocal;
  double? _lensAperture;
  Map<String, dynamic>? _lensCandidate;
  Map<String, dynamic>? _lensDb;

  /// Informations de prise de vue du RAW ouvert (vide pour une image ordinaire).
  List<String> _shoot = const <String>[];
  num? _iso;
  String _curveChannel = 'rvb';
  String _hslKind = 'sat';

  /// Retouches de taches (onglet « Supprimer ») et réglages de la prochaine retouche.
  List<Spot> _spots = <Spot>[];
  int _spotSel = -1;
  bool _spotBrush = false;
  String _spotMode = 'heal';
  double _spotSize = 20; // 1..200 ; rayon = valeur × 0,0005 du grand côté
  double _spotFeather = 50;
  double _spotOpacity = 100;
  bool _spotSnap = true;
  List<Map<String, dynamic>>? _dust;
  bool _dustBusy = false;
  bool _dustShow = true;
  double _dustSens = 85;

  /// Masques locaux de la recette ; l'onglet « Supprimer » y ajoute les corrections d'yeux rouges.
  List<MaskMap> _masks = <MaskMap>[];
  bool _eyesBusy = false;
  String _eyesMsg = '';
  double _eyesStrength = 100;

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
    final SidecarData read = await _readSidecar(_key);
    final (Map<String, CurvePoints> loadedCurves, Map<String, dynamic> rest0) = splitCurves(read.extra);
    final (List<Spot> loadedSpots, Map<String, dynamic> rest1) = splitSpots(rest0);
    final (List<MaskMap> loadedMasks, Map<String, dynamic> rest) = splitMasks(rest1);
    final SidecarData loaded = SidecarData(read.values, rest);
    setState(() {
      _curves = loadedCurves;
      _spots = loadedSpots;
      _masks = loadedMasks;
      _eyesMsg = '';
      _syncEyesStrength();
      _spotSel = -1;
      _dust = null;
      _srcRgba = rgba;
      _w = w;
      _h = h;
      _name = name;
      _sidecar = loaded;
      for (final String k in _values.keys.toList()) {
        _values[k] = loaded.values[k] ?? defaultOf(k);
      }
      _cropMode = false;
      _aspect = null;
      _history = RecipeHistory(_values, curves: _curves, spots: _spots, masks: _masks);
      _saveInfo = loaded.values.isNotEmpty || loaded.extra.isNotEmpty || loadedCurves.isNotEmpty || loadedSpots.isNotEmpty || loadedMasks.isNotEmpty
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
      final SidecarData out =
          SidecarData(_sidecar.values, <String, dynamic>{
        ..._sidecar.extra,
        ...curvesToJson(_curves),
        if (_spots.isNotEmpty) 'spots': _spots,
        if (_masks.isNotEmpty) 'masks': _masks,
      });
      await f.writeAsString(out.encode(_values, _keys, defaults: kParamDefaults));
      if (mounted) setState(() => _saveInfo = 'Réglages enregistrés');
    } catch (e) {
      if (mounted) setState(() => _saveInfo = 'Enregistrement impossible : $e');
    }
  }

  /// Valide l'état actuel : une étape d'annulation + sauvegarde du fichier.
  void _commit() {
    _history.commit(_values, curves: _curves, spots: _spots, masks: _masks);
    _writeSidecar();
    setState(() {});
  }

  void _applyHistory(Map<String, double>? v) {
    if (v == null) return;
    setState(() {
      _curves = _history.currentCurves;
      _spots = _history.currentSpots;
      _masks = _history.currentMasks;
      _syncEyesStrength();
      _spotSel = -1;
      for (final String k in _values.keys.toList()) {
        _values[k] = v[k] ?? defaultOf(k);
      }
      _before = false;
    });
    _writeSidecar();
    _refresh();
  }

  /// « Depuis Photos » : le sélecteur de Photos, avec le fichier d'origine (compressionQuality 0 : ni
  /// conversion ni réduction). Un RAW arrive donc tel quel et passe par LibRaw.
  Future<void> _choose() async {
    try {
      final FilePickerResult? res =
          await FilePicker.platform.pickFiles(type: FileType.media, compressionQuality: 0);
      if (res == null || res.files.isEmpty) return;
      final PlatformFile f = res.files.first;
      final String? path = f.path;
      if (path == null) {
        _say('Photos n\'a pas donné de fichier. Pour un RAW, utilisez « Depuis Fichiers ».');
        return;
      }
      await _openPicked(path, f.name);
    } catch (e) {
      if (mounted) setState(() => _loading = '');
      _say('Ouverture impossible : $e\nPour un RAW, utilisez « Depuis Fichiers ».');
    }
  }

  /// RAW (d'après l'extension, ou l'en-tête TIFF que partagent ARW, DNG, CR2, NEF...) ou image ordinaire.
  Future<void> _openPicked(String path, String name) async {
    final bool byName = _isRaw(name);
    if (byName || await _looksLikeTiff(path)) {
      try {
        await _openRaw(path, name);
        return;
      } catch (_) {
        if (byName) rethrow;
        if (mounted) setState(() => _loading = ''); // simple TIFF : on l'ouvre comme une image
      }
    }
    await _openBytes(await File(path).readAsBytes(), name);
  }

  Future<bool> _looksLikeTiff(String path) async {
    try {
      final RandomAccessFile raf = await File(path).open();
      try {
        final Uint8List b = await raf.read(4);
        return b.length == 4 &&
            ((b[0] == 0x49 && b[1] == 0x49 && b[2] == 0x2A && b[3] == 0) ||
                (b[0] == 0x4D && b[1] == 0x4D && b[2] == 0 && b[3] == 0x2A));
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

  static const Set<String> _rawExt = <String>{
    'arw', 'sr2', 'srf', 'dng', 'cr2', 'cr3', 'crw', 'nef', 'nrw', 'raf', 'orf', 'rw2', 'pef', 'srw', '3fr', 'iiq',
  };

  static bool _isRaw(String name) {
    final int i = name.lastIndexOf('.');
    return i >= 0 && _rawExt.contains(name.substring(i + 1).toLowerCase());
  }

  /// Ferme le RAW ouvert (et annule un développement en attente).
  void _dropRaw() {
    _shoot = const <String>[];
    _iso = null;
    _lensName = null;
    _lensFocal = null;
    _lensAperture = null;
    _lensCandidate = null;
    _rawToken++;
    _raw?.close();
    _raw = null;
    _loading = '';
  }

  /// Ouvre une photo depuis l'app Fichiers (iCloud Drive, clé USB, dossier de l'app...) :
  /// image ordinaire ou RAW (Sony ARW, DNG, Canon, Nikon...).
  Future<void> _chooseFile() async {
    final FilePickerResult? res = await FilePicker.platform.pickFiles(type: FileType.any);
    final String? path = res?.files.single.path;
    if (path == null) return;
    final String name = res!.files.single.name;
    try {
      await _openPicked(path, name);
    } catch (e) {
      if (mounted) setState(() => _loading = '');
      _say('Ouverture impossible : $e');
    }
  }

  /// Ouvre un RAW : aperçu rapide (demi-taille, quelques centaines de ms) puis développement
  /// complet (démosaïquage DHT) qui remplace l'aperçu. Les réglages faits entre-temps sont gardés.
  /// Couleur : rendu « Comme le JPEG de l'appareil » (identique au PC, mesuré à l'étape 3b).
  Future<void> _openRaw(String path, String name) async {
    _dropRaw();
    final int token = _rawToken;
    setState(() => _loading = 'Lecture du RAW…');
    final RawFile raw = RawFile.open(path);
    final RenderResult quick;
    try {
      quick = await raw.develop(half: true, maxSide: 2752, look: 2);
    } catch (_) {
      raw.close();
      rethrow;
    }
    if (!mounted || token != _rawToken) {
      raw.close();
      return;
    }
    _raw = raw;
    await _detectLens(raw);
    await _useRgba(quick.rgba, quick.width, quick.height, name);
    if (!mounted || token != _rawToken) return;
    setState(() => _loading = 'Développement complet en cours…');
    final RenderResult full = await raw.develop(half: false, maxSide: 2752, look: 2);
    if (!mounted || token != _rawToken) return;
    _photo?.close();
    _photo = PhotoEngine.open(full.rgba, full.width, full.height);
    setState(() {
      _srcRgba = full.rgba;
      _w = full.width;
      _h = full.height;
      _loading = '';
    });
    await _refresh();
  }

  /// Lit l'objectif dans le RAW et cherche son profil dans la base Lensfun embarquée.
  Future<void> _detectLens(RawFile raw) async {
    String? lens;
    double? focal, aperture;
    try {
      final Map<String, dynamic> i = raw.info();
      _shoot = shootLines(i);
      _iso = i['iso'] is num ? i['iso'] as num : null;
      lens = (i['lens'] as String?)?.trim();
      focal = (i['focal_len'] as num?)?.toDouble();
      aperture = (i['aperture'] as num?)?.toDouble();
    } catch (_) {}
    Map<String, dynamic>? candidate;
    try {
      _lensDb ??= jsonDecode(await rootBundle.loadString('assets/lens_profiles.json')) as Map<String, dynamic>;
      candidate = lensProfileFor(_lensDb!, lens, focal, aperture);
    } catch (_) {}
    _lensName = (lens == null || lens.isEmpty) ? null : lens;
    _lensFocal = focal;
    _lensAperture = aperture;
    _lensCandidate = candidate;
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
    if (photo == null || _exporting || _loading.isNotEmpty) return;
    final RenderBox? box = _exportKey.currentContext?.findRenderObject() as RenderBox?;
    final Rect origin =
        box != null ? box.localToGlobal(Offset.zero) & box.size : const Rect.fromLTWH(0, 0, 1, 1);
    setState(() => _exporting = true);
    try {
      final Map<String, dynamic> recipe = _recipeMap();
      final Stopwatch sw = Stopwatch()..start();
      RenderResult r;
      int devMs = 0;
      final RawFile? raw = _raw;
      if (raw != null) {
        // RAW : développement complet à pleine taille, puis rendu des réglages sur cette image.
        setState(() => _loading = 'Développement pleine taille…');
        final RenderResult big = await raw.develop(half: false, maxSide: 0, look: 2);
        devMs = sw.elapsedMilliseconds;
        final PhotoEngine bigEngine = PhotoEngine.open(big.rgba, big.width, big.height);
        try {
          r = await bigEngine.render(jsonEncode(recipe));
        } finally {
          bigEngine.close();
        }
      } else {
        r = await photo.render(jsonEncode(recipe));
      }
      final int renderMs = sw.elapsedMilliseconds;
      final Uint8List jpg = await _encodeJpeg(r.rgba, r.width, r.height);
      final int totalMs = sw.elapsedMilliseconds;
      final Directory tmp = await getTemporaryDirectory();
      String base = _name.replaceAll(RegExp(r'\.[^.]*$'), '');
      base = base.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      if (base.isEmpty) base = 'photo';
      final File out = File('${tmp.path}/${base}_sursaut.jpg');
      await out.writeAsBytes(jpg, flush: true);
      await Share.shareXFiles(<XFile>[XFile(out.path, mimeType: 'image/jpeg')],
          sharePositionOrigin: origin);
      _say('Photo développée : ${r.width}×${r.height} px, ${(jpg.length / 1e6).toStringAsFixed(1)} Mo'
          '${raw != null ? ' · RAW $devMs ms, rendu ${renderMs - devMs} ms, JPEG ${totalMs - renderMs} ms' : ''}');
    } catch (e) {
      _say('Export impossible : $e');
    } finally {
      if (mounted) {
        setState(() {
          _exporting = false;
          _loading = '';
        });
      }
    }
  }

  Future<void> _openBytes(Uint8List bytes, String name) async {
    _dropRaw();
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
    _dropRaw();
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

  /// Recette complète : clés inconnues du fichier, courbes, réglages.
  Map<String, dynamic> _recipeMap() => <String, dynamic>{
        ..._sidecar.extra,
        ...curvesToJson(_curves),
        if (_spots.isNotEmpty) 'spots': _spots,
        if (_masks.isNotEmpty) 'masks': _masks,
        ..._values,
      };

  String _recipeJson() => jsonEncode(<String, dynamic>{
        ..._recipeMap(),
        // En mode recadrage, on voit toute l'image (déjà redressée) sous le cadre.
        if (_cropMode) ...kCropDefaults,
        // Onglet « Supprimer » : photo entière et droite, pour que les positions touchées soient celles de la source.
        if (_tool == 'spots' && !_cropMode) ...<String, double>{...kCropDefaults, 'angle': 0},
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
      _values.addAll(kCropDefaults);
    });
    _commit();
  }

  /// Impose un rapport largeur/hauteur : le plus grand cadre de ce rapport
  /// contenu dans le cadre actuel, centré sur lui.
  void _setAspect(double? a) {
    setState(() => _aspect = a);
    if (a == null) return;
    final Rect cur = _cropRect;
    final CropBox box =
        fitAspect(CropBox(cur.left, cur.top, cur.right, cur.bottom), a, _w, _h);
    _setCropRect(Rect.fromLTRB(box.left, box.top, box.right, box.bottom));
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
    if (_photo == null || _srcRgba == null) return;
    _busy = true;
    try {
      do {
        _dirty = false;
        final PhotoEngine? photo = _photo;
        final Uint8List? src = _srcRgba;
        if (photo == null || src == null) break;
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
    _dropRaw();
    _photo?.close();
    _shown?.dispose();
    super.dispose();
  }

  String _fmt(DevelopParam p) {
    final double v = _values[p.key]!;
    if (p.min >= 0) {
      return p.key == 'sharpen_radius'
          ? v.toStringAsFixed(1).replaceAll('.', ',')
          : v.round().toString();
    }
    if (v == 0) return '0';
    final String s = p.key == 'exposure'
        ? v.toStringAsFixed(2)
        : p.key == 'angle'
            ? v.toStringAsFixed(1)
            : v.round().toString();
    return v > 0 ? '+$s' : s.replaceFirst('-', '−');
  }

  void _resetKeys(Iterable<String> keys) {
    setState(() {
      for (final String k in keys) {
        _values[k] = defaultOf(k);
      }
      _before = false;
    });
    _commit();
    _refresh();
  }

  static const List<(String, List<String>)> _basicGroups = <(String, List<String>)>[
    ('BALANCE DES BLANCS', <String>['temperature', 'tint']),
    ('TONALITÉ', <String>['exposure', 'contrast', 'highlights', 'shadows', 'whites', 'blacks']),
    ('PRÉSENCE', <String>['texture', 'clarity', 'dehaze', 'vibrance', 'saturation']),
  ];

  /// Une ligne « libellé, curseur, valeur » : double-toucher = remise à zéro.
  Widget _paramRow(DevelopParam p, bool ready, {Color? color}) {
    Widget slider = Slider(
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
    );
    if (color != null) {
      slider = SliderTheme(
        data: SliderTheme.of(context).copyWith(activeTrackColor: color, thumbColor: color),
        child: slider,
      );
    }
    return Row(
      children: <Widget>[
        SizedBox(width: 130, child: Text(p.label)),
        Expanded(
          child: GestureDetector(
            onDoubleTap: !ready
                ? null
                : () {
                    setState(() => _values[p.key] = defaultOf(p.key));
                    _commit();
                    _refresh();
                  },
            child: slider,
          ),
        ),
        SizedBox(
          width: 52,
          child: Text(_fmt(p),
              textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }

  Widget _groupTitle(String title, VoidCallback? onReset) {
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 2),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(title,
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.5, color: Colors.white60)),
          ),
          TextButton(onPressed: onReset, child: const Text('Réinitialiser')),
        ],
      ),
    );
  }

  List<Widget> _basicPanel(bool ready) {
    final Map<String, DevelopParam> byKey = <String, DevelopParam>{
      for (final DevelopParam p in kDevelopParams) p.key: p,
    };
    return <Widget>[
      for (final (String title, List<String> keys) in _basicGroups) ...<Widget>[
        _groupTitle(title, ready ? () => _resetKeys(keys) : null),
        for (final String k in keys) _paramRow(byKey[k]!, ready),
      ],
    ];
  }

  List<Widget> _curvePanel(bool ready) {
    const Map<String, String> names = <String, String>{
      'rvb': 'RVB',
      'red': 'Rouge',
      'green': 'Vert',
      'blue': 'Bleu',
    };
    return <Widget>[
      const SizedBox(height: 8),
      SegmentedButton<String>(
        showSelectedIcon: false,
        segments: <ButtonSegment<String>>[
          for (final MapEntry<String, String> e in names.entries)
            ButtonSegment<String>(value: e.key, label: Text(e.value)),
        ],
        selected: <String>{_curveChannel},
        onSelectionChanged: (Set<String> v) => setState(() => _curveChannel = v.first),
      ),
      const SizedBox(height: 12),
      IgnorePointer(
        ignoring: !ready,
        child: CurveEditor(
          channel: _curveChannel,
          curves: _curves,
          onChanged: (CurvePoints pts) {
            setState(() {
              if (isIdentityCurve(pts)) {
                _curves.remove(_curveChannel);
              } else {
                _curves[_curveChannel] = pts;
              }
              _before = false;
            });
            _refresh();
          },
          onEnd: _commit,
        ),
      ),
      const Padding(
        padding: EdgeInsets.only(top: 8),
        child: Text(
          'Touchez la courbe pour ajouter un point, glissez-le pour le déplacer, '
          'touchez-le deux fois pour le supprimer.',
          style: TextStyle(fontSize: 12, color: Colors.white60),
        ),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          onPressed: ready && _curves.containsKey(_curveChannel)
              ? () {
                  setState(() => _curves.remove(_curveChannel));
                  _commit();
                  _refresh();
                }
              : null,
          child: Text('Réinitialiser la courbe ${names[_curveChannel]}'),
        ),
      ),
    ];
  }

  List<Widget> _colorPanel(bool ready) {
    final List<DevelopParam> rows = <DevelopParam>[
      for (final DevelopParam p in kHslParams)
        if (p.key.startsWith('hsl_${_hslKind}_')) p,
    ];
    return <Widget>[
      _groupTitle('MÉLANGEUR DE COULEURS',
          ready ? () => _resetKeys(rows.map((DevelopParam p) => p.key)) : null),
      SegmentedButton<String>(
        showSelectedIcon: false,
        segments: <ButtonSegment<String>>[
          for (int i = 0; i < kHslKinds.length; i++)
            ButtonSegment<String>(value: kHslKinds[i], label: Text(kHslKindLabels[i])),
        ],
        selected: <String>{_hslKind},
        onSelectionChanged: (Set<String> v) => setState(() => _hslKind = v.first),
      ),
      const SizedBox(height: 6),
      for (int i = 0; i < rows.length; i++) _paramRow(rows[i], ready, color: Color(0xFF000000 | kHslColorRgb[i])),
    ];
  }

  static const List<(String, List<String>)> _detailGroups = <(String, List<String>)>[
    ('NETTETÉ', <String>['sharpen_amount', 'sharpen_radius', 'sharpen_detail', 'sharpen_masking']),
    ('RÉDUCTION DU BRUIT', <String>[
      'denoise_luma', 'denoise_luma_detail', 'denoise_luma_contrast',
      'denoise_color', 'denoise_color_detail', 'denoise_color_smooth',
    ]),
    ('GRAIN', <String>['grain_amount', 'grain_size', 'grain_roughness']),
    ('VIGNETAGE', <String>['vig_amount', 'vig_mid', 'vig_round', 'vig_feather']),
  ];

  /// Curseur unique « Quantité » (luminosité, et couleur à 80 %) + bouton Auto d'après l'ISO, comme sur le PC.
  void _setDenoiseAmount(double v, {bool end = false}) {
    setState(() {
      _values['denoise_luma'] = v;
      _values['denoise_color'] = (v * kDenoiseColorRatio).roundToDouble().clamp(0, 100);
      _before = false;
    });
    if (end) _commit();
    _refresh();
  }

  List<Widget> _denoiseMacro(bool ready) {
    final double v = _values['denoise_luma']!;
    final String? advice = noiseAdvice(_iso);
    final int? auto = suggestDenoiseAmount(_iso);
    return <Widget>[
      _slideRow('Quantité', v, 0, 100, v.round().toString(), (double x) => _setDenoiseAmount(x.roundToDouble()),
          () => _commit(), ready),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.tonalIcon(
          onPressed: ready && auto != null
              ? () {
                  _setDenoiseAmount(auto.toDouble(), end: true);
                  _say('Réduction du bruit proposée pour ISO ${_iso!.round()} : $auto. Ajustez à l\'œil.');
                }
              : null,
          icon: const Icon(Icons.auto_fix_high),
          label: Text(auto == null ? 'Auto (ISO inconnu)' : 'Auto d\'après l\'ISO ($auto)'),
        ),
      ),
      if (advice != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(advice, style: const TextStyle(fontSize: 11, color: Color(0xFFE8B04A))),
        ),
      const Padding(
        padding: EdgeInsets.only(top: 8, bottom: 2),
        child: Text('Réglages détaillés', style: TextStyle(fontSize: 11, color: Colors.white60)),
      ),
    ];
  }

  List<Widget> _detailPanel(bool ready) {
    final Map<String, DevelopParam> byKey = <String, DevelopParam>{
      for (final DevelopParam p in kDetailParams) p.key: p,
    };
    return <Widget>[
      for (final (String title, List<String> keys) in _detailGroups) ...<Widget>[
        _groupTitle(title, ready ? () => _resetKeys(keys) : null),
        if (title == 'RÉDUCTION DU BRUIT') ..._denoiseMacro(ready),
        for (final String k in keys) _paramRow(byKey[k]!, ready),
      ],
    ];
  }

  void _setTool(String t) {
    final bool redo = (t == 'spots') != (_tool == 'spots');
    setState(() => _tool = t);
    if (redo) _refresh();
  }

  // -- Supprimer : retouches de taches ---------------------------------------------------------
  void _spotsChanged() {
    _commit();
    _refresh();
  }

  void _addSpot(double fx, double fy) {
    final Uint8List? rgba = _srcRgba;
    if (rgba == null) return;
    try {
      double x = fx, y = fy, r = _spotSize * 0.0005;
      if (_spotSnap) {
        final (double, double, double)? f = RetouchTools.refine(rgba, _w, _h, fx, fy, r);
        if (f != null) {
          x = f.$1;
          y = f.$2;
          r = f.$3;
        } else {
          _say('Aucune tache nette près du touché : taille réglée utilisée.');
        }
      }
      final (double sx, double sy) = RetouchTools.suggestSource(rgba, _w, _h, x, y, r);
      _spots = <Spot>[
        ..._spots,
        newSpot(x: x, y: y, r: r, sx: sx, sy: sy, mode: _spotMode, feather: _spotFeather / 100, opacity: _spotOpacity / 100),
      ];
      _spotSel = _spots.length - 1;
      _before = false;
      _spotsChanged();
    } catch (e) {
      _say('Retouche impossible : $e');
    }
  }

  void _strokeDone(List<List<double>> pts) {
    final Uint8List? rgba = _srcRgba;
    if (rgba == null || pts.isEmpty) return;
    try {
      final double r = _spotSize * 0.0005;
      final (double sx, double sy) = RetouchTools.suggestSource(rgba, _w, _h, pts.first[0], pts.first[1], r);
      _spots = <Spot>[
        ..._spots,
        newSpot(
            x: pts.first[0], y: pts.first[1], r: r, sx: sx, sy: sy, mode: _spotMode,
            feather: _spotFeather / 100, opacity: _spotOpacity / 100, stroke: pts),
      ];
      _spotSel = _spots.length - 1;
      _before = false;
      _spotsChanged();
    } catch (e) {
      _say('Retouche impossible : $e');
    }
  }

  /// Déplace la retouche (`target`, un trait se déplace d'un bloc) ou sa zone copiée (`source`) : rendu en direct,
  /// une seule étape d'annulation à la fin du geste.
  void _moveSpot(int i, String which, double fx, double fy) {
    if (i < 0 || i >= _spots.length) return;
    final Spot s = Map<String, dynamic>.of(_spots[i]);
    if (which == 'target') {
      final double dx = fx - (s['x'] as num).toDouble(), dy = fy - (s['y'] as num).toDouble();
      final List<dynamic>? stroke = s['stroke'] as List<dynamic>?;
      if (stroke != null) {
        s['stroke'] = <List<double>>[
          for (final Object? p in stroke)
            <double>[((p as List<dynamic>)[0] as num).toDouble() + dx, (p[1] as num).toDouble() + dy],
        ];
      }
      s['x'] = fx;
      s['y'] = fy;
    } else {
      s['sx'] = fx;
      s['sy'] = fy;
    }
    setState(() {
      _spots = <Spot>[for (int k = 0; k < _spots.length; k++) k == i ? s : _spots[k]];
      _before = false;
    });
    _refresh();
  }

  /// Change un réglage de la retouche choisie (sans retouche choisie : réglage de la prochaine).
  void _spotField(String field, Object value, {bool end = false}) {
    final int i = _spotSel;
    if (i < 0 || i >= _spots.length) return;
    final Spot s = Map<String, dynamic>.of(_spots[i])..[field] = value;
    setState(() {
      _spots = <Spot>[for (int k = 0; k < _spots.length; k++) k == i ? s : _spots[k]];
      _before = false;
    });
    if (end) {
      _spotsChanged();
    } else {
      _refresh();
    }
  }

  void _spotDelete() {
    if (_spotSel < 0 || _spotSel >= _spots.length) return;
    setState(() {
      _spots = <Spot>[for (int k = 0; k < _spots.length; k++) if (k != _spotSel) _spots[k]];
      _spotSel = -1;
    });
    _spotsChanged();
  }

  void _spotsClear() {
    if (_spots.isEmpty) return;
    setState(() {
      _spots = <Spot>[];
      _spotSel = -1;
    });
    _spotsChanged();
  }

  Future<void> _dustFind() async {
    final Uint8List? rgba = _srcRgba;
    if (rgba == null || _dustBusy) return;
    final int token = _rawToken;
    final String key = _key;
    setState(() => _dustBusy = true);
    try {
      final List<Map<String, dynamic>> found = await RetouchTools.detectDust(rgba, _w, _h);
      if (!mounted || key != _key || token != _rawToken) return;
      setState(() => _dust = found);
    } catch (e) {
      _say('La recherche a échoué : $e');
    } finally {
      if (mounted) setState(() => _dustBusy = false);
    }
  }

  void _dustApply() {
    final Uint8List? rgba = _srcRgba;
    if (rgba == null || _dust == null) return;
    final List<Map<String, dynamic>> kept = keptDust(_dust!, _spots, _dustSens.round(), _w, _h);
    if (kept.isEmpty) return;
    try {
      final List<Spot> added = <Spot>[];
      for (final Map<String, dynamic> d in kept) {
        final double x = (d['x'] as num).toDouble(), y = (d['y'] as num).toDouble(), r = (d['r'] as num).toDouble();
        final (double sx, double sy) = RetouchTools.suggestSource(rgba, _w, _h, x, y, r);
        added.add(<String, dynamic>{...newSpot(x: x, y: y, r: r, sx: sx, sy: sy), 'auto': true});
      }
      setState(() {
        _spots = <Spot>[..._spots, ...added];
        _spotSel = -1;
        _before = false;
      });
      _spotsChanged();
    } catch (e) {
      _say('Correction impossible : $e');
    }
  }

  void _dustRemove() {
    if (!_spots.any((Spot s) => s['auto'] == true)) return;
    setState(() {
      _spots = <Spot>[for (final Spot s in _spots) if (s['auto'] != true) s];
      _spotSel = -1;
    });
    _spotsChanged();
  }

  // -- Supprimer : yeux rouges et reflets d'animaux ---------------------------------------------
  /// Le curseur « Force » reprend l'opacité des corrections d'yeux présentes (fichier ouvert, annuler/rétablir).
  void _syncEyesStrength() {
    final List<MaskMap> eyes = _eyeMasks;
    _eyesStrength = eyes.isEmpty ? 100 : ((eyes.first['amount'] as num?)?.toDouble() ?? 100);
  }

  List<MaskMap> get _eyeMasks => <MaskMap>[
        for (final MaskMap m in _masks)
          if (isEyeMask(m)) m,
      ];

  Future<void> _eyesFix() async {
    final Uint8List? rgba = _srcRgba;
    if (rgba == null || _eyesBusy) return;
    final int token = _rawToken;
    final String key = _key;
    setState(() {
      _eyesBusy = true;
      _eyesMsg = '';
    });
    try {
      final List<Map<String, dynamic>> seen = await RetouchTools.detectEyes(rgba, _w, _h);
      if (!mounted || key != _key || token != _rawToken) return;
      final (List<Map<String, dynamic>> fresh, int weak) = freshEyes(seen, _masks);
      if (fresh.isEmpty) {
        final String pale = weak > 0 ? ' ($weak reflet${weak > 1 ? 's' : ''} trop pâle${weak > 1 ? 's' : ''} ignoré${weak > 1 ? 's' : ''})' : '';
        setState(() {
          _eyesMsg = seen.length > weak
              ? 'Les yeux trouvés sont déjà corrigés.'
              : weak > 0
                  ? 'Aucune pupille nettement colorée trouvée$pale.'
                  : 'Aucune pupille colorée trouvée.';
        });
        return;
      }
      final List<MaskMap> added = <MaskMap>[];
      final int base = _eyeMasks.length;
      for (final Map<String, dynamic> e in fresh) {
        added.add(eyeMask(e, _eyesStrength / 100, '$kEyeMaskPrefix${e['hue']} ${base + added.length + 1}'));
      }
      final int n = added.length;
      setState(() {
        _masks = <MaskMap>[..._masks, ...added];
        _before = false;
        _eyesMsg = '$n œil${n > 1 ? 's' : ''} corrigé${n > 1 ? 's' : ''} : vérifiez sur la photo.';
      });
      _commit();
      _refresh();
    } catch (e) {
      _say('La recherche des yeux a échoué : $e');
    } finally {
      if (mounted) setState(() => _eyesBusy = false);
    }
  }

  /// Le curseur « Force » règle l'opacité de toutes les corrections d'yeux déjà faites.
  void _eyesStrengthChanged(double v) {
    setState(() {
      _eyesStrength = v;
      _masks = <MaskMap>[
        for (final MaskMap m in _masks)
          if (isEyeMask(m)) <String, dynamic>{...m, 'amount': v} else m,
      ];
      _before = false;
    });
    if (_eyeMasks.isNotEmpty) _refresh();
  }

  void _eyesStrengthEnd() {
    if (_eyeMasks.isEmpty) return;
    _commit();
    _refresh();
  }

  void _eyesRemove() {
    if (_eyeMasks.isEmpty) return;
    setState(() {
      _masks = <MaskMap>[
        for (final MaskMap m in _masks)
          if (!isEyeMask(m)) m,
      ];
      _eyesMsg = 'Corrections retirées.';
      _before = false;
    });
    _commit();
    _refresh();
  }

  Widget _slideRow(String label, double value, double min, double max, String shown,
      ValueChanged<double> onChanged, VoidCallback onEnd, bool ready) {
    return Row(
      children: <Widget>[
        SizedBox(width: 112, child: Text(label, style: const TextStyle(fontSize: 13))),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: ready ? onChanged : null,
            onChangeEnd: ready ? (double _) => onEnd() : null,
          ),
        ),
        SizedBox(width: 46, child: Text(shown, textAlign: TextAlign.end, style: const TextStyle(fontSize: 12))),
      ],
    );
  }

  List<Widget> _spotsPanel(bool ready) {
    final Spot? sel = _spotSel >= 0 && _spotSel < _spots.length ? _spots[_spotSel] : null;
    final String mode = sel != null ? '${sel['mode']}' : _spotMode;
    final double size = sel != null ? (sel['r'] as num).toDouble() / 0.0005 : _spotSize;
    final double feather = sel != null ? (sel['feather'] as num).toDouble() * 100 : _spotFeather;
    final double opacity = sel != null ? (sel['opacity'] as num).toDouble() * 100 : _spotOpacity;
    final int autoCount = _spots.where((Spot s) => s['auto'] == true).length;
    final int kept = _dust == null ? 0 : keptDust(_dust!, _spots, _dustSens.round(), _w, _h).length;
    return <Widget>[
      _groupTitle('RETOUCHE DE TACHES', ready && _spots.isNotEmpty ? _spotsClear : null),
      Text(
        _spots.isEmpty
            ? 'Touchez une tache pour la retirer.'
            : '${_spots.length} retouche${_spots.length > 1 ? 's' : ''}'
                '${sel != null ? ' · une est choisie : glissez le cercle ou la zone copiée' : ''}',
        style: const TextStyle(fontSize: 12, color: Colors.white70),
      ),
      const SizedBox(height: 4),
      const Text(
        'Pincez avec deux doigts pour zoomer et déplacer la photo (ou boutons + / − sur la photo).',
        style: TextStyle(fontSize: 11, color: Colors.white54),
      ),
      const SizedBox(height: 8),
      SegmentedButton<bool>(
        showSelectedIcon: false,
        segments: const <ButtonSegment<bool>>[
          ButtonSegment<bool>(value: false, label: Text('Toucher'), icon: Icon(Icons.touch_app_outlined)),
          ButtonSegment<bool>(value: true, label: Text('Pinceau'), icon: Icon(Icons.brush_outlined)),
        ],
        selected: <bool>{_spotBrush},
        onSelectionChanged: (Set<bool> v) => setState(() => _spotBrush = v.first),
      ),
      const SizedBox(height: 8),
      SegmentedButton<String>(
        showSelectedIcon: false,
        segments: const <ButtonSegment<String>>[
          ButtonSegment<String>(value: 'heal', label: Text('Corriger')),
          ButtonSegment<String>(value: 'clone', label: Text('Cloner')),
        ],
        selected: <String>{mode == 'clone' ? 'clone' : 'heal'},
        onSelectionChanged: (Set<String> v) {
          if (sel != null) {
            _spotField('mode', v.first, end: true);
          } else {
            setState(() => _spotMode = v.first);
          }
        },
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: const Text('Ajuster sur la tache'),
        subtitle: const Text('Centre et dimensionne la retouche sur la tache touchée', style: TextStyle(fontSize: 11)),
        value: _spotSnap,
        onChanged: (bool v) => setState(() => _spotSnap = v),
      ),
      _slideRow('Taille', size, 1, 200, size.round().toString(), (double v) {
        if (sel != null) {
          _spotField('r', v * 0.0005);
        } else {
          setState(() => _spotSize = v);
        }
      }, () {
        if (sel != null) _spotsChanged();
      }, ready),
      _slideRow('Bord progressif', feather, 0, 100, feather.round().toString(), (double v) {
        if (sel != null) {
          _spotField('feather', v / 100);
        } else {
          setState(() => _spotFeather = v);
        }
      }, () {
        if (sel != null) _spotsChanged();
      }, ready),
      _slideRow('Opacité', opacity, 0, 100, opacity.round().toString(), (double v) {
        if (sel != null) {
          _spotField('opacity', v / 100);
        } else {
          setState(() => _spotOpacity = v);
        }
      }, () {
        if (sel != null) _spotsChanged();
      }, ready),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: ready && sel != null ? _spotDelete : null,
          icon: const Icon(Icons.delete_outline),
          label: const Text('Supprimer la retouche choisie'),
        ),
      ),
      _groupTitle('POUSSIÈRE AUTOMATIQUE', null),
      FilledButton.tonalIcon(
        onPressed: ready && !_dustBusy ? _dustFind : null,
        icon: _dustBusy
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.search),
        label: Text(_dustBusy ? 'Recherche en cours…' : 'Chercher la poussière'),
      ),
      if (_dust != null) ...<Widget>[
        const SizedBox(height: 6),
        Text(
          _dust!.isEmpty
              ? 'Aucune poussière trouvée.'
              : '${_dust!.length} trouvée${_dust!.length > 1 ? 's' : ''} · $kept à corriger avec cette sensibilité'
                  '${autoCount > 0 ? ' · $autoCount déjà corrigée${autoCount > 1 ? 's' : ''}' : ''}',
          style: const TextStyle(fontSize: 12, color: Colors.white70),
        ),
        _slideRow('Sensibilité', _dustSens, 0, 100, _dustSens.round().toString(),
            (double v) => setState(() => _dustSens = v), () {}, ready),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('Afficher les repères bleus'),
          value: _dustShow,
          onChanged: (bool v) => setState(() => _dustShow = v),
        ),
        Row(
          children: <Widget>[
            Expanded(
              child: FilledButton(
                onPressed: ready && kept > 0 ? _dustApply : null,
                child: Text(kept > 0 ? 'Corriger $kept tache${kept > 1 ? 's' : ''}' : 'Rien à corriger'),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(onPressed: ready && autoCount > 0 ? _dustRemove : null, child: const Text('Retirer')),
          ],
        ),
      ],
      _groupTitle('YEUX ROUGES ET REFLETS D\'ANIMAUX', null),
      const Text(
        'Cherche les pupilles colorées (rouges chez les personnes, vertes, jaunes ou bleues chez les animaux) et leur retire la couleur ; le petit reflet blanc reste.',
        style: TextStyle(fontSize: 12, color: Colors.white70),
      ),
      const SizedBox(height: 6),
      FilledButton.tonalIcon(
        onPressed: ready && !_eyesBusy ? _eyesFix : null,
        icon: _eyesBusy
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.remove_red_eye_outlined),
        label: Text(_eyesBusy ? 'Recherche en cours…' : 'Corriger les yeux'),
      ),
      if (_eyesMsg.isNotEmpty) ...<Widget>[
        const SizedBox(height: 6),
        Text(_eyesMsg, style: const TextStyle(fontSize: 12, color: Colors.white70)),
      ],
      if (_eyeMasks.isNotEmpty) ...<Widget>[
        _slideRow('Force', _eyesStrength, 0, 100, _eyesStrength.round().toString(), _eyesStrengthChanged, _eyesStrengthEnd, ready),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: ready ? _eyesRemove : null,
            icon: const Icon(Icons.delete_outline),
            label: Text('Retirer les ${_eyeMasks.length} correction${_eyeMasks.length > 1 ? 's' : ''}'),
          ),
        ),
      ],
    ];
  }

  bool get _lensOn => _sidecar.extra['lens_profile'] is Map;

  void _setLensProfile(bool on) {
    final Map<String, dynamic> extra = Map<String, dynamic>.of(_sidecar.extra);
    if (on && _lensCandidate != null) {
      extra['lens_profile'] = _lensCandidate;
    } else {
      extra.remove('lens_profile');
    }
    setState(() {
      _sidecar = SidecarData(_sidecar.values, extra);
      _before = false;
    });
    _commit();
    _refresh();
  }

  List<Widget> _lensPanel(bool ready) {
    final String detected = _raw == null
        ? 'Ouvrez un fichier RAW : l\'objectif est lu dans la photo.'
        : _lensName == null
            ? 'Objectif non indiqué dans la photo : aucun profil possible.'
            : 'Objectif détecté : $_lensName'
                '${_lensFocal != null ? ' (${_lensFocal!.round()} mm' : ''}'
                '${_lensAperture != null && _lensAperture! > 0 ? ' · f/${_lensAperture!.toStringAsFixed(1)}' : ''}'
                '${_lensFocal != null ? ')' : ''}.';
    final String found = _raw == null || _lensName == null
        ? ''
        : _lensCandidate != null
            ? 'Profil trouvé : ${describeLensProfile(_lensCandidate!)}.'
            : 'Aucun profil pour « $_lensName ».';
    final List<String> manual = <String>[for (final DevelopParam p in kLensParams) p.key];
    return <Widget>[
      _groupTitle('PROFIL AUTOMATIQUE', null),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Appliquer le profil de l\'objectif'),
        subtitle: Text('$detected\n$found', style: const TextStyle(fontSize: 12)),
        value: _lensOn,
        onChanged: ready && _lensCandidate != null ? _setLensProfile : null,
      ),
      _groupTitle('CORRECTIONS MANUELLES', ready ? () => _resetKeys(manual) : null),
      for (final DevelopParam p in kLensParams) _paramRow(p, ready),
    ];
  }

  Widget _toolButton(String id, IconData icon, String label, {required VoidCallback? onTap}) {
    final bool on = _tool == id && !_cropMode;
    final Color fg = on ? const Color(0xFFF2A33A) : Colors.white70;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        width: 68,
        height: 68,
        decoration: BoxDecoration(
          color: on ? const Color(0xFF33291A) : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(icon, color: fg, size: 26),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(color: fg, fontSize: 11, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  List<Widget> _tools(bool ready) => <Widget>[
        _toolButton('basic', Icons.tune, 'Basique', onTap: _cropMode ? null : () => _setTool('basic')),
        _toolButton('curve', Icons.show_chart, 'Courbe', onTap: _cropMode ? null : () => _setTool('curve')),
        _toolButton('color', Icons.palette_outlined, 'Couleur', onTap: _cropMode ? null : () => _setTool('color')),
        _toolButton('detail', Icons.change_history_outlined, 'Détail', onTap: _cropMode ? null : () => _setTool('detail')),
        _toolButton('lens', Icons.lens_outlined, 'Objectif', onTap: _cropMode ? null : () => _setTool('lens')),
        _toolButton('spots', Icons.healing, 'Supprimer', onTap: _cropMode ? null : () => _setTool('spots')),
        _toolButton('crop', Icons.crop, 'Recadrer', onTap: ready && !_cropMode ? _enterCrop : null),
      ];

  Widget _photoArea() {
    if (_shown == null) {
      return const Center(child: Text('Touchez « Image d\'essai » ou « Ouvrir ».'));
    }
    if (_cropMode) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: CropOverlay(
          image: _shown!,
          rect: _cropRect,
          aspect: _aspect,
          onChanged: _setCropRect,
          onEnd: _commit,
        ),
      );
    }
    if (_tool == 'spots') {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: SpotOverlay(
          image: _shown!,
          spots: _spots,
          selected: _spotSel,
          brush: _spotBrush,
          brushRadius: _spotSize * 0.0005,
          dust: _dustShow && _dust != null ? keptDust(_dust!, _spots, _dustSens.round(), _w, _h) : const <Map<String, dynamic>>[],
          onAdd: _addSpot,
          onSelect: (int i) => setState(() => _spotSel = i),
          onMove: _moveSpot,
          onMoveEnd: _spotsChanged,
          onStroke: _strokeDone,
        ),
      );
    }
    return InteractiveViewer(
      maxScale: 8,
      child: Center(child: RawImage(image: _shown, fit: BoxFit.contain)),
    );
  }

  Widget _banner() {
    final bool bad = _error != null || _info.version == null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          _error != null
              ? 'Erreur : $_error'
              : _info.version == null
                  ? 'Moteur Rust ABSENT : ${_info.error}'
                  : _loading.isNotEmpty
                      ? _loading
                      : 'Moteur Rust chargé : ${_info.version}',
          style: TextStyle(color: bad ? Colors.redAccent : Colors.greenAccent),
        ),
      ),
    );
  }

  Widget _infoRow(bool ready) {
    final List<String> shoot = <String>[for (final String l in _shoot) if (l.isNotEmpty) l];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (shoot.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(shoot.join('\n'),
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFFF2A33A))),
          ),
        _infoLine(ready),
      ],
    );
  }

  Widget _infoLine(bool ready) {
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            _srcRgba == null
                ? ''
                : '$_name · $_w×$_h px · rendu $_renderMs ms · conversion $_imageMs ms · $_saveInfo',
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
    );
  }

  List<Widget> _panelBody(bool ready) {
    if (_cropMode) {
      return <Widget>[
        ..._cropControls(),
        _paramRow(kDevelopParams.firstWhere((DevelopParam p) => p.key == 'angle'), ready),
      ];
    }
    switch (_tool) {
      case 'curve':
        return _curvePanel(ready);
      case 'color':
        return _colorPanel(ready);
      case 'detail':
        return _detailPanel(ready);
      case 'lens':
        return _lensPanel(ready);
      case 'spots':
        return _spotsPanel(ready);
      default:
        return _basicPanel(ready);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool ready = _srcRgba != null && _photo != null;
    final bool wide = MediaQuery.of(context).size.width >= 1000;
    final Widget content = wide
        ? Row(
            children: <Widget>[
              Container(
                width: 84,
                color: Theme.of(context).colorScheme.surface,
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(children: _tools(ready)),
              ),
              Expanded(
                child: Column(
                  children: <Widget>[
                    _banner(),
                    Expanded(child: _photoArea()),
                  ],
                ),
              ),
              Container(
                width: 396,
                color: Theme.of(context).colorScheme.surface,
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                child: Column(
                  children: <Widget>[
                    _infoRow(ready),
                    Expanded(child: SingleChildScrollView(
                        child: Material(type: MaterialType.transparency, child: Column(children: _panelBody(ready))))),
                  ],
                ),
              ),
            ],
          )
        : Column(
            children: <Widget>[
              _banner(),
              Expanded(child: _photoArea()),
              Container(
                color: Theme.of(context).colorScheme.surface,
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.5),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(children: _tools(ready)),
                    ),
                    _infoRow(ready),
                    Flexible(child: SingleChildScrollView(
                        child: Material(type: MaterialType.transparency, child: Column(children: _panelBody(ready))))),
                  ],
                ),
              ),
            ],
          );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Développement'),
        actions: <Widget>[
          TextButton(
              onPressed: ready && !_cropMode ? _enterCrop : null, child: const Text('Recadrer')),
          IconButton(
              tooltip: 'Annuler',
              onPressed: ready && _history.canUndo ? () => _applyHistory(_history.undo()) : null,
              icon: const Icon(Icons.undo)),
          IconButton(
              tooltip: 'Rétablir',
              onPressed: ready && _history.canRedo ? () => _applyHistory(_history.redo()) : null,
              icon: const Icon(Icons.redo)),
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
              onPressed: ready && !_cropMode && !_exporting && _loading.isEmpty ? _export : null,
              child: Text(_exporting ? 'Export…' : 'Exporter'),
            ),
          ),
        ],
      ),
      body: SafeArea(child: content),
    );
  }
}
