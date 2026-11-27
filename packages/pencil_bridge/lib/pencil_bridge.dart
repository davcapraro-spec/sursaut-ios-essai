import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Un événement envoyé par le code natif (Swift) : contact du Pencil,
/// survol, serrage, double appui, ou message d'information.
///
/// `type` vaut : `touch`, `hover`, `squeeze`, `tap` ou `info`.
/// Les angles sont en radians, comme chez Apple.
class PencilNativeEvent {
  const PencilNativeEvent(this.type, this.data);

  final String type;
  final Map<String, Object?> data;

  double? number(String key) {
    final Object? v = data[key];
    return v is num ? v.toDouble() : null;
  }

  String? text(String key) {
    final Object? v = data[key];
    return v is String ? v : null;
  }

  bool? flag(String key) {
    final Object? v = data[key];
    return v is bool ? v : null;
  }
}

/// Accès au pont natif Apple Pencil.
///
/// Sous Windows ou en test, le pont n'existe pas : les appels échouent
/// proprement (message d'erreur), sans faire tomber l'application.
class PencilBridge {
  PencilBridge._();

  static const EventChannel _events = EventChannel('sursaut/pencil/events');
  static const MethodChannel _methods = MethodChannel('sursaut/pencil/methods');

  /// Flux des événements natifs. S'abonner attache le pont à la vue Flutter.
  static Stream<PencilNativeEvent> get events {
    return _events.receiveBroadcastStream().map((Object? raw) {
      final Map<Object?, Object?> map =
          raw is Map ? Map<Object?, Object?>.from(raw) : <Object?, Object?>{};
      final Map<String, Object?> data = <String, Object?>{
        for (final MapEntry<Object?, Object?> e in map.entries)
          e.key.toString(): e.value,
      };
      return PencilNativeEvent(data['type']?.toString() ?? 'inconnu', data);
    });
  }

  /// Ce que l'iPad dit de lui-même : modèle, version, réglages du Pencil.
  static Future<Map<String, Object?>> capabilities() async {
    try {
      final Map<String, Object?>? r =
          await _methods.invokeMapMethod<String, Object?>('capabilities');
      return r ?? <String, Object?>{};
    } on MissingPluginException {
      return <String, Object?>{'erreur': 'pont natif absent (pas un iPad)'};
    } on PlatformException catch (e) {
      return <String, Object?>{'erreur': e.message ?? e.code};
    }
  }
}

/// Accès au pont natif « appareil photo » (ImageCaptureCore, essai S2).
class CameraBridge {
  CameraBridge._();

  static const EventChannel _events = EventChannel('sursaut/camera/events');
  static const MethodChannel _methods = MethodChannel('sursaut/camera/methods');

  /// Les lignes de compte rendu envoyées par le code natif.
  static Stream<String> get lines {
    return _events.receiveBroadcastStream().where((Object? raw) => raw is! Map || raw.containsKey('line')).map((Object? raw) {
      if (raw is Map) {
        return raw['line']?.toString() ?? '';
      }
      return raw?.toString() ?? '';
    });
  }

  /// Chemin de la dernière image de vue directe enregistrée par l'essai du banc, ou null.
  static Future<String?> liveFramePath() async {
    try {
      return await _methods.invokeMethod<String>('liveFrame');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Les événements structurés du mode connecté : état de l'appareil, photo reçue, réglage confirmé.
  static Stream<CameraLiveEvent> get liveEvents {
    return _events
        .receiveBroadcastStream()
        .where((Object? raw) => raw is Map && !raw.containsKey('line'))
        .map((Object? raw) => CameraLiveEvent.fromMap(raw! as Map<Object?, Object?>));
  }

  /// État actuel de l'appareil (sans rien demander à l'appareil).
  static Future<CameraLiveState> liveSnapshot() async {
    try {
      final Map<Object?, Object?>? r = await _methods.invokeMapMethod<Object?, Object?>('liveSnapshot');
      return CameraLiveState.fromMap(r ?? <Object?, Object?>{});
    } on MissingPluginException {
      return const CameraLiveState();
    } on PlatformException {
      return const CameraLiveState();
    }
  }

  /// Place le point de mise au point : x de 0 à 639, y de 0 à 479 (grille de l'appareil).
  static Future<String?> liveAF(int x, int y) async {
    try {
      await _methods.invokeMethod<void>('liveAF', <String, Object>{'x': x, 'y': y});
      return null;
    } on MissingPluginException {
      return 'pont natif absent (pas un iPad)';
    } on PlatformException catch (e) {
      return e.message ?? e.code;
    }
  }

  /// Règle une propriété de l'appareil ; la confirmation arrive par [liveEvents] (`kind == 'set'`).
  static Future<String?> liveSet(int code, int value) async {
    try {
      await _methods.invokeMethod<void>('liveSet', <String, Object>{'code': code, 'value': value});
      return null;
    } on MissingPluginException {
      return 'pont natif absent (pas un iPad)';
    } on PlatformException catch (e) {
      return e.message ?? e.code;
    }
  }

  /// Extrait l'aperçu JPEG du dernier fichier reçu. Renvoie son chemin, ou null.
  static Future<String?> previewLast() async {
    try {
      return await _methods.invokeMethod<String>('previewLast');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Demande une action au code natif. Renvoie un message d'erreur, ou null.
  static Future<String?> call(String method) async {
    try {
      await _methods.invokeMethod<void>(method);
      return null;
    } on MissingPluginException {
      return 'pont natif absent (pas un iPad)';
    } on PlatformException catch (e) {
      return e.message ?? e.code;
    }
  }
}

/// Un cadre de mise au point affiché sur l'image directe (fractions de l'image, de 0 à 1).
class CameraFocusFrame {
  const CameraFocusFrame({required this.x, required this.y, required this.w, required this.h, required this.type, required this.state});

  final double x;
  final double y;
  final double w;
  final double h;
  final int type;

  /// 1 = pas net, 2 = net, 3 = sélection, 4 = en mouvement (référence Sony).
  final int state;
}

/// Une image de la vue directe : JPEG, dimensions, cadres de mise au point.
class CameraLiveFrame {
  const CameraLiveFrame({required this.jpeg, required this.width, required this.height, this.focus = const <CameraFocusFrame>[]});

  final Uint8List jpeg;
  final int width;
  final int height;
  final List<CameraFocusFrame> focus;

  factory CameraLiveFrame.fromMap(Map<Object?, Object?> m) {
    final List<CameraFocusFrame> focus = <CameraFocusFrame>[];
    final Object? raw = m['focus'];
    if (raw is List) {
      for (final Object? f in raw) {
        if (f is List && f.length >= 6) {
          final List<double> v = f.map((Object? e) => (e as num).toDouble()).toList();
          focus.add(CameraFocusFrame(x: v[0], y: v[1], w: v[2], h: v[3], type: v[4].toInt(), state: v[5].toInt()));
        }
      }
    }
    return CameraLiveFrame(
      jpeg: m['jpeg']! as Uint8List,
      width: (m['w'] as num?)?.toInt() ?? 0,
      height: (m['h'] as num?)?.toInt() ?? 0,
      focus: focus,
    );
  }
}

/// Une propriété de l'appareil : valeur actuelle, droits, choix proposés.
class CameraLiveProp {
  const CameraLiveProp({required this.cur, this.writable = false, this.enabled = true, this.choices = const <int>[]});

  final int cur;
  final bool writable;
  final bool enabled;
  final List<int> choices;
}

/// Photographie de l'état de l'appareil connecté.
class CameraLiveState {
  const CameraLiveState({
    this.found = false,
    this.session = false,
    this.ready = false,
    this.name,
    this.received = 0,
    this.lastFile,
    this.props = const <int, CameraLiveProp>{},
    this.area,
  });

  /// Zone où l'appareil accepte un point de mise au point, en cases de la grille 640 × 480 : [xMin, yMin, xMax, yMax]. Null si inconnue.
  final List<int>? area;

  final bool found;
  final bool session;

  /// Poignée de main PTP 3 faite : les réglages et le déclenchement sont possibles.
  final bool ready;
  final String? name;
  final int received;
  final String? lastFile;
  final Map<int, CameraLiveProp> props;

  factory CameraLiveState.fromMap(Map<Object?, Object?> m) {
    final Map<int, CameraLiveProp> props = <int, CameraLiveProp>{};
    final Object? raw = m['props'];
    if (raw is Map) {
      raw.forEach((Object? k, Object? v) {
        final int? code = int.tryParse('$k');
        if (code == null || v is! Map) return;
        final Object? ch = v['ch'];
        props[code] = CameraLiveProp(
          cur: (v['cur'] as num?)?.toInt() ?? 0,
          writable: v['w'] == true,
          enabled: v['on'] != false,
          choices: ch is List ? ch.whereType<num>().map((num n) => n.toInt()).toList() : const <int>[],
        );
      });
    }
    return CameraLiveState(
      found: m['found'] == true,
      session: m['session'] == true,
      ready: m['ready'] == true,
      name: m['name'] as String?,
      received: (m['received'] as num?)?.toInt() ?? 0,
      lastFile: m['lastFile'] as String?,
      props: props,
      area: m['area'] is List ? (m['area']! as List<Object?>).map((Object? e) => (e as num).toInt()).toList() : null,
    );
  }
}

/// Événement du mode connecté : `state` (nouvel état), `photo` (fichier reçu), `set` (réglage confirmé ou refusé).
class CameraLiveEvent {
  const CameraLiveEvent(this.kind, {this.state, this.frame, this.data = const <String, Object?>{}});

  final String kind;
  final CameraLiveState? state;
  final CameraLiveFrame? frame;
  final Map<String, Object?> data;

  factory CameraLiveEvent.fromMap(Map<Object?, Object?> m) {
    if (m['frame'] is Map) {
      return CameraLiveEvent('frame', frame: CameraLiveFrame.fromMap(m['frame']! as Map<Object?, Object?>));
    }
    if (m['stream'] is Map) {
      return const CameraLiveEvent('stream');
    }
    if (m['state'] is Map) {
      return CameraLiveEvent('state', state: CameraLiveState.fromMap(m['state']! as Map<Object?, Object?>));
    }
    for (final String k in <String>['photo', 'set']) {
      final Object? v = m[k];
      if (v is Map) {
        return CameraLiveEvent(k, data: v.map((Object? a, Object? b) => MapEntry<String, Object?>('$a', b)));
      }
    }
    return const CameraLiveEvent('inconnu');
  }
}

/// Résultat d'un détourage par Vision : image de masque (un octet par pixel, 255 = dans la zone) ou message d'erreur.
class VisionMaskResult {
  const VisionMaskResult({this.width = 0, this.height = 0, this.count = 0, this.mask, this.error});

  final int width;
  final int height;

  /// Nombre d'éléments (sujets, personnes) trouvés sur la photo.
  final int count;
  final Uint8List? mask;
  final String? error;

  bool get ok => mask != null && error == null;
}

/// Une personne repérée par Vision : son cadre et un point à l'intérieur de sa silhouette (fractions de la photo).
class VisionPerson {
  const VisionPerson(this.x0, this.y0, this.x1, this.y1, this.px, this.py);

  final double x0, y0, x1, y1, px, py;
}

/// Les personnes repérées par Vision, ou un message d'erreur.
class VisionPersons {
  const VisionPersons({this.persons = const <VisionPerson>[], this.error});

  final List<VisionPerson> persons;
  final String? error;
}

/// Un visage repéré : son cadre (x0, y0, x1, y1) et ses repères, chacun une suite x, y, x, y… en fractions de la photo.
class VisionFace {
  const VisionFace(this.x0, this.y0, this.x1, this.y1, this.parts);

  final double x0, y0, x1, y1;

  /// `leftEye`, `rightEye`, `leftBrow`, `rightBrow`, `outerLips`, `innerLips`, `contour` (certains peuvent manquer).
  final Map<String, List<double>> parts;
}

/// Les visages repérés par Vision, ou un message d'erreur.
class VisionFaces {
  const VisionFaces({this.faces = const <VisionFace>[], this.error});

  final List<VisionFace> faces;
  final String? error;
}

/// Les parties du corps d'une zone de la photo : [classes] plans de [size] x [size] octets (probabilité x 255), classe par classe.
/// Classes : 0 fond, 1 cheveux, 2 peau du corps, 3 peau du visage, 4 vêtements, 5 autres.
class VisionParts {
  const VisionParts({this.size = 0, this.probs, this.error});

  static const int classes = 6;
  final int size;
  final Uint8List? probs;
  final String? error;
}

/// Masque de SAM 2.1 pour des points : `logits` (size x size, avant sigmoïde : > 0 = dans l'objet).
class VisionSam {
  const VisionSam({this.size = 0, this.logits, this.score = 0, this.error});

  final int size;
  final Float32List? logits;
  final double score;
  final String? error;
}

/// Résultat de la segmentation au toucher de Vision (iPadOS 27) : `mask` (un octet par pixel de la photo, 255 = dans l'objet), `ms`.
class VisionIter {
  const VisionIter({this.mask, this.ms = 0, this.error});

  final Uint8List? mask;
  final double ms;
  final String? error;
}

/// Résultat d'un remplissage par LaMa : `rgba` (512 x 512 x 4) et les mesures (temps en millisecondes, mémoire de l'application en Mo).
class VisionLama {
  const VisionLama({this.rgba, this.loadMs = 0, this.runMs = 0, this.memBeforeMB = 0, this.memAfterMB = 0, this.error});

  final Uint8List? rgba;
  final double loadMs;
  final double runMs;
  final double memBeforeMB;
  final double memAfterMB;
  final String? error;
}

/// Détourage par Vision (Apple) : sujet principal ou personnes, sans fichier de modèle (iPadOS 17 ou plus).
class VisionBridge {
  VisionBridge._();

  static const MethodChannel _methods = MethodChannel('sursaut/vision/methods');

  /// SAM 2.1 : analyse la photo (une fois par photo et par zone : [key] les identifie ; [crop] = zone [x0, y0, x1, y1] en fractions, en gros plan). Rend un message d'erreur, ou null si tout va bien.
  static Future<String?> samEncode(Uint8List rgba, int width, int height, int key, {List<double>? crop}) async {
    try {
      final Map<Object?, Object?>? r = await _methods.invokeMapMethod<Object?, Object?>(
        'samEncode',
        <String, Object?>{'rgba': rgba, 'width': width, 'height': height, 'key': key, if (crop != null) 'crop': crop},
      );
      if (r == null) return 'Pas de réponse de SAM 2.1.';
      final Object? err = r['error'];
      return err?.toString();
    } on MissingPluginException {
      return 'SAM 2.1 indisponible (pas un iPad).';
    } on PlatformException catch (e) {
      return e.message ?? e.code;
    }
  }

  /// SAM 2.1 : le masque pour des points [x, y, étiquette] (x et y : fractions de la photo ; 1 = dans l'objet, 0 = en dehors).
  static Future<VisionSam> samDecode(List<List<double>> points) async {
    try {
      final Map<Object?, Object?>? r = await _methods.invokeMapMethod<Object?, Object?>(
        'samDecode',
        <String, Object?>{'points': points},
      );
      if (r == null) return const VisionSam(error: 'Pas de réponse de SAM 2.1.');
      final Object? err = r['error'];
      if (err != null) return VisionSam(error: err.toString());
      final Object? size = r['size'];
      final Object? logits = r['logits'];
      final Object? score = r['score'];
      if (size is! int || logits is! Float32List || logits.length < size * size) {
        return const VisionSam(error: 'Réponse de SAM 2.1 illisible.');
      }
      return VisionSam(size: size, logits: logits, score: score is num ? score.toDouble() : 0);
    } on MissingPluginException {
      return const VisionSam(error: 'SAM 2.1 indisponible (pas un iPad).');
    } on PlatformException catch (e) {
      return VisionSam(error: e.message ?? e.code);
    }
  }

  /// Les parties du corps dans le carré (`cropX`, `cropY`, `cropSide`, en pixels ; il peut dépasser la photo) : cheveux, peau, vêtements.
  static Future<VisionParts> bodyParts(Uint8List rgba, int width, int height, int cropX, int cropY, int cropSide) async {
    try {
      final Map<Object?, Object?>? r = await _methods.invokeMapMethod<Object?, Object?>(
        'bodyParts',
        <String, Object?>{
          'rgba': rgba,
          'width': width,
          'height': height,
          'kind': 'body',
          'cropX': cropX,
          'cropY': cropY,
          'cropSide': cropSide,
        },
      );
      if (r == null) return const VisionParts(error: 'Pas de réponse des parties du corps.');
      final Object? err = r['error'];
      if (err != null) return VisionParts(error: err.toString());
      final Object? size = r['size'];
      final Object? probs = r['probs'];
      if (size is! int || probs is! Uint8List || probs.length < size * size * VisionParts.classes) {
        return const VisionParts(error: 'Réponse des parties du corps illisible.');
      }
      return VisionParts(size: size, probs: probs);
    } on MissingPluginException {
      return const VisionParts(error: 'Parties du corps indisponibles (pas un iPad).');
    } on PlatformException catch (e) {
      return VisionParts(error: e.message ?? e.code);
    }
  }

  /// LaMa : le modèle est-il téléchargé ? (`present`, `bytes`)
  static Future<bool> lamaPresent() async {
    try {
      final Map<Object?, Object?>? r = await _methods.invokeMapMethod<Object?, Object?>('lamaStatus');
      return r != null && r['present'] == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// LaMa : télécharge le modèle Core ML (≈ 40 Mo) et vérifie son empreinte. Rend un message d'erreur, ou null si tout va bien.
  static Future<String?> lamaDownload() async {
    try {
      final Map<Object?, Object?>? r = await _methods.invokeMapMethod<Object?, Object?>('lamaDownload');
      if (r == null) return 'Pas de réponse du téléchargement.';
      final Object? err = r['error'];
      return err?.toString();
    } on MissingPluginException {
      return 'LaMa indisponible (pas un iPad).';
    } on PlatformException catch (e) {
      return e.message ?? e.code;
    }
  }

  /// Vision (iPadOS 27) : masque de l'objet pour des points [x, y] puis [x, y, 1 ou 0] (fractions de la photo, origine en haut à gauche ;
  /// le premier est le toucher de départ, les suivants incluent (1) ou excluent (0)).
  static Future<VisionIter> iterSeg(Uint8List rgba, int width, int height, List<List<double>> points) async {
    try {
      final Map<Object?, Object?>? r = await _methods.invokeMapMethod<Object?, Object?>(
        'iterSeg',
        <String, Object?>{'rgba': rgba, 'width': width, 'height': height, 'points': points},
      );
      if (r == null) return const VisionIter(error: 'Pas de réponse de Vision.');
      final Object? err = r['error'];
      if (err != null) return VisionIter(error: err.toString());
      final Object? m = r['mask'];
      if (m is! Uint8List || m.length < width * height) return const VisionIter(error: 'Réponse de Vision illisible.');
      return VisionIter(mask: m, ms: (r['ms'] is num) ? (r['ms']! as num).toDouble() : 0);
    } on MissingPluginException {
      return const VisionIter(error: 'Vision indisponible (pas un iPad).');
    } on PlatformException catch (e) {
      return VisionIter(error: e.message ?? e.code);
    }
  }

  /// LaMa : remplit la zone du masque. [rgba] : 512 x 512 x 4 octets ; [mask] : 512 x 512 octets (255 = à remplir).
  static Future<VisionLama> lamaFill(Uint8List rgba, Uint8List mask) async {
    try {
      final Map<Object?, Object?>? r = await _methods.invokeMapMethod<Object?, Object?>(
        'lamaFill',
        <String, Object?>{'rgba': rgba, 'mask': mask},
      );
      if (r == null) return const VisionLama(error: 'Pas de réponse de LaMa.');
      final Object? err = r['error'];
      if (err != null) return VisionLama(error: err.toString());
      final Object? out = r['rgba'];
      if (out is! Uint8List || out.length < 512 * 512 * 4) return const VisionLama(error: 'Réponse de LaMa illisible.');
      double val(String k) => (r[k] is num) ? (r[k]! as num).toDouble() : 0;
      return VisionLama(
        rgba: out,
        loadMs: val('loadMs'),
        runMs: val('runMs'),
        memBeforeMB: val('memBeforeMB'),
        memAfterMB: val('memAfterMB'),
      );
    } on MissingPluginException {
      return const VisionLama(error: 'LaMa indisponible (pas un iPad).');
    } on PlatformException catch (e) {
      return VisionLama(error: e.message ?? e.code);
    }
  }

  /// Les visages de la photo avec leurs repères (yeux, sourcils, lèvres, contour).
  static Future<VisionFaces> faceParts(Uint8List rgba, int width, int height) async {
    try {
      final Map<Object?, Object?>? r = await _methods.invokeMapMethod<Object?, Object?>(
        'faceParts',
        <String, Object?>{'rgba': rgba, 'width': width, 'height': height, 'kind': 'face'},
      );
      if (r == null) return const VisionFaces(error: 'Pas de réponse du repérage des visages.');
      final Object? err = r['error'];
      if (err != null) return VisionFaces(error: err.toString());
      final Object? list = r['faces'];
      if (list is! List<Object?>) return const VisionFaces(error: 'Réponse du repérage illisible.');
      const List<String> keys = <String>['leftEye', 'rightEye', 'leftBrow', 'rightBrow', 'outerLips', 'innerLips', 'contour'];
      final List<VisionFace> out = <VisionFace>[];
      for (final Object? e in list) {
        if (e is! Map<Object?, Object?>) continue;
        double v(String k) => (e[k] as num?)?.toDouble() ?? 0;
        final Map<String, List<double>> parts = <String, List<double>>{};
        for (final String k in keys) {
          final Object? raw = e[k];
          if (raw is List<Object?>) {
            parts[k] = <double>[for (final Object? n in raw) if (n is num) n.toDouble()];
          }
        }
        out.add(VisionFace(v('x0'), v('y0'), v('x1'), v('y1'), parts));
      }
      return VisionFaces(faces: out);
    } on MissingPluginException {
      return const VisionFaces(error: 'Repérage des visages indisponible (pas un iPad).');
    } on PlatformException catch (e) {
      return VisionFaces(error: e.message ?? e.code);
    }
  }

  /// Les personnes de la photo, une entrée chacune (cadre + point intérieur), de gauche à droite.
  static Future<VisionPersons> listPersons(Uint8List rgba, int width, int height) async {
    try {
      final Map<Object?, Object?>? r = await _methods.invokeMapMethod<Object?, Object?>(
        'listPersons',
        <String, Object?>{'rgba': rgba, 'width': width, 'height': height, 'kind': 'person'},
      );
      if (r == null) return const VisionPersons(error: 'Pas de réponse du détourage.');
      final Object? err = r['error'];
      if (err != null) return VisionPersons(error: err.toString());
      final Object? list = r['persons'];
      if (list is! List<Object?>) return const VisionPersons(error: 'Réponse du détourage illisible.');
      final List<VisionPerson> out = <VisionPerson>[];
      for (final Object? e in list) {
        if (e is! Map<Object?, Object?>) continue;
        double v(String k) => (e[k] as num?)?.toDouble() ?? 0;
        out.add(VisionPerson(v('x0'), v('y0'), v('x1'), v('y1'), v('px'), v('py')));
      }
      out.sort((VisionPerson a, VisionPerson b) => a.x0.compareTo(b.x0));
      return VisionPersons(persons: out);
    } on MissingPluginException {
      return const VisionPersons(error: 'Détourage indisponible (pas un iPad).');
    } on PlatformException catch (e) {
      return VisionPersons(error: e.message ?? e.code);
    }
  }

  /// [rgba] : photo RGBA 8 bits ([width] × [height]). [person] : les personnes au lieu du sujet principal.
  /// Avec [fx], [fy] (fractions de la photo, origine en haut à gauche) : seul l'élément touché ; sinon tous ensemble.
  static Future<VisionMaskResult> instanceMask(Uint8List rgba, int width, int height,
      {bool person = false, double? fx, double? fy}) async {
    try {
      final Map<Object?, Object?>? r = await _methods.invokeMapMethod<Object?, Object?>(
        'instanceMask',
        <String, Object?>{
          'rgba': rgba,
          'width': width,
          'height': height,
          'kind': person ? 'person' : 'subject',
          if (fx != null && fy != null) 'x': fx,
          if (fx != null && fy != null) 'y': fy,
        },
      );
      if (r == null) return const VisionMaskResult(error: 'Pas de réponse du détourage.');
      final Object? err = r['error'];
      if (err != null) return VisionMaskResult(error: err.toString());
      final Object? m = r['mask'];
      final Object? w = r['width'];
      final Object? h = r['height'];
      if (m is! Uint8List || w is! int || h is! int) {
        return const VisionMaskResult(error: 'Réponse du détourage illisible.');
      }
      return VisionMaskResult(width: w, height: h, count: (r['count'] as int?) ?? 0, mask: m);
    } on MissingPluginException {
      return const VisionMaskResult(error: 'Détourage indisponible (pas un iPad).');
    } on PlatformException catch (e) {
      return VisionMaskResult(error: e.message ?? e.code);
    }
  }
}

