import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:pencil_bridge/pencil_bridge.dart'
    show VisionBridge, VisionFace, VisionFaces, VisionMaskResult, VisionParts, VisionSam;
import 'package:share_plus/share_plus.dart';

import '../../engine/engine.dart';
import '../../domain/ai_masks.dart';
import '../../common/app_version.dart';
import '../../domain/crop_math.dart';
import '../../domain/body_parts.dart';
import '../../domain/sam_mask.dart';
import '../../domain/face_parts.dart';
import '../../domain/curves.dart';
import '../../domain/develop_params.dart';
import '../../domain/histogram.dart';
import '../../domain/lens_profiles.dart';
import '../../domain/mask_tools.dart';
import '../../domain/masks.dart';
import '../../domain/shoot_info.dart';
import '../../domain/photo_key.dart';
import '../../domain/recipe_history.dart';
import '../../domain/spots.dart';
import '../../domain/sidecar.dart';
import 'crop_overlay.dart';
import 'curve_editor.dart';
import 'histogram_view.dart';
import 'mask_overlay.dart';
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
  String _tool = 'basic'; // basic | curve | color | detail | lens | masks | spots

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

  /// Onglet « Masques » : masque choisi (indice dans `_masks`), type en cours de tracé, zone teintée sur la photo.
  int _maskSel = -1;
  int _compSel = 0; // composante choisie du masque choisi
  String? _maskDraw;
  bool _maskAttach = false; // le tracé en cours s'ajoute au masque choisi au lieu d'en créer un
  bool _aiBusy = false; // un détourage (Vision) est en cours
  String? _brushTool; // pinceau actif : 'paint' (peindre), 'erase' (gommer) ou null (déplacer les poignées)
  double _brushR = kBrushDefaultR; // taille du pinceau pour un nouveau masque ou une nouvelle composante
  bool _maskPickNew = false; // la pipette sert à créer un nouveau masque de couleur (rien n'existe avant le toucher)
  bool _maskPick = false; // pipette : le prochain toucher sur la photo choisit la couleur
  List<VisionFace> _faces = <VisionFace>[]; // personnes repérées = un visage chacune (pastilles du panneau Masques)
  List<ui.Image> _faceImgs = <ui.Image>[];
  Uint8List? _facesFor; // la photo pour laquelle on les a cherchés
  bool _samOn = false; // sélection au toucher (SAM 2.1) : chaque toucher sur la photo ajoute un point
  bool _samAdd = true; // le prochain point est « dans l'objet » (sinon « en dehors »)
  List<List<double>> _samPts = <List<double>>[]; // points [x, y, 1 ou 0] (fractions de la photo)
  int _samMask = -1; // numéro du masque en cours de construction
  Set<int> _selFaces = <int>{}; // personnes cochées (indices dans `_faces`)
  Set<String> _selParts = <String>{}; // parties cochées : person | skin | eyes | … | hair | clothes | bodyskin
  bool _maskZone = false; // « Voir la zone du masque » : la photo montre la zone en rouge, sans les réglages
  String _newOp = 'add'; // comment la prochaine composante se combine : add | subtract | intersect

  bool _cropMode = false;
  double? _aspect; // largeur/hauteur imposée ; null = cadre libre

  late RecipeHistory _history = RecipeHistory(<String, double>{});
  SidecarData _sidecar = SidecarData(<String, double>{}, <String, dynamic>{});
  String _saveInfo = '';
  String _key = '';

  bool _busy = false;
  bool _dirty = false;
  int _renderMs = -1;

  /// Histogramme de l'image affichée (petit encart sur la photo) ; choix mémorisés dans preferences.json.
  Histogram? _hist;
  bool _histVisible = true;
  bool _histLum = false;
  int _imageMs = -1;

  @override
  void initState() {
    super.initState();
    _info = EngineInfo.probe();
    _loadPrefs();
  }

  Future<File> _prefsFile() async {
    final Directory base = await getApplicationDocumentsDirectory();
    return File('${base.path}/preferences.json');
  }

  Future<void> _loadPrefs() async {
    try {
      final File f = await _prefsFile();
      if (!await f.exists()) return;
      final Object? j = jsonDecode(await f.readAsString());
      if (j is Map<String, dynamic> && mounted) {
        setState(() {
          _histVisible = j['histogram_visible'] != false;
          _histLum = j['histogram_mode'] == 'lum';
        });
        if (_histVisible) _refresh();
      }
    } catch (_) {}
  }

  Future<void> _savePrefs() async {
    try {
      final File f = await _prefsFile();
      await f.writeAsString(jsonEncode(<String, dynamic>{
        'histogram_visible': _histVisible,
        'histogram_mode': _histLum ? 'lum' : 'rgb',
      }));
    } catch (_) {}
  }

  void _setHistVisible(bool v) {
    setState(() {
      _histVisible = v;
      if (!v) _hist = null;
    });
    _savePrefs();
    if (v) _refresh();
  }

  void _setHistMode(bool lum) {
    setState(() => _histLum = lum);
    _savePrefs();
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
      _maskSel = -1;
      _compSel = 0;
      _maskDraw = null;
      _maskAttach = false;
      _maskPick = false;
      _brushTool = null;
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
      _maskSel = -1;
      _compSel = 0;
      _maskDraw = null;
      _maskAttach = false;
      _maskPick = false;
      _brushTool = null;
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
          r = await bigEngine.render(jsonEncode(_forEngine(recipe)));
        } finally {
          bigEngine.close();
        }
      } else {
        r = await photo.render(jsonEncode(_forEngine(recipe)));
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

  /// Recette complète : clés inconnues du fichier, courbes, réglages.
  Map<String, dynamic> _recipeMap() => <String, dynamic>{
        ..._sidecar.extra,
        ...curvesToJson(_curves),
        if (_spots.isNotEmpty) 'spots': _spots,
        if (_masks.isNotEmpty) 'masks': _masks,
        ..._values,
      };

  /// Recette pour le moteur : les images des masques d'IA (`png`) lui sont d'abord confiées sous leur clé, puis retirées du texte.
  Map<String, dynamic> _forEngine(Map<String, dynamic> recipe) {
    final Object? masks = recipe['masks'];
    if (masks is! List<dynamic>) return recipe;
    for (final Map<String, dynamic> c in bitmapComps(masks)) {
      final Object? key = c['key'], png = c['png'];
      if (key is! String || key.isEmpty || png is! String || png.isEmpty || MaskBitmaps.has(key)) continue;
      try {
        final (Uint8List, int, int)? plane = pngToPlane(base64Decode(png));
        if (plane != null) MaskBitmaps.set(key, plane.$2, plane.$3, plane.$1);
      } catch (_) {
        // image illisible : le masque reste sans effet, la photo se rend quand même
      }
    }
    return <String, dynamic>{...recipe, 'masks': withoutPngs(masks)};
  }

  String _recipeJson() => jsonEncode(_forEngine(<String, dynamic>{
        ..._recipeMap(),
        // « Voir la zone du masque » : le masque choisi est montré en rouge (jamais enregistré ni exporté).
        if (_tool == 'masks' && _maskZone && _maskSelected != null && _maskSelected!['enabled'] != false) 'zone_view': _maskSel,
        // En mode recadrage, on voit toute l'image (déjà redressée) sous le cadre.
        if (_cropMode) ...kCropDefaults,
        // Onglet « Supprimer » : photo entière et droite, pour que les positions touchées soient celles de la source.
        if (_uncropped(_tool) && !_cropMode) ...<String, double>{...kCropDefaults, 'angle': 0},
      }));

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
        final Histogram? hist = _histVisible ? Histogram.of(out, w, h) : null;
        sw.reset();
        final Completer<ui.Image> done = Completer<ui.Image>();
        ui.decodeImageFromPixels(out, w, h, ui.PixelFormat.rgba8888, done.complete);
        final ui.Image img = await done.future;
        final int imageMs = sw.elapsedMilliseconds;
        if (!mounted) return;
        final ui.Image? old = _shown;
        setState(() {
          _shown = img;
          _hist = hist;
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

  void _applyCurvePreset(int index) {
    final CurvePoints pts = curvePresetPoints(index);
    setState(() {
      if (isIdentityCurve(pts)) {
        _curves.remove(_curveChannel);
      } else {
        _curves[_curveChannel] = pts;
      }
      _before = false;
    });
    _commit();
    _refresh();
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
      const Padding(
        padding: EdgeInsets.only(top: 10, bottom: 4),
        child: Text('COURBES PRÊTES À L\'EMPLOI',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.5, color: Colors.white60)),
      ),
      Text('Appliquées au canal ${names[_curveChannel]} ; vous pouvez ensuite les ajuster au doigt.',
          style: const TextStyle(fontSize: 12, color: Colors.white60)),
      const SizedBox(height: 6),
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: <Widget>[
          for (int i = 0; i < kCurvePresets.length; i++)
            ActionChip(
              label: Text(kCurvePresets[i].$1),
              onPressed: ready ? () => _applyCurvePreset(i) : null,
            ),
        ],
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

  /// Onglets qui montrent la photo entière et droite (les positions touchées sont celles de la photo d'origine).
  bool _uncropped(String t) => t == 'spots' || t == 'masks';

  void _setTool(String t) {
    final bool redo = _uncropped(t) != _uncropped(_tool) || (_maskZone && t != 'masks');
    setState(() {
      _tool = t;
      if (t != 'masks') {
        _maskDraw = null;
        _maskAttach = false;
        _maskPick = false;
        _brushTool = null;
        _maskZone = false;
      }
    });
    if (redo) _refresh();
  }

  // -- Masques : dégradés linéaire et radial ---------------------------------------------------
  MaskMap? get _maskSelected =>
      _maskSel >= 0 && _maskSel < _masks.length && isManualMask(_masks[_maskSel]) ? _masks[_maskSel] : null;

  void _maskSet(int i, MaskMap m) {
    if (i < 0 || i >= _masks.length) return;
    setState(() {
      _masks = <MaskMap>[for (int k = 0; k < _masks.length; k++) k == i ? m : _masks[k]];
      _before = false;
    });
  }

  /// Un doigt a tracé un dégradé sur la photo : un nouveau masque, ou une composante de plus du masque choisi.
  void _maskDrawn(String kind, double ax, double ay, double bx, double by) {
    final double aspect = _h == 0 ? 1 : _w / _h;
    final MaskMap? base = _maskAttach ? _maskSelected : null;
    final String name = nextMaskName(_masks, kMaskKindNames[kind]!);
    final MaskMap shape = kind == kLinear
        ? linearFromDrag(name, ax, ay, bx, by, aspect)
        : radialFromDrag(name, ax, ay, bx, by, aspect);
    if (base != null) {
      final MaskMap grown = addComp(base, <String, dynamic>{...?mainComp(shape), 'op': _newOp});
      _maskSet(_maskSel, grown);
      setState(() {
        _compSel = compsOf(grown).length - 1;
        _maskDraw = null;
        _maskAttach = false;
        _maskZone = true; // la zone du masque se voit toujours quand on le crée ou qu'on y ajoute
      });
      _commit();
      _refresh();
      return;
    }
    setState(() {
      _masks = <MaskMap>[..._masks, shape];
      _maskSel = _masks.length - 1;
      _compSel = 0;
      _maskDraw = null;
      _maskAttach = false;
      _before = false;
        _maskZone = true; // la zone du masque se voit toujours quand on le crée ou qu'on y ajoute
    });
    _commit();
    _refresh();
  }

  /// Un nouveau masque : les dégradés se tracent au doigt, les plages se créent tout de suite.
  void _maskNew(String kind) {
    if (kind == kLinear || kind == kRadial) {
      setState(() {
        final bool on = _maskDraw == kind && !_maskAttach;
        _maskDraw = on ? null : kind;
        _maskAttach = false;
        _maskPick = false;
        _brushTool = null;
        _maskPickNew = false;
      });
      return;
    }
    if (kind == kBrush) {
      final MaskMap b = withCompAt(brushMask(nextMaskName(_masks, kMaskKindNames[kBrush]!)), 0, <String, dynamic>{'r': _brushR});
      setState(() {
        _masks = <MaskMap>[..._masks, b];
        _maskSel = _masks.length - 1;
        _compSel = 0;
        _maskDraw = null;
        _maskAttach = false;
        _maskPick = false;
        _maskPickNew = false;
        _brushTool = 'paint';
        _before = false;
        _maskZone = true; // la zone du masque se voit toujours quand on le crée ou qu'on y ajoute
      });
      _commit();
      return;
    }
    if (kind == kColor) {
      // le masque n'est créé qu'au toucher sur la photo : aucune zone « rouge par défaut » avant de choisir
      setState(() {
        _maskPickNew = !(_maskPick && _maskPickNew);
        _maskPick = _maskPickNew;
        _maskDraw = null;
        _maskAttach = false;
      });
      return;
    }
    final MaskMap m = rangeMask(nextMaskName(_masks, kMaskKindNames[kind]!), kind);
    setState(() {
      _masks = <MaskMap>[..._masks, m];
      _maskSel = _masks.length - 1;
      _compSel = 0;
      _maskDraw = null;
      _maskAttach = false;
      _maskPick = false;
      _brushTool = null;
      _maskPickNew = false;
      _before = false;
      _maskZone = true; // la zone du masque se voit toujours quand on le crée ou qu'on y ajoute
    });
    _commit();
  }

  /// Une composante de plus pour le masque choisi, combinée selon [_newOp].
  void _maskAddComp(String kind) {
    final MaskMap? m = _maskSelected;
    if (m == null) return;
    if (kind == kLinear || kind == kRadial) {
      setState(() {
        _maskDraw = kind;
        _maskAttach = true;
        _maskPick = false;
        _brushTool = null;
      });
      return;
    }
    final MaskMap grown = addComp(m, defaultComp(kind, op: _newOp));
    _maskSet(_maskSel, grown);
    setState(() {
      _compSel = compsOf(grown).length - 1;
      _maskDraw = null;
      _maskAttach = false;
      _maskPick = kind == kColor;
      _maskPickNew = false;
      _brushTool = kind == kBrush ? (_newOp == 'subtract' ? 'erase' : 'paint') : null;
      _maskZone = true; // la zone du masque se voit toujours quand on le crée ou qu'on y ajoute
    });
    _commit();
    _refresh();
  }

  void _maskCompOp(int i, String op) {
    final MaskMap? m = _maskSelected;
    if (m == null) return;
    _maskSet(_maskSel, withCompAt(m, i, <String, dynamic>{'op': op}));
    _commit();
    _refresh();
  }

  void _maskCompDelete(int i) {
    final MaskMap? m = _maskSelected;
    if (m == null) return;
    _maskSet(_maskSel, removeCompAt(m, i));
    setState(() {
      _compSel = 0;
      _maskPick = false;
      _brushTool = null;
    });
    _commit();
    _refresh();
  }

  /// Pipette : la teinte (et une saturation minimale) de la couleur touchée sur la photo.
  void _maskPicked(double fx, double fy) {
    final Uint8List? rgba = _srcRgba;
    if (rgba == null) return;
    final (double hue, double sat) = hueSatAt(rgba, _w, _h, fx, fy);
    if (_maskPickNew) {
      final MaskMap made = withCompAt(rangeMask(nextMaskName(_masks, kMaskKindNames[kColor]!), kColor), 0, <String, dynamic>{
        'hue': hue,
        'sat_min': (sat * 0.5).clamp(0.02, 0.5).toDouble(),
      });
      setState(() {
        _masks = <MaskMap>[..._masks, made];
        _maskSel = _masks.length - 1;
        _compSel = 0;
        _maskPick = false;
        _brushTool = null;
        _maskPickNew = false;
        _before = false;
        _maskZone = true; // la zone du masque se voit toujours quand on le crée ou qu'on y ajoute
      });
      _commit();
      _refresh();
      return;
    }
    final MaskMap? m = _maskSelected;
    final Map<String, dynamic>? c = m == null ? null : compAt(m, _compSel);
    if (m == null || c == null || '${c['kind']}' != kColor) return;
    _maskSet(
        _maskSel,
        withCompAt(m, _compSel, <String, dynamic>{
          'hue': hue,
          'sat_min': (sat * 0.5).clamp(0.02, 0.5).toDouble(),
        }));
    setState(() {
      _maskPick = false;
      _maskZone = true;
    });
    _commit();
    _refresh();
  }

  /// « Personnes » : une pastille par personne repérée (une personne = un visage), même quand les corps se touchent.
  Future<void> _maskPersons() async {
    final Uint8List? rgba = _srcRgba;
    if (rgba == null || _aiBusy || _w == 0 || _h == 0) return;
    setState(() => _aiBusy = true);
    VisionFaces found = const VisionFaces();
    try {
      found = await VisionBridge.faceParts(rgba, _w, _h);
    } finally {
      if (mounted) setState(() => _aiBusy = false);
    }
    if (!mounted) return;
    final String? error = found.error;
    if (error != null) {
      _say(error);
      return;
    }
    // de gauche à droite
    final List<VisionFace> list = List<VisionFace>.of(found.faces);
    list.sort((VisionFace a, VisionFace b) => (a.x0 + a.x1).compareTo(b.x0 + b.x1));
    final List<ui.Image> thumbs = await _cropThumbs(
      rgba,
      <List<double>>[
        for (final VisionFace f in list) <double>[f.x0, f.y0, f.x1, f.y1],
      ],
      0.35,
    );
    if (!mounted) return;
    setState(() {
      _faces = list;
      _faceImgs = thumbs;
      _facesFor = rgba;
      _selFaces = list.length == 1 ? <int>{0} : <int>{};
      _selParts = <String>{};
    });
    _say(list.length == 1 ? '1 personne repérée.' : '${list.length} personnes repérées : touchez « Toutes » ou une pastille.');
  }

  /// Les pastilles des visages sont-elles à montrer (même photo que celle où on les a cherchés) ?
  bool get _facesShown => _faces.isNotEmpty && identical(_facesFor, _srcRgba) && _faceImgs.length == _faces.length;

  /// Centre du visage [i] : sert d'identifiant du visage dans les masques de ses parties.
  List<double> _faceCenter(int i) => <double>[(_faces[i].x0 + _faces[i].x1) / 2, (_faces[i].y0 + _faces[i].y1) / 2];

  /// La personne [i] figure-t-elle dans un masque déjà créé ?
  bool _faceHasMask(int i) {
    final List<double> c = _faceCenter(i);
    for (final MaskMap m in _masks) {
      final Map<String, dynamic>? comp = mainComp(m);
      if (comp == null || '${comp['kind']}' != kBitmap) continue;
      final Object? ai = comp['ai'];
      if (ai is! Map<String, dynamic>) continue;
      final Object? pts = ai['points'];
      if (pts is! List<dynamic>) continue;
      for (final dynamic q in pts) {
        if (q is List<dynamic> && q.length >= 2 && q[0] is num && q[1] is num && ((q[0] as num) - c[0]).abs() < 1e-4 && ((q[1] as num) - c[1]).abs() < 1e-4) {
          return true;
        }
      }
    }
    return false;
  }

  static const Map<String, String> _kSelParts = <String, String>{
    'person': 'Toute la personne',
    'skin': 'Peau du visage',
    'bodyskin': 'Peau du corps',
    'eyes': 'Yeux',
    'brows': 'Sourcils',
    'lips': 'Lèvres',
    'hair': 'Cheveux',
    'clothes': 'Vêtements',
  };

  /// Rangée de pastilles à la Lightroom : « Toutes les personnes » puis une pastille par personne (plusieurs possibles).
  List<Widget> _faceTiles(TextStyle title, TextStyle hint) {
    final bool all = _selFaces.length == _faces.length;
    const Color on = Color(0xFFF2A33A);
    Widget tile(Widget picture, String label, bool selected, VoidCallback tap) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: _aiBusy ? null : tap,
            child: Column(
              children: <Widget>[
                Container(
                  height: 72,
                  constraints: const BoxConstraints(minWidth: 56),
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: selected ? on : Colors.transparent, width: 2),
                  ),
                  child: ClipRRect(borderRadius: BorderRadius.circular(8), child: picture),
                ),
                const SizedBox(height: 2),
                Text(label, style: hint),
              ],
            ),
          ),
        );
    return <Widget>[
      Padding(padding: const EdgeInsets.only(top: 10, bottom: 4), child: Text('PERSONNES', style: title)),
      SizedBox(
        height: 94,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: <Widget>[
            tile(
              const SizedBox(width: 56, child: Center(child: Icon(Icons.groups_outlined, size: 30))),
              'Toutes',
              all,
              () => setState(() => _selFaces = all ? <int>{} : <int>{for (int i = 0; i < _faces.length; i++) i}),
            ),
            for (int i = 0; i < _faces.length; i++)
              tile(
                RawImage(image: _faceImgs[i], fit: BoxFit.contain),
                'Personne ${i + 1}${_faceHasMask(i) ? ' ✓' : ''}',
                _selFaces.contains(i),
                () => setState(() {
                  final Set<int> n = <int>{..._selFaces};
                  if (!n.remove(i)) n.add(i);
                  _selFaces = n;
                }),
              ),
          ],
        ),
      ),
    ];
  }

  /// Cases à cocher (comme Lightroom) puis « Annuler » / « Créer ».
  List<Widget> _facePartChips(TextStyle title, TextStyle hint) {
    final bool ready = _selFaces.isNotEmpty && _selParts.isNotEmpty && !_aiBusy;
    if (_selFaces.isEmpty) {
      return <Widget>[
        Padding(padding: const EdgeInsets.only(top: 4), child: Text('Touchez « Toutes » ou une ou plusieurs pastilles : les cases à cocher apparaissent ensuite.', style: hint)),
      ];
    }
    return <Widget>[
      Padding(padding: const EdgeInsets.only(top: 6, bottom: 4), child: Text('CE QUE LE MASQUE COUVRE', style: title)),
      Wrap(
        children: <Widget>[
          for (final MapEntry<String, String> e in _kSelParts.entries)
            SizedBox(
              width: 170,
              child: CheckboxListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(e.value),
                value: _selParts.contains(e.key),
                onChanged: _aiBusy
                    ? null
                    : (bool? v) => setState(() {
                          final bool on = v ?? false;
                          Set<String> n = <String>{..._selParts};
                          if (e.key == 'person') {
                            // « Toute la personne » coche (ou décoche) tout le reste
                            n = on ? <String>{..._kSelParts.keys} : <String>{};
                          } else if (on) {
                            n.add(e.key);
                            if (_kSelParts.keys.where((String k) => k != 'person').every(n.contains)) n.add('person');
                          } else {
                            n.remove(e.key);
                            n.remove('person');
                          }
                          _selParts = n;
                        }),
              ),
            ),
        ],
      ),
      Row(
        children: <Widget>[
          TextButton(onPressed: _aiBusy || _selParts.isEmpty ? null : () => setState(() => _selParts = <String>{}), child: const Text('Annuler')),
          const SizedBox(width: 8),
          FilledButton(onPressed: ready ? _createSelection : null, child: const Text('Créer')),
        ],
      ),
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          _selFaces.isEmpty
              ? 'Touchez « Toutes » ou une ou plusieurs pastilles.'
              : 'Un seul masque pour ${_selFaces.length == _faces.length ? 'toutes les personnes' : _selFaces.length == 1 ? 'la personne ${_selFaces.first + 1}' : '${_selFaces.length} personnes'}. Visage : iPadOS ; cheveux, vêtements, peau du corps : modèle MediaPipe (essai). Corps qui se touchent : la silhouette peut inclure le voisin.',
          style: hint,
        ),
      ),
    ];
  }

  /// Plan (pw×ph) d'une partie du visage de la personne [which], ou null si iPadOS ne l'a pas trouvée.
  Uint8List? _facePartPlaneFor(int which, String part, int pw, int ph) {
    final VisionFace face = _faces[which];
    final Map<String, List<double>> marks = <String, List<double>>{
      ...face.parts,
      'box': <double>[face.x0, face.y0, face.x1, face.y1],
    };
    final PartShape? shape = partShape(marks, part);
    if (shape == null) return null;
    return blurPlane(fillShape(pw, ph, shape), pw, ph, (math.max(pw, ph) * 0.003).round().clamp(1, 12).toInt());
  }

  /// Plan (pw×ph) cheveux / vêtements / peau du corps de la personne [which] ; message d'erreur dans [errors] si le modèle échoue.
  Future<Uint8List?> _bodyPartPlaneFor(int which, String part, int pw, int ph, Uint8List rgba, List<String> errors) async {
    final VisionFace face = _faces[which];
    final CropSquare crop = bodyCrop(face.x0, face.y0, face.x1, face.y1, _w, _h, part: part);
    final VisionParts r = await VisionBridge.bodyParts(rgba, _w, _h, crop.x0, crop.y0, crop.side);
    final Uint8List? probs = r.probs;
    final String? error = r.error;
    if (error != null || probs == null) {
      errors.add(error ?? 'Parties du corps indisponibles.');
      return null;
    }
    return bodyPartPlane(
      probs: probs,
      size: r.size,
      cls: kBodyPartClass[part]!,
      crop: crop,
      anchor: partAnchor(part, face.x0, face.y0, face.x1, face.y1, _w, _h),
      pw: pw,
      ph: ph,
      imgW: _w,
      imgH: _h,
      guide: grayPlane(rgba, _w, _h, pw, ph),
      faces: <List<double>>[
        for (final VisionFace f in _faces) <double>[(f.x0 + f.x1) / 2 * _w, (f.x1 - f.x0) * _w],
      ],
      self: which,
    );
  }

  /// Silhouette de la personne [which] (Vision), rééchantillonnée en pw×ph.
  Future<Uint8List?> _personPlaneFor(int which, int pw, int ph, Uint8List rgba, List<String> errors) async {
    final List<double> c = _faceCenter(which);
    final VisionMaskResult r = await VisionBridge.instanceMask(rgba, _w, _h, person: true, fx: c[0], fy: c[1]);
    final Uint8List? mask = r.mask;
    if (!r.ok || mask == null) {
      errors.add(r.error ?? 'Détourage impossible.');
      return null;
    }
    return resamplePlane(mask, r.width, r.height, pw, ph);
  }

  /// « Créer » : UN masque, réunion des parties cochées pour les personnes cochées.
  Future<void> _createSelection() async {
    final Uint8List? rgba = _srcRgba;
    if (rgba == null || _aiBusy || _w == 0 || _h == 0 || _selFaces.isEmpty || _selParts.isEmpty) return;
    final List<int> who = (_selFaces.where((int i) => i >= 0 && i < _faces.length).toList())..sort();
    final List<String> parts = <String>[for (final String k in _kSelParts.keys) if (_selParts.contains(k)) k];
    final double aspect = _w / _h;
    final int pw = aspect >= 1 ? 1024 : (1024 * aspect).round().clamp(64, 1024).toInt();
    final int ph = aspect >= 1 ? (1024 / aspect).round().clamp(64, 1024).toInt() : 1024;
    setState(() => _aiBusy = true);
    try {
      final Uint8List plane = Uint8List(pw * ph);
      final List<String> errors = <String>[];
      final List<String> missing = <String>[];
      for (final int i in who) {
        for (final String part in parts) {
          Uint8List? p;
          if (part == 'person') {
            p = await _personPlaneFor(i, pw, ph, rgba, errors);
          } else if (kFacePartNames.containsKey(part)) {
            p = _facePartPlaneFor(i, part, pw, ph);
          } else {
            p = await _bodyPartPlaneFor(i, part, pw, ph, rgba, errors);
          }
          if (!mounted) return;
          if (p == null) {
            missing.add('${_kSelParts[part]!.toLowerCase()} (personne ${i + 1})');
          } else {
            unionPlanes(plane, p);
          }
        }
      }
      int covered = 0;
      for (final int v in plane) {
        if (v > 127) covered++;
      }
      if (covered == 0) {
        _say(errors.isNotEmpty ? errors.first : 'Rien trouvé pour cette sélection.');
        return;
      }
      final String who0 = who.length == _faces.length && who.length > 1 ? 'Tous' : who.length == 1 ? 'Personne ${who.first + 1}' : 'Personnes ${who.map((int i) => i + 1).join('+')}';
      final String what0 = parts.length == 1 ? _kSelParts[parts.first]! : parts.map((String k) => _kSelParts[k]!).join(', ');
      final String key = maskKey(plane);
      MaskBitmaps.set(key, pw, ph, plane);
      final MaskMap m = bitmapMask(
        name: nextMaskName(_masks, '$who0 · $what0'),
        key: key,
        pngBase64: planeToBase64(plane, pw, ph),
        what: 'face_multi',
      );
      ((m['comps'] as List<dynamic>).first as Map<String, dynamic>)['ai']['points'] = <dynamic>[for (final int i in who) _faceCenter(i)];
      setState(() {
        _masks = <MaskMap>[..._masks, m];
        _maskSel = _masks.length - 1;
        _compSel = 0;
        _maskDraw = null;
        _maskAttach = false;
        _maskPick = false;
        _brushTool = null;
        _before = false;
        _maskZone = true;
        _selParts = <String>{};
      });
      _commit();
      _refresh();
      _say(missing.isEmpty ? 'Masque créé (${(covered * 100 / plane.length).round()} % de l\'image).' : 'Masque créé ; non trouvé : ${missing.join(', ')}.');
    } catch (e) {
      _say('Sélection impossible : $e');
    } finally {
      if (mounted) setState(() => _aiBusy = false);
    }
  }

  /// SAM 2.1 : analyse la photo (une fois), puis chaque toucher sur la photo ajoute un point.
  Future<void> _samStart() async {
    final Uint8List? rgba = _srcRgba;
    if (rgba == null || _aiBusy || _w == 0 || _h == 0) return;
    setState(() => _aiBusy = true);
    _say('SAM 2.1 analyse la photo…');
    try {
      final String? error = await VisionBridge.samEncode(rgba, _w, _h, identityHashCode(rgba));
      if (!mounted) return;
      if (error != null) {
        _say(error);
        return;
      }
      setState(() {
        _samOn = true;
        _samAdd = true;
        _samPts = <List<double>>[];
        _samMask = -1;
        _maskPick = false;
        _maskPickNew = false;
        _maskDraw = null;
        _maskAttach = false;
        _brushTool = null;
      });
      _say('Touchez l\'objet à sélectionner.');
    } catch (e) {
      _say('SAM 2.1 : $e');
    } finally {
      if (mounted) setState(() => _aiBusy = false);
    }
  }

  Future<void> _samTapped(double fx, double fy) async {
    if (_aiBusy || !_samOn) return;
    _samPts = <List<double>>[..._samPts, <double>[fx, fy, _samAdd ? 1.0 : 0.0]];
    await _samRun();
  }

  Future<void> _samUndo() async {
    if (_aiBusy || _samPts.length < 2) return;
    _samPts = _samPts.sublist(0, _samPts.length - 1);
    await _samRun();
  }

  /// Calcule le masque pour tous les points et le met à la place de celui en cours (ou le crée).
  Future<void> _samRun() async {
    final Uint8List? rgba = _srcRgba;
    if (rgba == null || _samPts.isEmpty || _w == 0 || _h == 0) return;
    setState(() => _aiBusy = true);
    try {
      final VisionSam r = await VisionBridge.samDecode(_samPts);
      if (!mounted) return;
      final Float32List? logits = r.logits;
      final String? error = r.error;
      if (error != null || logits == null) {
        _say(error ?? 'SAM 2.1 : pas de masque.');
        return;
      }
      final double aspect = _w / _h;
      final int pw = aspect >= 1 ? 1024 : (1024 * aspect).round().clamp(64, 1024).toInt();
      final int ph = aspect >= 1 ? (1024 / aspect).round().clamp(64, 1024).toInt() : 1024;
      final Uint8List plane = samPlane(logits: logits, size: r.size, pw: pw, ph: ph, guide: grayPlane(rgba, _w, _h, pw, ph));
      int covered = 0;
      for (final int v in plane) {
        if (v > 127) covered++;
      }
      if (covered == 0) {
        _say('Rien n\'est sélectionné ici : touchez l\'objet.');
        return;
      }
      final String key = maskKey(plane);
      MaskBitmaps.set(key, pw, ph, plane);
      final bool existing = _samMask >= 0 && _samMask < _masks.length;
      final MaskMap old = existing ? _masks[_samMask] : <String, dynamic>{};
      MaskMap m = bitmapMask(
        name: existing ? '${old['name']}' : nextMaskName(_masks, 'Sélection'),
        key: key,
        pngBase64: planeToBase64(plane, pw, ph),
        what: 'sam',
      );
      ((m['comps'] as List<dynamic>).first as Map<String, dynamic>)['ai']['points'] = <dynamic>[
        for (final List<double> q in _samPts) List<double>.of(q),
      ];
      if (existing) {
        m = <String, dynamic>{...m, 'enabled': old['enabled'], 'invert': old['invert'], 'amount': old['amount'], 'adj': old['adj']};
      }
      setState(() {
        if (existing) {
          final int at = _samMask;
          _masks = <MaskMap>[for (int k = 0; k < _masks.length; k++) k == at ? m : _masks[k]];
        } else {
          _masks = <MaskMap>[..._masks, m];
          _samMask = _masks.length - 1;
        }
        _maskSel = _samMask;
        _compSel = 0;
        _before = false;
        _maskZone = true;
      });
      _commit();
      _refresh();
      _say('Sélection : ${(covered * 100 / plane.length).round()} % de l\'image (${_samPts.length} point${_samPts.length > 1 ? 's' : ''}).');
    } catch (e) {
      _say('SAM 2.1 : $e');
    } finally {
      if (mounted) setState(() => _aiBusy = false);
    }
  }

  /// Les points du masque choisi s'il a été fait par SAM (pour le reprendre), sinon null.
  List<List<double>>? get _samEditablePoints {
    final MaskMap? m = _maskSelected;
    final Map<String, dynamic>? c = m == null ? null : mainComp(m);
    if (c == null || '${c['kind']}' != kBitmap) return null;
    return samPointsOf(c['ai']);
  }

  /// « Modifier la sélection » : reprend un masque SAM avec ses points, pour en ajouter ou en retirer.
  Future<void> _samEdit() async {
    final Uint8List? rgba = _srcRgba;
    final List<List<double>>? pts = _samEditablePoints;
    if (rgba == null || pts == null || _aiBusy || _w == 0 || _h == 0 || _maskSel < 0) return;
    final int at = _maskSel;
    setState(() => _aiBusy = true);
    _say('SAM 2.1 prépare la photo…');
    try {
      final String? error = await VisionBridge.samEncode(rgba, _w, _h, identityHashCode(rgba));
      if (!mounted) return;
      if (error != null) {
        _say(error);
        return;
      }
      setState(() {
        _samOn = true;
        _samAdd = true;
        _samPts = <List<double>>[for (final List<double> q in pts) List<double>.of(q)];
        _samMask = at;
        _maskPick = false;
        _maskPickNew = false;
        _maskDraw = null;
        _maskAttach = false;
        _brushTool = null;
        _maskZone = true;
      });
      _say('Touchez la photo pour ajouter ou retirer une zone.');
    } catch (e) {
      _say('SAM 2.1 : $e');
    } finally {
      if (mounted) setState(() => _aiBusy = false);
    }
  }

  /// Bouton « Objet au toucher », puis ses choix quand la sélection au toucher est en cours.
  List<Widget> _samBlock(TextStyle title, TextStyle hint, bool ready) {
    if (!_samOn) {
      return <Widget>[
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.white24), minimumSize: const Size(48, 48)),
            onPressed: ready && !_aiBusy ? _samStart : null,
            icon: _aiBusy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.touch_app_outlined, size: 20),
            label: const Text('Objet au toucher (SAM 2.1, en essai)'),
          ),
        ),
      ];
    }
    return <Widget>[
      const SizedBox(height: 8),
      Text('OBJET AU TOUCHER', style: title),
      const SizedBox(height: 4),
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: <Widget>[
          ChoiceChip(label: const Text('+ Dans l\'objet'), selected: _samAdd, onSelected: (_) => setState(() => _samAdd = true)),
          ChoiceChip(label: const Text('− En dehors'), selected: !_samAdd, onSelected: (_) => setState(() => _samAdd = false)),
          ActionChip(label: const Text('Annuler le dernier point'), onPressed: _aiBusy || _samPts.length < 2 ? null : _samUndo),
          ActionChip(avatar: const Icon(Icons.check, size: 18), label: const Text('Terminé'), onPressed: _aiBusy ? null : () => setState(() => _samOn = false)),
        ],
      ),
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          _samPts.isEmpty
              ? 'Touchez l\'objet sur la photo.'
              : '${_samPts.length} point${_samPts.length > 1 ? 's' : ''}. Touchez encore pour ajouter une zone (« Dans l\'objet ») ou en retirer une (« En dehors »), puis « Terminé ».',
          style: hint,
        ),
      ),
    ];
  }

  /// Petites images (120 px de haut) de la photo recadrée sur chaque cadre [x0, y0, x1, y1] (fractions), élargi de [margin].
  Future<List<ui.Image>> _cropThumbs(Uint8List rgba, List<List<double>> boxes, double margin) async {
    const int th = 120;
    final List<ui.Image> out = <ui.Image>[];
    for (final List<double> b in boxes) {
      final double mx = (b[2] - b[0]) * margin, my = (b[3] - b[1]) * margin;
      final int sx0 = ((b[0] - mx) * _w).floor().clamp(0, _w - 1).toInt();
      final int sy0 = ((b[1] - my) * _h).floor().clamp(0, _h - 1).toInt();
      final int sx1 = ((b[2] + mx) * _w).ceil().clamp(sx0 + 1, _w).toInt();
      final int sy1 = ((b[3] + my) * _h).ceil().clamp(sy0 + 1, _h).toInt();
      final int cw = sx1 - sx0, ch = sy1 - sy0;
      final int tw = (cw * th / ch).round().clamp(24, 240).toInt();
      final Uint8List px = Uint8List(tw * th * 4);
      for (int y = 0; y < th; y++) {
        final int sy = sy0 + (y * ch ~/ th);
        for (int x = 0; x < tw; x++) {
          final int sx = sx0 + (x * cw ~/ tw);
          final int s = (sy * _w + sx) * 4, d = (y * tw + x) * 4;
          px[d] = rgba[s];
          px[d + 1] = rgba[s + 1];
          px[d + 2] = rgba[s + 2];
          px[d + 3] = 255;
        }
      }
      final Completer<ui.Image> done = Completer<ui.Image>();
      ui.decodeImageFromPixels(px, tw, th, ui.PixelFormat.rgba8888, done.complete);
      out.add(await done.future);
    }
    return out;
  }

  /// Masque d'IA par Vision (iPadOS) : le sujet, l'arrière-plan (le sujet inversé) ou les personnes.
  Future<void> _maskAi(String what, {double? fx, double? fy, String? base}) async {
    final Uint8List? rgba = _srcRgba;
    if (rgba == null || _aiBusy || _w == 0 || _h == 0) return;
    setState(() => _aiBusy = true);
    try {
      final VisionMaskResult r = await VisionBridge.instanceMask(rgba, _w, _h, person: what == 'person', fx: fx, fy: fy);
      if (!mounted) return;
      final Uint8List? mask = r.mask;
      if (!r.ok || mask == null) {
        _say(r.error ?? 'Détourage impossible.');
        return;
      }
      final (Uint8List, int, int) fit = fitPlane(mask, r.width, r.height);
      int covered = 0;
      for (final int v in fit.$1) {
        if (v > 127) covered++;
      }
      if (covered == 0) {
        _say('Aucun sujet repéré par iPadOS.');
        return;
      }
      final String key = maskKey(fit.$1);
      MaskBitmaps.set(key, fit.$2, fit.$3, fit.$1);
      final bool inEngine = MaskBitmaps.has(key);
      final int pct = (covered * 100 / fit.$1.length).round();
      _say(inEngine ? 'Zone repérée : $pct % de l\'image.' : 'Zone repérée ($pct % de l\'image) mais refusée par le moteur.');
      final MaskMap m = bitmapMask(
        name: nextMaskName(_masks, base ?? kAiNames[what]!),
        key: key,
        pngBase64: planeToBase64(fit.$1, fit.$2, fit.$3),
        what: what,
        invert: what == 'background',
      );
      if (fx != null && fy != null) {
        // on garde le point de la personne : sa pastille retrouve ainsi son masque
        final Map<String, dynamic> c0 = (m['comps'] as List<dynamic>).first as Map<String, dynamic>;
        (c0['ai'] as Map<String, dynamic>)['points'] = <dynamic>[
          <double>[fx, fy]
        ];
      }
      setState(() {
        _masks = <MaskMap>[..._masks, m];
        _maskSel = _masks.length - 1;
        _compSel = 0;
        _maskDraw = null;
        _maskAttach = false;
        _maskPick = false;
        _brushTool = null;
        _before = false;
        _maskZone = true; // la sélection s'affiche tout de suite en rouge ; l'interrupteur « Voir la zone du masque » la retire
      });
      _commit();
      _refresh();
    } catch (e) {
      _say('Détourage impossible : $e');
    } finally {
      if (mounted) setState(() => _aiBusy = false);
    }
  }

  /// Rayon du pinceau montré à l'écran : celui de la composante pinceau choisie, sinon celui de départ.
  double get _effBrushR {
    final MaskMap? m = _maskSelected;
    final Map<String, dynamic>? c = m == null ? null : compAt(m, _compSel);
    if (c != null && '${c['kind']}' == kBrush && c['r'] is num) return (c['r'] as num).toDouble();
    return _brushR;
  }

  /// Un trait de pinceau (peindre ou gommer) : va dans la composante pinceau choisie, sinon dans une nouvelle.
  void _maskStroke(List<List<double>> raw) {
    final String? tool = _brushTool;
    if (tool == null || raw.isEmpty) return;
    final bool erase = tool == 'erase';
    final String op = erase ? 'subtract' : 'add';
    final double aspect = _h == 0 ? 1 : _w / _h;
    final MaskMap? sel = _maskSelected;
    MaskMap base;
    int ci = 0;
    final bool fresh = sel == null;
    if (sel == null) {
      if (erase) {
        _say('Choisissez d\'abord le masque à gommer.');
        return;
      }
      base = withCompAt(brushMask(nextMaskName(_masks, kMaskKindNames[kBrush]!)), 0, <String, dynamic>{'r': _brushR});
    } else {
      base = sel;
      final Map<String, dynamic>? c = compAt(sel, _compSel);
      final String cop = c == null ? '' : '${c['op']}';
      final bool fits = c != null && '${c['kind']}' == kBrush && (erase ? cop == 'subtract' : (cop == 'add' || cop == 'intersect'));
      if (fits) {
        ci = _compSel;
      } else {
        // même taille que le dernier pinceau du masque
        Map<String, dynamic>? last;
        for (final Map<String, dynamic> cc in compsOf(sel)) {
          if ('${cc['kind']}' == kBrush) last = cc;
        }
        final Map<String, dynamic> nc = defaultComp(kBrush, op: op);
        nc['r'] = last != null && last['r'] is num ? last['r'] : _brushR;
        if (last != null && last['feather'] is num) nc['feather'] = last['feather'];
        base = addComp(sel, nc);
        ci = compsOf(base).length - 1;
      }
    }
    final double r = ((compAt(base, ci)?['r'] as num?) ?? _brushR).toDouble();
    final MaskMap done = addStrokePoints(base, ci, densifyStroke(raw, aspect, r));
    setState(() {
      if (fresh) {
        _masks = <MaskMap>[..._masks, done];
        _maskSel = _masks.length - 1;
      } else {
        _masks = <MaskMap>[for (int k = 0; k < _masks.length; k++) k == _maskSel ? done : _masks[k]];
      }
      _compSel = ci;
      _before = false;
    });
    _commit();
    _refresh();
  }

  /// Une poignée du masque choisi est déplacée.
  void _maskEdit(Map<String, dynamic> changes) {
    final MaskMap? m = _maskSelected;
    if (m == null) return;
    _maskSet(_maskSel, withCompAt(m, _compSel, changes));
    if (!maskIsNeutral(m) || _maskZone) _refresh();
  }

  void _maskEditEnd() {
    _commit();
    final MaskMap? m = _maskSelected;
    if (m != null && (!maskIsNeutral(m) || _maskZone)) _refresh();
  }

  void _maskAdj(String key, double v) {
    final MaskMap? m = _maskSelected;
    if (m == null) return;
    if (_maskZone) setState(() => _maskZone = false); // on règle : on veut voir l'effet, plus la zone
    _maskSet(_maskSel, withAdj(m, key, v));
    _refresh();
  }

  void _maskResetKeys(Iterable<String> keys) {
    final MaskMap? start = _maskSelected;
    if (start == null) return;
    MaskMap m = start;
    for (final String k in keys) {
      m = withAdj(m, k, 0);
    }
    _maskSet(_maskSel, m);
    _commit();
    _refresh();
  }

  void _maskField(String key, Object? v) {
    final MaskMap? m = _maskSelected;
    if (m == null) return;
    _maskSet(_maskSel, <String, dynamic>{...m, key: v});
    _refresh();
  }

  void _maskDelete() {
    final int i = _maskSel;
    if (_maskSelected == null) return;
    setState(() {
      _masks = <MaskMap>[for (int k = 0; k < _masks.length; k++) if (k != i) _masks[k]];
      _maskSel = -1;
      _compSel = 0;
      _before = false;
    });
    _commit();
    _refresh();
  }

  void _maskDuplicate() {
    final MaskMap? m = _maskSelected;
    if (m == null) return;
    final int at = _maskSel + 1;
    setState(() {
      _masks = <MaskMap>[..._masks.sublist(0, at), duplicateMask(m), ..._masks.sublist(at)];
      _maskSel = at;
      _compSel = 0;
      _before = false;
    });
    _commit();
    _refresh();
  }

  Future<void> _maskRename() async {
    final MaskMap? m = _maskSelected;
    if (m == null) return;
    final int i = _maskSel;
    final TextEditingController c = TextEditingController(text: '${m['name'] ?? ''}');
    final String? name = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Nom du masque'),
        content: TextField(controller: c, autofocus: true, onSubmitted: (String v) => Navigator.pop(ctx, v)),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('OK')),
        ],
      ),
    );
    c.dispose();
    if (name == null || name.trim().isEmpty || !mounted || i >= _masks.length) return;
    _maskSet(i, <String, dynamic>{..._masks[i], 'name': name.trim()});
    _commit();
  }

  Widget _maskSlider(String label, double value, double min, double max, int decimals, ValueChanged<double> onChanged,
      {required VoidCallback onEnd, double reset = 0}) {
    return Row(
      children: <Widget>[
        SizedBox(width: 130, child: Text(label)),
        Expanded(
          child: GestureDetector(
            onDoubleTap: () {
              onChanged(reset);
              onEnd();
            },
            child: Slider(
              value: value.clamp(min, max).toDouble(),
              min: min,
              max: max,
              onChanged: onChanged,
              onChangeEnd: (double _) => onEnd(),
            ),
          ),
        ),
        SizedBox(
          width: 52,
          child: Text(value.toStringAsFixed(decimals),
              textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }

  static const Map<String, String> _kindShort = <String, String>{
    kLinear: 'Linéaire',
    kRadial: 'Radial',
    kLuminance: 'Luminosité',
    kColor: 'Couleur',
    kBrush: 'Pinceau',
  };

  static IconData _kindIcon(String kind) => kind == kBitmap
      ? Icons.auto_awesome
      : kind == kBrush
      ? Icons.brush
      : kind == kRadial
      ? Icons.radio_button_unchecked
      : kind == kLuminance
          ? Icons.brightness_6_outlined
          : kind == kColor
              ? Icons.colorize
              : Icons.gradient;

  Widget _maskKindButton(String kind, bool ready) {
    final bool on = (kind == kBrush && _brushTool != null) || (_maskDraw == kind && !_maskAttach) || (kind == kColor && _maskPick && _maskPickNew);
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        backgroundColor: on ? const Color(0xFF33291A) : null,
        side: BorderSide(color: on ? const Color(0xFFF2A33A) : Colors.white24),
        minimumSize: const Size(48, 48),
      ),
      onPressed: ready ? () => _maskNew(kind) : null,
      icon: Icon(_kindIcon(kind), size: 20),
      label: Text(_kindShort[kind]!),
    );
  }

  Widget _aiButton(String what, IconData icon, bool ready) {
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        side: const BorderSide(color: Colors.white24),
        minimumSize: const Size(48, 48),
      ),
      onPressed: ready && !_aiBusy ? () => (what == 'person' ? _maskPersons() : _maskAi(what)) : null,
      icon: _aiBusy
          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : Icon(icon, size: 20),
      label: Text(kAiNames[what]!),
    );
  }

  List<Widget> _masksPanel(bool ready) {
    final List<int> idx = <int>[
      for (int i = 0; i < _masks.length; i++)
        if (isManualMask(_masks[i])) i,
    ];
    final MaskMap? sel = _maskSelected;
    final List<Map<String, dynamic>> comps = sel == null ? const <Map<String, dynamic>>[] : compsOf(sel);
    final int cs = comps.isEmpty ? 0 : _compSel.clamp(0, comps.length - 1).toInt();
    final Map<String, dynamic>? comp = comps.isEmpty ? null : comps[cs];
    final String ckind = comp == null ? '' : '${comp['kind']}';
    double num0(String k, double d) => comp != null && comp[k] is num ? (comp[k] as num).toDouble() : d;
    const TextStyle hint = TextStyle(fontSize: 12, color: Colors.white60);
    const TextStyle title =
        TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.5, color: Colors.white60);
    final String guide = _aiBusy
        ? 'Détourage en cours par iPadOS…'
        : _brushTool != null
        ? (_brushTool == 'erase'
            ? 'Passez le doigt sur la photo pour effacer une partie du masque.'
            : 'Passez le doigt sur la photo pour peindre la zone à retoucher.')
        : _maskPick
        ? (_maskPickNew
            ? 'Touchez sur la photo la couleur à cibler : le masque sera créé à cet endroit.'
            : 'Touchez sur la photo la couleur à cibler.')
        : _maskDraw == kLinear
            ? 'Posez le doigt là où l\'effet est plein, glissez jusqu\'où il s\'arrête, puis levez le doigt.'
            : _maskDraw == kRadial
                ? 'Posez le doigt au centre, glissez jusqu\'au bord, puis levez le doigt.'
                : 'Touchez un type : les dégradés se tracent au doigt, les plages se règlent avec des curseurs.';
    return <Widget>[
      if (_facesShown) ..._faceTiles(title, hint),
      if (_facesShown) ..._facePartChips(title, hint),
      const SizedBox(height: 12),
      const Text('NOUVEAU MASQUE', style: title),
      const SizedBox(height: 6),
      Row(
        children: <Widget>[
          Expanded(child: _maskKindButton(kLinear, ready)),
          const SizedBox(width: 8),
          Expanded(child: _maskKindButton(kRadial, ready)),
        ],
      ),
      const SizedBox(height: 8),
      Row(
        children: <Widget>[
          Expanded(child: _maskKindButton(kLuminance, ready)),
          const SizedBox(width: 8),
          Expanded(child: _maskKindButton(kColor, ready)),
        ],
      ),
      const SizedBox(height: 8),
      Row(
        children: <Widget>[
          Expanded(child: _maskKindButton(kBrush, ready)),
          const SizedBox(width: 8),
          Expanded(child: _aiButton('subject', Icons.person_outline, ready)),
        ],
      ),
      const SizedBox(height: 8),
      Row(
        children: <Widget>[
          Expanded(child: _aiButton('background', Icons.landscape_outlined, ready)),
          const SizedBox(width: 8),
          Expanded(child: _aiButton('person', Icons.groups_outlined, ready)),
        ],
      ),
      ..._samBlock(title, hint, ready),
      Padding(padding: const EdgeInsets.only(top: 6), child: Text(guide, style: hint)),
      if (idx.isNotEmpty) ...<Widget>[
        const Padding(padding: EdgeInsets.only(top: 14, bottom: 2), child: Text('MASQUES', style: title)),
        for (final int i in idx)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            selected: i == _maskSel,
            selectedColor: const Color(0xFFF2A33A),
            leading: Icon(_kindIcon(maskKind(_masks[i]))),
            title: Text('${_masks[i]['name'] ?? ''}',
                style: TextStyle(color: _masks[i]['enabled'] == false ? Colors.white38 : null)),
            trailing: IconButton(
              tooltip: _masks[i]['enabled'] == false ? 'Réactiver ce masque' : 'Désactiver ce masque',
              icon: Icon(_masks[i]['enabled'] == false ? Icons.visibility_off_outlined : Icons.visibility_outlined),
              onPressed: () {
                _maskSet(i, <String, dynamic>{..._masks[i], 'enabled': _masks[i]['enabled'] == false});
                _commit();
                _refresh();
              },
            ),
            onTap: () => setState(() {
              _maskSel = i;
              _compSel = 0;
              _maskDraw = null;
              _maskAttach = false;
              _maskPick = false;
              _brushTool = null;
            }),
          ),
      ],
      if (sel != null && comp != null) ...<Widget>[
        const Divider(height: 20),
        Wrap(
          spacing: 4,
          children: <Widget>[
            if (!_samOn && _samEditablePoints != null)
              TextButton.icon(onPressed: _aiBusy ? null : _samEdit, icon: const Icon(Icons.touch_app_outlined, size: 18), label: const Text('Modifier la sélection')),
            TextButton.icon(onPressed: _maskRename, icon: const Icon(Icons.edit_outlined, size: 18), label: const Text('Renommer')),
            TextButton.icon(onPressed: _maskDuplicate, icon: const Icon(Icons.copy_outlined, size: 18), label: const Text('Dupliquer')),
            TextButton.icon(onPressed: _maskDelete, icon: const Icon(Icons.delete_outline, size: 18), label: const Text('Supprimer')),
          ],
        ),
        // Peindre / Gommer : seulement pour un masque pinceau ou d'IA (les poignées d'un dégradé se déplacent toutes seules ;
        // pour peindre sur un autre masque, on ajoute une composante « Pinceau »).
        if (comps.any((Map<String, dynamic> c) => '${c['kind']}' == kBrush || '${c['kind']}' == kBitmap)) ...<Widget>[
          const SizedBox(height: 6),
          SegmentedButton<String>(
            showSelectedIcon: false,
            emptySelectionAllowed: true,
            segments: const <ButtonSegment<String>>[
              ButtonSegment<String>(value: 'paint', label: Text('Peindre'), icon: Icon(Icons.brush)),
              ButtonSegment<String>(value: 'erase', label: Text('Gommer'), icon: Icon(Icons.cleaning_services_outlined)),
            ],
            selected: <String>{if (_brushTool != null) _brushTool!},
            onSelectionChanged: (Set<String> v) => setState(() {
              _brushTool = v.isEmpty ? null : v.first;
              _maskDraw = null;
              _maskAttach = false;
              _maskPick = false;
            }),
          ),
        ],
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Inverser le masque'),
          value: sel['invert'] == true,
          onChanged: (bool v) {
            _maskField('invert', v);
            _commit();
          },
        ),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Voir la zone du masque'),
          subtitle: const Text('Rouge = zone touchée par le masque (la photo garde vos réglages).', style: hint),
          value: _maskZone,
          onChanged: (bool v) {
            setState(() => _maskZone = v);
            _refresh();
          },
        ),
        _maskSlider('Opacité', ((sel['amount'] as num?) ?? 100).toDouble(), 0, 100, 0,
            (double v) => _maskField('amount', v), onEnd: _commit, reset: 100),
        const Padding(padding: EdgeInsets.only(top: 14, bottom: 2), child: Text('COMPOSANTES', style: title)),
        for (int i = 0; i < comps.length; i++)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            selected: i == cs,
            selectedColor: const Color(0xFFF2A33A),
            leading: Icon(_kindIcon('${comps[i]['kind']}')),
            title: Text(kMaskKindNames['${comps[i]['kind']}'] ?? '${comps[i]['kind']}'),
            subtitle: i == 0 ? null : Text(kOpNames['${comps[i]['op']}'] ?? 'Ajouter'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (i > 0)
                  PopupMenuButton<String>(
                    tooltip: 'Façon de combiner',
                    icon: const Icon(Icons.swap_vert),
                    onSelected: (String op) => _maskCompOp(i, op),
                    itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                      for (final MapEntry<String, String> e in kOpNames.entries)
                        PopupMenuItem<String>(value: e.key, child: Text(e.value)),
                    ],
                  ),
                if (comps.length > 1)
                  IconButton(
                    tooltip: 'Retirer cette composante',
                    icon: const Icon(Icons.close),
                    onPressed: () => _maskCompDelete(i),
                  ),
              ],
            ),
            onTap: () => setState(() {
              _compSel = i;
              _maskPick = false;
              _brushTool = null;
              _maskDraw = null;
              _maskAttach = false;
            }),
          ),
        const SizedBox(height: 6),
        const Text('Ajouter une composante', style: hint),
        const SizedBox(height: 4),
        SegmentedButton<String>(
          showSelectedIcon: false,
          segments: <ButtonSegment<String>>[
            for (final MapEntry<String, String> e in kOpNames.entries)
              ButtonSegment<String>(value: e.key, label: Text(e.value)),
          ],
          selected: <String>{_newOp},
          onSelectionChanged: (Set<String> v) => setState(() => _newOp = v.first),
        ),
        Wrap(
          spacing: 8,
          children: <Widget>[
            for (final String k in <String>[kLinear, kRadial, kBrush, kLuminance, kColor])
              ActionChip(
                avatar: Icon(_kindIcon(k), size: 18),
                label: Text(_kindShort[k]!),
                onPressed: ready ? () => _maskAddComp(k) : null,
              ),
          ],
        ),
        if (ckind == kRadial) ...<Widget>[
          const SizedBox(height: 6),
          _maskSlider('Contour progressif', num0('feather', 0.5) * 100, 0, 100, 0,
              (double v) => _maskEdit(<String, dynamic>{'feather': v / 100}), onEnd: _maskEditEnd, reset: 50),
          _maskSlider('Angle', num0('angle', 0), -90, 90, 0,
              (double v) => _maskEdit(<String, dynamic>{'angle': v}), onEnd: _maskEditEnd),
        ],
        if (ckind == kBitmap) ...<Widget>[
          const SizedBox(height: 6),
          const Text('Zone calculée par iPadOS à partir de la photo.', style: hint),
          _maskSlider('Agrandir / réduire', num0('grow', 0) * 100, -100, 100, 0,
              (double v) => _maskEdit(<String, dynamic>{'grow': v / 100}), onEnd: _maskEditEnd),
        ],
        if (ckind == kBrush) ...<Widget>[
          const SizedBox(height: 6),
          _maskSlider('Taille', num0('r', kBrushDefaultR) * 1000, 1, 100, 0, (double v) {
            _brushR = v / 1000;
            _maskEdit(<String, dynamic>{'r': v / 1000});
          }, onEnd: _maskEditEnd, reset: kBrushDefaultR * 1000),
          _maskSlider('Contour progressif', num0('feather', 0.5) * 100, 0, 100, 0,
              (double v) => _maskEdit(<String, dynamic>{'feather': v / 100}), onEnd: _maskEditEnd, reset: 50),
          _maskSlider('Agrandir / réduire', num0('grow', 0) * 100, -100, 100, 0,
              (double v) => _maskEdit(<String, dynamic>{'grow': v / 100}), onEnd: _maskEditEnd),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () {
                _maskEdit(<String, dynamic>{'stroke': <List<double>>[]});
                _commit();
                _refresh();
              },
              icon: const Icon(Icons.layers_clear_outlined, size: 18),
              label: const Text('Effacer le tracé de cette composante'),
            ),
          ),
        ],
        if (ckind == kLuminance) ...<Widget>[
          const SizedBox(height: 6),
          _maskSlider('Tons les plus sombres', num0('lo', 0) * 100, 0, 100, 0,
              (double v) => _maskEdit(<String, dynamic>{'lo': v / 100}), onEnd: _maskEditEnd),
          _maskSlider('Tons les plus clairs', num0('hi', 1) * 100, 0, 100, 0,
              (double v) => _maskEdit(<String, dynamic>{'hi': v / 100}), onEnd: _maskEditEnd, reset: 100),
          _maskSlider('Lissage', num0('smooth', 0.3) * 100, 0, 100, 0,
              (double v) => _maskEdit(<String, dynamic>{'smooth': v / 100}), onEnd: _maskEditEnd, reset: 30),
        ],
        if (ckind == kColor) ...<Widget>[
          const SizedBox(height: 6),
          Row(
            children: <Widget>[
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: HSVColor.fromAHSV(1, num0('hue', 0).clamp(0, 360).toDouble(), 1, 1).toColor(),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.white24),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => setState(() {
                    _maskPick = !_maskPick;
                    _maskPickNew = false;
                    _maskDraw = null;
                    _maskAttach = false;
                  }),
                  icon: const Icon(Icons.colorize, size: 18),
                  label: Text(_maskPick ? 'Touchez la couleur sur la photo' : 'Pipette : choisir sur la photo'),
                ),
              ),
            ],
          ),
          _maskSlider('Teinte visée', num0('hue', 0), 0, 360, 0,
              (double v) => _maskEdit(<String, dynamic>{'hue': v}), onEnd: _maskEditEnd),
          _maskSlider('Étendue', num0('hue_range', 30), 5, 90, 0,
              (double v) => _maskEdit(<String, dynamic>{'hue_range': v}), onEnd: _maskEditEnd, reset: 30),
          _maskSlider('Saturation minimale', num0('sat_min', 0.1) * 100, 0, 100, 0,
              (double v) => _maskEdit(<String, dynamic>{'sat_min': v / 100}), onEnd: _maskEditEnd, reset: 10),
        ],
        const Divider(height: 24),
        if (maskIsNeutral(sel))
          const Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Text('Tant que tous les réglages ci-dessous sont à zéro, le masque ne change rien à la photo.', style: hint),
          ),
        for (final (String gt, List<LocalParam> params) in kLocalGroups) ...<Widget>[
          _groupTitle(gt, () => _maskResetKeys(params.map((LocalParam p) => p.key))),
          for (final LocalParam p in params)
            _maskSlider(p.label, adjOf(sel, p.key), p.min, p.max, p.decimals, (double v) => _maskAdj(p.key, v),
                onEnd: _commit),
        ],
      ],
    ];
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
      _maskSel = -1; // les indices des masques ont pu changer
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
        _toolButton('masks', Icons.gradient, 'Masques', onTap: _cropMode ? null : () => _setTool('masks')),
        _toolButton('spots', Icons.healing, 'Supprimer', onTap: _cropMode ? null : () => _setTool('spots')),
        _toolButton('crop', Icons.crop, 'Recadrer', onTap: ready && !_cropMode ? _enterCrop : null),
      ];

  /// La photo, avec l'histogramme en haut à droite (ou sa pastille quand il est masqué).
  Widget _photoStack() {
    final Widget area = _photoArea();
    if (_shown == null || _cropMode) return area;
    return Stack(
      children: <Widget>[
        Positioned.fill(child: area),
        Positioned(
          top: 12,
          right: 12,
          child: _histVisible
              ? HistogramView(data: _hist, luminosity: _histLum, onMode: _setHistMode, onHide: () => _setHistVisible(false))
              : HistogramChip(onShow: () => _setHistVisible(true)),
        ),
      ],
    );
  }

  Widget _photoArea() {
    if (_shown == null) {
      return const Center(child: Text('Touchez « Ouvrir » pour choisir une photo.'));
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
    if (_tool == 'masks') {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: MaskOverlay(
          image: _shown!,
          comp: _maskSelected == null ? null : compAt(_maskSelected!, _compSel),
          invert: _maskSelected?['invert'] == true,
          drawKind: _maskDraw,
          showArea: !_maskZone,
          pickMode: _maskPick || _samOn,
          onPick: _samOn ? _samTapped : _maskPicked,
          paintKind: _brushTool,
          brushR: _effBrushR,
          onStroke: _maskStroke,
          onDraw: _maskDrawn,
          onEdit: _maskEdit,
          onEditEnd: _maskEditEnd,
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
                      : 'Version $kAppVersion · Moteur Rust chargé : ${_info.version}',
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
      case 'masks':
        return _masksPanel(ready);
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
                    Expanded(child: _photoStack()),
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
              Expanded(child: _photoStack()),
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
