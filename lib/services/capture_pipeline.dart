import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../core/composition/composition_engine.dart';
import '../core/composition/geometry.dart';
import '../core/composition/subject.dart';
import '../core/processing/aperture_sim.dart';
import 'image_io.dart';
import 'media_store.dart';
import 'processing_jobs.dart';
import 'shader_service.dart';
import 'vision_service.dart';

/// Result of analysing a still for auto-framing.
class FramingResult {
  FramingResult({
    required this.file,
    required this.preview,
    required this.fullWidth,
    required this.fullHeight,
    required this.subjects,
    required this.suggestions,
  });

  final File file;
  final ui.Image preview;
  final double fullWidth;
  final double fullHeight;
  final List<Subject> subjects;
  final List<CropSuggestion> suggestions;
}

/// One synthetic-aperture render.
class ApertureRender {
  ApertureRender(this.fNumber, this.image);

  final double fNumber;
  final ui.Image image;
}

/// Turns raw captures into Auto Frame results: framing suggestions, HDR
/// merges and aperture brackets.
class CapturePipeline {
  CapturePipeline({required this.vision, this.store});

  final VisionService vision;
  final MediaStore? store;
  final CompositionEngine engine = const CompositionEngine();

  MediaStore get _store => store ?? MediaStore.instance;

  /// Analyse [file] and propose crops. [horizonTilt] is the tilt measured
  /// by the motion sensor at capture time.
  Future<FramingResult> frame(File file, {double horizonTilt = 0}) async {
    var longSide = 0;
    final buffer = await ui.ImmutableBuffer.fromFilePath(file.path);
    final codec = await ui.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: (w, h) {
        longSide = math.max(w, h);
        final s = math.min(1.0, 1600 / longSide);
        return ui.TargetImageSize(width: (w * s).round(), height: (h * s).round());
      },
    );
    final preview = (await codec.getNextFrame()).image;
    codec.dispose();

    // Oriented full-resolution size (the long side is orientation-free).
    final scale = longSide / math.max(preview.width, preview.height);
    final fw = preview.width * scale, fh = preview.height * scale;

    final scene = await vision.analyzeFile(file.path, width: fw, height: fh);
    final subjects = [...scene.subjects];
    if (subjects.isEmpty) {
      final data = await preview.toByteData(format: ui.ImageByteFormat.rawRgba);
      final box = await ProcessingJobs.salientRegion((
        rgba: data!.buffer.asUint8List(),
        width: preview.width,
        height: preview.height,
      ));
      if (box != null) {
        subjects.add(Subject(box: box.scale(scale, scale), kind: SubjectKind.salient, weight: 0.8));
      }
    }

    final suggestions = engine.suggest(
      width: fw,
      height: fh,
      subjects: subjects,
      horizonTiltDegrees: horizonTilt,
    );
    return FramingResult(
      file: file,
      preview: preview,
      fullWidth: fw,
      fullHeight: fh,
      subjects: subjects,
      suggestions: suggestions,
    );
  }

  /// Merge a bracket (0 EV first) into one HDR photo saved to the library.
  Future<File> mergeHdr(List<String> paths, {int maxSide = 3000}) async {
    final frames = <RgbaImage>[];
    for (final p in paths) {
      frames.add(await loadRgba(p, maxSide: maxSide));
    }
    // Different exposures can decode at off-by-one sizes; crop to common.
    final w = frames.map((f) => f.width).reduce(math.min);
    final h = frames.map((f) => f.height).reduce(math.min);
    final same = [for (final f in frames) _cropRgba(f, w, h)];
    final fused = await ProcessingJobs.fuseBracket(same);
    final jpg = await encodeJpeg(fused.rgba, fused.width, fused.height);
    final out = await _store.writeBytes(jpg, prefix: 'AF_HDR');
    for (final p in paths) {
      try {
        await File(p).delete();
      } catch (_) {}
    }
    return out;
  }

  /// Render the photo at several simulated f-stops.
  Future<List<ApertureRender>> apertureBracket(
    File file, {
    List<double> stops = const [1.4, 2.0, 2.8, 4.0, 8.0],
    int maxSide = 2400,
  }) async {
    final src = await loadRgba(file.path, maxSide: maxSide);
    Float32List mask;
    int mw, mh;
    final person = await vision.personMask(file.path);
    if (person != null) {
      mask = person.mask;
      mw = person.width;
      mh = person.height;
    } else {
      // Fall back to detected subjects (or the salient region).
      final framing = await frame(file);
      final s = src.width / framing.fullWidth;
      final boxes = [for (final sub in framing.subjects) sub.box.scale(s, s)];
      framing.preview.dispose();
      final m = ApertureSimulator.maskFromBoxes(
        boxes.isEmpty
            ? [Box(src.width * 0.3, src.height * 0.25, src.width * 0.4, src.height * 0.5)]
            : boxes,
        src.width,
        src.height,
      );
      mask = m.mask;
      mw = m.width;
      mh = m.height;
    }
    final renders = await ProcessingJobs.renderApertures(
      src,
      mask: mask,
      maskWidth: mw,
      maskHeight: mh,
      stops: stops,
    );
    final out = <ApertureRender>[];
    for (var i = 0; i < stops.length; i++) {
      final r = renders[i];
      out.add(ApertureRender(stops[i], await ShaderService.rgbaToImage(r.rgba, r.width, r.height)));
    }
    return out;
  }

  /// Save a rendered image to the library and return the file.
  Future<File> saveImage(ui.Image image, {String prefix = 'AF'}) async {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final jpg = await encodeJpeg(data!.buffer.asUint8List(), image.width, image.height);
    return _store.writeBytes(jpg, prefix: prefix);
  }

  RgbaImage _cropRgba(RgbaImage f, int w, int h) {
    if (f.width == w && f.height == h) return f;
    final out = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      out.setRange(y * w * 4, (y + 1) * w * 4, f.rgba, y * f.width * 4);
    }
    return (rgba: out, width: w, height: h);
  }
}
