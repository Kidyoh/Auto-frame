import '../composition/geometry.dart';
import 'tone_curve.dart';

/// Panels in the develop module, in Lightroom order.
enum AdjustGroup { light, color, effects, detail }

/// Every scalar slider in the editor. Metadata drives the UI and the shader
/// uniform layout, so adding a slider here is most of the work.
enum Adjust {
  exposure('Exposure', AdjustGroup.light, -5, 5),
  contrast('Contrast', AdjustGroup.light, -100, 100),
  highlights('Highlights', AdjustGroup.light, -100, 100),
  shadows('Shadows', AdjustGroup.light, -100, 100),
  whites('Whites', AdjustGroup.light, -100, 100),
  blacks('Blacks', AdjustGroup.light, -100, 100),
  temperature('Temp', AdjustGroup.color, -100, 100),
  tint('Tint', AdjustGroup.color, -100, 100),
  vibrance('Vibrance', AdjustGroup.color, -100, 100),
  saturation('Saturation', AdjustGroup.color, -100, 100),
  clarity('Clarity', AdjustGroup.effects, -100, 100),
  dehaze('Dehaze', AdjustGroup.effects, -100, 100),
  vignette('Vignette', AdjustGroup.effects, -100, 100),
  grain('Grain', AdjustGroup.effects, 0, 100),
  grainSize('Grain Size', AdjustGroup.effects, 0, 100, 25),
  sharpness('Sharpening', AdjustGroup.detail, 0, 150);

  const Adjust(this.label, this.group, this.min, this.max, [this.defaultValue = 0]);

  final String label;
  final AdjustGroup group;
  final double min;
  final double max;
  final double defaultValue;
}

/// Lightroom's eight HSL colour bands.
enum HslBand {
  red('Red', 0),
  orange('Orange', 30),
  yellow('Yellow', 60),
  green('Green', 120),
  aqua('Aqua', 180),
  blue('Blue', 225),
  purple('Purple', 270),
  magenta('Magenta', 315);

  const HslBand(this.label, this.hue);

  final String label;

  /// Centre hue in degrees.
  final double hue;
}

/// Hue / saturation / luminance shift for one band, each -100..100.
class HslShift {
  const HslShift([this.hue = 0, this.saturation = 0, this.luminance = 0]);

  final double hue;
  final double saturation;
  final double luminance;

  bool get isZero => hue == 0 && saturation == 0 && luminance == 0;

  HslShift copyWith({double? hue, double? saturation, double? luminance}) =>
      HslShift(hue ?? this.hue, saturation ?? this.saturation, luminance ?? this.luminance);

  List<double> toJson() => [hue, saturation, luminance];
}

/// Shadow/highlight colour wheels (Lightroom "Color Grading").
class ColorGrade {
  const ColorGrade({
    this.shadowHue = 210,
    this.shadowSat = 0,
    this.highlightHue = 40,
    this.highlightSat = 0,
    this.balance = 0,
  });

  final double shadowHue;
  final double shadowSat; // 0..100
  final double highlightHue;
  final double highlightSat; // 0..100
  final double balance; // -100..100

  ColorGrade copyWith({
    double? shadowHue,
    double? shadowSat,
    double? highlightHue,
    double? highlightSat,
    double? balance,
  }) => ColorGrade(
    shadowHue: shadowHue ?? this.shadowHue,
    shadowSat: shadowSat ?? this.shadowSat,
    highlightHue: highlightHue ?? this.highlightHue,
    highlightSat: highlightSat ?? this.highlightSat,
    balance: balance ?? this.balance,
  );

  Map<String, double> toJson() => {
    'shadowHue': shadowHue,
    'shadowSat': shadowSat,
    'highlightHue': highlightHue,
    'highlightSat': highlightSat,
    'balance': balance,
  };

  factory ColorGrade.fromJson(Map<String, dynamic> j) => ColorGrade(
    shadowHue: (j['shadowHue'] as num?)?.toDouble() ?? 210,
    shadowSat: (j['shadowSat'] as num?)?.toDouble() ?? 0,
    highlightHue: (j['highlightHue'] as num?)?.toDouble() ?? 40,
    highlightSat: (j['highlightSat'] as num?)?.toDouble() ?? 0,
    balance: (j['balance'] as num?)?.toDouble() ?? 0,
  );
}

/// Curve channels.
enum CurveChannel { master, red, green, blue }

/// A complete, non-destructive develop recipe. Stored as a JSON sidecar next
/// to the original, so the original pixels are never modified.
class EditParams {
  EditParams({
    Map<Adjust, double>? values,
    Map<HslBand, HslShift>? hsl,
    Map<CurveChannel, ToneCurve>? curves,
    this.grade = const ColorGrade(),
    this.lutName,
    this.lutIntensity = 1,
    this.crop,
    this.rotationDegrees = 0,
  }) : values = Map.unmodifiable(values ?? const {}),
       hsl = Map.unmodifiable(hsl ?? const {}),
       curves = Map.unmodifiable(curves ?? const {});

  final Map<Adjust, double> values;
  final Map<HslBand, HslShift> hsl;
  final Map<CurveChannel, ToneCurve> curves;
  final ColorGrade grade;

  /// Built-in or imported LUT name; null for none.
  final String? lutName;
  final double lutIntensity;

  /// Normalised crop of the rotated image, or null for full frame.
  final Box? crop;
  final double rotationDegrees;

  double operator [](Adjust a) => values[a] ?? a.defaultValue;
  HslShift hslOf(HslBand b) => hsl[b] ?? const HslShift();
  ToneCurve curveOf(CurveChannel c) => curves[c] ?? ToneCurve.identity;

  bool get isDefault =>
      values.entries.every((e) => e.value == e.key.defaultValue) &&
      hsl.values.every((h) => h.isZero) &&
      curves.values.every((c) => c.isIdentity) &&
      grade.shadowSat == 0 &&
      grade.highlightSat == 0 &&
      lutName == null &&
      crop == null &&
      rotationDegrees == 0;

  EditParams set(Adjust a, double v) =>
      copyWith(values: {...values, a: v.clamp(a.min, a.max).toDouble()});

  EditParams setHsl(HslBand b, HslShift s) => copyWith(hsl: {...hsl, b: s});

  EditParams setCurve(CurveChannel c, ToneCurve curve) => copyWith(curves: {...curves, c: curve});

  EditParams copyWith({
    Map<Adjust, double>? values,
    Map<HslBand, HslShift>? hsl,
    Map<CurveChannel, ToneCurve>? curves,
    ColorGrade? grade,
    String? lutName,
    bool clearLut = false,
    double? lutIntensity,
    Box? crop,
    bool clearCrop = false,
    double? rotationDegrees,
  }) => EditParams(
    values: values ?? this.values,
    hsl: hsl ?? this.hsl,
    curves: curves ?? this.curves,
    grade: grade ?? this.grade,
    lutName: clearLut ? null : (lutName ?? this.lutName),
    lutIntensity: lutIntensity ?? this.lutIntensity,
    crop: clearCrop ? null : (crop ?? this.crop),
    rotationDegrees: rotationDegrees ?? this.rotationDegrees,
  );

  /// Apply a preset on top of the geometry (crop/rotation) of this edit.
  EditParams applyPreset(EditParams preset) =>
      preset.copyWith(crop: crop, clearCrop: crop == null, rotationDegrees: rotationDegrees);

  Map<String, dynamic> toJson() => {
    'version': 1,
    'values': {for (final e in values.entries) e.key.name: e.value},
    'hsl': {for (final e in hsl.entries) e.key.name: e.value.toJson()},
    'curves': {for (final e in curves.entries) e.key.name: e.value.toJson()},
    'grade': grade.toJson(),
    'lutName': lutName,
    'lutIntensity': lutIntensity,
    if (crop != null) 'crop': [crop!.left, crop!.top, crop!.width, crop!.height],
    'rotation': rotationDegrees,
  };

  factory EditParams.fromJson(Map<String, dynamic> j) {
    T? byName<T extends Enum>(List<T> values, String name) {
      for (final v in values) {
        if (v.name == name) return v;
      }
      return null;
    }

    final values = <Adjust, double>{};
    (j['values'] as Map<String, dynamic>? ?? {}).forEach((k, v) {
      final a = byName(Adjust.values, k);
      if (a != null) values[a] = (v as num).toDouble();
    });
    final hsl = <HslBand, HslShift>{};
    (j['hsl'] as Map<String, dynamic>? ?? {}).forEach((k, v) {
      final b = byName(HslBand.values, k);
      final l = (v as List).map((e) => (e as num).toDouble()).toList();
      if (b != null) hsl[b] = HslShift(l[0], l[1], l[2]);
    });
    final curves = <CurveChannel, ToneCurve>{};
    (j['curves'] as Map<String, dynamic>? ?? {}).forEach((k, v) {
      final c = byName(CurveChannel.values, k);
      if (c != null) curves[c] = ToneCurve.fromJson(v as List);
    });
    final c = j['crop'] as List?;
    return EditParams(
      values: values,
      hsl: hsl,
      curves: curves,
      grade: ColorGrade.fromJson(j['grade'] as Map<String, dynamic>? ?? {}),
      lutName: j['lutName'] as String?,
      lutIntensity: (j['lutIntensity'] as num?)?.toDouble() ?? 1,
      crop: c == null
          ? null
          : Box(
              (c[0] as num).toDouble(),
              (c[1] as num).toDouble(),
              (c[2] as num).toDouble(),
              (c[3] as num).toDouble(),
            ),
      rotationDegrees: (j['rotation'] as num?)?.toDouble() ?? 0,
    );
  }
}
