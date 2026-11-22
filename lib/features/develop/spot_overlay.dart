import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../domain/spots.dart';

/// Photo entière (sans recadrage) avec les retouches de taches dessinées dessus.
///
/// Toutes les positions sont des fractions de la photo. Gestes :
/// - outil « Clic » : toucher une zone vide ajoute une retouche ; toucher un cercle le choisit ;
///   glisser le cercle de la retouche choisie la déplace, glisser son petit cercle « source » change la zone copiée ;
/// - outil « Pinceau » : glisser sur la photo trace une seule retouche qui suit le trait.
class SpotOverlay extends StatefulWidget {
  const SpotOverlay({
    super.key,
    required this.image,
    required this.spots,
    required this.selected,
    required this.brush,
    required this.brushRadius,
    required this.dust,
    required this.onAdd,
    required this.onSelect,
    required this.onMove,
    required this.onMoveEnd,
    required this.onStroke,
  });

  final ui.Image image;
  final List<Spot> spots;
  final int selected;
  final bool brush;

  /// Rayon du pinceau, en fraction du grand côté (pour l'aperçu du trait).
  final double brushRadius;
  final List<Map<String, dynamic>> dust;
  final void Function(double fx, double fy) onAdd;
  final ValueChanged<int> onSelect;

  /// `which` : 'target' (la retouche) ou 'source' (la zone copiée).
  final void Function(int index, String which, double fx, double fy) onMove;
  final VoidCallback onMoveEnd;
  final ValueChanged<List<List<double>>> onStroke;

  @override
  State<SpotOverlay> createState() => _SpotOverlayState();
}

class _SpotOverlayState extends State<SpotOverlay> {
  static const double _grab = 34;

  String? _drag; // 'target' | 'source' | 'stroke'
  int _dragIndex = -1;
  Offset _downAt = Offset.zero;
  bool _moved = false;
  final List<List<double>> _stroke = <List<double>>[];

  Rect _fit(Size box) {
    final double iw = widget.image.width.toDouble(), ih = widget.image.height.toDouble();
    final double s = math.min(box.width / iw, box.height / ih);
    return Rect.fromLTWH((box.width - iw * s) / 2, (box.height - ih * s) / 2, iw * s, ih * s);
  }

  List<double> _frac(Rect img, Offset p) => <double>[
        ((p.dx - img.left) / img.width).clamp(0.0, 1.0),
        ((p.dy - img.top) / img.height).clamp(0.0, 1.0),
      ];

  Offset _px(Rect img, double fx, double fy) => Offset(img.left + fx * img.width, img.top + fy * img.height);

  double _radiusPx(Rect img, double r) => math.max(r * math.max(img.width, img.height), 6);

  /// Rétouche touchée à la position p (la plus proche), ou -1.
  int _hitSpot(Rect img, Offset p) {
    int best = -1;
    double bestD = double.infinity;
    for (int i = 0; i < widget.spots.length; i++) {
      final Spot s = widget.spots[i];
      final double d = (_px(img, (s['x'] as num).toDouble(), (s['y'] as num).toDouble()) - p).distance;
      final double reach = math.max(_radiusPx(img, (s['r'] as num).toDouble()), 18) + 8;
      if (d <= reach && d < bestD) {
        best = i;
        bestD = d;
      }
    }
    return best;
  }

  void _down(Rect img, Offset p) {
    _downAt = p;
    _moved = false;
    _drag = null;
    _dragIndex = -1;
    if (widget.brush) {
      _drag = 'stroke';
      _stroke
        ..clear()
        ..add(_frac(img, p));
      return;
    }
    final int sel = widget.selected;
    if (sel >= 0 && sel < widget.spots.length) {
      final Spot s = widget.spots[sel];
      final Offset src = _px(img, (s['sx'] as num).toDouble(), (s['sy'] as num).toDouble());
      if ((src - p).distance <= _grab) {
        _drag = 'source';
        _dragIndex = sel;
        return;
      }
      final Offset tgt = _px(img, (s['x'] as num).toDouble(), (s['y'] as num).toDouble());
      if ((tgt - p).distance <= math.max(_radiusPx(img, (s['r'] as num).toDouble()), _grab)) {
        _drag = 'target';
        _dragIndex = sel;
      }
    }
  }

  void _update(Rect img, Offset p) {
    if (!_moved && (p - _downAt).distance < 6) return;
    _moved = true;
    final List<double> f = _frac(img, p);
    if (_drag == 'stroke') {
      final List<double> last = _stroke.last;
      if ((f[0] - last[0]).abs() * img.width + (f[1] - last[1]).abs() * img.height > 3) {
        setState(() => _stroke.add(f));
      }
    } else if (_drag != null) {
      widget.onMove(_dragIndex, _drag!, f[0], f[1]);
    }
  }

  void _up(Rect img, Offset p) {
    if (_drag == 'stroke') {
      final List<List<double>> pts = List<List<double>>.of(_stroke);
      setState(_stroke.clear);
      if (_moved && pts.length > 1) {
        widget.onStroke(pts);
      } else {
        widget.onAdd(pts.first[0], pts.first[1]); // simple appui avec le pinceau : une retouche ronde
      }
    } else if (_drag != null && _moved) {
      widget.onMoveEnd();
    } else if (!_moved) {
      final int hit = _hitSpot(img, p);
      if (hit >= 0) {
        widget.onSelect(hit);
      } else {
        final List<double> f = _frac(img, p);
        widget.onAdd(f[0], f[1]);
      }
    }
    _drag = null;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (BuildContext context, BoxConstraints c) {
      final Size box = Size(c.maxWidth, c.maxHeight);
      final Rect img = _fit(box);
      return Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (PointerDownEvent e) => _down(img, e.localPosition),
        onPointerMove: (PointerMoveEvent e) => _update(img, e.localPosition),
        onPointerUp: (PointerUpEvent e) => _up(img, e.localPosition),
        child: CustomPaint(
          size: box,
          painter: _SpotPainter(
            image: widget.image,
            img: img,
            spots: widget.spots,
            selected: widget.selected,
            dust: widget.dust,
            stroke: List<List<double>>.of(_stroke),
            brushRadius: widget.brushRadius,
          ),
        ),
      );
    });
  }
}

class _SpotPainter extends CustomPainter {
  _SpotPainter({
    required this.image,
    required this.img,
    required this.spots,
    required this.selected,
    required this.dust,
    required this.stroke,
    required this.brushRadius,
  });

  final ui.Image image;
  final Rect img;
  final List<Spot> spots;
  final int selected;
  final List<Map<String, dynamic>> dust;
  final List<List<double>> stroke;
  final double brushRadius;

  Offset _px(double fx, double fy) => Offset(img.left + fx * img.width, img.top + fy * img.height);
  double _rad(double r) => math.max(r * math.max(img.width, img.height), 6);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      img,
      Paint()..filterQuality = FilterQuality.medium,
    );
    final Paint dustPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = const Color(0xFF55D6FF);
    for (final Map<String, dynamic> d in dust) {
      canvas.drawCircle(_px((d['x'] as num).toDouble(), (d['y'] as num).toDouble()),
          _rad((d['r'] as num).toDouble()) + 3, dustPaint);
    }
    for (int i = 0; i < spots.length; i++) {
      final Spot s = spots[i];
      final bool sel = i == selected;
      final Color col = sel ? const Color(0xFFF2A33A) : Colors.white;
      final Paint ring = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = sel ? 2.4 : 1.4
        ..color = col;
      final double r = _rad((s['r'] as num).toDouble());
      final List<dynamic>? stroke = s['stroke'] as List<dynamic>?;
      if (stroke != null && stroke.length > 1) {
        final Paint line = Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = math.max(2 * r, 4)
          ..color = col.withAlpha(sel ? 90 : 50);
        final Path path = Path();
        for (int k = 0; k < stroke.length; k++) {
          final List<dynamic> pt = stroke[k] as List<dynamic>;
          final Offset o = _px((pt[0] as num).toDouble(), (pt[1] as num).toDouble());
          k == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
        }
        canvas.drawPath(path, line);
      } else {
        canvas.drawCircle(_px((s['x'] as num).toDouble(), (s['y'] as num).toDouble()), r, ring);
      }
      if (sel) {
        final Offset t = _px((s['x'] as num).toDouble(), (s['y'] as num).toDouble());
        final Offset src = _px((s['sx'] as num).toDouble(), (s['sy'] as num).toDouble());
        canvas.drawLine(t, src, Paint()..color = col.withAlpha(160)..strokeWidth = 1.4);
        canvas.drawCircle(src, math.min(r, 40), ring..strokeWidth = 1.8);
        canvas.drawCircle(src, 4, Paint()..color = col);
      }
    }
    if (stroke.length > 1) {
      final Path p = Path();
      for (int k = 0; k < stroke.length; k++) {
        final Offset o = _px(stroke[k][0], stroke[k][1]);
        k == 0 ? p.moveTo(o.dx, o.dy) : p.lineTo(o.dx, o.dy);
      }
      canvas.drawPath(
        p,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = math.max(2 * _rad(brushRadius), 4)
          ..color = const Color(0xFFF2A33A).withAlpha(90),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SpotPainter old) => true;
}
