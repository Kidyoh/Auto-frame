import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/composition/geometry.dart';
import '../../core/edit/edit_params.dart';
import '../../services/lut_library.dart';
import '../../services/shader_service.dart';

/// Displays [image] through the develop shader with [params], sized to the
/// params' crop aspect. Handles LUT / curve textures itself.
class DevelopedImage extends StatefulWidget {
  const DevelopedImage({super.key, required this.image, required this.params});

  final ui.Image image;
  final EditParams params;

  @override
  State<DevelopedImage> createState() => _DevelopedImageState();
}

class _DevelopedImageState extends State<DevelopedImage> {
  ui.FragmentShader? _shader;
  ui.Image? _lut;
  ui.Image? _curve;
  ui.Image? _blank;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void didUpdateWidget(DevelopedImage old) {
    super.didUpdateWidget(old);
    if (old.params.lutName != widget.params.lutName || old.params.curves != widget.params.curves) {
      _prepare();
    }
  }

  Future<void> _prepare() async {
    final svc = ShaderService.instance;
    await svc.load();
    final lut = LutLibrary.instance.byName(widget.params.lutName);
    final blank = await svc.blankLut();
    final lutImg = lut == null ? null : await svc.lutImage(lut);
    final curve = await svc.curveImage(widget.params);
    if (!mounted) return;
    setState(() {
      _shader ??= svc.developShader();
      _blank = blank;
      _lut = lutImg;
      _curve?.dispose();
      _curve = curve;
    });
  }

  @override
  void dispose() {
    _shader?.dispose();
    _curve?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final crop = widget.params.crop ?? const Box(0, 0, 1, 1);
    final aspect = (widget.image.width * crop.width) / (widget.image.height * crop.height);
    final ready = _shader != null && _curve != null && _blank != null;
    final lut = LutLibrary.instance.byName(widget.params.lutName);
    return AspectRatio(
      aspectRatio: aspect,
      child: ready
          ? CustomPaint(
              painter: DevelopPainter(
                shader: _shader!,
                image: widget.image,
                params: widget.params,
                lutImage: _lut ?? _blank!,
                curveImage: _curve!,
                lut: _lut == null ? null : lut,
              ),
            )
          : const ColoredBox(color: Colors.black),
    );
  }
}
