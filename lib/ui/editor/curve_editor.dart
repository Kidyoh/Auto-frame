import 'package:flutter/material.dart';

import '../../core/edit/edit_params.dart';
import '../../core/edit/tone_curve.dart';
import '../theme.dart';

/// Lightroom-style point curve: tap to add a point, drag to move, double-tap
/// a point to remove it. End points move vertically only.
class CurveEditor extends StatefulWidget {
  const CurveEditor({
    super.key,
    required this.curve,
    required this.channel,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final ToneCurve curve;
  final CurveChannel channel;
  final ValueChanged<ToneCurve> onChanged;
  final VoidCallback onChangeEnd;

  @override
  State<CurveEditor> createState() => _CurveEditorState();
}

class _CurveEditorState extends State<CurveEditor> {
  int? _drag;

  Color get _color => switch (widget.channel) {
    CurveChannel.master => Colors.white,
    CurveChannel.red => const Color(0xFFFF5A5A),
    CurveChannel.green => const Color(0xFF5BE38C),
    CurveChannel.blue => const Color(0xFF5AA8FF),
  };

  (double, double) _toCurve(Offset p, Size s) =>
      ((p.dx / s.width).clamp(0.0, 1.0), (1 - p.dy / s.height).clamp(0.0, 1.0));

  int? _hit(Offset p, Size s) {
    final pts = widget.curve.points;
    for (var i = 0; i < pts.length; i++) {
      final o = Offset(pts[i].$1 * s.width, (1 - pts[i].$2) * s.height);
      if ((o - p).distance < 22) return i;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: LayoutBuilder(
        builder: (context, box) {
          final size = box.biggest;
          return GestureDetector(
            onPanStart: (d) {
              var i = _hit(d.localPosition, size);
              if (i == null) {
                final (x, y) = _toCurve(d.localPosition, size);
                final pts = [...widget.curve.points, (x, widget.curve.evaluate(x))];
                final next = ToneCurve(pts);
                i = next.points.indexWhere((p) => p.$1 == x);
                widget.onChanged(next);
              }
              setState(() => _drag = i);
            },
            onPanUpdate: (d) {
              final i = _drag;
              if (i == null) return;
              final pts = widget.curve.points;
              var (x, y) = _toCurve(d.localPosition, size);
              if (i == 0) x = 0;
              if (i == pts.length - 1) x = 1;
              // Keep points ordered.
              if (i > 0) x = x.clamp(pts[i - 1].$1 + 0.01, 1.0);
              if (i < pts.length - 1) x = x.clamp(0.0, pts[i + 1].$1 - 0.01);
              widget.onChanged(widget.curve.withPoint(i, (x, y)));
            },
            onPanEnd: (_) {
              setState(() => _drag = null);
              widget.onChangeEnd();
            },
            onDoubleTapDown: (d) {
              final i = _hit(d.localPosition, size);
              final pts = widget.curve.points;
              if (i == null || i == 0 || i == pts.length - 1) return;
              widget.onChanged(ToneCurve([...pts]..removeAt(i)));
              widget.onChangeEnd();
            },
            onDoubleTap: () {},
            child: CustomPaint(painter: _CurvePainter(widget.curve, _color, _drag), size: size),
          );
        },
      ),
    );
  }
}

class _CurvePainter extends CustomPainter {
  _CurvePainter(this.curve, this.color, this.active);

  final ToneCurve curve;
  final Color color;
  final int? active;

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = AfColors.surfaceHigh;
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8)), bg);
    final grid = Paint()
      ..color = Colors.white12
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final x = size.width * i / 4, y = size.height * i / 4;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    canvas.drawLine(Offset(0, size.height), Offset(size.width, 0), grid..color = Colors.white24);

    final path = Path();
    for (var i = 0; i <= 100; i++) {
      final x = i / 100;
      final p = Offset(x * size.width, (1 - curve.evaluate(x)) * size.height);
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    for (final (i, pt) in curve.points.indexed) {
      final o = Offset(pt.$1 * size.width, (1 - pt.$2) * size.height);
      canvas.drawCircle(o, i == active ? 8 : 6, Paint()..color = color);
      canvas.drawCircle(
        o,
        i == active ? 8 : 6,
        Paint()
          ..color = Colors.black
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(_CurvePainter old) =>
      old.curve != curve || old.color != color || old.active != active;
}
