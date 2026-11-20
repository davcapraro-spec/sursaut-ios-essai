import 'dart:async';

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
