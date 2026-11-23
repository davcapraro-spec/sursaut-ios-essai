import 'package:flutter/material.dart';

import '../../domain/histogram.dart';

/// Petit histogramme translucide posé sur la photo : rouge, vert, bleu superposés ou luminosité seule,
/// avec deux triangles d'alerte (ombres bouchées à gauche, hautes lumières brûlées à droite).
class HistogramView extends StatelessWidget {
  const HistogramView({
    super.key,
    required this.data,
    required this.luminosity,
    required this.onMode,
    required this.onHide,
  });

  final Histogram? data;

  /// Vrai : luminosité seule ; faux : rouge, vert, bleu.
  final bool luminosity;
  final ValueChanged<bool> onMode;
  final VoidCallback onHide;

  static const Color _alert = Color(0xFFFF6B5E);
  static const Color _idle = Color(0xFF5A5A5E);

  Widget _tri(bool on, String tip) => Tooltip(
        message: tip,
        child: CustomPaint(size: const Size(10, 7), painter: _TrianglePainter(on ? _alert : _idle)),
      );

  Widget _mode(String label, bool lum) {
    final bool on = luminosity == lum;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onMode(lum),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: on ? const Color(0x29FFFFFF) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(label, style: TextStyle(fontSize: 11, color: on ? Colors.white : const Color(0xFFA8A8AD))),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Histogram? h = data;
    return Container(
      width: 148,
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
      decoration: BoxDecoration(
        color: const Color(0xA0141416),
        border: Border.all(color: const Color(0x24FFFFFF), width: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            height: 52,
            width: double.infinity,
            child: CustomPaint(painter: _HistogramPainter(h, luminosity)),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              _tri(h?.shadowsClipped ?? false, 'Ombres bouchées'),
              Row(mainAxisSize: MainAxisSize.min, children: <Widget>[_mode('RVB', false), _mode('Lum.', true)]),
              _tri(h?.highlightsClipped ?? false, 'Hautes lumières brûlées'),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onHide,
              child: const Padding(
                padding: EdgeInsets.fromLTRB(10, 2, 0, 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.visibility_off_outlined, size: 13, color: Color(0xFFA8A8AD)),
                    SizedBox(width: 4),
                    Text('Masquer', style: TextStyle(fontSize: 11, color: Color(0xFFA8A8AD))),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Pastille qui remplace l'histogramme quand il est masqué.
class HistogramChip extends StatelessWidget {
  const HistogramChip({super.key, required this.onShow});

  final VoidCallback onShow;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Afficher l\'histogramme',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onShow,
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: const Color(0xA0141416),
            border: Border.all(color: const Color(0x24FFFFFF), width: 0.5),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(Icons.bar_chart, size: 18, color: Color(0xFFC8C8CC)),
        ),
      ),
    );
  }
}

class _TrianglePainter extends CustomPainter {
  _TrianglePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Path p = Path()
      ..moveTo(size.width / 2, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(p, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _TrianglePainter old) => old.color != color;
}

class _HistogramPainter extends CustomPainter {
  _HistogramPainter(this.data, this.luminosity);

  final Histogram? data;
  final bool luminosity;

  void _fill(Canvas canvas, Size size, List<int> bins, Color color, double ref, {BlendMode mode = BlendMode.srcOver}) {
    final List<double> c = Histogram.curve(bins, ref);
    final Path p = Path()..moveTo(0, size.height);
    for (int i = 0; i < 256; i++) {
      p.lineTo(size.width * i / 255, size.height - c[i] * size.height * 0.96);
    }
    p
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(p, Paint()..color = color..blendMode = mode);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final Paint grid = Paint()
      ..color = const Color(0x1AFFFFFF)
      ..strokeWidth = 0.5;
    for (int k = 1; k < 4; k++) {
      final double x = size.width * k / 4;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    final Histogram? h = data;
    if (h == null || h.count == 0) return;
    canvas.saveLayer(Offset.zero & size, Paint());
    if (luminosity) {
      _fill(canvas, size, h.l, const Color(0xCCE8E8EA), Histogram.reference(h.l));
    } else {
      final double ref = <double>[Histogram.reference(h.r), Histogram.reference(h.g), Histogram.reference(h.b)]
          .reduce((double a, double b) => a > b ? a : b);
      _fill(canvas, size, h.r, const Color(0xCCFF4D4D), ref, mode: BlendMode.plus);
      _fill(canvas, size, h.g, const Color(0xCC3DDC6A), ref, mode: BlendMode.plus);
      _fill(canvas, size, h.b, const Color(0xCC4D7DFF), ref, mode: BlendMode.plus);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _HistogramPainter old) => old.data != data || old.luminosity != luminosity;
}
