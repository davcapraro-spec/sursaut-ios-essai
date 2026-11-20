import 'dart:ui' as ui;

import 'package:flutter/material.dart';

enum _Hit { none, move, tl, tr, bl, br, left, top, right, bottom }

/// Image affichée avec un cadre de recadrage déplaçable (doigt ou Pencil).
///
/// [rect] est exprimé en fractions (0..1) de l'image affichée, comme les réglages
/// `crop_left/top/right/bottom` du moteur. [aspect] = largeur/hauteur en pixels
/// imposée, ou null pour un cadre libre.
class CropOverlay extends StatefulWidget {
  const CropOverlay({
    super.key,
    required this.image,
    required this.rect,
    required this.aspect,
    required this.onChanged,
    required this.onEnd,
  });

  final ui.Image image;
  final Rect rect;
  final double? aspect;
  final ValueChanged<Rect> onChanged;
  final VoidCallback onEnd;

  @override
  State<CropOverlay> createState() => _CropOverlayState();
}

class _CropOverlayState extends State<CropOverlay> {
  static const double _grab = 40;
  static const double _minSize = 0.04;

  _Hit _hit = _Hit.none;
  Rect _start = Rect.zero;
  Offset _acc = Offset.zero;

  Rect _fit(Size box) {
    final double iw = widget.image.width.toDouble();
    final double ih = widget.image.height.toDouble();
    final double s = (box.width / iw) < (box.height / ih) ? box.width / iw : box.height / ih;
    final double w = iw * s, h = ih * s;
    return Rect.fromLTWH((box.width - w) / 2, (box.height - h) / 2, w, h);
  }

  Rect _pixels(Rect img, Rect f) => Rect.fromLTRB(
        img.left + f.left * img.width,
        img.top + f.top * img.height,
        img.left + f.right * img.width,
        img.top + f.bottom * img.height,
      );

  _Hit _hitTest(Rect cr, Offset p) {
    bool near(Offset a) => (a - p).distance <= _grab;
    if (near(cr.topLeft)) return _Hit.tl;
    if (near(cr.topRight)) return _Hit.tr;
    if (near(cr.bottomLeft)) return _Hit.bl;
    if (near(cr.bottomRight)) return _Hit.br;
    if (widget.aspect == null) {
      final bool inX = p.dx > cr.left && p.dx < cr.right;
      final bool inY = p.dy > cr.top && p.dy < cr.bottom;
      if (inX && (p.dy - cr.top).abs() <= _grab / 2) return _Hit.top;
      if (inX && (p.dy - cr.bottom).abs() <= _grab / 2) return _Hit.bottom;
      if (inY && (p.dx - cr.left).abs() <= _grab / 2) return _Hit.left;
      if (inY && (p.dx - cr.right).abs() <= _grab / 2) return _Hit.right;
    }
    if (cr.contains(p)) return _Hit.move;
    return _Hit.none;
  }

  double _clamp(double v, double lo, double hi) => v < lo ? lo : (v > hi ? hi : v);

  Rect _compute(double dx, double dy) {
    final Rect s = _start;
    double l = s.left, t = s.top, r = s.right, b = s.bottom;
    switch (_hit) {
      case _Hit.none:
        return s;
      case _Hit.move:
        final double w = s.width, h = s.height;
        l = _clamp(s.left + dx, 0, 1 - w);
        t = _clamp(s.top + dy, 0, 1 - h);
        return Rect.fromLTWH(l, t, w, h);
      case _Hit.left:
        l = _clamp(s.left + dx, 0, r - _minSize);
      case _Hit.right:
        r = _clamp(s.right + dx, l + _minSize, 1);
      case _Hit.top:
        t = _clamp(s.top + dy, 0, b - _minSize);
      case _Hit.bottom:
        b = _clamp(s.bottom + dy, t + _minSize, 1);
      case _Hit.tl:
      case _Hit.tr:
      case _Hit.bl:
      case _Hit.br:
        final bool leftSide = _hit == _Hit.tl || _hit == _Hit.bl;
        final bool topSide = _hit == _Hit.tl || _hit == _Hit.tr;
        final double ax = leftSide ? s.right : s.left; // coin opposé, fixe
        final double ay = topSide ? s.bottom : s.top;
        double px = (leftSide ? s.left : s.right) + dx;
        double py = (topSide ? s.top : s.bottom) + dy;
        px = _clamp(px, 0, 1);
        py = _clamp(py, 0, 1);
        double fw = (px - ax).abs();
        double fh = (py - ay).abs();
        final double? a = widget.aspect;
        if (a != null) {
          // fh = fw * iw / (a * ih)
          final double k = widget.image.width / (a * widget.image.height);
          final double availX = leftSide ? ax : 1 - ax;
          final double availY = topSide ? ay : 1 - ay;
          final double maxFw = availX < availY / k ? availX : availY / k;
          fw = _clamp(fw, _minSize, maxFw);
          fh = fw * k;
        } else {
          fw = fw < _minSize ? _minSize : fw;
          fh = fh < _minSize ? _minSize : fh;
        }
        l = leftSide ? ax - fw : ax;
        r = leftSide ? ax : ax + fw;
        t = topSide ? ay - fh : ay;
        b = topSide ? ay : ay + fh;
        return Rect.fromLTRB(_clamp(l, 0, 1), _clamp(t, 0, 1), _clamp(r, 0, 1), _clamp(b, 0, 1));
    }
    return Rect.fromLTRB(l, t, r, b);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final Size box = Size(c.maxWidth, c.maxHeight);
        final Rect img = _fit(box);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (DragStartDetails d) {
            _hit = _hitTest(_pixels(img, widget.rect), d.localPosition);
            _start = widget.rect;
            _acc = Offset.zero;
          },
          onPanUpdate: (DragUpdateDetails d) {
            if (_hit == _Hit.none) return;
            _acc += d.delta;
            widget.onChanged(_compute(_acc.dx / img.width, _acc.dy / img.height));
          },
          onPanEnd: (DragEndDetails _) {
            if (_hit != _Hit.none) widget.onEnd();
            _hit = _Hit.none;
          },
          child: CustomPaint(
            size: box,
            painter: _CropPainter(widget.image, img, _pixels(img, widget.rect)),
          ),
        );
      },
    );
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter(this.image, this.img, this.crop);
  final ui.Image image;
  final Rect img;
  final Rect crop;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      img,
      Paint()..filterQuality = FilterQuality.medium,
    );
    final Paint dim = Paint()..color = const Color(0x99000000);
    canvas.drawRect(Rect.fromLTRB(img.left, img.top, img.right, crop.top), dim);
    canvas.drawRect(Rect.fromLTRB(img.left, crop.bottom, img.right, img.bottom), dim);
    canvas.drawRect(Rect.fromLTRB(img.left, crop.top, crop.left, crop.bottom), dim);
    canvas.drawRect(Rect.fromLTRB(crop.right, crop.top, img.right, crop.bottom), dim);

    final Paint line = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRect(crop, line);
    final Paint grid = Paint()
      ..color = const Color(0x66FFFFFF)
      ..strokeWidth = 1;
    for (int i = 1; i <= 2; i++) {
      final double x = crop.left + crop.width * i / 3;
      final double y = crop.top + crop.height * i / 3;
      canvas.drawLine(Offset(x, crop.top), Offset(x, crop.bottom), grid);
      canvas.drawLine(Offset(crop.left, y), Offset(crop.right, y), grid);
    }
    final Paint handle = Paint()..color = Colors.white;
    for (final Offset p in <Offset>[
      crop.topLeft, crop.topRight, crop.bottomLeft, crop.bottomRight,
    ]) {
      canvas.drawCircle(p, 9, handle);
    }
  }

  @override
  bool shouldRepaint(_CropPainter old) =>
      old.image != image || old.img != img || old.crop != crop;
}
