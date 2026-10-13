import 'dart:math' as math;

import 'af_log.dart';
import 'color_math.dart';
import 'lut.dart';

/// Auto Frame's built-in looks, generated procedurally so they ship without
/// binary assets and stay resolution-independent.
class BuiltinLuts {
  BuiltinLuts._();

  static const int defaultSize = 33;

  static final Map<String, Lut3D Function()> _factories = {
    'AF-Log → Rec.709': afLogToRec709,
    'AF Cinematic': afCinematic,
    'Teal & Orange': tealOrange,
    'Golden Hour Film': goldenHour,
    'Nordic Fade': nordicFade,
    'Chroma Pop': chromaPop,
    'Bleach Bypass': bleachBypass,
    'Noir': noir,
  };

  static final Map<String, Lut3D> _cache = {};

  static List<String> get names => _factories.keys.toList(growable: false);

  static Lut3D byName(String name) => _cache.putIfAbsent(name, () => _factories[name]!());

  /// Technical transform: AF-Log back to a neutral display image.
  static Lut3D afLogToRec709() => Lut3D.generate(
    title: 'AF-Log → Rec.709',
    inputSpace: LutInputSpace.afLog,
    (r, g, b) => [AfLog.toSrgb(r), AfLog.toSrgb(g), AfLog.toSrgb(b)],
  );

  /// Log-input film look: filmic S-curve, warm highlights, cool shadows.
  static Lut3D afCinematic() =>
      Lut3D.generate(title: 'AF Cinematic', inputSpace: LutInputSpace.afLog, (r, g, b) {
        final lin = [AfLog.decode(r), AfLog.decode(g), AfLog.decode(b)];
        final out = lin.map((v) => _filmic(v * 1.1)).toList();
        final l = luma(out[0], out[1], out[2]);
        return _splitTone(
          out,
          l,
          shadowHue: 195,
          shadowAmt: 0.06,
          highHue: 35,
          highAmt: 0.07,
        ).map(clamp01).toList();
      });

  static Lut3D tealOrange() => Lut3D.generate(title: 'Teal & Orange', (r, g, b) {
    var c = [r, g, b];
    final l = luma(r, g, b);
    c = _splitTone(c, l, shadowHue: 185, shadowAmt: 0.12, highHue: 28, highAmt: 0.10);
    c = _saturate(c, 1.12);
    return c.map((v) => clamp01(_sCurve(v, 0.18))).toList();
  });

  static Lut3D goldenHour() => Lut3D.generate(title: 'Golden Hour Film', (r, g, b) {
    var c = [r * 1.06, g * 1.0, b * 0.86];
    c = c.map((v) => _sCurve(clamp01(v), 0.12)).toList();
    // Lifted, warm blacks and soft highlight roll-off like negative film.
    c = [0.04 + c[0] * 0.95, 0.03 + c[1] * 0.94, 0.02 + c[2] * 0.90];
    return _saturate(c, 1.05).map(clamp01).toList();
  });

  static Lut3D nordicFade() => Lut3D.generate(title: 'Nordic Fade', (r, g, b) {
    var c = _saturate([r, g, b], 0.72);
    c = [c[0] * 0.95, c[1] * 1.0, c[2] * 1.06];
    return c.map((v) => clamp01(0.08 + _sCurve(clamp01(v), 0.08) * 0.86)).toList();
  });

  static Lut3D chromaPop() => Lut3D.generate(title: 'Chroma Pop', (r, g, b) {
    final c = _vibrance([r, g, b], 0.45);
    return c.map((v) => clamp01(_sCurve(clamp01(v), 0.22))).toList();
  });

  static Lut3D bleachBypass() => Lut3D.generate(title: 'Bleach Bypass', (r, g, b) {
    final l = luma(r, g, b);
    // Overlay-blend the luma layer back onto the colour, then desaturate.
    double overlay(double base, double blend) =>
        base < 0.5 ? 2 * base * blend : 1 - 2 * (1 - base) * (1 - blend);
    var c = [overlay(r, l), overlay(g, l), overlay(b, l)];
    c = _saturate(c, 0.55);
    return c.map((v) => clamp01(_sCurve(v, 0.15))).toList();
  });

  static Lut3D noir() => Lut3D.generate(title: 'Noir', (r, g, b) {
    // Red-filter black & white: darker skies, bright skin.
    final l = clamp01(0.45 * r + 0.45 * g + 0.10 * b);
    final v = clamp01(_sCurve(l, 0.35));
    return [v, v, v * 0.98];
  });

  // --- helpers -------------------------------------------------------------

  /// Contrast S-curve around mid-grey; [k] 0..1.
  static double _sCurve(double v, double k) {
    final s = v - (math.sin(2 * math.pi * v) / (2 * math.pi));
    return mix(v, s, k * 2.2).clamp(0.0, 1.0);
  }

  /// Hable-style filmic tone curve, white-normalised.
  static double _filmic(double x) {
    double f(double x) {
      const a = 0.22, b = 0.30, c = 0.10, d = 0.20, e = 0.01, f = 0.30;
      return ((x * (a * x + c * b) + d * e) / (x * (a * x + b) + d * f)) - e / f;
    }

    const exposureBias = 4.0;
    return linearToSrgb(clamp01(f(x * exposureBias) / f(11.2)));
  }

  static List<double> _saturate(List<double> c, double s) {
    final l = luma(c[0], c[1], c[2]);
    return [mix(l, c[0], s), mix(l, c[1], s), mix(l, c[2], s)];
  }

  static List<double> _vibrance(List<double> c, double amount) {
    final maxC = math.max(c[0], math.max(c[1], c[2]));
    final minC = math.min(c[0], math.min(c[1], c[2]));
    final sat = maxC - minC;
    return _saturate(c, 1 + amount * (1 - sat));
  }

  static List<double> _splitTone(
    List<double> c,
    double l, {
    required double shadowHue,
    required double shadowAmt,
    required double highHue,
    required double highAmt,
  }) {
    final sh = hsvToRgb(shadowHue, 1, 1);
    final hi = hsvToRgb(highHue, 1, 1);
    final ws = (1 - smoothstep(0.0, 0.55, l)) * shadowAmt;
    final wh = smoothstep(0.45, 1.0, l) * highAmt;
    return List.generate(3, (i) {
      return c[i] + (sh[i] - 0.5) * ws + (hi[i] - 0.5) * wh;
    });
  }
}
