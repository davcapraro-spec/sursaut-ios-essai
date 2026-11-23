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
    return _events.receiveBroadcastStream().map((Object? raw) {
      if (raw is Map) {
        return raw['line']?.toString() ?? '';
      }
      return raw?.toString() ?? '';
    });
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

/// Détourage par Vision (Apple) : sujet principal ou personnes, sans fichier de modèle (iPadOS 17 ou plus).
class VisionBridge {
  VisionBridge._();

  static const MethodChannel _methods = MethodChannel('sursaut/vision/methods');

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

