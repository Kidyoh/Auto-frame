import 'edit_params.dart';
import 'tone_curve.dart';

/// Built-in develop presets.
class Presets {
  Presets._();

  static final Map<String, EditParams> all = {
    'Original': EditParams(),
    'Natural': EditParams(
      values: {
        Adjust.contrast: 8,
        Adjust.highlights: -25,
        Adjust.shadows: 20,
        Adjust.vibrance: 15,
        Adjust.clarity: 8,
        Adjust.sharpness: 30,
      },
    ),
    'Vivid': EditParams(
      values: {
        Adjust.contrast: 22,
        Adjust.highlights: -30,
        Adjust.shadows: 25,
        Adjust.whites: 10,
        Adjust.blacks: -10,
        Adjust.vibrance: 40,
        Adjust.saturation: 8,
        Adjust.clarity: 18,
        Adjust.dehaze: 10,
        Adjust.sharpness: 40,
      },
    ),
    'Moody': EditParams(
      values: {
        Adjust.exposure: -0.3,
        Adjust.contrast: 15,
        Adjust.highlights: -40,
        Adjust.shadows: -10,
        Adjust.temperature: -8,
        Adjust.vibrance: -10,
        Adjust.saturation: -15,
        Adjust.clarity: 20,
        Adjust.vignette: -30,
      },
      hsl: {
        HslBand.green: const HslShift(-20, -40, -25),
        HslBand.blue: const HslShift(-10, -20, -20),
        HslBand.orange: const HslShift(0, 5, 5),
      },
      grade: const ColorGrade(shadowHue: 200, shadowSat: 18, highlightHue: 38, highlightSat: 12),
    ),
    'Film': EditParams(
      values: {
        Adjust.contrast: -10,
        Adjust.highlights: -20,
        Adjust.temperature: 8,
        Adjust.saturation: -8,
        Adjust.grain: 28,
        Adjust.grainSize: 35,
      },
      curves: {
        CurveChannel.master: ToneCurve(const [(0, 0.06), (0.25, 0.25), (0.75, 0.78), (1, 0.95)]),
      },
      grade: const ColorGrade(shadowHue: 190, shadowSat: 10, highlightHue: 45, highlightSat: 14),
    ),
    'Airy': EditParams(
      values: {
        Adjust.exposure: 0.4,
        Adjust.contrast: -15,
        Adjust.highlights: -20,
        Adjust.shadows: 40,
        Adjust.temperature: 5,
        Adjust.vibrance: 10,
        Adjust.saturation: -10,
        Adjust.clarity: -10,
      },
    ),
    'Portrait Glow': EditParams(
      values: {
        Adjust.exposure: 0.15,
        Adjust.highlights: -20,
        Adjust.shadows: 15,
        Adjust.temperature: 6,
        Adjust.vibrance: 10,
        Adjust.clarity: -18,
        Adjust.vignette: -15,
      },
      hsl: {HslBand.orange: const HslShift(-4, -8, 12), HslBand.red: const HslShift(0, -6, 5)},
    ),
    'B&W Matte': EditParams(
      values: {Adjust.saturation: -100, Adjust.contrast: 20, Adjust.clarity: 20, Adjust.grain: 20},
      curves: {
        CurveChannel.master: ToneCurve(const [(0, 0.08), (0.3, 0.26), (0.7, 0.76), (1, 0.97)]),
      },
    ),
  };
}
