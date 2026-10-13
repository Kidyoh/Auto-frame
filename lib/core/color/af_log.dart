import 'dart:math' as math;

import 'color_math.dart';

/// AF-Log — Auto Frame's own logarithmic encoding.
///
/// A flat, grade-friendly curve that maps scene-linear light (18% grey = 0.18)
/// into a 0..1 signal:
///
///   y = A * log2(x + O) + B
///
/// * 18% grey lands at [greyCode] (0.42).
/// * Each stop above grey adds roughly [A] (0.075) of code value.
/// * Black (x = 0) sits at ~0.10, white clips ~7.8 stops over grey, giving
///   about 14 stops of latitude.
///
/// The shader (`shaders/camera_look.frag`) uses the same constants; keep the
/// two in sync.
class AfLog {
  AfLog._();

  static const double a = 0.075;
  static const double offset = 0.01;
  static const double greyCode = 0.42;
  static final double b = greyCode - a * _log2(0.18 + offset);

  /// Scene-linear -> AF-Log code value (0..1).
  static double encode(double linear) {
    final x = math.max(linear, 0.0);
    return clamp01(a * _log2(x + offset) + b);
  }

  /// AF-Log code value -> scene-linear.
  static double decode(double code) {
    return math.max(0.0, math.pow(2, (code - b) / a).toDouble() - offset);
  }

  /// Display sRGB -> AF-Log. Display highlights are expanded slightly with an
  /// inverse Reinhard-style shoulder so a phone JPEG/preview gains some
  /// pseudo scene-referred range before log encoding.
  static double fromSrgb(double srgb) {
    final lin = srgbToLinear(clamp01(srgb));
    return encode(expandHighlights(lin));
  }

  /// AF-Log -> display sRGB (the "AF-Log to Rec.709" technical transform).
  static double toSrgb(double code) {
    return linearToSrgb(clamp01(compressHighlights(decode(code))));
  }

  /// Inverse of [compressHighlights]: display-linear -> pseudo scene-linear.
  static double expandHighlights(double lin) {
    const k = 0.25;
    final l = math.min(lin, 0.995);
    return l / (1 - l * (1 - k));
  }

  /// Soft shoulder that rolls scene-linear highlights back into 0..1.
  static double compressHighlights(double x) {
    const k = 0.25;
    return x / (1 + x * (1 - k));
  }

  static double _log2(double v) => math.log(v) / math.ln2;
}
