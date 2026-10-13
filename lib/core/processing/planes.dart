import 'dart:math' as math;
import 'dart:typed_data';

import '../color/color_math.dart';

/// Planar float RGB image (0..1 per channel), the working format for all CPU
/// processing (HDR fusion, aperture simulation, saliency).
class RgbPlanes {
  RgbPlanes(this.width, this.height)
    : r = Float32List(width * height),
      g = Float32List(width * height),
      b = Float32List(width * height);

  RgbPlanes.from(this.width, this.height, this.r, this.g, this.b);

  final int width;
  final int height;
  final Float32List r;
  final Float32List g;
  final Float32List b;

  int get length => width * height;

  /// From interleaved RGBA8 bytes.
  factory RgbPlanes.fromRgba(Uint8List rgba, int width, int height) {
    final p = RgbPlanes(width, height);
    for (var i = 0, j = 0; i < p.length; i++, j += 4) {
      p.r[i] = rgba[j] / 255;
      p.g[i] = rgba[j + 1] / 255;
      p.b[i] = rgba[j + 2] / 255;
    }
    return p;
  }

  Uint8List toRgba() {
    final out = Uint8List(length * 4);
    for (var i = 0, j = 0; i < length; i++, j += 4) {
      out[j] = (clamp01(r[i]) * 255 + 0.5).toInt();
      out[j + 1] = (clamp01(g[i]) * 255 + 0.5).toInt();
      out[j + 2] = (clamp01(b[i]) * 255 + 0.5).toInt();
      out[j + 3] = 255;
    }
    return out;
  }

  RgbPlanes clone() => RgbPlanes.from(
    width,
    height,
    Float32List.fromList(r),
    Float32List.fromList(g),
    Float32List.fromList(b),
  );

  Float32List luminance() {
    final out = Float32List(length);
    for (var i = 0; i < length; i++) {
      out[i] = luma(r[i], g[i], b[i]);
    }
    return out;
  }

  /// Box-filtered downscale so the longest side is at most [maxSide].
  RgbPlanes downscale(int maxSide) {
    final s = math.max(width, height);
    if (s <= maxSide) return clone();
    final f = s / maxSide;
    final nw = math.max(1, (width / f).round());
    final nh = math.max(1, (height / f).round());
    return resize(nw, nh);
  }

  /// Area-average resample (good for downscaling, bilinear-ish upscaling).
  RgbPlanes resize(int nw, int nh) {
    final out = RgbPlanes(nw, nh);
    resizePlane(r, width, height, out.r, nw, nh);
    resizePlane(g, width, height, out.g, nw, nh);
    resizePlane(b, width, height, out.b, nw, nh);
    return out;
  }
}

/// Resample a single plane. Downscaling averages the covered source area;
/// upscaling uses bilinear interpolation.
void resizePlane(
  Float32List src,
  int sw,
  int sh,
  Float32List dst,
  int dw,
  int dh,
) {
  if (dw <= sw && dh <= sh) {
    final fx = sw / dw, fy = sh / dh;
    for (var y = 0; y < dh; y++) {
      final y0 = (y * fy).floor();
      final y1 = math.max(y0 + 1, ((y + 1) * fy).floor()).clamp(0, sh);
      for (var x = 0; x < dw; x++) {
        final x0 = (x * fx).floor();
        final x1 = math.max(x0 + 1, ((x + 1) * fx).floor()).clamp(0, sw);
        var sum = 0.0;
        var n = 0;
        for (var yy = y0; yy < y1; yy++) {
          final row = yy * sw;
          for (var xx = x0; xx < x1; xx++) {
            sum += src[row + xx];
            n++;
          }
        }
        dst[y * dw + x] = n == 0 ? 0 : sum / n;
      }
    }
    return;
  }
  for (var y = 0; y < dh; y++) {
    final sy = ((y + 0.5) * sh / dh - 0.5).clamp(0.0, sh - 1.0);
    final y0 = sy.floor();
    final y1 = math.min(y0 + 1, sh - 1);
    final fy = sy - y0;
    for (var x = 0; x < dw; x++) {
      final sx = ((x + 0.5) * sw / dw - 0.5).clamp(0.0, sw - 1.0);
      final x0 = sx.floor();
      final x1 = math.min(x0 + 1, sw - 1);
      final fx = sx - x0;
      final a = src[y0 * sw + x0], b = src[y0 * sw + x1];
      final c = src[y1 * sw + x0], d = src[y1 * sw + x1];
      dst[y * dw + x] = (a + (b - a) * fx) + ((c + (d - c) * fx) - (a + (b - a) * fx)) * fy;
    }
  }
}

/// Separable box blur with clamped edges, O(n) per pixel regardless of
/// radius. Three passes approximate a Gaussian.
void boxBlur(Float32List p, int w, int h, int radius) {
  if (radius < 1) return;
  final tmp = Float32List(math.max(w, h));
  final win = 2 * radius + 1;
  // Horizontal.
  for (var y = 0; y < h; y++) {
    final row = y * w;
    var acc = 0.0;
    for (var k = -radius; k <= radius; k++) {
      acc += p[row + k.clamp(0, w - 1)];
    }
    for (var x = 0; x < w; x++) {
      tmp[x] = acc / win;
      acc += p[row + (x + radius + 1).clamp(0, w - 1)] -
          p[row + (x - radius).clamp(0, w - 1)];
    }
    for (var x = 0; x < w; x++) {
      p[row + x] = tmp[x];
    }
  }
  // Vertical.
  for (var x = 0; x < w; x++) {
    var acc = 0.0;
    for (var k = -radius; k <= radius; k++) {
      acc += p[k.clamp(0, h - 1) * w + x];
    }
    for (var y = 0; y < h; y++) {
      tmp[y] = acc / win;
      acc += p[(y + radius + 1).clamp(0, h - 1) * w + x] -
          p[(y - radius).clamp(0, h - 1) * w + x];
    }
    for (var y = 0; y < h; y++) {
      p[y * w + x] = tmp[y];
    }
  }
}

/// Approximate Gaussian blur with standard deviation [sigma] via three box
/// passes.
void gaussianBlur(Float32List p, int w, int h, double sigma) {
  if (sigma < 0.5) return;
  // Box width for 3 passes: w = sqrt(12*sigma^2/3 + 1).
  final r = math.max(1, ((math.sqrt(4 * sigma * sigma + 1) - 1) / 2).round());
  for (var i = 0; i < 3; i++) {
    boxBlur(p, w, h, r);
  }
}
