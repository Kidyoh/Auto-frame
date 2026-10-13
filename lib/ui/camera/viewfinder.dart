import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../services/camera_service.dart';
import '../../services/lut_library.dart';
import '../../services/motion_service.dart';
import '../../services/shader_service.dart';
import 'overlays.dart';

/// Live preview with GPU look (AF-Log / LUT / zebras / peaking), grids,
/// composition guidance, horizon level, tap-to-focus and pinch-to-zoom.
class Viewfinder extends StatefulWidget {
  const Viewfinder({super.key, required this.camera, required this.motion});

  final CameraService camera;
  final MotionService motion;

  @override
  State<Viewfinder> createState() => _ViewfinderState();
}

class _ViewfinderState extends State<Viewfinder> with SingleTickerProviderStateMixin {
  ui.FragmentShader? _shader;
  ui.Image? _lutImage;
  ui.Image? _blank;
  String? _lutFor;
  Offset? _focus;
  double _zoomStart = 1;
  late final Ticker _ticker;
  double _time = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((d) {
      setState(() => _time = d.inMicroseconds / 1e6);
    });
    _prepare();
  }

  Future<void> _prepare() async {
    final svc = ShaderService.instance;
    await svc.load();
    _blank = await svc.blankLut();
    if (!mounted) return;
    setState(() => _shader = svc.cameraShader());
  }

  Future<void> _syncLut() async {
    final name = widget.camera.lutName;
    if (name == _lutFor) return;
    _lutFor = name;
    final lut = LutLibrary.instance.byName(name);
    final img = lut == null ? null : await ShaderService.instance.lutImage(lut);
    if (mounted && _lutFor == name) setState(() => _lutImage = img);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cam = widget.camera;
    final c = cam.controller;
    if (c == null || !c.value.isInitialized) {
      return const ColoredBox(color: Colors.black);
    }
    _syncLut();
    final wantsTicker = cam.zebra;
    if (wantsTicker && !_ticker.isActive) _ticker.start();
    if (!wantsTicker && _ticker.isActive) _ticker.stop();

    final lut = LutLibrary.instance.byName(cam.lutName);
    final look = CameraLook(
      lut: lut,
      lutImage: _lutImage,
      lutMix: cam.lutMix,
      logEncode: cam.logView,
      zebra: cam.zebra,
      peaking: cam.peaking,
    );

    Widget preview = CameraPreview(c);
    final shader = _shader;
    if (shader != null &&
        _blank != null &&
        !look.isNeutral &&
        ui.ImageFilter.isShaderFilterSupported) {
      look.apply(shader, _blank!, _time);
      preview = ImageFiltered(imageFilter: ui.ImageFilter.shader(shader), child: preview);
    }

    // Preview aspect is reported in landscape; the UI is portrait.
    final aspect = 1 / c.value.aspectRatio;
    return AspectRatio(
      aspectRatio: aspect,
      child: LayoutBuilder(
        builder: (context, box) {
          final size = box.biggest;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) {
              setState(() => _focus = d.localPosition);
              cam.focusAt(
                Offset(d.localPosition.dx / size.width, d.localPosition.dy / size.height),
              );
              Future.delayed(const Duration(milliseconds: 1400), () {
                if (mounted) setState(() => _focus = null);
              });
            },
            onScaleStart: (_) => _zoomStart = cam.zoom,
            onScaleUpdate: (d) {
              if (d.pointerCount >= 2) cam.setZoom(_zoomStart * d.scale);
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                preview,
                IgnorePointer(child: CustomPaint(painter: GridPainter(cam.grid))),
                if (cam.guidanceOn && cam.mode != CaptureMode.video)
                  IgnorePointer(
                    child: CustomPaint(
                      painter: GuidancePainter(analysis: cam.analysis, guidance: cam.guidance),
                    ),
                  ),
                ValueListenableBuilder<Attitude>(
                  valueListenable: widget.motion,
                  builder: (context, a, _) => LevelIndicator(attitude: a),
                ),
                if (cam.guidanceOn && cam.mode != CaptureMode.video)
                  Positioned(
                    top: 12,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: ScoreBadge(
                        guidance: cam.guidance,
                        hasSubject: cam.analysis.subjects.isNotEmpty,
                      ),
                    ),
                  ),
                if (cam.logView || cam.lutName != null)
                  Positioned(
                    left: 10,
                    bottom: 10,
                    child: _LookTag(
                      text: [
                        if (cam.logView) 'AF-LOG',
                        if (cam.lutName != null) cam.lutName!,
                      ].join(' · '),
                    ),
                  ),
                if (_focus != null) FocusReticle(position: _focus!),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _LookTag extends StatelessWidget {
  const _LookTag({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)),
      child: Text(
        text,
        style: const TextStyle(fontSize: 10.5, letterSpacing: 1, color: Colors.white),
      ),
    );
  }
}
