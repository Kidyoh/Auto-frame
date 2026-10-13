import 'dart:math' as math;
import 'dart:typed_data';

import 'planes.dart';

/// Merges an exposure bracket into a single, detailed, natural-looking image.
///
/// * Alignment: Ward's Median Threshold Bitmap (MTB) — robust to exposure
///   differences, fixes handheld shake between frames.
/// * Fusion: Mertens–Kautz–Van Reeth exposure fusion with Laplacian pyramid
///   blending — no tone-mapping halos, no radiance map needed.
class ExposureFusion {
  const ExposureFusion({
    this.contrastWeight = 1.0,
    this.saturationWeight = 1.0,
    this.exposureWeight = 1.0,
    this.sigma = 0.2,
    this.alignLevels = 5,
    this.maxAlignShift = 64,
  });

  final double contrastWeight;
  final double saturationWeight;
  final double exposureWeight;
  final double sigma;
  final int alignLevels;
  final int maxAlignShift;

  /// Fuse [frames] (all the same size). The first frame is the alignment
  /// reference; pass the normally exposed shot first for best results.
  RgbPlanes fuse(List<RgbPlanes> frames, {bool align = true}) {
    if (frames.isEmpty) throw ArgumentError('No frames to fuse');
    if (frames.length == 1) return frames.first.clone();
    final w = frames.first.width, h = frames.first.height;
    for (final f in frames) {
      if (f.width != w || f.height != h) {
        throw ArgumentError('All bracket frames must share dimensions');
      }
    }

    final aligned = <RgbPlanes>[frames.first];
    if (align) {
      final refLum = frames.first.luminance();
      for (var k = 1; k < frames.length; k++) {
        final (dx, dy) = estimateShift(refLum, frames[k].luminance(), w, h);
        aligned.add(dx == 0 && dy == 0 ? frames[k] : _translate(frames[k], dx, dy));
      }
    } else {
      aligned.addAll(frames.skip(1));
    }

    // Per-pixel quality weights, normalised across the stack.
    final weights = [for (final f in aligned) _qualityWeights(f)];
    final n = w * h;
    for (var i = 0; i < n; i++) {
      var sum = 0.0;
      for (final wk in weights) {
        sum += wk[i];
      }
      if (sum <= 0) {
        for (final wk in weights) {
          wk[i] = 1 / weights.length;
        }
      } else {
        for (final wk in weights) {
          wk[i] /= sum;
        }
      }
    }

    final levels = math.max(1, (math.log(math.min(w, h)) / math.ln2).floor() - 3);
    final weightPyramids = [for (final wk in weights) _gaussianPyramid(wk, w, h, levels)];

    final out = RgbPlanes(w, h);
    for (var c = 0; c < 3; c++) {
      List<_Level>? blended;
      for (var k = 0; k < aligned.length; k++) {
        final plane = switch (c) { 0 => aligned[k].r, 1 => aligned[k].g, _ => aligned[k].b };
        final lap = _laplacianPyramid(plane, w, h, levels);
        final gw = weightPyramids[k];
        if (blended == null) {
          blended = [
            for (var l = 0; l < levels; l++)
              _Level(Float32List(lap[l].data.length), lap[l].w, lap[l].h),
          ];
        }
        for (var l = 0; l < levels; l++) {
          final dst = blended[l].data, ld = lap[l].data, wd = gw[l].data;
          for (var i = 0; i < dst.length; i++) {
            dst[i] += ld[i] * wd[i];
          }
        }
      }
      final collapsed = _collapse(blended!);
      final target = switch (c) { 0 => out.r, 1 => out.g, _ => out.b };
      for (var i = 0; i < n; i++) {
        final v = collapsed[i];
        target[i] = v < 0 ? 0 : (v > 1 ? 1 : v);
      }
    }
    return out;
  }

  // --- MTB alignment ----------------------------------------------------

  /// Integer (dx, dy) that best aligns [moving] to [reference].
  (int, int) estimateShift(Float32List reference, Float32List moving, int w, int h) {
    final maxLevels = math.max(
      0,
      math.min(alignLevels, (math.log(maxAlignShift) / math.ln2).floor()),
    );
    var refPyr = <_Level>[_Level(reference, w, h)];
    var movPyr = <_Level>[_Level(moving, w, h)];
    for (var l = 0; l < maxLevels; l++) {
      final r = refPyr.last, m = movPyr.last;
      if (math.min(r.w, r.h) < 16) break;
      refPyr.add(_halve(r));
      movPyr.add(_halve(m));
    }

    var sx = 0, sy = 0;
    for (var l = refPyr.length - 1; l >= 0; l--) {
      sx *= 2;
      sy *= 2;
      final r = refPyr[l], m = movPyr[l];
      final (rb, re) = _mtb(r);
      final (mb, me) = _mtb(m);
      // Start from the centre so ties (featureless regions) don't drift.
      var bestErr = _xorError(rb, re, mb, me, r.w, r.h, sx, sy);
      var bx = sx, by = sy;
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final err = _xorError(rb, re, mb, me, r.w, r.h, sx + dx, sy + dy);
          if (err < bestErr - 1e-9) {
            bestErr = err;
            bx = sx + dx;
            by = sy + dy;
          }
        }
      }
      sx = bx;
      sy = by;
    }
    return (sx, sy);
  }

  (Uint8List, Uint8List) _mtb(_Level l) {
    final sorted = Float32List.fromList(l.data)..sort();
    final n = sorted.length;
    final median = sorted[n ~/ 2];
    // Ward's +-4/255 noise band, narrowed for low-contrast (dark) frames so
    // enough pixels survive to vote.
    var tol = 4 / 255;
    final spread = sorted[(n * 0.6).floor()] - sorted[(n * 0.4).floor()];
    if (spread < tol * 4) tol = math.max(spread / 4, 1e-4);
    final bits = Uint8List(n);
    final excl = Uint8List(n);
    for (var i = 0; i < n; i++) {
      final v = l.data[i];
      bits[i] = v > median ? 1 : 0;
      excl[i] = (v - median).abs() > tol ? 1 : 0;
    }
    return (bits, excl);
  }

  /// Fraction of mismatched, non-excluded pixels when [mb] is sampled at
  /// (x + dx, y + dy). Normalised by overlap so large shifts aren't favoured.
  double _xorError(
    Uint8List rb,
    Uint8List re,
    Uint8List mb,
    Uint8List me,
    int w,
    int h,
    int dx,
    int dy,
  ) {
    var err = 0;
    var count = 0;
    final x0 = math.max(0, -dx), x1 = math.min(w, w - dx);
    final y0 = math.max(0, -dy), y1 = math.min(h, h - dy);
    for (var y = y0; y < y1; y++) {
      final ri = y * w, mi = (y + dy) * w + dx;
      for (var x = x0; x < x1; x++) {
        final a = ri + x, b = mi + x;
        if ((re[a] & me[b]) == 1) {
          count++;
          if (rb[a] != mb[b]) err++;
        }
      }
    }
    return count == 0 ? 1.0 : err / count;
  }

  _Level _halve(_Level l) {
    final nw = math.max(1, l.w ~/ 2), nh = math.max(1, l.h ~/ 2);
    final out = Float32List(nw * nh);
    resizePlane(l.data, l.w, l.h, out, nw, nh);
    return _Level(out, nw, nh);
  }

  /// Sample [src] at (x + dx, y + dy), clamping at the borders.
  RgbPlanes _translate(RgbPlanes src, int dx, int dy) {
    final w = src.width, h = src.height;
    final out = RgbPlanes(w, h);
    for (var y = 0; y < h; y++) {
      final sy = (y + dy).clamp(0, h - 1);
      for (var x = 0; x < w; x++) {
        final sx = (x + dx).clamp(0, w - 1);
        final i = y * w + x, j = sy * w + sx;
        out.r[i] = src.r[j];
        out.g[i] = src.g[j];
        out.b[i] = src.b[j];
      }
    }
    return out;
  }

  // --- Mertens weights --------------------------------------------------

  Float32List _qualityWeights(RgbPlanes f) {
    final w = f.width, h = f.height;
    final lum = f.luminance();
    final out = Float32List(w * h);
    final twoSigma2 = 2 * sigma * sigma;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = y * w + x;
        // Contrast: |discrete Laplacian| of luminance.
        final c = lum[i];
        final up = lum[(y > 0 ? y - 1 : y) * w + x];
        final dn = lum[(y < h - 1 ? y + 1 : y) * w + x];
        final lf = lum[y * w + (x > 0 ? x - 1 : x)];
        final rt = lum[y * w + (x < w - 1 ? x + 1 : x)];
        final contrast = (up + dn + lf + rt - 4 * c).abs();
        // Saturation: std-dev across channels.
        final r = f.r[i], g = f.g[i], b = f.b[i];
        final mu = (r + g + b) / 3;
        final sat = math.sqrt(((r - mu) * (r - mu) + (g - mu) * (g - mu) + (b - mu) * (b - mu)) / 3);
        // Well-exposedness: closeness of each channel to mid-grey.
        final we = math.exp(
          -((r - 0.5) * (r - 0.5) + (g - 0.5) * (g - 0.5) + (b - 0.5) * (b - 0.5)) / twoSigma2,
        );
        out[i] = math.pow(contrast + 1e-3, contrastWeight).toDouble() *
                math.pow(sat + 1e-3, saturationWeight).toDouble() *
                math.pow(we, exposureWeight).toDouble() +
            1e-12;
      }
    }
    return out;
  }

  // --- Pyramids ---------------------------------------------------------

  static const _k = [1 / 16, 4 / 16, 6 / 16, 4 / 16, 1 / 16];

  /// 5-tap binomial blur followed by 2x decimation.
  _Level _pyrDown(_Level l) {
    final w = l.w, h = l.h;
    final nw = (w + 1) ~/ 2, nh = (h + 1) ~/ 2;
    final tmp = Float32List(nw * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < nw; x++) {
        var s = 0.0;
        for (var k = -2; k <= 2; k++) {
          final sx = (2 * x + k).clamp(0, w - 1);
          s += l.data[y * w + sx] * _k[k + 2];
        }
        tmp[y * nw + x] = s;
      }
    }
    final out = Float32List(nw * nh);
    for (var y = 0; y < nh; y++) {
      for (var x = 0; x < nw; x++) {
        var s = 0.0;
        for (var k = -2; k <= 2; k++) {
          final sy = (2 * y + k).clamp(0, h - 1);
          s += tmp[sy * nw + x] * _k[k + 2];
        }
        out[y * nw + x] = s;
      }
    }
    return _Level(out, nw, nh);
  }

  /// Zero-insertion upsample to (tw, th) followed by the same kernel x2.
  Float32List _pyrUp(_Level l, int tw, int th) {
    final tmp = Float32List(tw * l.h);
    for (var y = 0; y < l.h; y++) {
      for (var x = 0; x < tw; x++) {
        var s = 0.0;
        for (var k = -2; k <= 2; k++) {
          final px = x + k;
          if (px.isOdd) continue;
          final sx = (px ~/ 2).clamp(0, l.w - 1);
          s += l.data[y * l.w + sx] * _k[k + 2] * 2;
        }
        tmp[y * tw + x] = s;
      }
    }
    final out = Float32List(tw * th);
    for (var y = 0; y < th; y++) {
      for (var x = 0; x < tw; x++) {
        var s = 0.0;
        for (var k = -2; k <= 2; k++) {
          final py = y + k;
          if (py.isOdd) continue;
          final sy = (py ~/ 2).clamp(0, l.h - 1);
          s += tmp[sy * tw + x] * _k[k + 2] * 2;
        }
        out[y * tw + x] = s;
      }
    }
    return out;
  }

  List<_Level> _gaussianPyramid(Float32List p, int w, int h, int levels) {
    final pyr = <_Level>[_Level(p, w, h)];
    for (var l = 1; l < levels; l++) {
      pyr.add(_pyrDown(pyr.last));
    }
    return pyr;
  }

  List<_Level> _laplacianPyramid(Float32List p, int w, int h, int levels) {
    final g = _gaussianPyramid(p, w, h, levels);
    final out = <_Level>[];
    for (var l = 0; l < levels - 1; l++) {
      final up = _pyrUp(g[l + 1], g[l].w, g[l].h);
      final d = Float32List(g[l].data.length);
      for (var i = 0; i < d.length; i++) {
        d[i] = g[l].data[i] - up[i];
      }
      out.add(_Level(d, g[l].w, g[l].h));
    }
    out.add(g.last);
    return out;
  }

  Float32List _collapse(List<_Level> pyr) {
    var cur = pyr.last;
    for (var l = pyr.length - 2; l >= 0; l--) {
      final up = _pyrUp(cur, pyr[l].w, pyr[l].h);
      final d = pyr[l].data;
      for (var i = 0; i < up.length; i++) {
        up[i] += d[i];
      }
      cur = _Level(up, pyr[l].w, pyr[l].h);
    }
    return cur.data;
  }
}

class _Level {
  _Level(this.data, this.w, this.h);

  final Float32List data;
  final int w;
  final int h;
}
