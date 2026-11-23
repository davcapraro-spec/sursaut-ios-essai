import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../domain/spots.dart';

/// Photo entière (sans recadrage) avec les retouches de taches dessinées dessus.
///
/// Toutes les positions sont des fractions de la photo. Gestes :
/// - un doigt, outil « Toucher » : toucher une zone vide ajoute une retouche ; toucher un cercle le choisit ;
///   glisser le cercle de la retouche choisie la déplace, glisser son petit cercle « source » change la zone copiée ;
/// - un doigt, outil « Pinceau » : glisser sur la photo trace une seule retouche qui suit le trait
///   (sauf si l'on saisit la poignée orange de la zone copiée de la retouche choisie : elle se déplace) ;
/// - deux doigts : pincer pour zoomer, glisser pour déplacer la photo (ou boutons + / − en bas à droite).
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
  static const double _maxZoom = 10;

  String? _drag; // 'target' | 'source' | 'stroke'
  int _dragIndex = -1;
  Offset _downAt = Offset.zero;
  bool _moved = false;
  final List<List<double>> _stroke = <List<double>>[];

  // Zoom : la photo affichée est la photo « ajustée » agrandie de _zoom, centrée sur le centre de la zone + _pan.
  double _zoom = 1;
  Offset _pan = Offset.zero;
  Size _box = Size.zero;
  Rect _fitRect = Rect.zero;
  final Map<int, Offset> _pointers = <int, Offset>{};
  bool _pinching = false; // deux doigts posés : zoom et déplacement
  bool _blocked = false; // après un pincement, le doigt restant est ignoré jusqu'à ce que tout soit levé
  double _pinchD0 = 1;
  Offset _pinchM0 = Offset.zero;
  double _pinchZoom0 = 1;
  Offset _pinchPan0 = Offset.zero;

  Rect _fit(Size box) {
    final double iw = widget.image.width.toDouble(), ih = widget.image.height.toDouble();
    final double s = math.min(box.width / iw, box.height / ih);
    return Rect.fromLTWH((box.width - iw * s) / 2, (box.height - ih * s) / 2, iw * s, ih * s);
  }

  /// Rectangle de la photo à l'écran, zoom et déplacement compris.
  Rect _view() => Rect.fromCenter(
        center: Offset(_box.width / 2, _box.height / 2) + _pan,
        width: _fitRect.width * _zoom,
        height: _fitRect.height * _zoom,
      );

  Offset _clampPan(Offset pan, double zoom) {
    final double mx = math.max(0.0, (_fitRect.width * zoom - _box.width) / 2);
    final double my = math.max(0.0, (_fitRect.height * zoom - _box.height) / 2);
    return Offset(pan.dx.clamp(-mx, mx).toDouble(), pan.dy.clamp(-my, my).toDouble());
  }

  void _zoomBy(double factor) {
    final double z = (_zoom * factor).clamp(1.0, _maxZoom).toDouble();
    setState(() {
      _pan = _clampPan(_pan * (z / _zoom), z);
      _zoom = z;
    });
  }

  void _zoomReset() => setState(() {
        _zoom = 1;
        _pan = Offset.zero;
      });

  List<double> _frac(Rect img, Offset p) => <double>[
        ((p.dx - img.left) / img.width).clamp(0.0, 1.0).toDouble(),
        ((p.dy - img.top) / img.height).clamp(0.0, 1.0).toDouble(),
      ];

  Offset _px(Rect img, double fx, double fy) => Offset(img.left + fx * img.width, img.top + fy * img.height);

  double _radiusPx(Rect img, double r) => math.max(r * math.max(img.width, img.height), 6);

  /// Retouche touchée à la position p (la plus proche), ou -1.
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
    final int sel = widget.selected;
    if (sel >= 0 && sel < widget.spots.length) {
      final Spot s = widget.spots[sel];
      final Offset src = _px(img, (s['sx'] as num).toDouble(), (s['sy'] as num).toDouble());
      // la poignée orange de la zone copiée se déplace aussi avec le pinceau
      if ((src - p).distance <= _grab) {
        _drag = 'source';
        _dragIndex = sel;
        return;
      }
      if (widget.brush) {
        _drag = 'stroke';
        _stroke
          ..clear()
          ..add(_frac(img, p));
        return;
      }
      final Offset tgt = _px(img, (s['x'] as num).toDouble(), (s['y'] as num).toDouble());
      if ((tgt - p).distance <= math.max(_radiusPx(img, (s['r'] as num).toDouble()), _grab)) {
        _drag = 'target';
        _dragIndex = sel;
      }
    } else if (widget.brush) {
      _drag = 'stroke';
      _stroke
        ..clear()
        ..add(_frac(img, p));
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
      } else if (pts.isNotEmpty) {
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

  /// Un second doigt arrive : le geste d'un doigt en cours est abandonné (un déplacement déjà fait est validé).
  void _cancelSingle() {
    if (_drag != null && _drag != 'stroke' && _moved) widget.onMoveEnd();
    _drag = null;
    if (_stroke.isNotEmpty) setState(_stroke.clear);
  }

  void _onDown(PointerDownEvent e) {
    _pointers[e.pointer] = e.localPosition;
    if (_pointers.length == 2) {
      _cancelSingle();
      _pinching = true;
      _blocked = true;
      final List<Offset> pts = _pointers.values.toList();
      _pinchD0 = math.max((pts[0] - pts[1]).distance, 1);
      _pinchM0 = (pts[0] + pts[1]) / 2;
      _pinchZoom0 = _zoom;
      _pinchPan0 = _pan;
      return;
    }
    if (_pointers.length > 2 || _blocked) return;
    _down(_view(), e.localPosition);
  }

  void _onMove(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.localPosition;
    if (_pinching && _pointers.length >= 2) {
      final List<Offset> pts = _pointers.values.toList();
      final double d = math.max((pts[0] - pts[1]).distance, 1);
      final Offset m = (pts[0] + pts[1]) / 2;
      final double z = (_pinchZoom0 * d / _pinchD0).clamp(1.0, _maxZoom).toDouble();
      final Offset center = Offset(_box.width / 2, _box.height / 2);
      final Offset q = (_pinchM0 - center - _pinchPan0) / _pinchZoom0; // point de la photo sous les doigts au départ
      setState(() {
        _zoom = z;
        _pan = _clampPan(m - center - q * z, z);
      });
      return;
    }
    if (_blocked || _pointers.length != 1) return;
    _update(_view(), e.localPosition);
  }

  void _onUp(PointerUpEvent e) {
    if (_pointers.remove(e.pointer) == null) return;
    if (_pinching) {
      if (_pointers.length < 2) _pinching = false;
      if (_pointers.isEmpty) _blocked = false;
      return;
    }
    if (_blocked) {
      if (_pointers.isEmpty) _blocked = false;
      return;
    }
    _up(_view(), e.localPosition);
  }

  void _onCancel(PointerCancelEvent e) {
    _pointers.remove(e.pointer);
    _cancelSingle();
    if (_pointers.isEmpty) {
      _pinching = false;
      _blocked = false;
    }
  }

  Widget _zoomBar() {
    return Material(
      color: const Color(0xE61E1E21),
      borderRadius: BorderRadius.circular(14),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          IconButton(
            tooltip: 'Zoom arrière',
            onPressed: _zoom > 1 ? () => _zoomBy(1 / 1.5) : null,
            icon: const Icon(Icons.remove),
          ),
          TextButton(
            onPressed: _zoom > 1 ? _zoomReset : null,
            child: Text(_zoom > 1 ? '×${_zoom.toStringAsFixed(1).replaceAll('.', ',')}' : 'Ajusté'),
          ),
          IconButton(
            tooltip: 'Zoom avant',
            onPressed: _zoom < _maxZoom ? () => _zoomBy(1.5) : null,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (BuildContext context, BoxConstraints c) {
      _box = Size(c.maxWidth, c.maxHeight);
      _fitRect = _fit(_box);
      _pan = _clampPan(_pan, _zoom);
      final Rect view = _view();
      return Stack(
        children: <Widget>[
          Positioned.fill(
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _onDown,
              onPointerMove: _onMove,
              onPointerUp: _onUp,
              onPointerCancel: _onCancel,
              child: CustomPaint(
                size: _box,
                painter: _SpotPainter(
                  image: widget.image,
                  img: view,
                  spots: widget.spots,
                  selected: widget.selected,
                  dust: widget.dust,
                  stroke: List<List<double>>.of(_stroke),
                  brushRadius: widget.brushRadius,
                ),
              ),
            ),
          ),
          Positioned(right: 12, bottom: 12, child: _zoomBar()),
        ],
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
    canvas.clipRect(Offset.zero & size);
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
        canvas.drawCircle(src, 15, Paint()..color = const Color(0xCC000000));
        canvas.drawCircle(src, 12, Paint()..color = const Color(0xFFF2A33A));
        canvas.drawCircle(src, 4, Paint()..color = Colors.white);
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
