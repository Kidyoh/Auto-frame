import 'dart:math' as math;
import 'dart:typed_data';

import 'package:auto_frame/core/composition/geometry.dart';
import 'package:auto_frame/core/edit/edit_params.dart';
import 'package:auto_frame/core/edit/presets.dart';
import 'package:auto_frame/core/edit/tone_curve.dart';
import 'package:auto_frame/core/processing/aperture_sim.dart';
import 'package:auto_frame/core/processing/exposure_fusion.dart';
import 'package:auto_frame/core/processing/planes.dart';
import 'package:flutter_test/flutter_test.dart';

/// A synthetic scene with a dark interior and a bright window, rendered at
/// an exposure of [ev] stops with optional pixel offset.
RgbPlanes scene(int w, int h, double ev, {int dx = 0, int dy = 0}) {
  final p = RgbPlanes(w, h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final sx = x + dx, sy = y + dy;
      final inWindow = sx > w * 0.55 && sy < h * 0.5;
      // Non-periodic blocky texture (periodic patterns make alignment
      // ambiguous, unlike real scenes).
      final cell = (sx ~/ 6) * 7919 + (sy ~/ 6) * 104729;
      final texture = (math.sin(cell * 12.9898) * 43758.5453) % 1.0;
      final radiance = inWindow ? 2.5 + texture : 0.04 + 0.03 * texture;
      final v = (radiance * math.pow(2, ev)).clamp(0.0, 1.0).toDouble();
      final i = y * w + x;
      p.r[i] = v;
      p.g[i] = v * 0.95;
      p.b[i] = v * 0.9;
    }
  }
  return p;
}

double stdDev(Float32List p, bool Function(int) where) {
  final vals = <double>[];
  for (var i = 0; i < p.length; i++) {
    if (where(i)) vals.add(p[i]);
  }
  final mean = vals.reduce((a, b) => a + b) / vals.length;
  return math.sqrt(vals.map((v) => (v - mean) * (v - mean)).reduce((a, b) => a + b) / vals.length);
}

void main() {
  group('ExposureFusion', () {
    const w = 128, h = 96;

    test('MTB recovers a translation between differently exposed frames', () {
      const fusion = ExposureFusion();
      final ref = scene(w, h, 0);
      final moved = scene(w, h, 2, dx: 3, dy: -2);
      final (dx, dy) = fusion.estimateShift(ref.luminance(), moved.luminance(), w, h);
      expect(dx, -3);
      expect(dy, 2);
    });

    test('fused image keeps detail in both shadows and highlights', () {
      final under = scene(w, h, -2);
      final normal = scene(w, h, 0);
      final over = scene(w, h, 3);
      final fused = const ExposureFusion().fuse([normal, under, over]);

      bool window(int i) => (i % w) > w * 0.6 && (i ~/ w) < h * 0.45;
      bool interior(int i) => (i % w) < w * 0.5 && (i ~/ w) > h * 0.55;

      final normalL = normal.luminance(), fusedL = fused.luminance();
      // The normal frame clips the window; fusion should restore texture.
      expect(stdDev(normalL, window), lessThan(0.01));
      expect(stdDev(fusedL, window), greaterThan(0.03));
      // And lift the interior texture above the normal frame's.
      expect(stdDev(fusedL, interior), greaterThan(stdDev(normalL, interior)));
      for (final v in fused.r) {
        expect(v, inInclusiveRange(0, 1));
      }
    });
  });

  group('ApertureSimulator', () {
    test('wider apertures blur the background more, subject stays sharp', () {
      const w = 160, h = 120;
      final img = RgbPlanes(w, h);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final v = ((x ~/ 4 + y ~/ 4) % 2 == 0) ? 0.9 : 0.1; // checkerboard
          final i = y * w + x;
          img.r[i] = v;
          img.g[i] = v;
          img.b[i] = v;
        }
      }
      final m = ApertureSimulator.maskFromBoxes([const Box(60, 40, 40, 40)], w, h);
      const sim = ApertureSimulator(maxBlurFraction: 0.05);

      double bgDetail(RgbPlanes p) => stdDev(p.r, (i) {
        final x = i % w;
        return x < 30 || x > 130;
      });
      double subjectDiff(RgbPlanes p) {
        var d = 0.0;
        for (var y = 55; y < 65; y++) {
          for (var x = 75; x < 85; x++) {
            d += (p.r[y * w + x] - img.r[y * w + x]).abs();
          }
        }
        return d / 100;
      }

      RgbPlanes at(double f) =>
          sim.render(img, mask: m.mask, maskWidth: m.width, maskHeight: m.height, fNumber: f);
      final f14 = at(1.4), f4 = at(4), f16 = at(16);

      expect(bgDetail(f14), lessThan(bgDetail(f4)));
      expect(bgDetail(f4), lessThan(bgDetail(f16)));
      expect(subjectDiff(f14), lessThan(0.05));
      expect(ApertureSimulator.strengthFor(16), 0);
      expect(ApertureSimulator.strengthFor(1.4), 1);
    });
  });

  group('Planes', () {
    test('gaussianBlur preserves mean of a constant plane', () {
      final p = Float32List(50 * 40)..fillRange(0, 2000, 0.42);
      gaussianBlur(p, 50, 40, 4);
      for (final v in p) {
        expect(v, closeTo(0.42, 1e-5));
      }
    });

    test('downscale averages', () {
      final p = RgbPlanes(4, 4);
      for (var i = 0; i < 16; i++) {
        p.r[i] = i.isEven ? 1 : 0;
      }
      final s = p.resize(2, 2);
      for (final v in s.r) {
        expect(v, closeTo(0.5, 1e-6));
      }
    });
  });

  group('ToneCurve', () {
    test('identity and endpoints', () {
      expect(ToneCurve.identity.evaluate(0.37), closeTo(0.37, 1e-9));
      final c = ToneCurve(const [(0, 0.1), (0.5, 0.6), (1, 0.9)]);
      expect(c.evaluate(0), closeTo(0.1, 1e-9));
      expect(c.evaluate(0.5), closeTo(0.6, 1e-9));
      expect(c.evaluate(1), closeTo(0.9, 1e-9));
    });

    test('is monotone (no overshoot) for monotone points', () {
      final c = ToneCurve(const [(0, 0), (0.1, 0.5), (0.2, 0.52), (1, 1)]);
      var prev = -1.0;
      for (final v in c.bake(512)) {
        expect(v, greaterThanOrEqualTo(prev - 1e-9));
        prev = v;
      }
    });
  });

  group('EditParams', () {
    test('JSON round trip', () {
      final p = Presets.all['Moody']!
          .set(Adjust.exposure, 1.25)
          .copyWith(
            lutName: 'Teal & Orange',
            lutIntensity: 0.6,
            crop: const Box(0.1, 0.1, 0.8, 0.8),
          );
      final back = EditParams.fromJson(p.toJson());
      expect(back[Adjust.exposure], 1.25);
      expect(back.hslOf(HslBand.green).saturation, -40);
      expect(back.lutName, 'Teal & Orange');
      expect(back.crop!.width, 0.8);
      expect(back.grade.shadowSat, 18);
    });

    test('values clamp to slider range', () {
      expect(EditParams().set(Adjust.exposure, 99)[Adjust.exposure], 5);
    });

    test('presets keep geometry', () {
      final p = EditParams(crop: const Box(0, 0, 0.5, 0.5), rotationDegrees: 2);
      final applied = p.applyPreset(Presets.all['Vivid']!);
      expect(applied.crop!.width, 0.5);
      expect(applied.rotationDegrees, 2);
      expect(applied[Adjust.vibrance], 40);
    });
  });
}
