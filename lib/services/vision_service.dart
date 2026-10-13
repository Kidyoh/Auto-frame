import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'package:google_mlkit_selfie_segmentation/google_mlkit_selfie_segmentation.dart';

import '../core/composition/geometry.dart';
import '../core/composition/subject.dart';

/// Subjects found in a frame plus the frame size (upright orientation) they
/// were measured in.
class SceneAnalysis {
  const SceneAnalysis({required this.subjects, required this.width, required this.height});

  final List<Subject> subjects;
  final double width;
  final double height;

  static const empty = SceneAnalysis(subjects: [], width: 1, height: 1);
}

/// On-device ML Kit wrappers. Nothing leaves the phone.
class VisionService {
  VisionService();

  final FaceDetector _liveFaces = FaceDetector(
    options: FaceDetectorOptions(
      performanceMode: FaceDetectorMode.fast,
      enableClassification: false,
      minFaceSize: 0.08,
    ),
  );
  final FaceDetector _stillFaces = FaceDetector(
    options: FaceDetectorOptions(performanceMode: FaceDetectorMode.accurate, minFaceSize: 0.04),
  );
  final ObjectDetector _objects = ObjectDetector(
    options: ObjectDetectorOptions(
      mode: DetectionMode.single,
      classifyObjects: true,
      multipleObjects: true,
    ),
  );
  final SelfieSegmenter _segmenter = SelfieSegmenter(
    mode: SegmenterMode.single,
    enableRawSizeMask: true,
  );

  bool _busy = false;

  static const _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  /// Analyse a live preview frame. Returns null when a previous frame is
  /// still being processed (frames are dropped, never queued).
  Future<SceneAnalysis?> analyzeFrame(
    CameraImage image,
    CameraDescription camera,
    DeviceOrientation deviceOrientation,
  ) async {
    if (_busy) return null;
    final input = _inputFromCameraImage(image, camera, deviceOrientation);
    if (input == null) return null;
    _busy = true;
    try {
      final faces = await _liveFaces.processImage(input);
      // Android frames arrive in sensor orientation and ML Kit reports boxes
      // in the rotated (upright) space; iOS frames are already upright.
      final rot = input.metadata!.rotation;
      final swap =
          Platform.isAndroid &&
          (rot == InputImageRotation.rotation90deg || rot == InputImageRotation.rotation270deg);
      final w = (swap ? image.height : image.width).toDouble();
      final h = (swap ? image.width : image.height).toDouble();
      // The selfie preview is mirrored; mirror boxes to match what you see.
      final mirror = camera.lensDirection == CameraLensDirection.front;
      return SceneAnalysis(
        subjects: [for (final f in faces) _faceSubject(f, mirror ? w : null)],
        width: w,
        height: h,
      );
    } catch (e) {
      debugPrint('Live face detection failed: $e');
      return null;
    } finally {
      _busy = false;
    }
  }

  /// Full analysis of a captured still: faces (accurate), objects.
  Future<SceneAnalysis> analyzeFile(
    String path, {
    required double width,
    required double height,
  }) async {
    final input = InputImage.fromFilePath(path);
    final subjects = <Subject>[];
    try {
      final faces = await _stillFaces.processImage(input);
      subjects.addAll(faces.map((f) => _faceSubject(f, null)));
    } catch (e) {
      debugPrint('Face detection failed: $e');
    }
    try {
      final objects = await _objects.processImage(input);
      for (final o in objects) {
        final b = o.boundingBox;
        final box = Box(b.left, b.top, b.width, b.height);
        // Skip objects that are just the face/person we already have.
        final overlapsFace = subjects.any(
          (s) => s.kind == SubjectKind.face && s.box.intersect(box).area > 0.6 * s.box.area,
        );
        final areaFrac = box.area / (width * height);
        if (areaFrac > 0.85 || areaFrac < 0.002) continue;
        final label = o.labels.isEmpty ? null : o.labels.first.text;
        final isPerson = label != null && label.toLowerCase().contains('person');
        subjects.add(
          Subject(
            box: box,
            kind: isPerson ? SubjectKind.person : SubjectKind.object,
            weight: overlapsFace ? 0.4 : 0.6 + 0.4 * math.sqrt(areaFrac),
            label: label,
          ),
        );
      }
    } catch (e) {
      debugPrint('Object detection failed: $e');
    }
    return SceneAnalysis(subjects: subjects, width: width, height: height);
  }

  /// Person segmentation mask (subject probability) for synthetic aperture.
  /// Returns null if nobody is in frame.
  Future<({Float32List mask, int width, int height})?> personMask(String path) async {
    try {
      final m = await _segmenter.processImage(InputImage.fromFilePath(path));
      if (m == null) return null;
      final data = Float32List.fromList(m.confidences);
      var strong = 0;
      for (final v in data) {
        if (v > 0.6) strong++;
      }
      if (strong < data.length * 0.01) return null;
      return (mask: data, width: m.width, height: m.height);
    } catch (e) {
      debugPrint('Segmentation failed: $e');
      return null;
    }
  }

  Subject _faceSubject(Face f, double? mirrorWidth) {
    var b = f.boundingBox;
    // Yaw: positive = subject turned toward image-left on a back camera.
    final yaw = f.headEulerAngleY ?? 0;
    var gaze = (-yaw / 35).clamp(-1.0, 1.0);
    var left = b.left;
    if (mirrorWidth != null) {
      left = mirrorWidth - b.right;
      gaze = -gaze;
    }
    final size = math.sqrt(b.width * b.height);
    return Subject(
      box: Box(left, b.top, b.width, b.height),
      kind: SubjectKind.face,
      weight: 0.7 + 0.3 * math.min(1.0, size / 400),
      gazeX: gaze,
    );
  }

  InputImage? _inputFromCameraImage(
    CameraImage image,
    CameraDescription camera,
    DeviceOrientation deviceOrientation,
  ) {
    final sensor = camera.sensorOrientation;
    InputImageRotation? rotation;
    if (Platform.isIOS) {
      rotation = InputImageRotationValue.fromRawValue(sensor);
    } else {
      var comp = _orientations[deviceOrientation] ?? 0;
      comp = camera.lensDirection == CameraLensDirection.front
          ? (sensor + comp) % 360
          : (sensor - comp + 360) % 360;
      rotation = InputImageRotationValue.fromRawValue(comp);
    }
    if (rotation == null) return null;
    final format = InputImageFormatValue.fromRawValue(image.format.raw as int);
    if (format == null) return null;
    if (Platform.isAndroid && format != InputImageFormat.nv21) return null;
    if (Platform.isIOS && format != InputImageFormat.bgra8888) return null;
    if (image.planes.length != 1) return null;
    final plane = image.planes.first;
    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  Future<void> dispose() async {
    await _liveFaces.close();
    await _stillFaces.close();
    await _objects.close();
    await _segmenter.close();
  }
}
