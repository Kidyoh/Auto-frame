import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/composition/composition_engine.dart';
import '../../core/composition/subject.dart';
import '../../services/camera_service.dart';
import '../../services/motion_service.dart';
import '../../services/vision_service.dart';
import '../theme.dart';

/// Rule-of-thirds and/or golden-ratio (phi) grid.
class GridPainter extends CustomPainter {
  GridPainter(this.style);

  final GridStyle style;

  @override
  void paint(Canvas canvas, Size size) {
    if (style == GridStyle.off) return;
    final thirds = Paint()
      ..color = Colors.white.withValues(alpha: 0.35)
      ..strokeWidth = 0.8;
    final phi = Paint()
      ..color = AfColors.gold.withValues(alpha: 0.45)
      ..strokeWidth = 0.8;
    void lines(List<double> fr, Paint p) {
      for (final f in fr) {
        canvas.drawLine(Offset(size.width * f, 0), Offset(size.width * f, size.height), p);
        canvas.drawLine(Offset(0, size.height * f), Offset(size.width, size.height * f), p);
      }
    }

    if (style == GridStyle.thirds || style == GridStyle.both) lines([1 / 3, 2 / 3], thirds);
    if (style == GridStyle.golden || style == GridStyle.both) lines([0.382, 0.618], phi);
  }

  @override
  bool shouldRepaint(GridPainter old) => old.style != style;
}

/// Face brackets, the composition target and the frame score.
class GuidancePainter extends CustomPainter {
  GuidancePainter({required this.analysis, required this.guidance});

  final SceneAnalysis analysis;
  final FramingGuidance guidance;

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / analysis.width, sy = size.height / analysis.height;
    Paint bracket(Color c) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    final face = bracket(Colors.white.withValues(alpha: 0.9));
    final other = bracket(Colors.white54);
    for (final s in analysis.subjects) {
      final r = Rect.fromLTWH(s.box.left * sx, s.box.top * sy, s.box.width * sx, s.box.height * sy);
      _brackets(canvas, r, s.kind == SubjectKind.face ? face : other);
    }

    final a = guidance.anchor, t = guidance.target;
    if (a != null && t != null) {
      final from = Offset(a.$1 * size.width, a.$2 * size.height);
      final to = Offset(t.$1 * size.width, t.$2 * size.height);
      final aligned = (from - to).distance < size.shortestSide * 0.05;
      final color = aligned ? AfColors.good : AfColors.gold;
      canvas.drawCircle(
        to,
        14,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
      canvas.drawCircle(to, 3, Paint()..color = color);
      if (!aligned) {
        final p = Paint()
          ..color = color.withValues(alpha: 0.8)
          ..strokeWidth = 1.5;
        _dashed(canvas, from, to, p);
        canvas.drawCircle(from, 4, Paint()..color = Colors.white);
      }
    }
  }

  void _brackets(Canvas c, Rect r, Paint p) {
    final l = math.min(r.width, r.height) * 0.22;
    for (final (o, dx, dy) in [
      (r.topLeft, 1.0, 1.0),
      (r.topRight, -1.0, 1.0),
      (r.bottomLeft, 1.0, -1.0),
      (r.bottomRight, -1.0, -1.0),
    ]) {
      c.drawLine(o, o + Offset(l * dx, 0), p);
      c.drawLine(o, o + Offset(0, l * dy), p);
    }
  }

  void _dashed(Canvas c, Offset a, Offset b, Paint p) {
    final d = b - a;
    final len = d.distance;
    if (len < 1) return;
    final dir = d / len;
    for (var s = 0.0; s < len - 16; s += 10) {
      c.drawLine(a + dir * s, a + dir * math.min(s + 5, len - 16), p);
    }
  }

  @override
  bool shouldRepaint(GuidancePainter old) => old.analysis != analysis || old.guidance != guidance;
}

/// Artificial horizon: a split line that rotates with the device and snaps
/// gold when level.
class LevelIndicator extends StatelessWidget {
  const LevelIndicator({super.key, required this.attitude});

  final Attitude attitude;

  @override
  Widget build(BuildContext context) {
    if (!attitude.isReliable || attitude.roll.abs() > 25) return const SizedBox.shrink();
    final level = attitude.isLevel;
    final color = level ? AfColors.gold : Colors.white;
    return IgnorePointer(
      child: Center(
        child: SizedBox(
          width: 220,
          height: 40,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Fixed reference ticks.
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(width: 18, height: 1.5, color: color.withValues(alpha: 0.7)),
                  Container(width: 18, height: 1.5, color: color.withValues(alpha: 0.7)),
                ],
              ),
              Transform.rotate(
                angle: -attitude.roll * math.pi / 180,
                child: Container(width: 150, height: level ? 2 : 1.2, color: color),
              ),
              if (!level)
                Positioned(
                  bottom: 0,
                  child: Text(
                    '${attitude.roll.abs().toStringAsFixed(1)}°',
                    style: const TextStyle(fontSize: 10, color: Colors.white70),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Score badge + coaching hint at the top of the viewfinder.
class ScoreBadge extends StatelessWidget {
  const ScoreBadge({super.key, required this.guidance, required this.hasSubject});

  final FramingGuidance guidance;
  final bool hasSubject;

  @override
  Widget build(BuildContext context) {
    final score = guidance.score.round();
    final color = AfColors.forScore(guidance.score);
    final hint = guidance.hints.isEmpty
        ? (hasSubject ? 'Great framing' : 'Looking for a subject…')
        : guidance.hints.first;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$score',
            style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 15),
          ),
          const SizedBox(width: 8),
          Text(hint, style: const TextStyle(color: AfColors.text, fontSize: 12.5)),
        ],
      ),
    );
  }
}

/// Animated focus reticle shown where the user tapped.
class FocusReticle extends StatelessWidget {
  const FocusReticle({super.key, required this.position});

  final Offset position;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: position.dx - 36,
      top: position.dy - 36,
      child: IgnorePointer(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 1.4, end: 1),
          duration: const Duration(milliseconds: 220),
          builder: (context, s, child) => Transform.scale(scale: s, child: child),
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              border: Border.all(color: AfColors.gold, width: 1.4),
              borderRadius: BorderRadius.circular(6),
            ),
          ),
        ),
      ),
    );
  }
}
