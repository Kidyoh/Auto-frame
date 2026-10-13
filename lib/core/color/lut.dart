import 'dart:math' as math;
import 'dart:typed_data';

import 'af_log.dart';
import 'color_math.dart';

/// Colour space a LUT expects as its input.
enum LutInputSpace {
  /// Display-referred sRGB / Rec.709 (most creative .cube files).
  rec709,

  /// Auto Frame's AF-Log. The pipeline log-encodes before the lookup.
  afLog,
}

/// A 3D colour lookup table.
///
/// Storage follows the `.cube` convention: red varies fastest, then green,
/// then blue. Entry (r, g, b) lives at `((b * size + g) * size + r) * 3`.
class Lut3D {
  Lut3D({
    required this.size,
    required this.data,
    this.title = 'Untitled',
    this.inputSpace = LutInputSpace.rec709,
    this.domainMin = const [0, 0, 0],
    this.domainMax = const [1, 1, 1],
  }) : assert(size >= 2),
       assert(data.length == size * size * size * 3);

  final int size;
  final Float32List data;
  final String title;
  final LutInputSpace inputSpace;
  final List<double> domainMin;
  final List<double> domainMax;

  /// Identity LUT (output == input).
  factory Lut3D.identity({int size = 33, String title = 'Identity'}) {
    return Lut3D.generate(size: size, title: title, (r, g, b) => [r, g, b]);
  }

  /// Build a LUT by evaluating [fn] at every lattice point.
  factory Lut3D.generate(
    List<double> Function(double r, double g, double b) fn, {
    int size = 33,
    String title = 'Generated',
    LutInputSpace inputSpace = LutInputSpace.rec709,
  }) {
    final data = Float32List(size * size * size * 3);
    final n = size - 1;
    var i = 0;
    for (var b = 0; b < size; b++) {
      for (var g = 0; g < size; g++) {
        for (var r = 0; r < size; r++) {
          final out = fn(r / n, g / n, b / n);
          data[i++] = out[0];
          data[i++] = out[1];
          data[i++] = out[2];
        }
      }
    }
    return Lut3D(size: size, data: data, title: title, inputSpace: inputSpace);
  }

  int _index(int r, int g, int b) => ((b * size + g) * size + r) * 3;

  /// Trilinear lookup. Input/output are 0..1 (input is clamped to the domain).
  List<double> sample(double r, double g, double b) {
    final out = List<double>.filled(3, 0);
    sampleInto(r, g, b, out);
    return out;
  }

  /// Allocation-free variant of [sample] for hot loops.
  void sampleInto(double r, double g, double b, List<double> out) {
    final n = size - 1;
    double norm(double v, int c) {
      final lo = domainMin[c], hi = domainMax[c];
      return clamp01((v - lo) / (hi - lo)) * n;
    }

    final fr = norm(r, 0), fg = norm(g, 1), fb = norm(b, 2);
    final r0 = math.min(fr.floor(), n - 1);
    final g0 = math.min(fg.floor(), n - 1);
    final b0 = math.min(fb.floor(), n - 1);
    final dr = fr - r0, dg = fg - g0, db = fb - b0;

    for (var c = 0; c < 3; c++) {
      final c000 = data[_index(r0, g0, b0) + c];
      final c100 = data[_index(r0 + 1, g0, b0) + c];
      final c010 = data[_index(r0, g0 + 1, b0) + c];
      final c110 = data[_index(r0 + 1, g0 + 1, b0) + c];
      final c001 = data[_index(r0, g0, b0 + 1) + c];
      final c101 = data[_index(r0 + 1, g0, b0 + 1) + c];
      final c011 = data[_index(r0, g0 + 1, b0 + 1) + c];
      final c111 = data[_index(r0 + 1, g0 + 1, b0 + 1) + c];
      final c00 = c000 + (c100 - c000) * dr;
      final c10 = c010 + (c110 - c010) * dr;
      final c01 = c001 + (c101 - c001) * dr;
      final c11 = c011 + (c111 - c011) * dr;
      final c0 = c00 + (c10 - c00) * dg;
      final c1 = c01 + (c11 - c01) * dg;
      out[c] = c0 + (c1 - c0) * db;
    }
  }

  /// Apply the LUT to a display-sRGB colour, honouring [inputSpace] and
  /// blending with the original by [intensity].
  void applyToSrgb(
    double r,
    double g,
    double b,
    List<double> out, {
    double intensity = 1,
  }) {
    var ir = r, ig = g, ib = b;
    if (inputSpace == LutInputSpace.afLog) {
      ir = AfLog.fromSrgb(r);
      ig = AfLog.fromSrgb(g);
      ib = AfLog.fromSrgb(b);
    }
    sampleInto(ir, ig, ib, out);
    if (intensity < 1) {
      out[0] = mix(r, out[0], intensity);
      out[1] = mix(g, out[1], intensity);
      out[2] = mix(b, out[2], intensity);
    }
  }

  /// Bake a single Rec.709-input LUT that performs:
  /// sRGB -> (AF-Log if [logEncode]) -> this LUT (at [intensity]).
  ///
  /// Used for video, where the native encoder applies one LUT per frame.
  Lut3D bakeForSrgbInput({
    int outSize = 33,
    double intensity = 1,
    bool logEncode = false,
  }) {
    final tmp = List<double>.filled(3, 0);
    return Lut3D.generate(size: outSize, title: '$title (baked)', (r, g, b) {
      double ir = r, ig = g, ib = b;
      // Log-encode when recording AF-Log, or when the LUT expects log input.
      if (logEncode || inputSpace == LutInputSpace.afLog) {
        ir = AfLog.fromSrgb(r);
        ig = AfLog.fromSrgb(g);
        ib = AfLog.fromSrgb(b);
      }
      sampleInto(ir, ig, ib, tmp);
      return [
        clamp01(mix(r, tmp[0], intensity)),
        clamp01(mix(g, tmp[1], intensity)),
        clamp01(mix(b, tmp[2], intensity)),
      ];
    });
  }

  /// Lay the cube out as a 2D RGBA8 atlas of [size] slices (one per blue
  /// value) side by side: width = size*size, height = size.
  /// Consumed by the GLSL shaders for GPU lookups.
  Uint8List toAtlasRgba() {
    final w = size * size;
    final out = Uint8List(w * size * 4);
    for (var b = 0; b < size; b++) {
      for (var g = 0; g < size; g++) {
        for (var r = 0; r < size; r++) {
          final src = _index(r, g, b);
          final x = b * size + r;
          final dst = (g * w + x) * 4;
          out[dst] = (clamp01(data[src]) * 255).round();
          out[dst + 1] = (clamp01(data[src + 1]) * 255).round();
          out[dst + 2] = (clamp01(data[src + 2]) * 255).round();
          out[dst + 3] = 255;
        }
      }
    }
    return out;
  }

  /// Serialise to Adobe/Resolve `.cube` text.
  String toCube() {
    final sb = StringBuffer()
      ..writeln('TITLE "$title"')
      ..writeln('# Created with Auto Frame')
      ..writeln(
        '# AF_INPUT_SPACE ${inputSpace == LutInputSpace.afLog ? 'AF-LOG' : 'REC709'}',
      )
      ..writeln('LUT_3D_SIZE $size')
      ..writeln('DOMAIN_MIN ${domainMin.join(' ')}')
      ..writeln('DOMAIN_MAX ${domainMax.join(' ')}');
    for (var i = 0; i < data.length; i += 3) {
      sb.writeln(
        '${data[i].toStringAsFixed(6)} ${data[i + 1].toStringAsFixed(6)} ${data[i + 2].toStringAsFixed(6)}',
      );
    }
    return sb.toString();
  }

  /// Parse `.cube` text (3D LUTs; 1D LUT_1D_SIZE files are expanded to 3D).
  static Lut3D parseCube(String text, {String? fallbackTitle}) {
    var title = fallbackTitle ?? 'Imported LUT';
    var size3d = 0;
    var size1d = 0;
    var dMin = <double>[0, 0, 0];
    var dMax = <double>[1, 1, 1];
    var space = LutInputSpace.rec709;
    final values = <double>[];

    for (final rawLine in text.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#')) {
        if (line.toUpperCase().contains('AF_INPUT_SPACE AF-LOG')) {
          space = LutInputSpace.afLog;
        }
        continue;
      }
      final upper = line.toUpperCase();
      if (upper.startsWith('TITLE')) {
        final m = RegExp(r'"(.*)"').firstMatch(line);
        title = m?.group(1) ?? line.substring(5).trim();
      } else if (upper.startsWith('LUT_3D_SIZE')) {
        size3d = int.parse(line.split(RegExp(r'\s+'))[1]);
      } else if (upper.startsWith('LUT_1D_SIZE')) {
        size1d = int.parse(line.split(RegExp(r'\s+'))[1]);
      } else if (upper.startsWith('DOMAIN_MIN')) {
        dMin = _triple(line);
      } else if (upper.startsWith('DOMAIN_MAX')) {
        dMax = _triple(line);
      } else if (upper.startsWith('LUT_3D_INPUT_RANGE') ||
          upper.startsWith('LUT_1D_INPUT_RANGE')) {
        final parts = line.split(RegExp(r'\s+'));
        final lo = double.parse(parts[1]), hi = double.parse(parts[2]);
        dMin = [lo, lo, lo];
        dMax = [hi, hi, hi];
      } else if (RegExp(r'^[-+0-9.eE]').hasMatch(line)) {
        final parts = line.split(RegExp(r'\s+'));
        if (parts.length < 3) {
          throw FormatException('Malformed LUT row: "$line"');
        }
        values
          ..add(double.parse(parts[0]))
          ..add(double.parse(parts[1]))
          ..add(double.parse(parts[2]));
      }
      // Unknown keywords are ignored per the spec.
    }

    if (size3d > 0) {
      final expected = size3d * size3d * size3d * 3;
      if (values.length != expected) {
        throw FormatException(
          'LUT_3D_SIZE $size3d needs ${expected ~/ 3} rows, found ${values.length ~/ 3}.',
        );
      }
      return Lut3D(
        size: size3d,
        data: Float32List.fromList(values),
        title: title,
        inputSpace: space,
        domainMin: dMin,
        domainMax: dMax,
      );
    }

    if (size1d > 0) {
      if (values.length != size1d * 3) {
        throw FormatException(
          'LUT_1D_SIZE $size1d needs $size1d rows, found ${values.length ~/ 3}.',
        );
      }
      double curve(int c, double v) {
        final t = clamp01((v - dMin[c]) / (dMax[c] - dMin[c])) * (size1d - 1);
        final i0 = math.min(t.floor(), size1d - 2);
        final f = t - i0;
        return mix(values[i0 * 3 + c], values[(i0 + 1) * 3 + c], f);
      }

      return Lut3D.generate(
        size: 33,
        title: title,
        inputSpace: space,
        (r, g, b) => [curve(0, r), curve(1, g), curve(2, b)],
      );
    }

    throw const FormatException('No LUT_3D_SIZE or LUT_1D_SIZE found.');
  }

  static List<double> _triple(String line) {
    final p = line.split(RegExp(r'\s+'));
    return [double.parse(p[1]), double.parse(p[2]), double.parse(p[3])];
  }
}
