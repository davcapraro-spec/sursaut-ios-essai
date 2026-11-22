import 'package:flutter/material.dart';

import '../../domain/curves.dart';

/// Couleur d'affichage de chaque canal de courbe.
const Map<String, Color> kCurveColors = <String, Color>{
  'rvb': Color(0xFFF2A33A),
  'red': Color(0xFFE5534B),
  'green': Color(0xFF4CB36B),
  'blue': Color(0xFF4A8FE8),
};

/// Éditeur de courbe de tonalité, au doigt ou au Pencil.
///
/// Toucher une zone vide ajoute un point ; glisser un point le déplace ; deux touchers rapides
/// sur un point le suppriment (sauf les deux extrémités, qui ne bougent que verticalement).
/// Le dessin utilise le même calcul que le moteur (`domain/curves.dart`).
class CurveEditor extends StatefulWidget {
  const CurveEditor({
    super.key,
    required this.channel,
    required this.curves,
    required this.onChanged,
    required this.onEnd,
  });

  /// 'rvb', 'red', 'green' ou 'blue'.
  final String channel;
  final Map<String, CurvePoints> curves;

  /// Appelé pendant le geste avec la nouvelle courbe du canal.
  final ValueChanged<CurvePoints> onChanged;

  /// Appelé à la fin d'un geste (une étape d'annulation).
  final VoidCallback onEnd;

  @override
  State<CurveEditor> createState() => _CurveEditorState();
}

class _CurveEditorState extends State<CurveEditor> {
  static const double _grab = 30; // rayon de saisie d'un point, en pixels

  int? _drag;
  int _lastTapIndex = -1;
  DateTime _lastTap = DateTime.fromMillisecondsSinceEpoch(0);

  CurvePoints get _pts => widget.curves[widget.channel] ?? identityCurve();

  Offset _toPixel(List<double> p, Size s) => Offset(p[0] * s.width, (1 - p[1]) * s.height);

  int? _nearest(Offset pos, Size s) {
    int? best;
    double bestD = _grab;
    final CurvePoints pts = _pts;
    for (int i = 0; i < pts.length; i++) {
      final double d = (_toPixel(pts[i], s) - pos).distance;
      if (d <= bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }

  void _down(PointerDownEvent e, Size s) {
    final int? hit = _nearest(e.localPosition, s);
    final DateTime now = DateTime.now();
    if (hit != null) {
      final bool twice = hit == _lastTapIndex && now.difference(_lastTap).inMilliseconds < 350;
      _lastTap = now;
      _lastTapIndex = hit;
      if (twice && hit > 0 && hit < _pts.length - 1) {
        widget.onChanged(removeCurvePoint(_pts, hit));
        widget.onEnd();
        _drag = null;
        _lastTapIndex = -1;
        return;
      }
      _drag = hit;
      return;
    }
    final double x = (e.localPosition.dx / s.width).clamp(0.0, 1.0);
    final double y = (1 - e.localPosition.dy / s.height).clamp(0.0, 1.0);
    final (CurvePoints pts, int i) = addCurvePoint(_pts, x, y);
    _drag = i;
    _lastTapIndex = -1;
    widget.onChanged(pts);
  }

  void _move(PointerMoveEvent e, Size s) {
    final int? i = _drag;
    if (i == null) return;
    final double x = (e.localPosition.dx / s.width).clamp(0.0, 1.0);
    final double y = (1 - e.localPosition.dy / s.height).clamp(0.0, 1.0);
    widget.onChanged(moveCurvePoint(_pts, i, x, y));
  }

  void _up() {
    if (_drag != null) widget.onEnd();
    _drag = null;
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints c) {
          final Size s = Size(c.maxWidth, c.maxHeight);
          return Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (PointerDownEvent e) => _down(e, s),
            onPointerMove: (PointerMoveEvent e) => _move(e, s),
            onPointerUp: (PointerUpEvent e) => _up(),
            onPointerCancel: (PointerCancelEvent e) => _up(),
            child: CustomPaint(
              painter: _CurvePainter(widget.curves, widget.channel, _drag),
              size: s,
            ),
          );
        },
      ),
    );
  }
}

class _CurvePainter extends CustomPainter {
  _CurvePainter(this.curves, this.channel, this.selected);

  final Map<String, CurvePoints> curves;
  final String channel;
  final int? selected;

  Path _path(CurvePoints pts, Size s) {
    final List<double> v = curveSamples(pts, size: 128);
    final Path p = Path();
    for (int i = 0; i < v.length; i++) {
      final double x = i / (v.length - 1) * s.width;
      final double y = (1 - v[i]) * s.height;
      if (i == 0) {
        p.moveTo(x, y);
      } else {
        p.lineTo(x, y);
      }
    }
    return p;
  }

  @override
  void paint(Canvas canvas, Size s) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & s, const Radius.circular(10)),
      Paint()..color = const Color(0xFF141416),
    );
    final Paint grid = Paint()
      ..color = const Color(0xFF2C2C30)
      ..strokeWidth = 1;
    for (int i = 1; i < 4; i++) {
      canvas.drawLine(Offset(s.width * i / 4, 0), Offset(s.width * i / 4, s.height), grid);
      canvas.drawLine(Offset(0, s.height * i / 4), Offset(s.width, s.height * i / 4), grid);
    }
    canvas.drawLine(Offset(0, s.height), Offset(s.width, 0),
        Paint()..color = const Color(0xFF3A3A40)..strokeWidth = 1.5);
    // Les autres canaux, atténués, derrière le canal en cours.
    for (final MapEntry<String, CurvePoints> e in curves.entries) {
      if (e.key == channel) continue;
      canvas.drawPath(
          _path(e.value, s),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = (kCurveColors[e.key] ?? Colors.white).withAlpha(90));
    }
    final CurvePoints pts = curves[channel] ?? identityCurve();
    final Color col = kCurveColors[channel] ?? const Color(0xFFF2A33A);
    canvas.drawPath(
        _path(pts, s),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeJoin = StrokeJoin.round
          ..color = col);
    for (int i = 0; i < pts.length; i++) {
      final Offset c = Offset(pts[i][0] * s.width, (1 - pts[i][1]) * s.height);
      final bool sel = i == selected;
      canvas.drawCircle(c, sel ? 11 : 8, Paint()..color = sel ? col : const Color(0xFF151517));
      canvas.drawCircle(
          c,
          sel ? 11 : 8,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5
            ..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(_CurvePainter old) => true;
}
