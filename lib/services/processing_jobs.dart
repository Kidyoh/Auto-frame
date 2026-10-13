import 'dart:isolate';
import 'dart:typed_data';

import '../core/composition/geometry.dart';
import '../core/composition/saliency.dart';
import '../core/processing/aperture_sim.dart';
import '../core/processing/exposure_fusion.dart';
import '../core/processing/planes.dart';

typedef RgbaImage = ({Uint8List rgba, int width, int height});

/// Heavy CPU work, always off the UI isolate.
class ProcessingJobs {
  ProcessingJobs._();

  /// HDR: align + fuse an exposure bracket. Reference (0 EV) frame first.
  static Future<RgbaImage> fuseBracket(List<RgbaImage> frames) {
    final w = frames.first.width, h = frames.first.height;
    final transfers = [
      for (final f in frames) TransferableTypedData.fromList([f.rgba]),
    ];
    return Isolate.run(() {
      final planes = [
        for (final t in transfers) RgbPlanes.fromRgba(t.materialize().asUint8List(), w, h),
      ];
      final fused = const ExposureFusion().fuse(planes);
      return (rgba: fused.toRgba(), width: w, height: h);
    });
  }

  /// Synthetic aperture renders for each of [stops].
  static Future<List<RgbaImage>> renderApertures(
    RgbaImage image, {
    required Float32List mask,
    required int maskWidth,
    required int maskHeight,
    required List<double> stops,
  }) {
    final transfer = TransferableTypedData.fromList([image.rgba]);
    final w = image.width, h = image.height;
    return Isolate.run(() {
      final src = RgbPlanes.fromRgba(transfer.materialize().asUint8List(), w, h);
      const sim = ApertureSimulator();
      return [
        for (final f in stops)
          (
            rgba: sim
                .render(src, mask: mask, maskWidth: maskWidth, maskHeight: maskHeight, fNumber: f)
                .toRgba(),
            width: w,
            height: h,
          ),
      ];
    });
  }

  /// Salient region (in [image] pixel coordinates), or null.
  static Future<Box?> salientRegion(RgbaImage image) {
    final transfer = TransferableTypedData.fromList([image.rgba]);
    final w = image.width, h = image.height;
    return Isolate.run(() {
      final planes = RgbPlanes.fromRgba(transfer.materialize().asUint8List(), w, h);
      return const SaliencyDetector().detect(planes)?.box;
    });
  }
}
