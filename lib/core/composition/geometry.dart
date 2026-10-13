import 'dart:math' as math;

/// Axis-aligned rectangle. Units are whatever the caller uses (pixels or
/// normalised 0..1); the composition engine works in pixels internally and
/// reports normalised results.
class Box {
  const Box(this.left, this.top, this.width, this.height);

  factory Box.fromLTRB(double l, double t, double r, double b) =>
      Box(l, t, r - l, b - t);

  final double left;
  final double top;
  final double width;
  final double height;

  double get right => left + width;
  double get bottom => top + height;
  double get area => math.max(0, width) * math.max(0, height);
  double get cx => left + width / 2;
  double get cy => top + height / 2;

  Box intersect(Box o) {
    final l = math.max(left, o.left);
    final t = math.max(top, o.top);
    final r = math.min(right, o.right);
    final b = math.min(bottom, o.bottom);
    if (r <= l || b <= t) return const Box(0, 0, 0, 0);
    return Box.fromLTRB(l, t, r, b);
  }

  Box union(Box o) => Box.fromLTRB(
    math.min(left, o.left),
    math.min(top, o.top),
    math.max(right, o.right),
    math.max(bottom, o.bottom),
  );

  Box scale(double sx, double sy) =>
      Box(left * sx, top * sy, width * sx, height * sy);

  Box translate(double dx, double dy) => Box(left + dx, top + dy, width, height);

  bool containsPoint(double x, double y) =>
      x >= left && x <= right && y >= top && y <= bottom;

  @override
  String toString() =>
      'Box(${left.toStringAsFixed(3)}, ${top.toStringAsFixed(3)}, '
      '${width.toStringAsFixed(3)}x${height.toStringAsFixed(3)})';
}

/// Rotate (x, y) by [radians] around (cx, cy).
(double, double) rotatePoint(
  double x,
  double y,
  double cx,
  double cy,
  double radians,
) {
  final c = math.cos(radians), s = math.sin(radians);
  final dx = x - cx, dy = y - cy;
  return (cx + dx * c - dy * s, cy + dx * s + dy * c);
}
