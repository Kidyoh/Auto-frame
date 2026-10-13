import 'dart:math' as math;
import 'dart:typed_data';

/// A monotone cubic (Fritsch–Carlson) tone curve through control points,
/// like Lightroom's point curve. Monotone interpolation never overshoots,
/// so the curve can't invert tones between points.
class ToneCurve {
  ToneCurve(List<(double, double)> points)
    : points = List.unmodifiable(([...points]..sort((a, b) => a.$1.compareTo(b.$1)))) {
    if (this.points.length < 2) {
      throw ArgumentError('A tone curve needs at least two points');
    }
  }

  static final identity = ToneCurve(const [(0, 0), (1, 1)]);

  final List<(double, double)> points;

  bool get isIdentity => points.every((p) => (p.$1 - p.$2).abs() < 1e-6);

  /// Evaluate the curve at [x] (0..1).
  double evaluate(double x) {
    final p = points;
    if (x <= p.first.$1) return p.first.$2;
    if (x >= p.last.$1) return p.last.$2;
    final m = _tangents();
    var k = 0;
    while (k < p.length - 2 && x > p[k + 1].$1) {
      k++;
    }
    final x0 = p[k].$1, x1 = p[k + 1].$1;
    final y0 = p[k].$2, y1 = p[k + 1].$2;
    final h = x1 - x0;
    final t = (x - x0) / h;
    final t2 = t * t, t3 = t2 * t;
    final h00 = 2 * t3 - 3 * t2 + 1;
    final h10 = t3 - 2 * t2 + t;
    final h01 = -2 * t3 + 3 * t2;
    final h11 = t3 - t2;
    return (h00 * y0 + h10 * h * m[k] + h01 * y1 + h11 * h * m[k + 1]).clamp(0.0, 1.0);
  }

  List<double>? _cachedTangents;

  List<double> _tangents() {
    if (_cachedTangents != null) return _cachedTangents!;
    final p = points;
    final n = p.length;
    final d = List<double>.generate(n - 1, (i) {
      final dx = p[i + 1].$1 - p[i].$1;
      return dx <= 0 ? 0 : (p[i + 1].$2 - p[i].$2) / dx;
    });
    final m = List<double>.filled(n, 0);
    m[0] = d[0];
    m[n - 1] = d[n - 2];
    for (var i = 1; i < n - 1; i++) {
      m[i] = (d[i - 1] * d[i] <= 0) ? 0 : (d[i - 1] + d[i]) / 2;
    }
    // Fritsch–Carlson monotonicity constraint.
    for (var i = 0; i < n - 1; i++) {
      if (d[i] == 0) {
        m[i] = 0;
        m[i + 1] = 0;
        continue;
      }
      final a = m[i] / d[i], b = m[i + 1] / d[i];
      final s = a * a + b * b;
      if (s > 9) {
        final t = 3 / math.sqrt(s);
        m[i] = t * a * d[i];
        m[i + 1] = t * b * d[i];
      }
    }
    return _cachedTangents = m;
  }

  /// Sampled lookup table with [size] entries.
  Float32List bake([int size = 256]) {
    final out = Float32List(size);
    for (var i = 0; i < size; i++) {
      out[i] = evaluate(i / (size - 1));
    }
    return out;
  }

  ToneCurve withPoint(int index, (double, double) p) {
    final next = [...points];
    next[index] = p;
    return ToneCurve(next);
  }

  List<List<double>> toJson() => [
    for (final p in points) [p.$1, p.$2],
  ];

  factory ToneCurve.fromJson(List<dynamic> json) => ToneCurve([
    for (final p in json) (((p as List)[0] as num).toDouble(), (p[1] as num).toDouble()),
  ]);
}
