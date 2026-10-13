import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;

/// Decode an image file on the engine's native decoder (fast, EXIF-aware),
/// optionally downscaled so the long side is at most [maxSide].
Future<ui.Image> loadUiImage(String path, {int? maxSide}) async {
  final buffer = await ui.ImmutableBuffer.fromFilePath(path);
  final codec = await ui.instantiateImageCodecWithSize(
    buffer,
    getTargetSize: (w, h) {
      if (maxSide == null || math.max(w, h) <= maxSide) {
        return ui.TargetImageSize(width: w, height: h);
      }
      final s = maxSide / math.max(w, h);
      return ui.TargetImageSize(width: (w * s).round(), height: (h * s).round());
    },
  );
  final frame = await codec.getNextFrame();
  codec.dispose();
  return frame.image;
}

/// Raw RGBA8 pixels of a decoded image.
Future<({Uint8List rgba, int width, int height})> loadRgba(String path, {int? maxSide}) async {
  final image = await loadUiImage(path, maxSide: maxSide);
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final out = (rgba: data!.buffer.asUint8List(), width: image.width, height: image.height);
  image.dispose();
  return out;
}

/// JPEG-encode RGBA8 pixels in a background isolate.
Future<Uint8List> encodeJpeg(Uint8List rgba, int width, int height, {int quality = 95}) {
  final transfer = TransferableTypedData.fromList([rgba]);
  return Isolate.run(() {
    final bytes = transfer.materialize().asUint8List();
    final image = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: bytes.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
    return img.encodeJpg(image, quality: quality);
  });
}
