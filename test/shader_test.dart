import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:auto_frame/core/color/af_log.dart';
import 'package:auto_frame/core/color/builtin_luts.dart';
import 'package:auto_frame/core/color/lut.dart';
import 'package:auto_frame/core/composition/geometry.dart';
import 'package:auto_frame/core/edit/edit_params.dart';
import 'package:auto_frame/services/shader_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Renders through the real develop.frag to verify the Dart-side uniform
/// layout matches the shader.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ui.Image> gradient(int w, int h) {
    final px = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = (y * w + x) * 4;
        px[i] = (x * 255 / (w - 1)).round();
        px[i + 1] = (y * 255 / (h - 1)).round();
        px[i + 2] = 128;
        px[i + 3] = 255;
      }
    }
    return ShaderService.rgbaToImage(px, w, h);
  }

  Future<Uint8List> render(ui.Image img, EditParams p, {Lut3D? lut}) async {
    final out = await renderDeveloped(image: img, params: p, lut: lut);
    return out.rgba;
  }

  double meanLuma(Uint8List px) {
    var s = 0.0;
    for (var i = 0; i < px.length; i += 4) {
      s += 0.2126 * px[i] + 0.7152 * px[i + 1] + 0.0722 * px[i + 2];
    }
    return s / (px.length / 4);
  }

  double maxDiff(Uint8List a, Uint8List b) {
    var m = 0;
    for (var i = 0; i < a.length; i++) {
      final d = (a[i] - b[i]).abs();
      if (d > m) m = d;
    }
    return m.toDouble();
  }

  testWidgets('default params are an identity transform', (tester) async {
    await tester.runAsync(() async {
      final img = await gradient(32, 24);
      final src = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
      final out = await render(img, EditParams());
      expect(maxDiff(src, out), lessThanOrEqualTo(3));
    });
  });

  testWidgets('exposure +1 EV brightens, -1 EV darkens', (tester) async {
    await tester.runAsync(() async {
      final img = await gradient(32, 24);
      final base = meanLuma(await render(img, EditParams()));
      final up = meanLuma(await render(img, EditParams().set(Adjust.exposure, 1)));
      final down = meanLuma(await render(img, EditParams().set(Adjust.exposure, -1)));
      expect(up, greaterThan(base + 15));
      expect(down, lessThan(base - 15));
    });
  });

  testWidgets('saturation -100 produces greyscale', (tester) async {
    await tester.runAsync(() async {
      final img = await gradient(32, 24);
      final out = await render(img, EditParams().set(Adjust.saturation, -100));
      for (var i = 0; i < out.length; i += 4) {
        expect((out[i] - out[i + 1]).abs(), lessThanOrEqualTo(3));
        expect((out[i + 1] - out[i + 2]).abs(), lessThanOrEqualTo(3));
      }
    });
  });

  testWidgets('identity LUT at full strength is a no-op; Noir LUT is mono', (tester) async {
    await tester.runAsync(() async {
      final img = await gradient(32, 24);
      final plain = await render(img, EditParams());
      final id = Lut3D.identity(size: 17);
      final viaLut = await render(img, EditParams(lutName: 'id'), lut: id);
      expect(maxDiff(plain, viaLut), lessThanOrEqualTo(3));

      final noir = await render(img, EditParams(lutName: 'Noir'), lut: BuiltinLuts.byName('Noir'));
      for (var i = 0; i < noir.length; i += 4) {
        expect((noir[i] - noir[i + 1]).abs(), lessThanOrEqualTo(3));
      }
    });
  });

  testWidgets('crop renders the cropped region at the right size', (tester) async {
    await tester.runAsync(() async {
      final img = await gradient(40, 20);
      final out = await renderDeveloped(
        image: img,
        params: EditParams(crop: const Box(0.5, 0, 0.5, 1)),
      );
      expect(out.width, 20);
      expect(out.height, 20);
      // Right half of a left-to-right red ramp: first column is mid red.
      expect(out.rgba[0], inInclusiveRange(120, 140));
    });
  });

  /// camera_look.frag drawn directly (the engine normally binds uSize and
  /// the input texture when used as an ImageFilter).
  Future<Uint8List> look(ui.Image img, CameraLook l) async {
    final svc = ShaderService.instance;
    await svc.load();
    final shader = svc.cameraShader()
      ..setFloat(0, img.width.toDouble())
      ..setFloat(1, img.height.toDouble())
      ..setImageSampler(0, img);
    l.apply(shader, await svc.blankLut(), 0);
    final rec = ui.PictureRecorder();
    ui.Canvas(rec).drawRect(
      ui.Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      ui.Paint()..shader = shader,
    );
    final out = await rec.endRecording().toImage(img.width, img.height);
    return (await out.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
  }

  testWidgets('viewfinder AF-Log matches the Dart reference curve', (tester) async {
    await tester.runAsync(() async {
      final img = await gradient(32, 24);
      final src = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
      final log = await look(img, const CameraLook(logEncode: true));
      for (var i = 0; i < src.length; i += 4 * 37) {
        final expected = AfLog.fromSrgb(src[i] / 255) * 255;
        expect(log[i], closeTo(expected, 3), reason: 'input ${src[i]}');
      }
    });
  });

  testWidgets('AF-Log monitoring + AF-Log→Rec.709 LUT round-trips', (tester) async {
    await tester.runAsync(() async {
      final svc = ShaderService.instance;
      final img = await gradient(32, 24);
      final src = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
      final lut = BuiltinLuts.byName('AF-Log → Rec.709');
      final out = await look(
        img,
        CameraLook(logEncode: true, lut: lut, lutImage: await svc.lutImage(lut)),
      );
      expect(maxDiff(src, out), lessThanOrEqualTo(6));
    });
  });
}
