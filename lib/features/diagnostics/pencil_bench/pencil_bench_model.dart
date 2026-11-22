import 'dart:math' as math;

/// Dernière valeur, minimum, maximum et nombre d'échantillons d'une mesure.
class StatRange {
  double? min;
  double? max;
  double? last;
  int count = 0;

  void add(double? value) {
    if (value == null || value.isNaN || value.isInfinite) return;
    last = value;
    count++;
    min = min == null ? value : math.min(min!, value);
    max = max == null ? value : math.max(max!, value);
  }

  /// « — » tant qu'aucune valeur n'est arrivée.
  String describe({int digits = 2, String unit = ''}) {
    if (count == 0) return '—';
    String f(double v) => v.toStringAsFixed(digits);
    return 'dernier ${f(last!)}$unit · min ${f(min!)}$unit · '
        'max ${f(max!)}$unit ($count)';
  }
}

/// Mesure de cadence : combien d'événements arrivent par seconde.
class RateMeter {
  final List<int> _stamps = <int>[];
  double maxPerSecond = 0;

  void tick(int micros) {
    _stamps.add(micros);
    while (_stamps.isNotEmpty && micros - _stamps.first > 1000000) {
      _stamps.removeAt(0);
    }
    if (_stamps.length > maxPerSecond) {
      maxPerSecond = _stamps.length.toDouble();
    }
  }
}

double _deg(double rad) => rad * 180 / math.pi;

/// Tout ce que mesure le Banc Pencil, sans dépendre de Flutter (testable
/// sous Windows). L'écran n'affiche que ce modèle.
class PencilBenchModel {
  // Côté Flutter (ce que reçoit déjà l'application sans code natif).
  final StatRange flutterPressure = StatRange();
  final StatRange flutterTiltDeg = StatRange();
  final StatRange flutterOrientationDeg = StatRange();
  final StatRange flutterHoverDistance = StatRange();
  final RateMeter flutterMoveRate = RateMeter();
  int flutterStylusDowns = 0;
  int flutterFingerDowns = 0;
  int flutterHoverEvents = 0;
  int palmWhileStylus = 0;
  double? flutterPressureMax;
  double? flutterDistanceMax;

  // Côté natif (Swift).
  final StatRange nativeForce = StatRange();
  final StatRange nativeAltitudeDeg = StatRange();
  final StatRange nativeAzimuthDeg = StatRange();
  final StatRange nativeRollDeg = StatRange();
  final StatRange nativeSamples = StatRange();
  final StatRange hoverZOffset = StatRange();
  final StatRange hoverAltitudeDeg = StatRange();
  final StatRange hoverAzimuthDeg = StatRange();
  final StatRange hoverRollDeg = StatRange();
  final StatRange squeezeRollDeg = StatRange();
  int nativeTouchEvents = 0;
  int nativeHoverEvents = 0;
  int squeezeEvents = 0;
  int squeezeWithPose = 0;
  int taps = 0;
  bool? rollApi;
  String lastSqueezePhase = '—';
  final List<String> infos = <String>[];
  String? bridgeError;
  Map<String, Object?> capabilities = <String, Object?>{};

  void addFlutter({
    required String kind,
    required String phase,
    double? pressure,
    double? pressureMax,
    double? tiltRad,
    double? orientationRad,
    double? distance,
    double? distanceMax,
    required int micros,
  }) {
    final bool stylus = kind == 'stylet';
    if (phase == 'down') {
      if (stylus) flutterStylusDowns++;
      if (kind == 'doigt') flutterFingerDowns++;
    }
    if (!stylus) return;
    if (phase == 'survol') {
      flutterHoverEvents++;
      flutterHoverDistance.add(distance);
      flutterDistanceMax = distanceMax;
      flutterTiltDeg.add(tiltRad == null ? null : _deg(tiltRad));
      flutterOrientationDeg
          .add(orientationRad == null ? null : _deg(orientationRad));
      return;
    }
    flutterPressure.add(pressure);
    flutterPressureMax = pressureMax;
    flutterTiltDeg.add(tiltRad == null ? null : _deg(tiltRad));
    flutterOrientationDeg
        .add(orientationRad == null ? null : _deg(orientationRad));
    if (phase == 'move') flutterMoveRate.tick(micros);
  }

  /// [type] : touch, hover, squeeze, tap ou info. Angles reçus en radians.
  void addNative(String type, Map<String, Object?> data) {
    double? n(String key) {
      final Object? v = data[key];
      return v is num ? v.toDouble() : null;
    }

    double? d(String key) {
      final double? v = n(key);
      return v == null ? null : _deg(v);
    }

    switch (type) {
      case 'touch':
        nativeTouchEvents++;
        nativeForce.add(n('force'));
        nativeAltitudeDeg.add(d('altitude'));
        nativeAzimuthDeg.add(d('azimuth'));
        nativeSamples.add(n('samples'));
        final Object? api = data['rollApi'];
        if (api is bool) rollApi = api;
        nativeRollDeg.add(d('roll'));
      case 'hover':
        nativeHoverEvents++;
        hoverZOffset.add(n('zOffset'));
        hoverAltitudeDeg.add(d('altitude'));
        hoverAzimuthDeg.add(d('azimuth'));
        hoverRollDeg.add(d('roll'));
      case 'squeeze':
        squeezeEvents++;
        lastSqueezePhase = data['phase']?.toString() ?? '—';
        if (data['hasPose'] == true) squeezeWithPose++;
        squeezeRollDeg.add(d('roll'));
      case 'tap':
        taps++;
      case 'info':
        final String? message = data['message']?.toString();
        if (message != null) infos.add(message);
    }
  }

  String _cap(String key) => capabilities[key]?.toString() ?? '—';

  /// Rapport en texte à coller dans la conversation.
  String report(DateTime now) {
    final StringBuffer b = StringBuffer()
      ..writeln('BANC PENCIL — Sursaut iPad')
      ..writeln('Date : $now')
      ..writeln('Appareil : ${_cap('machine')} · ${_cap('systemName')} '
          '${_cap('systemVersion')}')
      ..writeln('API serrage (iPadOS 17.5+) : ${_cap('squeezeApi')}')
      ..writeln('Réglage système du serrage : ${_cap('preferredSqueezeAction')}')
      ..writeln('Réglage système du double appui : '
          '${_cap('preferredTapAction')}')
      ..writeln('Pont natif : ${infos.isEmpty ? '—' : infos.last}')
      ..writeln('Erreur du pont : ${bridgeError ?? 'aucune'}')
      ..writeln()
      ..writeln('— Flutter (stylet) —')
      ..writeln('Contacts stylet : $flutterStylusDowns · doigt : '
          '$flutterFingerDowns · doigt posé pendant le stylet : '
          '$palmWhileStylus')
      ..writeln('Pression (max possible ${flutterPressureMax ?? '—'}) : '
          '${flutterPressure.describe()}')
      ..writeln('Inclinaison : ${flutterTiltDeg.describe(digits: 0, unit: '°')}')
      ..writeln('Azimut : '
          '${flutterOrientationDeg.describe(digits: 0, unit: '°')}')
      ..writeln('Survol (événements $flutterHoverEvents, distance max '
          '${flutterDistanceMax ?? '—'}) : ${flutterHoverDistance.describe()}')
      ..writeln('Cadence max au contact : '
          '${flutterMoveRate.maxPerSecond.toStringAsFixed(0)} évén./s')
      ..writeln()
      ..writeln('— Natif Swift —')
      ..writeln('Contacts natifs : $nativeTouchEvents · échantillons par '
          'événement : ${nativeSamples.describe(digits: 1)}')
      ..writeln('Force : ${nativeForce.describe()}')
      ..writeln('Altitude : ${nativeAltitudeDeg.describe(digits: 0, unit: '°')}')
      ..writeln('Azimut : ${nativeAzimuthDeg.describe(digits: 0, unit: '°')}')
      ..writeln('Roulis au contact (API présente : ${rollApi ?? '—'}) : '
          '${nativeRollDeg.describe(digits: 0, unit: '°')}')
      ..writeln('Survol natif (événements $nativeHoverEvents)')
      ..writeln('  hauteur : ${hoverZOffset.describe()}')
      ..writeln('  altitude : ${hoverAltitudeDeg.describe(digits: 0, unit: '°')}')
      ..writeln('  azimut : ${hoverAzimuthDeg.describe(digits: 0, unit: '°')}')
      ..writeln('  roulis : ${hoverRollDeg.describe(digits: 0, unit: '°')}')
      ..writeln('Serrage : $squeezeEvents événements (dernière phase '
          '$lastSqueezePhase), avec position : $squeezeWithPose, roulis : '
          '${squeezeRollDeg.describe(digits: 0, unit: '°')}')
      ..writeln('Double appui : $taps');
    return b.toString();
  }
}
