import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pencil_bridge/pencil_bridge.dart';

import '../../common/theme.dart';
import '../../domain/camera_format.dart';

/// Capturer : piloter l'A7 IV branché en USB-C (réglages, déclenchement, réception de la photo).
///
/// Vérifié sur l'appareil (banc 19-20/11) : connexion, lecture des réglages, écriture ISO / ouverture /
/// vitesse, déclenchement, réception du RAW. Cet écran les assemble ; son comportement sur l'iPad
/// n'est pas encore vérifié.
class CapturePage extends StatefulWidget {
  const CapturePage({super.key, required this.onOpenPhoto});

  /// Ouvre une photo reçue dans le développement (fournie par l'accueil : une fonctionnalité n'en importe pas une autre).
  final void Function(BuildContext context, String path) onOpenPhoto;

  @override
  State<CapturePage> createState() => _CapturePageState();
}

class _CapturePageState extends State<CapturePage> {
  StreamSubscription<CameraLiveEvent>? _sub;
  CameraLiveState _st = const CameraLiveState();
  String _status = 'Appareil allumé, câble USB-C branché, mode USB « Pdv à distance ». Touchez « Connecter ».';
  bool _connecting = false;
  bool _shooting = false;
  String? _previewPath;
  CameraLiveFrame? _frame;
  String? _lastInfo;
  final Set<int> _pending = <int>{};
  Timer? _shootTimeout;

  @override
  void initState() {
    super.initState();
    _sub = CameraBridge.liveEvents.listen(_onEvent);
    unawaited(_resume());
  }

  @override
  void dispose() {
    _sub?.cancel();
    _shootTimeout?.cancel();
    unawaited(CameraBridge.call('liveStreamStop'));
    super.dispose();
  }

  /// Si l'appareil est déjà connecté (retour sur l'écran), reprendre l'état sans recommencer.
  Future<void> _resume() async {
    final CameraLiveState s = await CameraBridge.liveSnapshot();
    if (!mounted) return;
    setState(() {
      _st = s;
      if (s.ready) _status = 'Connecté à ${s.name ?? "l'appareil"}.';
    });
    if (s.ready) unawaited(CameraBridge.call('liveStreamStart'));
  }

  void _onEvent(CameraLiveEvent e) {
    if (!mounted) return;
    switch (e.kind) {
      case 'state':
        setState(() => _st = e.state ?? _st);
      case 'frame':
        setState(() => _frame = e.frame);
      case 'stream':
        setState(() => _frame = null);
        _toast('L\'image directe s\'est arrêtée. L\'appareil est-il en mode prise de vue ?');
      case 'photo':
        unawaited(_onPhoto(e.data));
      case 'set':
        final int code = (e.data['code'] as num?)?.toInt() ?? 0;
        final bool ok = e.data['ok'] == true;
        setState(() => _pending.remove(code));
        if (!ok) {
          _toast('L\'appareil n\'a pas pris ce réglage (mode d\'exposition ou molette ?). Valeur lue : '
              '${_fmt(code, (e.data['now'] as num?)?.toInt() ?? 0)}.');
        }
    }
  }

  Future<void> _onPhoto(Map<String, Object?> d) async {
    _shootTimeout?.cancel();
    final double mo = ((d['bytes'] as num?)?.toDouble() ?? 0) / 1000000;
    final double s = (d['seconds'] as num?)?.toDouble() ?? 0;
    final String? path = await CameraBridge.previewLast();
    final CameraLiveState snap = await CameraBridge.liveSnapshot();
    if (!mounted) return;
    setState(() {
      _shooting = false;
      _st = snap;
      if (path != null) _previewPath = path;
      _lastInfo = '${d['name']} · ${mo.toStringAsFixed(1)} Mo reçus en ${s.toStringAsFixed(1)} s';
    });
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<CameraLiveState> _waitFor(bool Function(CameraLiveState) ok, Duration max) async {
    final DateTime end = DateTime.now().add(max);
    CameraLiveState s = await CameraBridge.liveSnapshot();
    while (!ok(s) && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      s = await CameraBridge.liveSnapshot();
    }
    return s;
  }

  Future<void> _connect() async {
    if (_connecting) return;
    setState(() {
      _connecting = true;
      _status = 'Recherche de l\'appareil…';
    });
    try {
      String? err = await CameraBridge.call('liveStart');
      if (err != null) {
        _fail(err);
        return;
      }
      CameraLiveState s = await _waitFor((CameraLiveState x) => x.found, const Duration(seconds: 25));
      if (!s.found) {
        _fail('Appareil introuvable. Allumé ? Câble USB-C branché ? Mode USB « Pdv à distance » ? '
            'Au besoin, débranchez puis rebranchez le câble.');
        return;
      }
      if (!mounted) return;
      setState(() => _status = '${s.name ?? "Appareil"} trouvé. Ouverture de la session…');
      if (!s.session) {
        err = await CameraBridge.call('liveOpen');
        if (err != null) {
          _fail(err);
          return;
        }
        s = await _waitFor((CameraLiveState x) => x.session, const Duration(seconds: 12));
        if (!s.session) {
          _fail('La session ne s\'ouvre pas. Autorisez l\'accès à l\'appareil si l\'iPad le demande, puis réessayez.');
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 1500));
      }
      if (!s.ready) {
        if (!mounted) return;
        setState(() => _status = 'Session ouverte. Poignée de main avec l\'appareil…');
        err = await CameraBridge.call('liveHandshake');
        if (err != null) {
          _fail(err);
          return;
        }
        s = await _waitFor((CameraLiveState x) => x.ready, const Duration(seconds: 12));
        if (!s.ready) {
          _fail('L\'appareil ne répond pas à la poignée de main. Éteignez-le, rallumez-le, puis réessayez.');
          return;
        }
      }
      await CameraBridge.call('liveRefresh');
      final CameraLiveState fin = await _waitFor((CameraLiveState x) => x.props.isNotEmpty, const Duration(seconds: 8));
      if (!mounted) return;
      setState(() {
        _st = fin;
        _connecting = false;
        _status = fin.props.isEmpty
            ? 'Connecté, mais les réglages ne sont pas arrivés. Touchez « Relire ».'
            : 'Connecté à ${fin.name ?? "l'appareil"}.';
      });
      if (fin.ready) unawaited(CameraBridge.call('liveStreamStart'));
    } catch (e) {
      _fail('Connexion impossible : $e');
    }
  }

  void _fail(String text) {
    if (!mounted) return;
    setState(() {
      _connecting = false;
      _status = text;
    });
  }

  Future<void> _disconnect() async {
    await CameraBridge.call('liveStreamStop');
    await CameraBridge.call('liveStop');
    if (!mounted) return;
    setState(() {
      _frame = null;
      _st = const CameraLiveState();
      _status = 'Déconnecté.';
    });
  }

  Future<void> _shoot() async {
    if (!_st.ready || _shooting) return;
    setState(() => _shooting = true);
    _shootTimeout?.cancel();
    _shootTimeout = Timer(const Duration(seconds: 20), () {
      if (mounted && _shooting) {
        setState(() => _shooting = false);
        _toast('Aucune photo reçue au bout de 20 s. L\'appareil a-t-il fait la mise au point ? (carte, mode RAW)');
      }
    });
    final String? err = await CameraBridge.call('liveShoot');
    if (err != null && mounted) {
      setState(() => _shooting = false);
      _toast(err);
    }
  }

  Future<void> _step(int code, int dir) async {
    final CameraLiveProp? p = _st.props[code];
    if (p == null || !p.writable || _pending.contains(code)) return;
    final int? next = neighborChoice(sortedChoices(code, p.choices), p.cur, dir);
    if (next == null) return;
    setState(() => _pending.add(code));
    final String? err = await CameraBridge.liveSet(code, next);
    if (err != null && mounted) {
      setState(() => _pending.remove(code));
      _toast(err);
    }
  }

  String _fmt(int code, int v) {
    switch (code) {
      case kPropIso:
        return formatIso(v);
      case kPropAperture:
        return formatAperture(v);
      case kPropShutter:
        return formatShutterCode(v);
      case kPropExposureMode:
        return formatExposureMode(v);
      default:
        return formatRaw(v);
    }
  }

  void _openInDevelop() {
    final String? f = _st.lastFile;
    if (f == null) return;
    widget.onOpenPhoto(context, f);
  }

  @override
  Widget build(BuildContext context) {
    final bool ready = _st.ready;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Capturer'),
        actions: <Widget>[
          if (ready) TextButton(onPressed: () => CameraBridge.call('liveRefresh'), child: const Text('Relire')),
          if (ready) TextButton(onPressed: _disconnect, child: const Text('Déconnecter')),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(builder: (BuildContext context, BoxConstraints c) {
          final Widget preview = _buildPreview();
          final Widget panel = _buildPanel(ready);
          if (c.maxWidth >= 820) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(child: Padding(padding: const EdgeInsets.all(16), child: preview)),
                SizedBox(width: 400, child: SingleChildScrollView(padding: const EdgeInsets.all(16), child: panel)),
              ],
            );
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(children: <Widget>[SizedBox(height: 320, child: preview), const SizedBox(height: 16), panel]),
          );
        }),
      ),
    );
  }

  /// Touché sur l'image directe : place le point de mise au point (grille 640 × 480 de l'appareil).
  void _tapImage(Offset local, Rect imageRect) {
    if (!imageRect.contains(local)) return;
    final double fx = (local.dx - imageRect.left) / imageRect.width;
    final double fy = (local.dy - imageRect.top) / imageRect.height;
    CameraBridge.liveAF((fx * 639).round().clamp(0, 639).toInt(), (fy * 479).round().clamp(0, 479).toInt());
  }

  Widget _buildPreview() {
    final CameraLiveFrame? f = _frame;
    final String? photo = _previewPath;
    return DecoratedBox(
      decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(12)),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: LayoutBuilder(builder: (BuildContext context, BoxConstraints c) {
          final Size box = Size(c.maxWidth, c.maxHeight);
          Rect imageRect = Offset.zero & box;
          if (f != null && f.width > 0 && f.height > 0) {
            final FittedSizes fs = applyBoxFit(BoxFit.contain, Size(f.width.toDouble(), f.height.toDouble()), box);
            imageRect = Alignment.center.inscribe(fs.destination, Offset.zero & box);
          }
          return Stack(
            fit: StackFit.expand,
            children: <Widget>[
              if (f != null)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (TapUpDetails d) => _tapImage(d.localPosition, imageRect),
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      Image.memory(f.jpeg, fit: BoxFit.contain, gaplessPlayback: true),
                      CustomPaint(painter: _FocusFramesPainter(f.focus, imageRect)),
                    ],
                  ),
                )
              else if (photo != null)
                Image.file(File(photo), fit: BoxFit.contain, gaplessPlayback: true)
              else
                const Center(
                  child: Text('L\'image directe et la dernière photo apparaîtront ici.', style: TextStyle(color: Colors.white54)),
                ),
              if (f != null)
                const Positioned(
                  left: 12,
                  top: 10,
                  child: Text('Touchez l\'image pour placer le point de mise au point', style: TextStyle(color: Colors.white70, fontSize: 13)),
                ),
              if (f != null && photo != null)
                Positioned(
                  right: 10,
                  bottom: 10,
                  child: Container(
                    width: 150,
                    height: 100,
                    decoration: BoxDecoration(border: Border.all(color: kAccent, width: 2), borderRadius: BorderRadius.circular(6)),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Image.file(File(photo), fit: BoxFit.cover, gaplessPlayback: true),
                    ),
                  ),
                ),
              if (_lastInfo != null)
                Positioned(
                  left: 12,
                  bottom: 10,
                  child: Text(_lastInfo!, style: const TextStyle(color: Colors.white70, fontSize: 13)),
                ),
            ],
          );
        }),
      ),
    );
  }

  Widget _buildPanel(bool ready) {
    final CameraLiveState s = _st;
    final CameraLiveProp? bat = s.props[kPropBattery];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Card(
          color: kPanel,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(children: <Widget>[
                  Icon(ready ? Icons.usb : Icons.usb_off, color: ready ? kAccent : Colors.white38),
                  const SizedBox(width: 8),
                  Expanded(child: Text(s.name ?? 'Aucun appareil', style: Theme.of(context).textTheme.titleMedium)),
                  if (bat != null) Text('batterie ${batteryPercent(bat.cur)} % (à confirmer)', style: const TextStyle(fontSize: 12, color: Colors.white60)),
                ]),
                const SizedBox(height: 8),
                Text(_status),
                if (!ready) ...<Widget>[
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    onPressed: _connecting ? null : _connect,
                    icon: _connecting
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.link),
                    label: Text(_connecting ? 'Connexion…' : 'Connecter'),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (ready) ...<Widget>[
          _SettingRow(label: 'Ouverture', code: kPropAperture, st: s, pending: _pending, fmt: _fmt, onStep: _step),
          _SettingRow(label: 'Vitesse', code: kPropShutter, st: s, pending: _pending, fmt: _fmt, onStep: _step),
          _SettingRow(label: 'ISO', code: kPropIso, st: s, pending: _pending, fmt: _fmt, onStep: _step),
          const SizedBox(height: 8),
          _ReadOnlyBlock(st: s, fmt: _fmt),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => CameraBridge.call('liveFocus'),
            icon: const Icon(Icons.center_focus_strong),
            label: const Text('Mise au point'),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 84,
            child: FilledButton.icon(
              onPressed: _shooting ? null : _shoot,
              icon: _shooting
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 3))
                  : const Icon(Icons.camera, size: 32),
              label: Text(_shooting ? 'Prise en cours…' : 'Déclencher', style: const TextStyle(fontSize: 22)),
            ),
          ),
          const SizedBox(height: 10),
          Text('Photos reçues pendant cette session : ${s.received}', textAlign: TextAlign.center),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: s.lastFile == null ? null : _openInDevelop,
            icon: const Icon(Icons.tune),
            label: const Text('Ouvrir dans Développement'),
          ),
        ],
      ],
    );
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.label,
    required this.code,
    required this.st,
    required this.pending,
    required this.fmt,
    required this.onStep,
  });

  final String label;
  final int code;
  final CameraLiveState st;
  final Set<int> pending;
  final String Function(int, int) fmt;
  final Future<void> Function(int, int) onStep;

  @override
  Widget build(BuildContext context) {
    final CameraLiveProp? p = st.props[code];
    final bool busy = pending.contains(code);
    final List<int> sorted = p == null ? <int>[] : sortedChoices(code, p.choices);
    final bool can = p != null && p.writable && p.enabled && !busy;
    final bool less = can && neighborChoice(sorted, p.cur, -1) != null;
    final bool more = can && neighborChoice(sorted, p.cur, 1) != null;
    return Card(
      color: kPanel,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(children: <Widget>[
          SizedBox(width: 86, child: Text(label)),
          IconButton(onPressed: less ? () => onStep(code, -1) : null, icon: const Icon(Icons.remove_circle_outline), iconSize: 32),
          Expanded(
            child: Center(
              child: busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(
                      p == null ? '—' : fmt(code, p.cur),
                      style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600, color: p != null && !p.writable ? Colors.white54 : Colors.white),
                    ),
            ),
          ),
          IconButton(onPressed: more ? () => onStep(code, 1) : null, icon: const Icon(Icons.add_circle_outline), iconSize: 32),
        ]),
      ),
    );
  }
}

/// Réglages lus mais dont le sens n'est pas encore confirmé : valeur brute, sans interprétation.
class _ReadOnlyBlock extends StatelessWidget {
  const _ReadOnlyBlock({required this.st, required this.fmt});

  final CameraLiveState st;
  final String Function(int, int) fmt;

  @override
  Widget build(BuildContext context) {
    const List<(int, String)> rows = <(int, String)>[
      (kPropExposureMode, 'Mode d\'exposition'),
      (kPropExposureComp, 'Compensation'),
      (kPropWhiteBalance, 'Balance des blancs'),
      (kPropFocusMode, 'Mise au point'),
      (kPropDestination, 'Destination'),
    ];
    final List<Widget> chips = <Widget>[];
    for (final (int code, String name) in rows) {
      final CameraLiveProp? p = st.props[code];
      if (p == null) continue;
      chips.add(Chip(label: Text('$name : ${fmt(code, p.cur)}')));
    }
    if (chips.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      const Text('Lus sur l\'appareil (valeurs brutes, sens à confirmer)', style: TextStyle(fontSize: 12, color: Colors.white60)),
      const SizedBox(height: 4),
      Wrap(spacing: 6, runSpacing: 0, children: chips),
    ]);
  }
}

/// Dessine les cadres de mise au point renvoyés par l'appareil (position = centre du cadre : hypothèse à confirmer).
class _FocusFramesPainter extends CustomPainter {
  _FocusFramesPainter(this.frames, this.imageRect);

  final List<CameraFocusFrame> frames;
  final Rect imageRect;

  @override
  void paint(Canvas canvas, Size size) {
    for (final CameraFocusFrame f in frames) {
      final double cx = imageRect.left + f.x * imageRect.width;
      final double cy = imageRect.top + f.y * imageRect.height;
      final double w = f.w * imageRect.width;
      final double h = f.h * imageRect.height;
      final Paint p = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = f.state == 2 ? const Color(0xFF4CD964) : kAccent;
      canvas.drawRect(Rect.fromCenter(center: Offset(cx, cy), width: w, height: h), p);
    }
  }

  @override
  bool shouldRepaint(_FocusFramesPainter old) => old.frames != frames || old.imageRect != imageRect;
}
