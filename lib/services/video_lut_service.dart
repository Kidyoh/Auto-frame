import 'package:flutter/services.dart';

import '../core/color/lut.dart';

/// Native video re-encode with a per-frame 3D LUT
/// (Media3 Transformer on Android, AVFoundation + Core Image on iOS).
class VideoLutService {
  VideoLutService._();

  static const _channel = MethodChannel('auto_frame/video_lut');

  /// Re-encode [input] as flat AF-Log footage for grading.
  static Future<String> bakeLog({required String input, required String output}) {
    final lut = Lut3D.identity(size: 33).bakeForSrgbInput(logEncode: true);
    return _bake(input, output, lut);
  }

  /// Burn a look into [input]. LUTs that expect AF-Log input are fed a
  /// log-encoded signal automatically.
  static Future<String> bakeLook({
    required String input,
    required String output,
    required Lut3D look,
    double intensity = 1,
  }) {
    final lut = look.bakeForSrgbInput(intensity: intensity);
    return _bake(input, output, lut);
  }

  static Future<String> _bake(String input, String output, Lut3D baked) async {
    final result = await _channel.invokeMethod<String>('bake', {
      'input': input,
      'output': output,
      'size': baked.size,
      'data': baked.data,
    });
    return result ?? output;
  }
}
