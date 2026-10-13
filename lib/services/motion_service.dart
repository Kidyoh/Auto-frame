import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// Device attitude for the horizon level, derived from gravity.
class Attitude {
  const Attitude({required this.roll, required this.pitch, required this.quadrant});

  /// Tilt (degrees) relative to the nearest upright/landscape orientation.
  /// Positive = device rotated clockwise.
  final double roll;

  /// Forward/back tilt in degrees; near ±90 the phone faces up/down and the
  /// horizon is undefined.
  final double pitch;

  /// Device orientation in quarter turns (0 = portrait, 1 = landscape right...).
  final int quadrant;

  /// How the horizon appears tilted in the captured photo (clockwise
  /// positive). Fed to the composition engine for straightening.
  double get horizonTilt => -roll;

  bool get isReliable => pitch.abs() < 60;

  bool get isLevel => isReliable && roll.abs() < 1.0;

  static const zero = Attitude(roll: 0, pitch: 0, quadrant: 0);
}

class MotionService extends ValueNotifier<Attitude> {
  MotionService() : super(Attitude.zero);

  StreamSubscription<AccelerometerEvent>? _sub;
  double _gx = 0, _gy = 9.81, _gz = 0;

  void start() {
    _sub ??= accelerometerEventStream(samplingPeriod: SensorInterval.uiInterval).listen(
      _onEvent,
      onError: (Object e) => debugPrint('Accelerometer unavailable: $e'),
      cancelOnError: true,
    );
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
  }

  void _onEvent(AccelerometerEvent e) {
    // Low-pass filter to isolate gravity from hand shake.
    const k = 0.15;
    _gx += (e.x - _gx) * k;
    _gy += (e.y - _gy) * k;
    _gz += (e.z - _gz) * k;
    value = attitudeFromGravity(_gx, _gy, _gz);
  }

  /// Pure function for testing: gravity vector (device axes, Android
  /// convention: upright portrait reads y ≈ +9.81) -> attitude.
  static Attitude attitudeFromGravity(double x, double y, double z) {
    final g = math.sqrt(x * x + y * y + z * z);
    if (g < 1e-3) return Attitude.zero;
    final rotation = math.atan2(-x, y) * 180 / math.pi; // device clockwise
    final quadrant = ((rotation / 90).round()) % 4;
    final roll = rotation - 90 * (rotation / 90).round();
    final pitch = math.asin((z / g).clamp(-1.0, 1.0)) * 180 / math.pi;
    return Attitude(roll: roll, pitch: pitch, quadrant: quadrant < 0 ? quadrant + 4 : quadrant);
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
