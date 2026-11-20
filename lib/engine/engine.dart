import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

typedef _VersionC = Pointer<Utf8> Function();
typedef _VersionDart = Pointer<Utf8> Function();
typedef _RenderC = Int32 Function(
    Pointer<Uint8>, Uint32, Uint32, Pointer<Utf8>, Pointer<Uint8>);
typedef _RenderDart = int Function(
    Pointer<Uint8>, int, int, Pointer<Utf8>, Pointer<Uint8>);

/// Pont vers le moteur Rust (`engine/`, bibliothèque `sursaut_engine`).
///
/// Sur iPad, la bibliothèque est liée dans l'application : on la lit par
/// `DynamicLibrary.process()`. Ailleurs (essais sur PC), on cherche le fichier
/// de la bibliothèque à côté de l'exécutable ; s'il manque, [load] renvoie null.
class Engine {
  Engine._(this.version, this._render);

  final String version;
  final _RenderDart _render;

  /// Dernière raison d'échec du chargement (null si tout va bien).
  static String? lastError;

  static Engine? load() {
    try {
      final DynamicLibrary lib = _open();
      final _VersionDart v =
          lib.lookupFunction<_VersionC, _VersionDart>('sursaut_engine_version');
      final _RenderDart r =
          lib.lookupFunction<_RenderC, _RenderDart>('sursaut_render_rgba8');
      lastError = null;
      return Engine._(v().toDartString(), r);
    } catch (e) {
      lastError = e.toString();
      return null;
    }
  }

  static DynamicLibrary _open() {
    if (Platform.isIOS) return DynamicLibrary.process();
    if (Platform.isMacOS) return DynamicLibrary.open('libsursaut_engine.dylib');
    if (Platform.isWindows) return DynamicLibrary.open('sursaut_engine.dll');
    return DynamicLibrary.open('libsursaut_engine.so');
  }

  /// Applique la recette (JSON) à une image RGBA 8 bits de `width × height`.
  /// Renvoie une nouvelle image de même taille.
  Uint8List render(Uint8List rgba, int width, int height, String recipeJson) {
    final int n = width * height * 4;
    if (rgba.length != n) {
      throw ArgumentError('Taille attendue $n octets, reçu ${rgba.length}.');
    }
    final Pointer<Uint8> src = calloc<Uint8>(n);
    final Pointer<Uint8> out = calloc<Uint8>(n);
    final Pointer<Utf8> json = recipeJson.toNativeUtf8();
    try {
      src.asTypedList(n).setAll(0, rgba);
      final int code = _render(src, width, height, json, out);
      if (code != 0) throw StateError('Le moteur a refusé le rendu (code $code).');
      return Uint8List.fromList(out.asTypedList(n));
    } finally {
      calloc.free(src);
      calloc.free(out);
      calloc.free(json);
    }
  }
}
