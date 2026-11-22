// Vérifie la règle de dépendance de l'application : on descend, on ne remonte pas.
//
//   app  →  features  →  engine / domain / common
//
// Lancer : dart run tool/check_layers.dart   (code de sortie 1 s'il y a une violation)
import 'dart:io';

const String _pkg = 'package:sursaut_essai/';

/// Calque d'un fichier de `lib/` : common, domain, engine, platform, app, main
/// ou `features/<nom>`.
String layerOf(String libPath) {
  final List<String> parts = libPath.split('/');
  if (parts.length == 1) return 'main';
  if (parts[0] == 'features' && parts.length >= 3) return 'features/${parts[1]}';
  return parts[0];
}

/// Imports d'un fichier, ramenés à un chemin relatif à `lib/` (null = pas du projet).
List<String> projectImports(String libPath, String source) {
  final RegExp re = RegExp(r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''', multiLine: true);
  final List<String> out = <String>[];
  for (final RegExpMatch m in re.allMatches(source)) {
    final String target = m.group(1)!;
    if (target.startsWith(_pkg)) {
      out.add(target.substring(_pkg.length));
    } else if (!target.contains(':')) {
      final List<String> base = libPath.split('/')..removeLast();
      for (final String seg in target.split('/')) {
        if (seg == '..') {
          if (base.isNotEmpty) base.removeLast();
        } else if (seg != '.') {
          base.add(seg);
        }
      }
      out.add(base.join('/'));
    }
  }
  return out;
}

/// Imports non Dart-pur interdits dans `domain/`.
const List<String> _forbiddenInDomain = <String>[
  'package:flutter', 'dart:ui', 'dart:io', 'dart:isolate', 'dart:ffi',
];

List<String> checkFile(String libPath, String source) {
  final List<String> problems = <String>[];
  final String me = layerOf(libPath);
  if (me == 'domain') {
    for (final String bad in _forbiddenInDomain) {
      if (RegExp('''['"]${RegExp.escape(bad)}''').hasMatch(source)) {
        problems.add('$libPath : domain/ doit rester du Dart pur (importe $bad)');
      }
    }
  }
  for (final String target in projectImports(libPath, source)) {
    final String other = layerOf(target);
    if (other == me) continue;
    final bool ok;
    switch (me) {
      case 'common':
        ok = false;
      case 'domain':
        ok = other == 'common';
      case 'engine':
      case 'platform':
        ok = other == 'common' || other == 'domain';
      case 'app':
        ok = other != 'main';
      case 'main':
        ok = true;
      default: // features/<nom>
        ok = other == 'common' ||
            other == 'domain' ||
            other == 'engine' ||
            other == 'platform';
    }
    if (!ok) problems.add('$libPath ($me) importe $target ($other) : sens interdit');
  }
  return problems;
}

List<String> checkTree(Directory lib) {
  final List<String> problems = <String>[];
  final String root = lib.absolute.path.replaceAll('\\', '/');
  for (final FileSystemEntity e in lib.listSync(recursive: true)) {
    if (e is! File || !e.path.endsWith('.dart')) continue;
    final String full = e.absolute.path.replaceAll('\\', '/');
    final String libPath = full.substring(root.length + 1);
    problems.addAll(checkFile(libPath, e.readAsStringSync()));
  }
  return problems;
}

void main() {
  final List<String> problems = checkTree(Directory('lib'));
  if (problems.isEmpty) {
    stdout.writeln('Couches : OK');
    return;
  }
  problems.forEach(stdout.writeln);
  exit(1);
}
