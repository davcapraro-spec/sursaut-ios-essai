import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'mask_tools.dart';
import 'masks.dart';

/// Masques d'IA (Sujet, Arrière-plan, Personnes) : l'image du masque est enregistrée dans la recette en PNG (base64) sous
/// `png`, avec une clé `key` qui identifie son contenu ; le moteur la reçoit sous cette clé (même format que le PC).
/// Partie pure : le détourage lui-même (Vision) est dans le code natif.

/// Noms des masques d'IA proposés (début du nom : « Sujet 1 »).
const Map<String, String> kAiNames = <String, String>{
  'subject': 'Sujet',
  'background': 'Arrière-plan',
  'person': 'Personnes',
};

/// Plus grand côté de l'image d'un masque d'IA enregistrée (comme la copie de 1024 px du PC, un peu plus fine).
const int kAiMaskMaxSide = 1280;

/// Empreinte du contenu d'un masque : 16 caractères (deux sommes de contrôle FNV de 32 bits).
String maskKey(Uint8List plane) {
  int a = 0x811c9dc5, b = 0x9747b28c;
  for (final int v in plane) {
    a = ((a ^ v) * 0x01000193) & 0xFFFFFFFF;
    b = ((b ^ v) * 0x01000193 ^ (b >> 15)) & 0xFFFFFFFF;
  }
  return a.toRadixString(16).padLeft(8, '0') + b.toRadixString(16).padLeft(8, '0');
}

/// Image de masque (un octet par pixel) en PNG en niveaux de gris.
Uint8List planeToPng(Uint8List plane, int width, int height) {
  final Uint8List own = Uint8List.fromList(plane);
  final img.Image im = img.Image.fromBytes(width: width, height: height, bytes: own.buffer, numChannels: 1);
  return Uint8List.fromList(img.encodePng(im));
}

/// PNG d'un masque en image de masque (un octet par pixel), ou null s'il est illisible.
(Uint8List, int, int)? pngToPlane(Uint8List png) {
  final img.Image? im = img.decodePng(png);
  if (im == null) return null;
  final int w = im.width, h = im.height;
  final Uint8List out = Uint8List(w * h);
  int i = 0;
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      out[i++] = im.getPixel(x, y).r.toInt().clamp(0, 255).toInt();
    }
  }
  return (out, w, h);
}

/// Réduit l'image d'un masque à [maxSide] pixels au plus pour le grand côté (inchangée si elle est déjà plus petite).
(Uint8List, int, int) fitPlane(Uint8List plane, int width, int height, {int maxSide = kAiMaskMaxSide}) {
  final int long = width > height ? width : height;
  if (long <= maxSide) return (plane, width, height);
  final double s = maxSide / long;
  final int nw = (width * s).round().clamp(1, maxSide).toInt(), nh = (height * s).round().clamp(1, maxSide).toInt();
  final Uint8List own = Uint8List.fromList(plane);
  final img.Image src = img.Image.fromBytes(width: width, height: height, bytes: own.buffer, numChannels: 1);
  final img.Image small = img.copyResize(src, width: nw, height: nh, interpolation: img.Interpolation.linear);
  final Uint8List out = Uint8List(nw * nh);
  int i = 0;
  for (int y = 0; y < nh; y++) {
    for (int x = 0; x < nw; x++) {
      out[i++] = small.getPixel(x, y).r.toInt().clamp(0, 255).toInt();
    }
  }
  return (out, nw, nh);
}

/// Un masque d'IA : une composante `bitmap` (clé, PNG en base64, ce qui l'a produite). `invert` pour « Arrière-plan ».
MaskMap bitmapMask({
  required String name,
  required String key,
  required String pngBase64,
  required String what,
  bool invert = false,
}) =>
    <String, dynamic>{
      'name': name,
      'enabled': true,
      'invert': invert,
      'amount': 100.0,
      'comps': <Map<String, dynamic>>[
        <String, dynamic>{
          ...defaultComp(kBitmap),
          'key': key,
          'png': pngBase64,
          'ai': <String, dynamic>{'what': what, 'points': <dynamic>[], 'source': 'vision'},
        },
      ],
      'adj': <String, dynamic>{for (final String k in kLocalKeys) k: 0.0},
    };

/// Les composantes `bitmap` d'une liste de masques (telle qu'elle sort d'un fichier : types libres).
Iterable<Map<String, dynamic>> bitmapComps(Object? masks) sync* {
  if (masks is! List<dynamic>) return;
  for (final Object? m in masks) {
    if (m is! Map<String, dynamic>) continue;
    final Object? comps = m['comps'];
    if (comps is! List<dynamic>) continue;
    for (final Object? c in comps) {
      if (c is Map<String, dynamic> && '${c['kind']}' == kBitmap) yield c;
    }
  }
}

/// Les mêmes masques sans les images `png` (le moteur ne reçoit que les clés ; les images lui sont confiées à part).
List<dynamic> withoutPngs(List<dynamic> masks) => <dynamic>[
      for (final Object? m in masks)
        if (m is Map<String, dynamic> && m['comps'] is List<dynamic>)
          <String, dynamic>{
            ...m,
            'comps': <dynamic>[
              for (final Object? c in m['comps'] as List<dynamic>)
                if (c is Map<String, dynamic> && c.containsKey('png'))
                  <String, dynamic>{for (final MapEntry<String, dynamic> e in c.entries) if (e.key != 'png') e.key: e.value}
                else
                  c,
            ],
          }
        else
          m,
    ];

/// PNG en base64 d'une image de masque.
String planeToBase64(Uint8List plane, int width, int height) => base64Encode(planeToPng(plane, width, height));
