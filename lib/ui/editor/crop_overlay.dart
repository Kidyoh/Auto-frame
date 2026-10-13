import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/composition/geometry.dart';
import '../theme.dart';

/// Interactive crop rectangle over the (rotated, uncropped) image. Drag the
/// middle to move, drag a corner to resize. [aspect] (pixel width/height)
/// locks the ratio when set. [imageAspect] converts normalised units to
/// pixel ratios.
class CropOverlay extends StatefulWidget {
  const CropOverlay({
    super.key,
    required this.crop,
    required this.imageAspect,
    required this.onChanged,
    required this.onChangeEnd,
    this.aspect,
  });

  final Box crop;
  final double imageAspect;
  final double? aspect;
  final ValueChanged<Box> onChanged;
  final VoidCallback onChangeEnd;

  @override
  State<CropOverlay> createState() => _CropOverlayState();
}

class _CropOverlayState extends State<CropOverlay> {
  int _corner = -1; // -1 = move, 0..3 = TL, TR, BL, BR
  Box _start = const Box(0, 0, 1, 1);
  Offset _origin = Offset.zero;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final size = box.biggest;
        final c = widget.crop;
        final rect = Rect.fromLTWH(
          c.left * size.width,
          c.top * size.height,
          c.width * size.width,
          c.height * size.height,
        );
        return GestureDetector(
          onPanStart: (d) {
            _start = widget.crop;
            _origin = d.localPosition;
            final corners = [rect.topLeft, rect.topRight, rect.bottomLeft, rect.bottomRight];
            _corner = -1;
            for (var i = 0; i < 4; i++) {
              if ((corners[i] - d.localPosition).distance < 36) _corner = i;
            }
          },
          onPanUpdate: (d) {
            final dx = (d.localPosition.dx - _origin.dx) / size.width;
            final dy = (d.localPosition.dy - _origin.dy) / size.height;
            widget.onChanged(_corner < 0 ? _move(dx, dy) : _resize(dx, dy));
          },
          onPanEnd: (_) => widget.onChangeEnd(),
          child: CustomPaint(size: size, painter: _CropPainter(rect)),
        );
      },
    );
  }

  Box _move(double dx, double dy) {
    final s = _start;
    final l = (s.left + dx).clamp(0.0, 1 - s.width);
    final t = (s.top + dy).clamp(0.0, 1 - s.height);
    return Box(l, t, s.width, s.height);
  }

  Box _resize(double dx, double dy) {
    final s = _start;
    var l = s.left, t = s.top, r = s.right, b = s.bottom;
    const minSize = 0.08;
    switch (_corner) {
      case 0:
        l = (l + dx).clamp(0.0, r - minSize);
        t = (t + dy).clamp(0.0, b - minSize);
      case 1:
        r = (r + dx).clamp(l + minSize, 1.0);
        t = (t + dy).clamp(0.0, b - minSize);
      case 2:
        l = (l + dx).clamp(0.0, r - minSize);
        b = (b + dy).clamp(t + minSize, 1.0);
      default:
        r = (r + dx).clamp(l + minSize, 1.0);
        b = (b + dy).clamp(t + minSize, 1.0);
    }
    final a = widget.aspect;
    if (a != null) {
      // Normalised height that yields the pixel aspect for this width.
      var w = r - l;
      var h = w * widget.imageAspect / a;
      final maxH = (_corner < 2) ? b : 1 - t;
      if (h > maxH) {
        h = maxH;
        w = h * a / widget.imageAspect;
      }
      if (_corner == 0 || _corner == 2) l = r - w;
      if (_corner == 1 || _corner == 3) r = l + w;
      if (_corner < 2) {
        t = b - h;
      } else {
        b = t + h;
      }
      l = math.max(0, l);
      t = math.max(0, t);
    }
    return Box.fromLTRB(l, t, r, b);
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter(this.rect);

  final Rect rect;

  @override
  void paint(Canvas canvas, Size size) {
    final shade = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(rect);
    canvas.drawPath(shade, Paint()..color = Colors.black.withValues(alpha: 0.6));
    final line = Paint()
      ..color = Colors.white70
      ..strokeWidth = 0.7;
    for (final f in [1 / 3, 2 / 3]) {
      canvas.drawLine(
        Offset(rect.left + rect.width * f, rect.top),
        Offset(rect.left + rect.width * f, rect.bottom),
        line,
      );
      canvas.drawLine(
        Offset(rect.left, rect.top + rect.height * f),
        Offset(rect.right, rect.top + rect.height * f),
        line,
      );
    }
    canvas.drawRect(
      rect,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
    final corner = Paint()
      ..color = AfColors.gold
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;
    const l = 18.0;
    for (final (o, dx, dy) in [
      (rect.topLeft, 1.0, 1.0),
      (rect.topRight, -1.0, 1.0),
      (rect.bottomLeft, 1.0, -1.0),
      (rect.bottomRight, -1.0, -1.0),
    ]) {
      canvas.drawLine(o, o + Offset(l * dx, 0), corner);
      canvas.drawLine(o, o + Offset(0, l * dy), corner);
    }
  }

  @override
  bool shouldRepaint(_CropPainter old) => old.rect != rect;
}
