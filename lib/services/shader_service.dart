import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import '../core/color/color_math.dart';
import '../core/color/lut.dart';
import '../core/composition/geometry.dart';
import '../core/edit/edit_params.dart';

/// Loads the fragment programs once and turns LUTs / curves into GPU
/// textures.
class ShaderService {
  ShaderService._();

  static final ShaderService instance = ShaderService._();

  ui.FragmentProgram? _camera;
  ui.FragmentProgram? _develop;
  final Map<Lut3D, ui.Image> _lutImages = {};

  Future<void> load() async {
    _camera ??= await ui.FragmentProgram.fromAsset('shaders/camera_look.frag');
    _develop ??= await ui.FragmentProgram.fromAsset('shaders/develop.frag');
  }

  bool get isReady => _camera != null && _develop != null;

  ui.FragmentShader cameraShader() => _camera!.fragmentShader();
  ui.FragmentShader developShader() => _develop!.fragmentShader();

  /// GPU atlas for [lut], cached per LUT instance.
  Future<ui.Image> lutImage(Lut3D lut) async {
    final cached = _lutImages[lut];
    if (cached != null) return cached;
    final img = await rgbaToImage(lut.toAtlasRgba(), lut.size * lut.size, lut.size);
    _lutImages[lut] = img;
    return img;
  }

  /// A 1x1 placeholder for unused samplers (every sampler must be bound).
  Future<ui.Image> blankLut() => lutImage(_identity2);
  static final Lut3D _identity2 = Lut3D.identity(size: 2);

  /// Per-channel composite curves (channel ∘ master) as a 256x1 texture.
  Future<ui.Image> curveImage(EditParams p) {
    final master = p.curveOf(CurveChannel.master);
    final channels = [
      p.curveOf(CurveChannel.red),
      p.curveOf(CurveChannel.green),
      p.curveOf(CurveChannel.blue),
    ];
    final bytes = Uint8List(256 * 4);
    for (var i = 0; i < 256; i++) {
      final m = master.evaluate(i / 255);
      for (var c = 0; c < 3; c++) {
        bytes[i * 4 + c] = (channels[c].evaluate(m) * 255).round().clamp(0, 255);
      }
      bytes[i * 4 + 3] = 255;
    }
    return rgbaToImage(bytes, 256, 1);
  }

  static Future<ui.Image> rgbaToImage(Uint8List rgba, int w, int h) {
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, c.complete);
    return c.future;
  }
}

/// Writes float uniforms sequentially, matching declaration order.
class _Uniforms {
  _Uniforms(this.shader);

  final ui.FragmentShader shader;
  int _i = 0;

  void f(double v) => shader.setFloat(_i++, v);
  void v2(double a, double b) {
    f(a);
    f(b);
  }

  void v3(List<double> v) => v.take(3).forEach(f);
  void v4(double a, double b, double c, double d) {
    f(a);
    f(b);
    f(c);
    f(d);
  }
}

/// Configures `camera_look.frag` for an ImageFilter over the camera preview.
class CameraLook {
  const CameraLook({
    this.lut,
    this.lutImage,
    this.lutMix = 1,
    this.logEncode = false,
    this.zebra = false,
    this.peaking = false,
  });

  final Lut3D? lut;
  final ui.Image? lutImage;
  final double lutMix;
  final bool logEncode;
  final bool zebra;
  final bool peaking;

  bool get isNeutral => lut == null && !logEncode && !zebra && !peaking;

  /// Index 0-1 (uSize) is set by the engine for image filters; we start at 2.
  void apply(ui.FragmentShader s, ui.Image blank, double timeSeconds) {
    var i = 2;
    void f(double v) => s.setFloat(i++, v);
    f((lut?.size ?? 2).toDouble());
    f(lut == null ? 0 : lutMix);
    f(logEncode ? 1 : 0);
    f(lut?.inputSpace == LutInputSpace.afLog ? 1 : 0);
    f(zebra ? 1 : 0);
    f(peaking ? 1 : 0);
    f(timeSeconds);
    // Sampler 0 is the preview (engine-bound); 1 is the LUT atlas.
    s.setImageSampler(1, lutImage ?? blank);
  }
}

/// Configures `develop.frag` from an [EditParams].
class DevelopShader {
  DevelopShader._();

  static void configure(
    ui.FragmentShader s, {
    required Size outputSize,
    required ui.Image image,
    required EditParams params,
    required ui.Image lutImage,
    required ui.Image curveImage,
    Lut3D? lut,
  }) {
    final u = _Uniforms(s);
    final crop = params.crop ?? const Box(0, 0, 1, 1);
    u.v2(outputSize.width, outputSize.height);
    u.v2(image.width.toDouble(), image.height.toDouble());
    u.v4(crop.left, crop.top, crop.width, crop.height);
    u.f(params.rotationDegrees * 3.141592653589793 / 180);

    double n(Adjust a) => params[a] / 100;
    u.f(params[Adjust.exposure]);
    u.f(n(Adjust.contrast));
    u.f(n(Adjust.highlights));
    u.f(n(Adjust.shadows));
    u.f(n(Adjust.whites));
    u.f(n(Adjust.blacks));
    u.f(n(Adjust.temperature));
    u.f(n(Adjust.tint));
    u.f(n(Adjust.vibrance));
    u.f(n(Adjust.saturation));
    u.f(n(Adjust.clarity));
    u.f(n(Adjust.dehaze));
    u.f(n(Adjust.vignette));
    u.f(n(Adjust.grain));
    u.f(n(Adjust.grainSize));
    u.f(n(Adjust.sharpness));

    final bands = HslBand.values;
    double h(int i) => params.hslOf(bands[i]).hue / 100;
    double sa(int i) => params.hslOf(bands[i]).saturation / 100;
    double l(int i) => params.hslOf(bands[i]).luminance / 100;
    u.v4(h(0), h(1), h(2), h(3));
    u.v4(h(4), h(5), h(6), h(7));
    u.v4(sa(0), sa(1), sa(2), sa(3));
    u.v4(sa(4), sa(5), sa(6), sa(7));
    u.v4(l(0), l(1), l(2), l(3));
    u.v4(l(4), l(5), l(6), l(7));

    u.v3(_tint(params.grade.shadowHue, params.grade.shadowSat));
    u.v3(_tint(params.grade.highlightHue, params.grade.highlightSat));
    u.f(params.grade.balance / 100);

    u.f((lut?.size ?? 2).toDouble());
    u.f(lut == null ? 0 : params.lutIntensity);
    u.f(lut?.inputSpace == LutInputSpace.afLog ? 1 : 0);
    final curvesOn = params.curves.values.any((c) => !c.isIdentity);
    u.f(curvesOn ? 1 : 0);

    s.setImageSampler(0, image, filterQuality: ui.FilterQuality.medium);
    s.setImageSampler(1, lutImage);
    s.setImageSampler(2, curveImage, filterQuality: ui.FilterQuality.medium);
  }

  /// Colour-wheel offset: hue at [sat] (0..100), luminance-neutral.
  static List<double> _tint(double hue, double sat) {
    final rgb = hsvToRgb(hue, 1, 1);
    final l = luma(rgb[0], rgb[1], rgb[2]);
    final k = sat / 100 * 0.18;
    return [(rgb[0] - l) * k, (rgb[1] - l) * k, (rgb[2] - l) * k];
  }
}

/// Paints a developed image into the available box (preview).
class DevelopPainter extends CustomPainter {
  DevelopPainter({
    required this.shader,
    required this.image,
    required this.params,
    required this.lutImage,
    required this.curveImage,
    this.lut,
  });

  final ui.FragmentShader shader;
  final ui.Image image;
  final EditParams params;
  final ui.Image lutImage;
  final ui.Image curveImage;
  final Lut3D? lut;

  @override
  void paint(Canvas canvas, Size size) {
    DevelopShader.configure(
      shader,
      outputSize: size,
      image: image,
      params: params,
      lutImage: lutImage,
      curveImage: curveImage,
      lut: lut,
    );
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(DevelopPainter old) =>
      old.params != params ||
      old.image != image ||
      old.lutImage != lutImage ||
      old.curveImage != curveImage;
}

/// Offscreen render of [image] developed with [params], at the cropped
/// size capped to [maxSide]. Used for export, thumbnails and histograms.
Future<ui.Image> renderDevelopedImage({
  required ui.Image image,
  required EditParams params,
  Lut3D? lut,
  int maxSide = 8192,
}) async {
  final svc = ShaderService.instance;
  await svc.load();
  final crop = params.crop ?? const Box(0, 0, 1, 1);
  var w = (image.width * crop.width).round();
  var h = (image.height * crop.height).round();
  final longest = w > h ? w : h;
  if (longest > maxSide) {
    w = (w * maxSide / longest).round();
    h = (h * maxSide / longest).round();
  }
  w = w < 1 ? 1 : w;
  h = h < 1 ? 1 : h;
  final shader = svc.developShader();
  final lutImg = lut == null ? await svc.blankLut() : await svc.lutImage(lut);
  final curve = await svc.curveImage(params);
  DevelopShader.configure(
    shader,
    outputSize: Size(w.toDouble(), h.toDouble()),
    image: image,
    params: params,
    lutImage: lutImg,
    curveImage: curve,
    lut: lut,
  );
  final recorder = ui.PictureRecorder();
  Canvas(recorder)
      .drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..shader = shader);
  final picture = recorder.endRecording();
  final out = await picture.toImage(w, h);
  picture.dispose();
  shader.dispose();
  curve.dispose();
  return out;
}

/// Full-resolution offscreen render for export. Returns raw RGBA8.
Future<({Uint8List rgba, int width, int height})> renderDeveloped({
  required ui.Image image,
  required EditParams params,
  Lut3D? lut,
  int maxSide = 8192,
}) async {
  final out = await renderDevelopedImage(image: image, params: params, lut: lut, maxSide: maxSide);
  final data = await out.toByteData(format: ui.ImageByteFormat.rawRgba);
  final result = (rgba: data!.buffer.asUint8List(), width: out.width, height: out.height);
  out.dispose();
  return result;
}
