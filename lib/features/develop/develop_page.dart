import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../pencil_bench/pencil_bench_page.dart';

/// Écran d'essai : choisir une photo, régler une luminosité d'essai.
///
/// IMPORTANT : ce curseur n'agit PAS sur le moteur Sursaut. C'est un simple
/// filtre d'affichage Flutter, pour vérifier la chaîne (compilation,
/// installation, photo choisie, curseur au doigt). Le moteur Rust viendra
/// à l'étape 1.
class DevelopPage extends StatefulWidget {
  const DevelopPage({super.key});

  @override
  State<DevelopPage> createState() => _DevelopPageState();
}

class _DevelopPageState extends State<DevelopPage> {
  final ImagePicker _picker = ImagePicker();
  Uint8List? _bytes;
  String? _name;
  double _brightness = 0; // −100 à +100, comme les curseurs de Sursaut

  Future<void> _choose() async {
    final XFile? file = await _picker.pickImage(source: ImageSource.gallery);
    if (file == null) return;
    final Uint8List bytes = await file.readAsBytes();
    if (!mounted) return;
    setState(() {
      _bytes = bytes;
      _name = file.name;
      _brightness = 0;
    });
  }

  ColorFilter get _filter {
    final double offset = _brightness * 1.2;
    return ColorFilter.matrix(<double>[
      1, 0, 0, 0, offset, //
      0, 1, 0, 0, offset,
      0, 0, 1, 0, offset,
      0, 0, 0, 1, 0,
    ]);
  }

  String get _valueText {
    if (_brightness == 0) return '0';
    final String sign = _brightness > 0 ? '+' : '−';
    return '$sign${_brightness.abs().round()}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_name ?? 'Sursaut iPad (essai)'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (BuildContext context) => const PencilBenchPage(),
              ),
            ),
            child: const Text('Banc Pencil'),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _choose,
              child: const Text('Choisir une photo'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Expanded(
              child: _bytes == null
                  ? const Center(
                      child: Text('Aucune photo. Touchez « Choisir une photo ».'),
                    )
                  : InteractiveViewer(
                      maxScale: 8,
                      child: Center(
                        child: ColorFiltered(
                          colorFilter: _filter,
                          child: Image.memory(_bytes!, fit: BoxFit.contain),
                        ),
                      ),
                    ),
            ),
            Container(
              color: Theme.of(context).colorScheme.surface,
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      const Text('Luminosité (essai, hors moteur)'),
                      Text(
                        _valueText,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  // Double appui = retour à zéro, comme prévu pour les curseurs.
                  GestureDetector(
                    onDoubleTap: () => setState(() => _brightness = 0),
                    child: Slider(
                      value: _brightness,
                      min: -100,
                      max: 100,
                      onChanged: _bytes == null
                          ? null
                          : (double v) => setState(() => _brightness = v),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
