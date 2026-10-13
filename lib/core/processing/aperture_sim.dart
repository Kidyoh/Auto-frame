import 'dart:math' as math;
import 'dart:typed_data';

import '../color/af_log.dart';
import '../color/color_math.dart';
import '../composition/geometry.dart';
import 'planes.dart';

/// Synthetic aperture: re-renders a photo as if shot at a different f-stop.
///
/// Phone lenses have a fixed aperture, so depth of field is simulated:
/// a subject mask (person segmentation or detected subject boxes) defines
/// the focal plane, a depth proxy grows blur with distance from the subject,
/// and the background is blurred in linear light with highlight expansion so
/// specular points bloom into bokeh balls rather than smearing.
class ApertureSimulator {
  const ApertureSimulator({this.maxBlurFraction = 0.022, this.levels = 4});

  /// Blur radius at f/1.4 as a fraction of the long side.
  final double maxBlurFraction;

  /// Number of discrete blur layers interpolated between.
  final int levels;

  static const List<double> standardStops = [1.4, 2.0, 2.8, 4.0, 5.6, 8.0, 11.0, 16.0];

  /// Relative blur strength for [fNumber]: 1 at f/1.4, ~0 by f/16.
  static double strengthFor(double fNumber) {
    const wide = 1.4, closed = 16.0;
    final s = (1 / fNumber - 1 / closed) / (1 / wide - 1 / closed);
    return clamp01(s);
  }

  /// Render [image] at [fNumber]. [mask] is subject probability (0..1) at
  /// [maskWidth] x [maskHeight]; any resolution is accepted.
  RgbPlanes render(
    RgbPlanes image, {
    required Float32List mask,
    required int maskWidth,
    required int maskHeight,
    required double fNumber,
  }) {
    final w = image.width, h = image.height;
    final strength = strengthFor(fNumber);
    if (strength <= 0.01) return image.clone();

    final longSide = math.max(w, h);
    final maxRadius = longSide * maxBlurFraction * strength;

    // Blur work happens at reduced resolution — a blurred background has no
    // high frequencies to lose.
    final ds = longSide > 3000 ? 4 : (longSide > 1200 ? 2 : 1);
    final bw = (w / ds).ceil(), bh = (h / ds).ceil();
    final small = image.resize(bw, bh);

    final m = Float32List(bw * bh);
    resizePlane(mask, maskWidth, maskHeight, m, bw, bh);
    // Feather the mask edge slightly to avoid cut-out look.
    gaussianBlur(m, bw, bh, math.max(1.0, longSide / ds * 0.002));

    // Depth proxy: far from subject => deeper. Plus a gentle "top is far"
    // prior common to most photos.
    final near = Float32List.fromList(m);
    gaussianBlur(near, bw, bh, math.max(2.0, longSide / ds * 0.08));
    var nearMax = 1e-6;
    for (final v in near) {
      if (v > nearMax) nearMax = v;
    }
    final coc = Float32List(bw * bh);
    for (var y = 0; y < bh; y++) {
      final vertical = 1 - 0.25 * (y / bh);
      for (var x = 0; x < bw; x++) {
        final i = y * bw + x;
        final depth = 1 - near[i] / nearMax;
        final background = 1 - m[i];
        coc[i] = clamp01(smoothstep(0.0, 0.5, background) * (0.55 + 0.45 * depth) * vertical);
      }
    }

    // Linear light with highlight expansion for bokeh.
    List<Float32List> lin(RgbPlanes p) => [
      for (final ch in [p.r, p.g, p.b])
        Float32List.fromList([for (final v in ch) AfLog.expandHighlights(srgbToLinear(v))]),
    ];
    final linSmall = lin(small);

    // Subject-excluded weights stop the subject's colour bleeding into the
    // blurred background (the classic portrait-mode halo).
    final bgWeight = Float32List(bw * bh);
    for (var i = 0; i < bgWeight.length; i++) {
      bgWeight[i] = 1 - m[i] * 0.98;
    }

    final layerRadii = [
      for (var l = 1; l <= levels; l++) maxRadius / ds * l / levels,
    ];
    final layers = <List<Float32List>>[];
    for (final r in layerRadii) {
      final wgt = Float32List.fromList(bgWeight);
      _discBlur(wgt, bw, bh, r);
      final chans = <Float32List>[];
      for (final ch in linSmall) {
        final p = Float32List(ch.length);
        for (var i = 0; i < p.length; i++) {
          p[i] = ch[i] * bgWeight[i];
        }
        _discBlur(p, bw, bh, r);
        for (var i = 0; i < p.length; i++) {
          p[i] = wgt[i] > 1e-4 ? p[i] / wgt[i] : ch[i];
        }
        chans.add(p);
      }
      layers.add(chans);
    }

    // Composite at full resolution, sampling the low-res blur layers
    // bilinearly on the fly (keeps memory to a few small planes).
    final out = RgbPlanes(w, h);
    final src = [image.r, image.g, image.b];
    final dst = [out.r, out.g, out.b];
    final fx = bw / w, fy = bh / h;
    for (var y = 0; y < h; y++) {
      final sy = ((y + 0.5) * fy - 0.5).clamp(0.0, bh - 1.0);
      final y0 = sy.floor(), y1 = math.min(y0 + 1, bh - 1);
      final ty = sy - y0;
      for (var x = 0; x < w; x++) {
        final sx = ((x + 0.5) * fx - 0.5).clamp(0.0, bw - 1.0);
        final x0 = sx.floor(), x1 = math.min(x0 + 1, bw - 1);
        final tx = sx - x0;
        final i00 = y0 * bw + x0, i10 = y0 * bw + x1;
        final i01 = y1 * bw + x0, i11 = y1 * bw + x1;
        double bilerp(Float32List p) {
          final top = p[i00] + (p[i10] - p[i00]) * tx;
          final bot = p[i01] + (p[i11] - p[i01]) * tx;
          return top + (bot - top) * ty;
        }

        final i = y * w + x;
        final t = bilerp(coc) * levels; // 0..levels
        final li = t.floor().clamp(0, levels - 1);
        final f = t - li;
        final subject = clamp01(bilerp(m) * 1.2);
        for (var c = 0; c < 3; c++) {
          final hi = bilerp(layers[li][c]);
          final double blurred;
          if (li == 0) {
            final sharpLin = AfLog.expandHighlights(srgbToLinear(src[c][i]));
            blurred = mix(sharpLin, hi, clamp01(t));
          } else {
            blurred = mix(bilerp(layers[li - 1][c]), hi, f);
          }
          final v = linearToSrgb(AfLog.compressHighlights(blurred));
          // Keep the in-focus subject pixel-perfect.
          dst[c][i] = mix(v, src[c][i], subject);
        }
      }
    }
    return out;
  }

  /// Flat-topped blur that approximates a circular aperture: two box passes
  /// give a trapezoidal kernel, closer to a disc than a Gaussian.
  void _discBlur(Float32List p, int w, int h, double radius) {
    final r = radius.round();
    if (r < 1) return;
    final r1 = math.max(1, (r * 0.75).round());
    final r2 = math.max(1, (r * 0.45).round());
    boxBlur(p, w, h, r1);
    boxBlur(p, w, h, r2);
  }

  /// Soft elliptical mask from subject boxes (used when person segmentation
  /// is unavailable). Boxes are in pixel coordinates of a [w] x [h] image;
  /// the mask is produced at the same size, or downscaled by [scale].
  static ({Float32List mask, int width, int height}) maskFromBoxes(
    List<Box> boxes,
    int w,
    int h, {
    int maxSide = 256,
  }) {
    final s = math.min(1.0, maxSide / math.max(w, h));
    final mw = math.max(1, (w * s).round()), mh = math.max(1, (h * s).round());
    final mask = Float32List(mw * mh);
    for (final b in boxes) {
      final cx = b.cx * s, cy = b.cy * s;
      final rx = math.max(1.0, b.width * s * 0.58), ry = math.max(1.0, b.height * s * 0.6);
      for (var y = 0; y < mh; y++) {
        for (var x = 0; x < mw; x++) {
          final dx = (x + 0.5 - cx) / rx, dy = (y + 0.5 - cy) / ry;
          final d = math.sqrt(dx * dx + dy * dy);
          final v = 1 - smoothstep(0.75, 1.05, d);
          final i = y * mw + x;
          if (v > mask[i]) mask[i] = v;
        }
      }
    }
    return (mask: mask, width: mw, height: mh);
  }
}
