import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/check_layers.dart';

void main() {
  test('les dépendances vont toujours vers le bas (app → features → engine/domain/common)', () {
    expect(checkTree(Directory('lib')), isEmpty);
  });

  test('le contrôle détecte un import interdit', () {
    expect(
        checkFile('domain/x.dart', "import 'package:flutter/material.dart';\n"),
        isNotEmpty);
    expect(
        checkFile('features/develop/a.dart',
            "import '../diagnostics/b.dart';\n"),
        isNotEmpty);
    expect(
        checkFile('features/develop/a.dart', "import '../../domain/x.dart';\n"),
        isEmpty);
    expect(
        checkFile('common/t.dart', "import '../domain/x.dart';\n"), isNotEmpty);
  });
}
