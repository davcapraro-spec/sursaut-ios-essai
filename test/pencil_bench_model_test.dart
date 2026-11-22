import 'package:flutter_test/flutter_test.dart';

import 'package:sursaut_essai/features/diagnostics/pencil_bench/pencil_bench_model.dart';

void main() {
  test('StatRange garde min, max et dernière valeur', () {
    final StatRange r = StatRange();
    expect(r.describe(), '—');
    r.add(0.5);
    r.add(0.2);
    r.add(0.9);
    r.add(null);
    expect(r.min, 0.2);
    expect(r.max, 0.9);
    expect(r.last, 0.9);
    expect(r.count, 3);
  });

  test('le modèle compte les contacts et convertit les angles', () {
    final PencilBenchModel m = PencilBenchModel();
    m.addFlutter(
      kind: 'stylet',
      phase: 'down',
      pressure: 0.4,
      pressureMax: 4,
      tiltRad: 3.141592653589793 / 4,
      orientationRad: 0,
      micros: 0,
    );
    m.addNative('touch', <String, Object?>{
      'force': 1.0,
      'roll': 3.141592653589793,
      'rollApi': true,
      'samples': 4,
    });
    m.addNative('squeeze', <String, Object?>{'phase': 'ended', 'hasPose': true});
    m.addNative('tap', <String, Object?>{});
    expect(m.flutterStylusDowns, 1);
    expect(m.flutterTiltDeg.last, closeTo(45, 0.001));
    expect(m.nativeRollDeg.last, closeTo(180, 0.001));
    expect(m.squeezeEvents, 1);
    expect(m.taps, 1);
    expect(m.report(DateTime(2026, 11, 19)), contains('BANC PENCIL'));
  });
}
