import 'dart:async';

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
