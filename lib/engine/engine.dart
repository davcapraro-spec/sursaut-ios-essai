import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

typedef _VersionC = Pointer<Utf8> Function();
typedef _OpenC = Pointer<Void> Function(Pointer<Uint8>, Uint32, Uint32);
typedef _OpenD = Pointer<Void> Function(Pointer<Uint8>, int, int);
typedef _RenderC = Pointer<Uint8> Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Uint32>, Pointer<Uint32>);
typedef _CloseC = Void Function(Pointer<Void>);
typedef _CloseD = void Function(Pointer<Void>);
typedef _RawOpenC = Pointer<Void> Function(Pointer<Utf8>);
typedef _RawInfoC = Pointer<Utf8> Function(Pointer<Void>);
typedef _RawDevelopC = Pointer<Uint8> Function(
    Pointer<Void>, Int32, Uint32, Int32, Pointer<Uint32>, Pointer<Uint32>);
typedef _RawDevelopD = Pointer<Uint8> Function(
    Pointer<Void>, int, int, int, Pointer<Uint32>, Pointer<Uint32>);

/// Les fonctions du moteur Rust (bibliothèque `sursaut_engine`, qui contient `sursaut-core`).
///
/// Sur iPad la bibliothèque est liée dans l'application : `DynamicLibrary.process()`.
/// Ailleurs (essais sur PC), on cherche le fichier à côté de l'exécutable.
class _Bindings {
  _Bindings(DynamicLibrary lib)
      : version = lib.lookupFunction<_VersionC, _VersionC>('sursaut_engine_version'),
        lastError = lib.lookupFunction<_VersionC, _VersionC>('sursaut_engine_last_error'),
        open = lib.lookupFunction<_OpenC, _OpenD>('sursaut_engine_open_rgba8'),
        render = lib.lookupFunction<_RenderC, _RenderC>('sursaut_engine_render'),
        close = lib.lookupFunction<_CloseC, _CloseD>('sursaut_engine_close'),
        rawOpen = lib.lookupFunction<_RawOpenC, _RawOpenC>('sursaut_raw_open'),
        rawInfo = lib.lookupFunction<_RawInfoC, _RawInfoC>('sursaut_raw_info_json'),
        rawDevelop = lib.lookupFunction<_RawDevelopC, _RawDevelopD>('sursaut_raw_develop'),
        rawClose = lib.lookupFunction<_CloseC, _CloseD>('sursaut_raw_close');

  final _VersionC version;
  final _VersionC lastError;
  final _OpenD open;
  final _RenderC render;
  final _CloseD close;
  final _RawOpenC rawOpen;
  final _RawInfoC rawInfo;
  final _RawDevelopD rawDevelop;
  final _CloseD rawClose;

  static DynamicLibrary _library() {
    if (Platform.isIOS) return DynamicLibrary.process();
    if (Platform.isMacOS) return DynamicLibrary.open('libsursaut_engine.dylib');
    if (Platform.isWindows) return DynamicLibrary.open('sursaut_engine.dll');
    return DynamicLibrary.open('libsursaut_engine.so');
  }

  static _Bindings load() => _Bindings(_library());

  String error() => lastError().toDartString();
}

/// Résultat d'un rendu : image RGBA 8 bits.
class RenderResult {
  const RenderResult(this.width, this.height, this.rgba);
  final int width;
  final int height;
  final Uint8List rgba;
}

/// Vérifie que le moteur est présent et donne sa version.
class EngineInfo {
  EngineInfo._(this.version, this.error);
  final String? version;
  final String? error;

  static EngineInfo probe() {
    try {
      return EngineInfo._(_Bindings.load().version().toDartString(), null);
    } catch (e) {
      return EngineInfo._(null, e.toString());
    }
  }
}

/// Une photo ouverte dans le moteur, avec le cache par étage du pipeline.
///
/// Les rendus tournent dans un autre fil (isolate) pour que l'écran reste fluide.
/// Ils doivent se suivre : un seul à la fois.
class PhotoEngine {
  PhotoEngine._(this._handle);

  Pointer<Void> _handle;
  Future<void>? _last;
  bool _closed = false;

  /// Ouvre une photo RGBA 8 bits. Lève une erreur lisible si le moteur refuse.
  static PhotoEngine open(Uint8List rgba, int width, int height) {
    final _Bindings b = _Bindings.load();
    final int n = width * height * 4;
    if (rgba.length != n) {
      throw ArgumentError('Taille attendue $n octets, reçu ${rgba.length}.');
    }
    final Pointer<Uint8> src = calloc<Uint8>(n);
    try {
      src.asTypedList(n).setAll(0, rgba);
      final Pointer<Void> h = b.open(src, width, height);
      if (h == nullptr) throw StateError(b.error());
      return PhotoEngine._(h);
    } finally {
      calloc.free(src);
    }
  }

  /// Rend la photo avec la recette JSON (même format que le PC).
  Future<RenderResult> render(String recipeJson) {
    if (_closed) throw StateError('Moteur fermé.');
    final int address = _handle.address;
    final Future<RenderResult> f = Isolate.run<RenderResult>(() {
      final _Bindings b = _Bindings.load();
      final Pointer<Uint32> pw = calloc<Uint32>();
      final Pointer<Uint32> ph = calloc<Uint32>();
      final Pointer<Utf8> json = recipeJson.toNativeUtf8();
      try {
        final Pointer<Uint8> p =
            b.render(Pointer<Void>.fromAddress(address), json, pw, ph);
        if (p == nullptr) throw StateError(b.error());
        final int w = pw.value, h = ph.value;
        return RenderResult(w, h, Uint8List.fromList(p.asTypedList(w * h * 4)));
      } finally {
        calloc.free(pw);
        calloc.free(ph);
        calloc.free(json);
      }
    });
    _last = f.then<void>((_) {}, onError: (Object _) {});
    return f;
  }

  /// Libère la photo (après la fin du rendu en cours, s'il y en a un).
  void close() {
    if (_closed) return;
    _closed = true;
    final Pointer<Void> h = _handle;
    _handle = nullptr;
    (_last ?? Future<void>.value()).whenComplete(() => _Bindings.load().close(h));
  }
}

/// Un fichier RAW ouvert par LibRaw (étape 3a) : métadonnées, développement rapide ou complet.
///
/// Le développement dure de quelques centaines de millisecondes à plusieurs secondes :
/// il tourne dans un autre fil (isolate). Un seul développement à la fois.
class RawFile {
  RawFile._(this._handle);

  Pointer<Void> _handle;
  Future<void>? _last;
  bool _closed = false;

  /// Ouvre un RAW (chemin d'un fichier). Lève une erreur lisible si LibRaw refuse.
  static RawFile open(String path) {
    final _Bindings b = _Bindings.load();
    final Pointer<Utf8> p = path.toNativeUtf8();
    try {
      final Pointer<Void> h = b.rawOpen(p);
      if (h == nullptr) throw StateError(b.error());
      return RawFile._(h);
    } finally {
      calloc.free(p);
    }
  }

  /// Métadonnées et, après un développement, temps et mémoire mesurés (`last`).
  Map<String, dynamic> info() {
    if (_closed) throw StateError('RAW fermé.');
    final _Bindings b = _Bindings.load();
    final Pointer<Utf8> p = b.rawInfo(_handle);
    if (p == nullptr) throw StateError(b.error());
    return jsonDecode(p.toDartString()) as Map<String, dynamic>;
  }

  /// Développe le RAW : [half] = demi-taille (rapide, sans démosaïquage) ou complet (DHT).
  /// [look] : rendu de base du PC (0 neutre, 1 doux, 2 « comme le JPEG de l'appareil »).
  /// L'image rendue est réduite à [maxSide] pixels au plus (0 = pleine taille).
  Future<RenderResult> develop({required bool half, int maxSide = 2752, int look = 2}) {
    if (_closed) throw StateError('RAW fermé.');
    final int address = _handle.address;
    final Future<RenderResult> f = Isolate.run<RenderResult>(() {
      final _Bindings b = _Bindings.load();
      final Pointer<Uint32> pw = calloc<Uint32>();
      final Pointer<Uint32> ph = calloc<Uint32>();
      try {
        final Pointer<Uint8> p = b.rawDevelop(
            Pointer<Void>.fromAddress(address), half ? 1 : 0, maxSide, look, pw, ph);
        if (p == nullptr) throw StateError(b.error());
        final int w = pw.value, h = ph.value;
        return RenderResult(w, h, Uint8List.fromList(p.asTypedList(w * h * 4)));
      } finally {
        calloc.free(pw);
        calloc.free(ph);
      }
    });
    _last = f.then<void>((_) {}, onError: (Object _) {});
    return f;
  }

  /// Libère le RAW (après la fin du développement en cours, s'il y en a un).
  void close() {
    if (_closed) return;
    _closed = true;
    final Pointer<Void> h = _handle;
    _handle = nullptr;
    (_last ?? Future<void>.value()).whenComplete(() => _Bindings.load().rawClose(h));
  }
}
