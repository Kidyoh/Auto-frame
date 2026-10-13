import 'dart:math' as math;

import 'geometry.dart';
import 'subject.dart';

/// A target crop shape. `ratio` is width / height; `null` keeps the source
/// aspect.
class AspectSpec {
  const AspectSpec(this.label, this.ratio);

  final String label;
  final double? ratio;

  static const original = AspectSpec('Original', null);
  static const square = AspectSpec('1:1', 1);
  static const portrait45 = AspectSpec('4:5', 4 / 5);
  static const story = AspectSpec('9:16', 9 / 16);
  static const wide169 = AspectSpec('16:9', 16 / 9);
  static const cinema = AspectSpec('2.39:1', 2.39);
  static const classic32 = AspectSpec('3:2', 3 / 2);

  static const all = [original, portrait45, square, story, classic32, wide169, cinema];
}

/// One proposed framing.
class CropSuggestion {
  const CropSuggestion({
    required this.aspect,
    required this.crop,
    required this.rotationDegrees,
    required this.score,
    required this.notes,
  });

  final AspectSpec aspect;

  /// Crop in normalised coordinates of the *rotated* image (0..1).
  final Box crop;

  /// Rotate the source image clockwise by this many degrees (about its
  /// centre, canvas size unchanged) before applying [crop].
  final double rotationDegrees;

  /// 0..100 "frame score".
  final double score;

  /// Human-readable reasons, e.g. "Eyes on upper third".
  final List<String> notes;
}

/// Live guidance for the viewfinder.
class FramingGuidance {
  const FramingGuidance({required this.score, required this.hints, this.anchor, this.target});

  final double score;
  final List<String> hints;

  /// Current subject anchor and the power point it should move to,
  /// normalised to the frame.
  final (double, double)? anchor;
  final (double, double)? target;

  static const empty = FramingGuidance(score: 0, hints: []);
}

/// Scores crops using classical composition rules:
/// rule of thirds / golden ratio placement, headroom, lead room, subject
/// scale, no amputations, edge tension, horizon level.
class CompositionEngine {
  const CompositionEngine({
    this.maxStraighten = 12,
    this.positionSteps = 17,
    this.scales = const [1.0, 0.93, 0.86, 0.79, 0.72, 0.65, 0.58, 0.5],
  });

  /// Tilts beyond this many degrees are treated as intentional (Dutch angle).
  final double maxStraighten;
  final int positionSteps;
  final List<double> scales;

  static const _thirds = [1 / 3, 2 / 3];
  static const _golden = [0.382, 0.618];

  /// Best crop per requested aspect, highest score first.
  List<CropSuggestion> suggest({
    required double width,
    required double height,
    required List<Subject> subjects,
    double horizonTiltDegrees = 0,
    List<AspectSpec> aspects = AspectSpec.all,
  }) {
    final rotation = horizonTiltDegrees.abs() <= maxStraighten ? -horizonTiltDegrees : 0.0;
    final rad = rotation * math.pi / 180;
    final cx = width / 2, cy = height / 2;

    // Subjects as they appear after straightening.
    final rotated = subjects.map((s) {
      final (x, y) = rotatePoint(s.box.cx, s.box.cy, cx, cy, rad);
      return s.copyWith(
        box: Box(x - s.box.width / 2, y - s.box.height / 2, s.box.width, s.box.height),
      );
    }).toList();

    final results = <CropSuggestion>[];
    for (final aspect in aspects) {
      final best = _bestForAspect(width, height, rotated, aspect, rad);
      if (best == null) continue;
      final notes = <String>[
        ...best.notes,
        if (rotation.abs() > 0.3) 'Horizon levelled ${rotation.toStringAsFixed(1)}°',
      ];
      results.add(
        CropSuggestion(
          aspect: aspect,
          crop: best.crop.scale(1 / width, 1 / height),
          rotationDegrees: rotation,
          score: best.score,
          notes: notes,
        ),
      );
    }
    results.sort((a, b) => b.score.compareTo(a.score));
    return results;
  }

  /// Score the frame as-is and tell the photographer how to improve it.
  FramingGuidance guide({
    required double width,
    required double height,
    required List<Subject> subjects,
    double horizonTiltDegrees = 0,
  }) {
    final hints = <String>[];
    if (horizonTiltDegrees.abs() > 1.5 && horizonTiltDegrees.abs() <= maxStraighten) {
      hints.add('Level the horizon');
    }
    if (subjects.isEmpty) {
      final levelScore = 60 - math.min(horizonTiltDegrees.abs(), 10) * 4;
      return FramingGuidance(score: levelScore.clamp(0, 100).toDouble(), hints: hints);
    }

    final frame = Box(0, 0, width, height);
    final eval = _evaluate(frame, subjects, width, height, 1.0);
    final (ax, ay) = _anchorOf(subjects);
    final u = ax / width, v = ay / height;
    final target = _nearestPowerPoint(u, v, subjects);

    // Camera moves opposite to where the subject needs to go in frame.
    final du = target.$1 - u, dv = target.$2 - v;
    if (du.abs() > 0.06) hints.add(du < 0 ? 'Pan right' : 'Pan left');
    if (dv.abs() > 0.06) hints.add(dv < 0 ? 'Tilt down' : 'Tilt up');

    final cover = _coverage(subjects, frame);
    if (eval.cutPenalty > 0.05) {
      hints.add('Step back — subject is cut off');
    } else if (cover < 0.02) {
      hints.add('Move closer');
    } else if (cover > 0.6) {
      hints.add('Step back for breathing room');
    }

    final tiltPenalty = math.min(horizonTiltDegrees.abs(), 10) * 2.5;
    return FramingGuidance(
      score: (eval.score - tiltPenalty).clamp(0, 100).toDouble(),
      hints: hints,
      anchor: (u, v),
      target: target,
    );
  }

  // ---------------------------------------------------------------------

  _Eval? _bestForAspect(double w, double h, List<Subject> subjects, AspectSpec aspect, double rad) {
    final ratio = aspect.ratio ?? w / h;
    double maxW, maxH;
    if (ratio > w / h) {
      maxW = w;
      maxH = w / ratio;
    } else {
      maxH = h;
      maxW = h * ratio;
    }

    _Eval? best;
    for (final s in scales) {
      final cw = maxW * s, ch = maxH * s;
      final xRange = w - cw, yRange = h - ch;
      final xs = xRange < 1 ? 1 : positionSteps;
      final ys = yRange < 1 ? 1 : positionSteps;
      for (var iy = 0; iy < ys; iy++) {
        for (var ix = 0; ix < xs; ix++) {
          final x = xs == 1 ? xRange / 2 : xRange * ix / (xs - 1);
          final y = ys == 1 ? yRange / 2 : yRange * iy / (ys - 1);
          final crop = Box(x, y, cw, ch);
          if (rad != 0 && !_insideRotated(crop, w, h, rad)) continue;
          final e = _evaluate(crop, subjects, w, h, s);
          if (best == null || e.score > best.score) best = e;
        }
      }
    }

    // When straightening, the full-size crops may all be invalid; shrink the
    // best centred crop until it fits so we always return something.
    if (best == null) {
      for (var s = scales.last; s > 0.2; s -= 0.05) {
        final cw = maxW * s, ch = maxH * s;
        final crop = Box((w - cw) / 2, (h - ch) / 2, cw, ch);
        if (_insideRotated(crop, w, h, rad)) {
          best = _evaluate(crop, subjects, w, h, s);
          break;
        }
      }
    }
    return best;
  }

  /// Whether [crop] (in the rotated output) only samples real source pixels.
  bool _insideRotated(Box crop, double w, double h, double rad) {
    final cx = w / 2, cy = h / 2;
    const eps = 0.5;
    for (final (px, py) in [
      (crop.left, crop.top),
      (crop.right, crop.top),
      (crop.left, crop.bottom),
      (crop.right, crop.bottom),
    ]) {
      final (sx, sy) = rotatePoint(px, py, cx, cy, -rad);
      if (sx < -eps || sy < -eps || sx > w + eps || sy > h + eps) return false;
    }
    return true;
  }

  _Eval _evaluate(Box crop, List<Subject> subjects, double imageW, double imageH, double scale) {
    final notes = <String>[];
    if (subjects.isEmpty) {
      // Nothing detected: prefer large, centred, levelled frames.
      final off = (crop.cx / imageW - 0.5).abs() + (crop.cy / imageH - 0.5).abs();
      return _Eval(crop, 40 + 30 * scale + 10 * (1 - off), notes, 0);
    }

    // 1. Amputations.
    var cut = 0.0;
    var edge = 0.0;
    for (final s in subjects) {
      final inside = s.box.intersect(crop).area;
      final frac = s.box.area <= 0 ? 0 : 1 - inside / s.box.area;
      cut += frac * s.cutCost * s.weight;
      if (frac < 0.01) {
        // Fully inside, but kissing the border creates tension.
        final m = 0.015 * math.max(crop.width, crop.height);
        final touches =
            (s.box.left - crop.left < m) ||
            (crop.right - s.box.right < m) ||
            (s.box.top - crop.top < m) ||
            (crop.bottom - s.box.bottom < m);
        if (touches && s.kind != SubjectKind.salient) edge += 0.15 * s.weight;
      }
    }

    // 2. Placement of the weighted anchor on a power point.
    final (ax, ay) = _anchorOf(subjects);
    final u = (ax - crop.left) / crop.width;
    final v = (ay - crop.top) / crop.height;
    var placement = 0.0;
    var placementNote = '';
    for (final px in [..._thirds, ..._golden]) {
      for (final py in [..._thirds, ..._golden]) {
        final d2 = (u - px) * (u - px) + (v - py) * (v - py);
        final sc = math.exp(-d2 / (2 * 0.055 * 0.055));
        if (sc > placement) {
          placement = sc;
          placementNote = _thirds.contains(px) ? 'Rule of thirds' : 'Golden ratio';
        }
      }
    }
    // Centred, symmetric framing is valid for a single subject facing camera.
    final single = subjects.length == 1 && subjects.first.gazeX.abs() < 0.3;
    if (single) {
      final dc = (u - 0.5) * (u - 0.5) + (v - 0.4) * (v - 0.4);
      final sc = 0.8 * math.exp(-dc / (2 * 0.045 * 0.045));
      if (sc > placement) {
        placement = sc;
        placementNote = 'Centred symmetry';
      }
    }
    // Eyes on the upper third line is the portrait classic.
    final hasFace = subjects.any((s) => s.kind == SubjectKind.face);
    if (hasFace) {
      final eyeLine = math.exp(-((v - 1 / 3) * (v - 1 / 3)) / (2 * 0.05 * 0.05));
      placement = math.max(placement, 0.55 * placement + 0.45 * eyeLine);
      if (eyeLine > 0.7) placementNote = 'Eyes on upper third';
    }
    if (placement > 0.5) notes.add(placementNote);

    // 3. Lead room: leave space in the direction the subject faces.
    final gaze = _weightedGaze(subjects);
    var lead = 0.0;
    if (gaze.abs() > 0.2) {
      lead = (gaze.sign * (0.5 - u) * 4).clamp(-1.0, 1.0) * gaze.abs();
      if (lead > 0.4) notes.add('Lead room');
    }

    // 4. Headroom above the top-most face.
    var headroom = 0.0;
    if (hasFace) {
      final top = subjects
          .where((s) => s.kind == SubjectKind.face)
          .map((s) => s.box.top - s.box.height * 0.25) // hair above bbox
          .reduce(math.min);
      final hr = (top - crop.top) / crop.height;
      if (hr < 0.03) {
        headroom = -1;
      } else if (hr < 0.25) {
        headroom = 1;
        notes.add('Balanced headroom');
      } else {
        headroom = 1 - ((hr - 0.25) * 3).clamp(0.0, 1.5);
      }
    }

    // 5. Subject scale relative to the frame.
    final cover = _coverage(subjects, crop);
    final ideal = hasFace ? 0.12 : 0.22;
    final sizeScore = math.exp(-math.pow(math.log((cover + 1e-4) / ideal), 2) / (2 * 0.9 * 0.9));

    // 6. Prefer keeping resolution.
    final resolution = math.sqrt(crop.area / (imageW * imageH));

    final raw =
        1.0 * placement +
        0.35 * lead +
        0.35 * headroom +
        0.5 * sizeScore +
        0.35 * resolution -
        1.6 * cut -
        edge;
    // Map raw (~ -2..2.5) to 0..100.
    final score = (100 / (1 + math.exp(-(raw - 1.0) * 2.2))).clamp(0.0, 100.0);
    return _Eval(crop, score, notes, cut);
  }

  (double, double) _anchorOf(List<Subject> subjects) {
    // Faces dominate; otherwise weighted by importance and area.
    final faces = subjects.where((s) => s.kind == SubjectKind.face).toList();
    final pool = faces.isNotEmpty ? faces : subjects;
    var wx = 0.0, wy = 0.0, wt = 0.0;
    for (final s in pool) {
      final w = s.weight * math.sqrt(math.max(s.box.area, 1));
      final (x, y) = s.anchor;
      wx += x * w;
      wy += y * w;
      wt += w;
    }
    return (wx / wt, wy / wt);
  }

  double _weightedGaze(List<Subject> subjects) {
    var g = 0.0, wt = 0.0;
    for (final s in subjects) {
      g += s.gazeX * s.weight;
      wt += s.weight;
    }
    return wt == 0 ? 0 : g / wt;
  }

  double _coverage(List<Subject> subjects, Box frame) {
    Box? u;
    for (final s in subjects) {
      final i = s.box.intersect(frame);
      if (i.area <= 0) continue;
      u = u == null ? i : u.union(i);
    }
    return u == null ? 0 : u.area / frame.area;
  }

  (double, double) _nearestPowerPoint(double u, double v, List<Subject> subjects) {
    final pts = <(double, double)>[
      for (final x in _thirds)
        for (final y in _thirds) (x, y),
    ];
    if (subjects.length == 1 && subjects.first.gazeX.abs() < 0.3) {
      pts.add((0.5, subjects.first.kind == SubjectKind.face ? 1 / 3 : 0.5));
    }
    final gaze = _weightedGaze(subjects);
    (double, double) best = pts.first;
    var bestD = double.infinity;
    for (final p in pts) {
      var d = (p.$1 - u) * (p.$1 - u) + (p.$2 - v) * (p.$2 - v);
      // Bias toward the side that leaves lead room.
      if (gaze.abs() > 0.3 && (p.$1 - 0.5).sign == gaze.sign) d += 0.05;
      if (d < bestD) {
        bestD = d;
        best = p;
      }
    }
    return best;
  }
}

class _Eval {
  _Eval(this.crop, this.score, this.notes, this.cutPenalty);

  final Box crop;
  final double score;
  final List<String> notes;
  final double cutPenalty;
}
