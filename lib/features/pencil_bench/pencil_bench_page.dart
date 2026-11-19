import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pencil_bridge/pencil_bridge.dart';

import 'pencil_bench_model.dart';

/// Banc Pencil (essai S5) : montre en direct ce que l'iPad transmet avec
/// l'Apple Pencil de David. Écran de diagnostic, pas une fonction de Sursaut.
class PencilBenchPage extends StatefulWidget {
  const PencilBenchPage({super.key});

  @override
  State<PencilBenchPage> createState() => _PencilBenchPageState();
}

class _Stroke {
  _Stroke(this.kind);

  final String kind;
  final List<Offset> points = <Offset>[];
  final List<double> widths = <double>[];
}

class _PencilBenchPageState extends State<PencilBenchPage> {
  final PencilBenchModel _model = PencilBenchModel();
  final List<_Stroke> _strokes = <_Stroke>[];
  final Set<int> _stylusDown = <int>{};
  StreamSubscription<PencilNativeEvent>? _subscription;
  Timer? _refresh;
  bool _dirty = true;
  _Stroke? _current;

  @override
  void initState() {
    super.initState();
    _subscription = PencilBridge.events.listen(
      (PencilNativeEvent e) {
        _model.addNative(e.type, e.data);
        _dirty = true;
      },
      onError: (Object error) {
        _model.bridgeError = error.toString();
        _dirty = true;
      },
    );
    _refresh = Timer.periodic(const Duration(milliseconds: 100), (Timer _) {
      if (_dirty && mounted) {
        _dirty = false;
        setState(() {});
      }
    });
    _loadCapabilities();
  }

  Future<void> _loadCapabilities() async {
    final Map<String, Object?> caps = await PencilBridge.capabilities();
    if (!mounted) return;
    setState(() => _model.capabilities = caps);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _refresh?.cancel();
    super.dispose();
  }

  String _kindName(PointerDeviceKind kind) {
    switch (kind) {
      case PointerDeviceKind.stylus:
      case PointerDeviceKind.invertedStylus:
        return 'stylet';
      case PointerDeviceKind.touch:
        return 'doigt';
      case PointerDeviceKind.mouse:
        return 'souris';
      default:
        return kind.name;
    }
  }

  void _record(PointerEvent e, String phase) {
    final String kind = _kindName(e.kind);
    if (phase == 'down') {
      if (kind == 'stylet') {
        _stylusDown.add(e.pointer);
      } else if (kind == 'doigt' && _stylusDown.isNotEmpty) {
        _model.palmWhileStylus++;
      }
    } else if (phase == 'up' || phase == 'cancel') {
      _stylusDown.remove(e.pointer);
    }
    _model.addFlutter(
      kind: kind,
      phase: phase,
      pressure: e.pressure,
      pressureMax: e.pressureMax,
      tiltRad: e.tilt,
      orientationRad: e.orientation,
      distance: e.distance,
      distanceMax: e.distanceMax,
      micros: e.timeStamp.inMicroseconds,
    );
    _dirty = true;
  }

  void _onDown(PointerDownEvent e) {
    _record(e, 'down');
    final _Stroke stroke = _Stroke(_kindName(e.kind));
    stroke.points.add(e.localPosition);
    stroke.widths.add(_width(e));
    setState(() {
      _current = stroke;
      _strokes.add(stroke);
    });
  }

  void _onMove(PointerMoveEvent e) {
    _record(e, 'move');
    final _Stroke? stroke = _current;
    if (stroke == null) return;
    stroke.points.add(e.localPosition);
    stroke.widths.add(_width(e));
    setState(() {});
  }

  void _onUp(PointerUpEvent e) {
    _record(e, 'up');
    _current = null;
  }

  void _onCancel(PointerCancelEvent e) {
    _record(e, 'cancel');
    _current = null;
  }

  void _onHover(PointerHoverEvent e) {
    _record(e, 'survol');
  }

  double _width(PointerEvent e) {
    final double max = e.pressureMax <= e.pressureMin ? 1 : e.pressureMax;
    final double p = (e.pressure / max).clamp(0.0, 1.0);
    return 1.5 + p * 12;
  }

  Future<void> _copyReport() async {
    await Clipboard.setData(ClipboardData(text: _model.report(DateTime.now())));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Rapport copié : collez-le dans la discussion.')),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 150,
            child: Text(label, style: const TextStyle(color: Colors.white70)),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  Widget _title(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 4),
      child: Text(
        text,
        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
      ),
    );
  }

  Widget _panel() {
    final PencilBenchModel m = _model;
    String cap(String key) => m.capabilities[key]?.toString() ?? '—';
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        const Text(
          'À faire dans l\'ordre, sur la zone de gauche : 1) écrire léger puis '
          'fort ; 2) incliner le Pencil ; 3) le faire tourner sur son axe, '
          'au contact puis en survol ; 4) le tenir à 1-2 cm de l\'écran ; '
          '5) serrer le Pencil ; 6) double-tapoter ; 7) poser la paume en '
          'écrivant ; 8) toucher au doigt. Puis « Copier le rapport ».',
          style: TextStyle(color: Colors.white70),
        ),
        _title('Appareil'),
        _row('Modèle', cap('machine')),
        _row('Système', '${cap('systemName')} ${cap('systemVersion')}'),
        _row('API serrage', cap('squeezeApi')),
        _row('Réglage du serrage', cap('preferredSqueezeAction')),
        _row('Réglage double appui', cap('preferredTapAction')),
        _row('Pont natif', m.infos.isEmpty ? '—' : m.infos.last),
        if (m.bridgeError != null) _row('Erreur du pont', m.bridgeError!),
        if (m.capabilities['erreur'] != null)
          _row('Erreur', cap('erreur')),
        _title('Flutter (stylet)'),
        _row('Contacts', 'stylet ${m.flutterStylusDowns} · doigt '
            '${m.flutterFingerDowns} · doigt pendant stylet '
            '${m.palmWhileStylus}'),
        _row('Pression', m.flutterPressure.describe()),
        _row('Inclinaison', m.flutterTiltDeg.describe(digits: 0, unit: '°')),
        _row('Azimut', m.flutterOrientationDeg.describe(digits: 0, unit: '°')),
        _row('Survol (distance)', m.flutterHoverDistance.describe()),
        _row('Cadence max', '${m.flutterMoveRate.maxPerSecond.toStringAsFixed(0)}'
            ' évén./s'),
        _title('Natif (Swift)'),
        _row('Contacts natifs', '${m.nativeTouchEvents}'),
        _row('Échantillons/évén.', m.nativeSamples.describe(digits: 1)),
        _row('Force', m.nativeForce.describe()),
        _row('Altitude', m.nativeAltitudeDeg.describe(digits: 0, unit: '°')),
        _row('Azimut', m.nativeAzimuthDeg.describe(digits: 0, unit: '°')),
        _row('Roulis (contact)', m.nativeRollDeg.describe(digits: 0, unit: '°')),
        _row('Survol natif', '${m.nativeHoverEvents} événements'),
        _row('  hauteur', m.hoverZOffset.describe()),
        _row('  roulis', m.hoverRollDeg.describe(digits: 0, unit: '°')),
        _row('Serrage', '${m.squeezeEvents} événements · phase '
            '${m.lastSqueezePhase} · avec position ${m.squeezeWithPose}'),
        _row('Double appui', '${m.taps}'),
        const SizedBox(height: 16),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _copyReport,
          icon: const Icon(Icons.copy),
          label: const Text('Copier le rapport'),
        ),
      ],
    );
  }

  Widget _canvas() {
    return ClipRect(
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _onDown,
        onPointerMove: _onMove,
        onPointerUp: _onUp,
        onPointerCancel: _onCancel,
        onPointerHover: _onHover,
        child: Container(
          color: const Color(0xFF101012),
          child: CustomPaint(
            painter: _StrokePainter(_strokes),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Banc Pencil'),
        actions: <Widget>[
          TextButton(
            onPressed: () => setState(_strokes.clear),
            child: const Text('Effacer'),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints box) {
            if (box.maxWidth >= 900) {
              return Row(
                children: <Widget>[
                  Expanded(flex: 3, child: _canvas()),
                  Expanded(flex: 2, child: _panel()),
                ],
              );
            }
            return Column(
              children: <Widget>[
                Expanded(flex: 3, child: _canvas()),
                Expanded(flex: 2, child: _panel()),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _StrokePainter extends CustomPainter {
  _StrokePainter(this.strokes);

  final List<_Stroke> strokes;

  @override
  void paint(Canvas canvas, Size size) {
    for (final _Stroke s in strokes) {
      final Paint paint = Paint()
        ..color = s.kind == 'stylet'
            ? const Color(0xFFF2A33A)
            : const Color(0xFF4FC3F7)
        ..strokeCap = StrokeCap.round;
      for (int i = 1; i < s.points.length; i++) {
        paint.strokeWidth = s.widths[i];
        canvas.drawLine(s.points[i - 1], s.points[i], paint);
      }
      if (s.points.length == 1) {
        canvas.drawCircle(s.points.first, s.widths.first / 2, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _StrokePainter oldDelegate) => true;
}
