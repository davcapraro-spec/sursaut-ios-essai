import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pencil_bridge/pencil_bridge.dart';

/// Banc Appareil (essai S2) : que peut faire l'iPad avec l'A7 IV branché
/// en USB-C ? L'écran raconte, ligne par ligne, ce que dit l'iPadOS.
class CameraBenchPage extends StatefulWidget {
  const CameraBenchPage({super.key});

  @override
  State<CameraBenchPage> createState() => _CameraBenchPageState();
}

class _CameraBenchPageState extends State<CameraBenchPage> {
  final List<String> _lines = <String>[];
  final ScrollController _scroll = ScrollController();
  StreamSubscription<String>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = CameraBridge.lines.listen(
      (String line) => _add(line),
      onError: (Object e) => _add('Erreur du flux : $e'),
    );
    _add('Prêt. Appareil allumé, câble USB-C branché, mode USB « Pdv à distance », puis touchez « 1. Chercher ».');
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  String _stamp() {
    final DateTime n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(n.hour)}:${two(n.minute)}:${two(n.second)}';
  }

  void _add(String text) {
    if (!mounted) return;
    setState(() => _lines.add('${_stamp()}  $text'));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _call(String method) async {
    final String? err = await CameraBridge.call(method);
    if (err != null) _add('Erreur : $err');
  }

  Future<void> _showPreview() async {
    final String? path = await CameraBridge.previewLast();
    if (path == null) {
      _add('Aucun aperçu à afficher (voir la ligne APERÇU ci-dessus).');
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => Dialog.fullscreen(
        child: Stack(
          children: <Widget>[
            Positioned.fill(
              child: InteractiveViewer(
                maxScale: 8,
                child: Image.file(File(path), fit: BoxFit.contain),
              ),
            ),
            Positioned(
              top: 12,
              right: 12,
              child: FilledButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Fermer'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showLiveFrame() async {
    final String? path = await CameraBridge.liveFramePath();
    if (path == null) {
      _add('Aucune image de vue directe : lancez d\'abord « 17. Vue directe (essai) ».');
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => Dialog.fullscreen(
        child: Stack(
          children: <Widget>[
            Positioned.fill(child: Image.file(File(path), fit: BoxFit.contain, gaplessPlayback: true)),
            Positioned(
              top: 12,
              right: 12,
              child: FilledButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Fermer')),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _copy() async {
    final String report = <String>[
      'BANC APPAREIL — Sursaut iPad',
      'Date : ${DateTime.now()}',
      ..._lines,
    ].join('\n');
    await Clipboard.setData(ClipboardData(text: report));
    _add('Rapport copié dans le presse-papiers.');
  }

  Widget _button(String label, String method) {
    return FilledButton.tonal(
      style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
      onPressed: () => _call(method),
      child: Text(label),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Banc Appareil (A7 IV)')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                _button('1. Chercher', 'start'),
                _button('2. Ouvrir la session', 'openSession'),
                _button('3. Infos PTP', 'ptpInfo'),
                _button('4. Télécharger la dernière', 'downloadLatest'),
                _button('5. Déclencher (PTP)', 'takePicture'),
                _button('6. Poignée de main Sony (essai)', 'sonyConnect'),
                _button('7. Photo par iPadOS', 'iccShoot'),
                _button('8. Lire la photo annoncée', 'readObject'),
                _button('9. Déclencher depuis l\'iPad (essai)', 'sonyShoot'),
                FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: _showPreview,
                  child: const Text('10. Voir la dernière photo'),
                ),
                _button('11. Rafale de 5 photos', 'burst'),
                _button('12. Partager les fichiers', 'shareFiles'),
                _button('12b. Partager la dernière photo', 'shareLast'),
                _button('12c. Vider les photos reçues', 'clearFiles'),
                _button('13. Lire les réglages', 'readSettings'),
                _button('6b. Poignée de main PTP 3 (essai)', 'sonyConnect3'),
                _button('14. Changer l\'ISO (essai)', 'writeISO'),
                _button('15. Changer l\'ouverture (essai)', 'writeAperture'),
                _button('16. Changer la vitesse (essai)', 'writeShutter'),
                _button('17. Vue directe (essai)', 'liveviewTest'),
                FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: _showLiveFrame,
                  child: const Text('17b. Voir la dernière image directe'),
                ),
                _button('18a. Collimateur : coin haut gauche', 'afTopLeft'),
                _button('18b. Collimateur : centre', 'afCenter'),
                _button('18c. Collimateur : coin bas droit', 'afBottomRight'),
                _button('18d. Toucher à distance : centre', 'touchCenter'),
                _button('État', 'state'),
                FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: _copy,
                  child: const Text('Copier le rapport'),
                ),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => setState(_lines.clear),
                  child: const Text('Effacer'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white24),
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.all(8),
                child: ListView.builder(
                  controller: _scroll,
                  itemCount: _lines.length,
                  itemBuilder: (BuildContext context, int i) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: SelectableText(
                      _lines[i],
                      style: const TextStyle(fontFamily: 'Menlo', fontSize: 13),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
