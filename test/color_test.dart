import 'package:auto_frame/core/color/af_log.dart';
import 'package:auto_frame/core/color/builtin_luts.dart';
import 'package:auto_frame/core/color/lut.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AF-Log', () {
    test('18% grey encodes to the documented code value', () {
      expect(AfLog.encode(0.18), closeTo(0.42, 1e-9));
    });

    test('encode/decode round-trip', () {
      for (final x in [0.0, 0.001, 0.05, 0.18, 0.5, 1.0, 4.0, 16.0]) {
        expect(AfLog.decode(AfLog.encode(x)), closeTo(x, 1e-6 + x * 1e-6));
      }
    });

    test('is monotonic and flat (about 0.075 per stop)', () {
      var prev = -1.0;
      for (var stop = -6; stop <= 7; stop++) {
        final code = AfLog.encode(0.18 * (1 << 10) / (1 << (10 - stop)));
        expect(code, greaterThan(prev));
        prev = code;
      }
      final oneStop = AfLog.encode(0.36) - AfLog.encode(0.18);
      expect(oneStop, closeTo(0.075, 0.005));
    });

    test('sRGB -> AF-Log -> sRGB is lossless below clip', () {
      for (var v = 0.0; v <= 0.99; v += 0.033) {
        expect(AfLog.toSrgb(AfLog.fromSrgb(v)), closeTo(v, 1e-4));
      }
    });

    test('black sits above zero (lifted, gradeable)', () {
      expect(AfLog.encode(0), inInclusiveRange(0.08, 0.12));
    });
  });

  group('Lut3D', () {
    test('identity LUT returns its input', () {
      final lut = Lut3D.identity(size: 17);
      for (final c in [
        [0.0, 0.0, 0.0],
        [1.0, 1.0, 1.0],
        [0.13, 0.57, 0.91],
        [0.5, 0.25, 0.75],
      ]) {
        final out = lut.sample(c[0], c[1], c[2]);
        for (var i = 0; i < 3; i++) {
          expect(out[i], closeTo(c[i], 1e-5));
        }
      }
    });

    test('trilinear interpolation is exact for affine LUTs', () {
      final lut = Lut3D.generate(size: 5, (r, g, b) => [0.5 * r + 0.1, g * g, 1 - b]);
      final out = lut.sample(0.3, 0.5, 0.6);
      expect(out[0], closeTo(0.25, 1e-6));
      expect(out[2], closeTo(0.4, 1e-6));
      // g*g is not affine: interpolated between lattice points 0.5 -> exact.
      expect(out[1], closeTo(0.25, 1e-6));
    });

    test('.cube round-trip preserves data and input space', () {
      final lut = BuiltinLuts.afCinematic();
      final parsed = Lut3D.parseCube(lut.toCube());
      expect(parsed.size, lut.size);
      expect(parsed.title, lut.title);
      expect(parsed.inputSpace, LutInputSpace.afLog);
      for (var i = 0; i < lut.data.length; i += 997) {
        expect(parsed.data[i], closeTo(lut.data[i], 1e-5));
      }
    });

    test('parses a hand-written .cube with comments and domain', () {
      const cube = '''
# comment
TITLE "Tiny"
LUT_3D_SIZE 2
DOMAIN_MIN 0 0 0
DOMAIN_MAX 1 1 1

0 0 0
1 0 0
0 1 0
1 1 0
0 0 1
1 0 1
0 1 1
1 1 1
''';
      final lut = Lut3D.parseCube(cube);
      expect(lut.title, 'Tiny');
      expect(lut.sample(0.2, 0.4, 0.6)[1], closeTo(0.4, 1e-6));
    });

    test('expands 1D LUTs to 3D', () {
      const cube = 'LUT_1D_SIZE 3\n0 0 0\n0.25 0.25 0.25\n1 1 1\n';
      final lut = Lut3D.parseCube(cube);
      expect(lut.sample(0.5, 0.5, 0.5)[0], closeTo(0.25, 1e-3));
    });

    test('rejects truncated files', () {
      expect(
        () => Lut3D.parseCube('LUT_3D_SIZE 2\n0 0 0\n'),
        throwsFormatException,
      );
    });

    test('atlas layout matches shader addressing', () {
      final lut = Lut3D.generate(size: 4, (r, g, b) => [r, g, b]);
      final atlas = lut.toAtlasRgba();
      const n = 4;
      // Entry (r=1, g=2, b=3) -> x = b*n + r, y = g.
      final x = 3 * n + 1, y = 2;
      final i = (y * n * n + x) * 4;
      expect(atlas[i], (1 / 3 * 255).round());
      expect(atlas[i + 1], (2 / 3 * 255).round());
      expect(atlas[i + 2], 255);
    });

    test('baking an AF-Log LUT for sRGB input equals the two-step pipeline', () {
      final log = BuiltinLuts.afLogToRec709();
      final baked = log.bakeForSrgbInput(outSize: 33);
      // AF-Log -> Rec.709 applied to a log-encoded image is ~identity.
      for (final v in [0.1, 0.3, 0.5, 0.7, 0.9]) {
        expect(baked.sample(v, v, v)[0], closeTo(v, 0.02));
      }
    });

    test('all built-in looks generate in range', () {
      for (final name in BuiltinLuts.names) {
        final lut = BuiltinLuts.byName(name);
        for (final v in lut.data) {
          expect(v, inInclusiveRange(0, 1), reason: name);
        }
      }
    });
  });
}
