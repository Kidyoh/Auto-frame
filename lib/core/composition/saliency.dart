import 'dart:math' as math;
import 'dart:typed_data';

import '../color/color_math.dart';
import '../processing/planes.dart';
import 'geometry.dart';
import 'subject.dart';

/// Frequency-tuned salient region detection (Achanta et al., 2009) with a
/// mild centre prior. Finds "the interesting thing" when no face or object
/// detector fires: a lone tree, a sunset, a cup of coffee.
class SaliencyDetector {
  const SaliencyDetector({this.workingSize = 96});

  final int workingSize;

  /// Returns a saliency map (0..1) at the downscaled working resolution.
  ({Float32List map, int width, int height}) computeMap(RgbPlanes image) {
    final small = image.downscale(workingSize);
    final w = small.width, h = small.height, n = w * h;
    final l = Float32List(n), a = Float32List(n), bb = Float32List(n);
    for (var i = 0; i < n; i++) {
      final lab = _srgbToLab(small.r[i], small.g[i], small.b[i]);
      l[i] = lab.$1;
      a[i] = lab.$2;
      bb[i] = lab.$3;
    }
    double mean(Float32List p) {
      var s = 0.0;
      for (final v in p) {
        s += v;
      }
      return s / p.length;
    }

    final ml = mean(l), ma = mean(a), mb = mean(bb);
    final sigma = math.max(w, h) / 64;
    gaussianBlur(l, w, h, math.max(sigma, 0.8));
    gaussianBlur(a, w, h, math.max(sigma, 0.8));
    gaussianBlur(bb, w, h, math.max(sigma, 0.8));

    final map = Float32List(n);
    var maxV = 1e-6;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = y * w + x;
        final dl = l[i] - ml, da = a[i] - ma, db = bb[i] - mb;
        final dx = (x / w - 0.5), dy = (y / h - 0.5);
        final centre = 0.6 + 0.4 * math.exp(-(dx * dx + dy * dy) / 0.18);
        final v = math.sqrt(dl * dl + da * da + db * db) * centre;
        map[i] = v;
        if (v > maxV) maxV = v;
      }
    }
    for (var i = 0; i < n; i++) {
      map[i] /= maxV;
    }
    return (map: map, width: w, height: h);
  }

  /// The dominant salient region as a [Subject] in source pixel coordinates,
  /// or null if the image is uniformly boring.
  Subject? detect(RgbPlanes image) {
    final (:map, :width, :height) = computeMap(image);
    var mean = 0.0;
    for (final v in map) {
      mean += v;
    }
    mean /= map.length;
    final threshold = math.max(mean * 2.0, 0.35);

    // Weighted percentiles of salient pixels -> robust bounding box.
    final xs = <(double, double)>[], ys = <(double, double)>[];
    var total = 0.0;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final v = map[y * width + x];
        if (v < threshold) continue;
        xs.add((x + 0.5, v));
        ys.add((y + 0.5, v));
        total += v;
      }
    }
    if (xs.length < 3 || total <= 0) return null;
    // Uniform images light up everywhere; that is not a subject.
    if (xs.length > map.length * 0.6) return null;

    double pct(List<(double, double)> vals, double q) {
      vals.sort((p, q) => p.$1.compareTo(q.$1));
      final target = total * q;
      var acc = 0.0;
      for (final (pos, wgt) in vals) {
        acc += wgt;
        if (acc >= target) return pos;
      }
      return vals.last.$1;
    }

    final x0 = pct(xs, 0.08), x1 = pct(xs, 0.92);
    final y0 = pct(ys, 0.08), y1 = pct(ys, 0.92);
    final sx = image.width / width, sy = image.height / height;
    final box = Box.fromLTRB((x0 - 0.5) * sx, (y0 - 0.5) * sy, (x1 + 0.5) * sx, (y1 + 0.5) * sy);
    return Subject(box: box, kind: SubjectKind.salient, weight: 0.8, label: 'Salient');
  }

  static (double, double, double) _srgbToLab(double r, double g, double b) {
    final lr = srgbToLinear(r), lg = srgbToLinear(g), lb = srgbToLinear(b);
    // sRGB D65 -> XYZ.
    final x = (0.4124 * lr + 0.3576 * lg + 0.1805 * lb) / 0.95047;
    final y = 0.2126 * lr + 0.7152 * lg + 0.0722 * lb;
    final z = (0.0193 * lr + 0.1192 * lg + 0.9505 * lb) / 1.08883;
    double f(double t) => t > 0.008856 ? math.pow(t, 1 / 3).toDouble() : 7.787 * t + 16 / 116;
    final fx = f(x), fy = f(y), fz = f(z);
    return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz));
  }
}
