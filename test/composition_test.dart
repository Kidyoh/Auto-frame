import 'package:auto_frame/core/composition/composition_engine.dart';
import 'package:auto_frame/core/composition/geometry.dart';
import 'package:auto_frame/core/composition/saliency.dart';
import 'package:auto_frame/core/composition/subject.dart';
import 'package:auto_frame/core/processing/planes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const engine = CompositionEngine();
  const w = 4000.0, h = 3000.0;

  Subject face(double cx, double cy, double size, {double gaze = 0}) => Subject(
    box: Box(cx - size / 2, cy - size / 2, size, size),
    kind: SubjectKind.face,
    gazeX: gaze,
  );

  test('dead-centre face gets reframed off-centre toward a power point', () {
    final s = engine.suggest(
      width: w,
      height: h,
      subjects: [face(2000, 1500, 300, gaze: 0.8)],
      aspects: const [AspectSpec.portrait45],
    );
    expect(s, hasLength(1));
    final crop = s.first.crop;
    // Anchor (eye line) position inside the crop.
    final u = (2000 / w - crop.left) / crop.width;
    final v = ((1500 - 150 + 300 * 0.38) / h - crop.top) / crop.height;
    expect(v, closeTo(1 / 3, 0.08), reason: 'eyes near upper third');
    // Looking right => subject sits left with lead room on the right.
    expect(u, lessThan(0.5));
  });

  test('never amputates a face when a clean crop exists', () {
    final f = face(600, 900, 400);
    final s = engine.suggest(
      width: w,
      height: h,
      subjects: [f],
      aspects: const [AspectSpec.square, AspectSpec.story, AspectSpec.wide169],
    );
    for (final sug in s) {
      final c = sug.crop.scale(w, h);
      expect(c.left, lessThanOrEqualTo(f.box.left + 1), reason: sug.aspect.label);
      expect(c.right, greaterThanOrEqualTo(f.box.right - 1), reason: sug.aspect.label);
      expect(c.top, lessThanOrEqualTo(f.box.top + 1), reason: sug.aspect.label);
      expect(c.bottom, greaterThanOrEqualTo(f.box.bottom - 1), reason: sug.aspect.label);
    }
  });

  test('straightens small tilts and keeps the crop inside the image', () {
    final s = engine.suggest(
      width: w,
      height: h,
      subjects: [face(1400, 1100, 350)],
      horizonTiltDegrees: 4,
      aspects: const [AspectSpec.original],
    );
    expect(s.first.rotationDegrees, closeTo(-4, 1e-9));
    expect(s.first.notes.any((n) => n.contains('Horizon')), isTrue);
    expect(s.first.crop.width, lessThan(1.0));
  });

  test('large tilts are kept as an intentional Dutch angle', () {
    final s = engine.suggest(
      width: w,
      height: h,
      subjects: const [],
      horizonTiltDegrees: 25,
      aspects: const [AspectSpec.original],
    );
    expect(s.first.rotationDegrees, 0);
  });

  test('guidance tells you which way to pan', () {
    final g = engine.guide(
      width: w,
      height: h,
      subjects: [face(3600, 1500, 250, gaze: -0.9)],
    );
    // Face hard right, looking left: target is the right third; need to pan
    // right so the subject moves left in frame.
    expect(g.hints, contains('Pan right'));
    expect(g.target!.$1, closeTo(2 / 3, 1e-9));
  });

  test('well-composed frame scores higher than a poorly composed one', () {
    final good = engine.guide(width: w, height: h, subjects: [face(w / 3, h / 3, 350)]);
    final bad = engine.guide(width: w, height: h, subjects: [face(3900, 2950, 350)]);
    expect(good.score, greaterThan(bad.score + 20));
  });

  test('saliency finds a bright object on a flat background', () {
    final img = RgbPlanes(200, 150);
    for (var i = 0; i < img.length; i++) {
      img.r[i] = 0.3;
      img.g[i] = 0.35;
      img.b[i] = 0.4;
    }
    // Orange square in the right third.
    for (var y = 40; y < 80; y++) {
      for (var x = 120; x < 160; x++) {
        final i = y * 200 + x;
        img.r[i] = 1.0;
        img.g[i] = 0.55;
        img.b[i] = 0.1;
      }
    }
    final s = const SaliencyDetector().detect(img);
    expect(s, isNotNull);
    expect(s!.box.cx, closeTo(140, 15));
    expect(s.box.cy, closeTo(60, 15));
  });

  test('saliency returns null for a flat image', () {
    final img = RgbPlanes(64, 48);
    img.r.fillRange(0, img.length, 0.5);
    img.g.fillRange(0, img.length, 0.5);
    img.b.fillRange(0, img.length, 0.5);
    expect(const SaliencyDetector().detect(img), isNull);
  });
}
