import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../domain/mask_tools.dart';
import '../../domain/masks.dart';

const Color _kAmber = Color(0xFFF2A33A);

/// Photo entière (sans recadrage) avec le masque choisi dessiné dessus : sa zone teintée, ses poignées.
///
/// Positions en fractions de la photo, rayons en fraction de son grand côté (comme le moteur et le PC). Gestes d'un doigt :
/// - [drawKind] non nul (« Dégradé linéaire » ou « Dégradé radial » touché dans le panneau) : glisser sur la photo trace le
///   masque (linéaire : de l'endroit de plein effet vers l'endroit sans effet ; radial : du centre vers le bord) ;
/// - sinon, avec un masque choisi : glisser une poignée la déplace ; glisser le reste du masque le déplace en entier.
class MaskOverlay extends StatefulWidget {
  const MaskOverlay({
    super.key,
    required this.image,
    required this.mask,
    required this.drawKind,
    required this.showArea,
    required this.onDraw,
    required this.onEdit,
    required this.onEditEnd,
  });

  final ui.Image image;

  /// Le masque choisi (dégradé linéaire ou radial), ou null.
  final MaskMap? mask;
  final String? drawKind;
  final bool showArea;

  /// Fin d'un tracé : type, point de départ, point d'arrivée (fractions de la photo).
  final void Function(String kind, double ax, double ay, double bx, double by) onDraw;

  /// Changement de la première composante du masque choisi (position, rayon…) pendant un glissement.
  final ValueChanged<Map<String, dynamic>> onEdit;
  final VoidCallback onEditEnd;

  @override
  State<MaskOverlay> createState() => _MaskOverlayState();
}

class _MaskOverlayState extends State<MaskOverlay> {
  static const double _grab = 30;

  String? _drag; // 'create' | 'p0' | 'p1' | 'line' | 'center' | 'rx' | 'ry'
  bool _moved = false;
  Offset? _a, _b; // tracé en cours (pixels de l'écran)
  Offset _downAt = Offset.zero;
  Map<String, dynamic> _comp0 = <String, dynamic>{};

  Rect _fit(Size box) {
    final double iw = widget.image.width.toDouble(), ih = widget.image.height.toDouble();
    final double s = math.min(box.width / iw, box.height / ih);
    return Rect.fromLTWH((box.width - iw * s) / 2, (box.height - ih * s) / 2, iw * s, ih * s);
  }

  double _d(Map<String, dynamic> c, String k, double fallback) => c[k] is num ? (c[k] as num).toDouble() : fallback;

  Offset _px(Rect img, double fx, double fy) => Offset(img.left + fx * img.width, img.top + fy * img.height);

  List<double> _frac(Rect img, Offset p) => <double>[
        ((p.dx - img.left) / img.width).clamp(0.0, 1.0).toDouble(),
        ((p.dy - img.top) / img.height).clamp(0.0, 1.0).toDouble(),
      ];

  /// Axes de l'ellipse d'un dégradé radial, en pixels : (centre, extrémité de l'axe rx, extrémité de l'axe ry, direction rx, direction ry).
  (Offset, Offset, Offset, Offset, Offset) _axes(Rect img, Map<String, dynamic> c) {
    final Offset centre = _px(img, _d(c, 'x0', 0.5), _d(c, 'y0', 0.5));
    final double th = _d(c, 'angle', 0) * math.pi / 180;
    final Offset u = Offset(math.cos(th), math.sin(th));
    final Offset v = Offset(-math.sin(th), math.cos(th));
    final double long = math.max(img.width, img.height);
    return (centre, centre + u * (_d(c, 'rx', 0.2) * long), centre + v * (_d(c, 'ry', 0.2) * long), u, v);
  }

  double _segDist(Offset p, Offset a, Offset b) {
    final Offset d = b - a;
    final double n = d.dx * d.dx + d.dy * d.dy;
    final double t = n == 0 ? 0 : (((p - a).dx * d.dx + (p - a).dy * d.dy) / n).clamp(0.0, 1.0).toDouble();
    return (p - (a + d * t)).distance;
  }

  void _down(Rect img, Offset p) {
    _downAt = p;
    _moved = false;
    _drag = null;
    _a = _b = null;
    if (widget.drawKind != null) {
      _drag = 'create';
      _a = _b = p;
      return;
    }
    final MaskMap? m = widget.mask;
    final Map<String, dynamic>? c = m == null ? null : mainComp(m);
    if (m == null || c == null) return;
    _comp0 = Map<String, dynamic>.of(c);
    if ('${c['kind']}' == kLinear) {
      final Offset a = _px(img, _d(c, 'x0', 0.5), _d(c, 'y0', 0.3)), b = _px(img, _d(c, 'x1', 0.5), _d(c, 'y1', 0.7));
      if ((p - a).distance <= _grab) {
        _drag = 'p0';
      } else if ((p - b).distance <= _grab) {
        _drag = 'p1';
      } else if (_segDist(p, a, b) <= _grab * 0.7) {
        _drag = 'line';
      }
    } else if ('${c['kind']}' == kRadial) {
      final (Offset centre, Offset hx, Offset hy, Offset u, Offset v) = _axes(img, c);
      if ((p - hx).distance <= _grab) {
        _drag = 'rx';
      } else if ((p - hy).distance <= _grab) {
        _drag = 'ry';
      } else if ((p - centre).distance <= _grab) {
        _drag = 'center';
      } else {
        // dans l'ellipse : on déplace tout le masque
        final Offset d = p - centre;
        final double lx = d.dx * u.dx + d.dy * u.dy, ly = d.dx * v.dx + d.dy * v.dy;
        final double ax = (hx - centre).distance, ay = (hy - centre).distance;
        if (ax > 0 && ay > 0 && (lx / ax) * (lx / ax) + (ly / ay) * (ly / ay) <= 1) _drag = 'center';
      }
    }
  }

  void _update(Rect img, Offset p) {
    if (!_moved && (p - _downAt).distance < 6) return;
    _moved = true;
    if (_drag == 'create') {
      setState(() => _b = p);
      return;
    }
    final String? d = _drag;
    if (d == null) return;
    final List<double> f = _frac(img, p);
    final double dx = (p.dx - _downAt.dx) / img.width, dy = (p.dy - _downAt.dy) / img.height;
    switch (d) {
      case 'p0':
        widget.onEdit(<String, dynamic>{'x0': f[0], 'y0': f[1]});
      case 'p1':
        widget.onEdit(<String, dynamic>{'x1': f[0], 'y1': f[1]});
      case 'line':
        final (double mx, double my) = _shift(<double>[_d(_comp0, 'x0', 0), _d(_comp0, 'x1', 0)], <double>[_d(_comp0, 'y0', 0), _d(_comp0, 'y1', 0)], dx, dy);
        widget.onEdit(<String, dynamic>{
          'x0': _d(_comp0, 'x0', 0) + mx,
          'y0': _d(_comp0, 'y0', 0) + my,
          'x1': _d(_comp0, 'x1', 0) + mx,
          'y1': _d(_comp0, 'y1', 0) + my,
        });
      case 'center':
        final (double mx, double my) = _shift(<double>[_d(_comp0, 'x0', 0)], <double>[_d(_comp0, 'y0', 0)], dx, dy);
        widget.onEdit(<String, dynamic>{'x0': _d(_comp0, 'x0', 0) + mx, 'y0': _d(_comp0, 'y0', 0) + my});
      case 'rx':
      case 'ry':
        final (Offset centre, Offset _, Offset _, Offset u, Offset v) = _axes(img, _comp0);
        final Offset q = p - centre;
        final Offset axis = d == 'rx' ? u : v;
        final double long = math.max(img.width, img.height);
        final double r = ((q.dx * axis.dx + q.dy * axis.dy) / long).clamp(0.005, 2.0).toDouble();
        widget.onEdit(<String, dynamic>{d: r});
    }
  }

  /// Déplacement (en fraction de la photo) limité pour que tous les points restent dans la photo.
  (double, double) _shift(List<double> xs, List<double> ys, double dx, double dy) {
    double lo = -double.infinity, hi = double.infinity;
    for (final double x in xs) {
      lo = math.max(lo, -x);
      hi = math.min(hi, 1 - x);
    }
    double lo2 = -double.infinity, hi2 = double.infinity;
    for (final double y in ys) {
      lo2 = math.max(lo2, -y);
      hi2 = math.min(hi2, 1 - y);
    }
    return (dx.clamp(lo, hi).toDouble(), dy.clamp(lo2, hi2).toDouble());
  }

  void _up(Rect img, Offset p) {
    if (_drag == 'create') {
      final Offset? a = _a;
      final String? kind = widget.drawKind;
      setState(() => _a = _b = null);
      if (a != null && kind != null) {
        final List<double> fa = _frac(img, a), fb = _frac(img, _moved ? p : a);
        widget.onDraw(kind, fa[0], fa[1], fb[0], fb[1]);
      }
    } else if (_drag != null && _moved) {
      widget.onEditEnd();
    }
    _drag = null;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (BuildContext context, BoxConstraints box) {
      final Rect img = _fit(Size(box.maxWidth, box.maxHeight));
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanDown: (DragDownDetails d) => _down(img, d.localPosition),
        onPanUpdate: (DragUpdateDetails d) => _update(img, d.localPosition),
        onPanEnd: (DragEndDetails d) => _up(img, d.localPosition),
        onPanCancel: () {
          if (_drag != null && _drag != 'create' && _moved) widget.onEditEnd();
          setState(() {
            _drag = null;
            _a = _b = null;
          });
        },
        child: CustomPaint(
          size: Size(box.maxWidth, box.maxHeight),
          painter: _MaskPainter(
            image: widget.image,
            rect: img,
            comp: widget.mask == null ? null : mainComp(widget.mask!),
            invert: widget.mask?['invert'] == true,
            showArea: widget.showArea,
            drawKind: widget.drawKind,
            a: _a,
            b: _b,
          ),
        ),
      );
    });
  }
}

class _MaskPainter extends CustomPainter {
  _MaskPainter({
    required this.image,
    required this.rect,
    required this.comp,
    required this.invert,
    required this.showArea,
    required this.drawKind,
    required this.a,
    required this.b,
  });

  final ui.Image image;
  final Rect rect;
  final Map<String, dynamic>? comp;
  final bool invert;
  final bool showArea;
  final String? drawKind;
  final Offset? a, b;

  double _d(Map<String, dynamic> c, String k, double fallback) => c[k] is num ? (c[k] as num).toDouble() : fallback;

  Offset _px(double fx, double fy) => Offset(rect.left + fx * rect.width, rect.top + fy * rect.height);

  static final Paint _line = Paint()
    ..color = Colors.white
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2;
  static final Paint _shadow = Paint()
    ..color = const Color(0x99000000)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 4;

  void _handle(Canvas canvas, Offset p, {bool main = false}) {
    canvas.drawCircle(p, main ? 13 : 11, Paint()..color = const Color(0xCC000000));
    canvas.drawCircle(p, main ? 11 : 9, Paint()..color = main ? _kAmber : Colors.white);
  }

  void _both(Canvas canvas, Path path) {
    canvas.drawPath(path, _shadow);
    canvas.drawPath(path, _line);
  }

  @override
  void paint(Canvas canvas, Size size) {
    paintImage(canvas: canvas, rect: rect, image: image, fit: BoxFit.fill, filterQuality: FilterQuality.medium);
    canvas.save();
    canvas.clipRect(rect);
    final Color tint = _kAmber.withValues(alpha: 0.42);
    const Color none = Color(0x00F2A33A);
    // tracé en cours
    if (a != null && b != null) {
      if (drawKind == kLinear) {
        _paintLinear(canvas, a!, b!, false, tint, none, true);
      } else if (drawKind == kRadial) {
        final double r = (b! - a!).distance;
        final Path p = Path()..addOval(Rect.fromCircle(center: a!, radius: math.max(r, 2)));
        _both(canvas, p);
        _handle(canvas, a!, main: true);
      }
    } else if (comp != null) {
      final Map<String, dynamic> c = comp!;
      if ('${c['kind']}' == kLinear) {
        _paintLinear(canvas, _px(_d(c, 'x0', 0.5), _d(c, 'y0', 0.3)), _px(_d(c, 'x1', 0.5), _d(c, 'y1', 0.7)), invert, tint, none, showArea);
      } else if ('${c['kind']}' == kRadial) {
        _paintRadial(canvas, c, tint, none);
      }
    }
    canvas.restore();
  }

  void _paintLinear(Canvas canvas, Offset p0, Offset p1, bool inv, Color tint, Color none, bool fill) {
    final Offset d = p1 - p0;
    final double len = d.distance;
    if (fill && len > 1) {
      final Paint fillPaint = Paint()
        ..shader = ui.Gradient.linear(p0, p1, inv ? <Color>[none, tint] : <Color>[tint, none]);
      canvas.drawRect(rect, fillPaint);
    }
    if (len < 1) return;
    final Offset n = Offset(-d.dy / len, d.dx / len);
    final double reach = rect.width + rect.height;
    // deux repères perpendiculaires (plein effet, effet nul) et l'axe entre les deux
    for (final Offset p in <Offset>[p0, p1]) {
      _both(canvas, Path()..moveTo(p.dx - n.dx * reach, p.dy - n.dy * reach)..lineTo(p.dx + n.dx * reach, p.dy + n.dy * reach));
    }
    _both(canvas, Path()..moveTo(p0.dx, p0.dy)..lineTo(p1.dx, p1.dy));
    _handle(canvas, p0, main: true);
    _handle(canvas, p1);
  }

  void _paintRadial(Canvas canvas, Map<String, dynamic> c, Color tint, Color none) {
    final Offset centre = _px(_d(c, 'x0', 0.5), _d(c, 'y0', 0.5));
    final double long = math.max(rect.width, rect.height);
    final double rx = _d(c, 'rx', 0.2) * long, ry = _d(c, 'ry', 0.2) * long;
    final double th = _d(c, 'angle', 0) * math.pi / 180;
    final double inner = 1 - _d(c, 'feather', 0.5).clamp(0.0, 1.0);
    if (showArea) {
      // dégradé circulaire de rayon 1, étiré en ellipse par la matrice : plein à l'intérieur, nul à partir du bord
      final Float64List m = Float64List.fromList(<double>[
        math.cos(th) * rx, math.sin(th) * rx, 0, 0,
        -math.sin(th) * ry, math.cos(th) * ry, 0, 0,
        0, 0, 1, 0,
        centre.dx, centre.dy, 0, 1,
      ]);
      final Paint fillPaint = Paint()
        ..shader = ui.Gradient.radial(
          Offset.zero,
          1,
          invert ? <Color>[none, none, tint] : <Color>[tint, tint, none],
          <double>[0, inner.clamp(0.0, 0.999).toDouble(), 1],
          TileMode.clamp,
          m,
        );
      canvas.drawRect(rect, fillPaint);
    }
    canvas.save();
    canvas.translate(centre.dx, centre.dy);
    canvas.rotate(th);
    final Path outer = Path()..addOval(Rect.fromLTRB(-rx, -ry, rx, ry));
    _both(canvas, outer);
    if (inner > 0.05) {
      final Path soft = Path()..addOval(Rect.fromLTRB(-rx * inner, -ry * inner, rx * inner, ry * inner));
      canvas.drawPath(soft, Paint()
        ..color = const Color(0x88FFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5);
    }
    _handle(canvas, Offset(rx, 0));
    _handle(canvas, Offset(0, ry));
    canvas.restore();
    _handle(canvas, centre, main: true);
  }

  @override
  bool shouldRepaint(_MaskPainter old) => true;
}
