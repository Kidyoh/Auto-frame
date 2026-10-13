import 'geometry.dart';

enum SubjectKind { face, person, object, salient }

/// Something the photographer probably cares about, in image pixel space.
class Subject {
  const Subject({
    required this.box,
    required this.kind,
    this.weight = 1,
    this.gazeX = 0,
    this.label,
  });

  final Box box;
  final SubjectKind kind;

  /// Relative importance; the largest/most confident subject should be ~1.
  final double weight;

  /// Horizontal facing direction in image space: -1 = looking left,
  /// +1 = looking right, 0 = toward camera / unknown. Drives lead room.
  final double gazeX;

  final String? label;

  /// The point that should sit on a power point. For faces this is the eye
  /// line; for everything else the centre of mass.
  (double, double) get anchor {
    if (kind == SubjectKind.face) {
      return (box.cx, box.top + box.height * 0.38);
    }
    return (box.cx, box.cy);
  }

  /// How much it hurts to crop through this subject.
  double get cutCost => switch (kind) {
    SubjectKind.face => 4.0,
    SubjectKind.person => 1.6,
    SubjectKind.object => 1.4,
    SubjectKind.salient => 1.0,
  };

  Subject copyWith({Box? box}) => Subject(
    box: box ?? this.box,
    kind: kind,
    weight: weight,
    gazeX: gazeX,
    label: label,
  );
}
