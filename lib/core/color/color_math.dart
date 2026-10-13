import 'dart:math' as math;

/// Shared colour-space helpers. All channel values are normalised to 0..1.

double clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

/// sRGB electro-optical transfer: encoded -> linear light.
double srgbToLinear(double v) {
  if (v <= 0.04045) return v / 12.92;
  return math.pow((v + 0.055) / 1.055, 2.4).toDouble();
}

/// Inverse sRGB transfer: linear light -> encoded.
double linearToSrgb(double v) {
  if (v <= 0) return 0;
  if (v <= 0.0031308) return v * 12.92;
  return 1.055 * math.pow(v, 1 / 2.4).toDouble() - 0.055;
}

/// Rec.709 luma weights.
double luma(double r, double g, double b) => 0.2126 * r + 0.7152 * g + 0.0722 * b;

double smoothstep(double e0, double e1, double x) {
  final t = clamp01((x - e0) / (e1 - e0));
  return t * t * (3 - 2 * t);
}

double mix(double a, double b, double t) => a + (b - a) * t;

/// RGB (0..1) -> HSV with hue in degrees.
List<double> rgbToHsv(double r, double g, double b) {
  final maxC = math.max(r, math.max(g, b));
  final minC = math.min(r, math.min(g, b));
  final d = maxC - minC;
  double h = 0;
  if (d > 1e-9) {
    if (maxC == r) {
      h = 60 * (((g - b) / d) % 6);
    } else if (maxC == g) {
      h = 60 * ((b - r) / d + 2);
    } else {
      h = 60 * ((r - g) / d + 4);
    }
  }
  if (h < 0) h += 360;
  final s = maxC <= 0 ? 0.0 : d / maxC;
  return [h, s, maxC];
}

List<double> hsvToRgb(double h, double s, double v) {
  h = h % 360;
  if (h < 0) h += 360;
  final c = v * s;
  final x = c * (1 - ((h / 60) % 2 - 1).abs());
  final m = v - c;
  double r, g, b;
  if (h < 60) {
    r = c; g = x; b = 0;
  } else if (h < 120) {
    r = x; g = c; b = 0;
  } else if (h < 180) {
    r = 0; g = c; b = x;
  } else if (h < 240) {
    r = 0; g = x; b = c;
  } else if (h < 300) {
    r = x; g = 0; b = c;
  } else {
    r = c; g = 0; b = x;
  }
  return [r + m, g + m, b + m];
}
