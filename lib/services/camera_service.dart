import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/composition/composition_engine.dart';
import 'motion_service.dart';
import 'vision_service.dart';

enum CaptureMode {
  autoFrame('AUTO FRAME'),
  photo('PHOTO'),
  hdr('HDR+'),
  aperture('APERTURE'),
  video('VIDEO');

  const CaptureMode(this.label);
  final String label;
}

enum GridStyle { off, thirds, golden, both }

enum VideoProfile { standard, afLog }

/// Owns the [CameraController] and all viewfinder state.
class CameraService extends ChangeNotifier {
  CameraService({required this.vision, required this.motion});

  final VisionService vision;
  final MotionService motion;
  final CompositionEngine _engine = const CompositionEngine();

  List<CameraDescription> _cameras = [];
  CameraController? controller;
  int _cameraIndex = 0;
  String? error;

  CaptureMode mode = CaptureMode.autoFrame;
  FlashMode flash = FlashMode.off;
  GridStyle grid = GridStyle.thirds;
  bool guidanceOn = true;
  bool smartShutter = false;

  double zoom = 1, minZoom = 1, maxZoom = 1;
  double ev = 0, minEv = 0, maxEv = 0;

  // Look / monitoring.
  String? lutName;
  double lutMix = 1;
  bool logView = false;
  bool zebra = false;
  bool peaking = false;

  // Video.
  VideoProfile videoProfile = VideoProfile.standard;
  bool bakeLookIntoVideo = true;
  bool isRecording = false;
  DateTime? recordingStarted;

  bool busy = false;
  String? busyLabel;

  SceneAnalysis analysis = SceneAnalysis.empty;
  FramingGuidance guidance = FramingGuidance.empty;
  DateTime _lastAnalysis = DateTime.fromMillisecondsSinceEpoch(0);
  bool _streaming = false;

  List<CameraDescription> get cameras => _cameras;
  bool get isReady => controller?.value.isInitialized ?? false;
  bool get isFront =>
      _cameras.isNotEmpty && _cameras[_cameraIndex].lensDirection == CameraLensDirection.front;
  CameraDescription? get description => _cameras.isEmpty ? null : _cameras[_cameraIndex];

  /// Back lenses, which on multi-camera phones are separate descriptions
  /// (ultra-wide / wide / tele).
  List<CameraDescription> get backLenses =>
      _cameras.where((c) => c.lensDirection == CameraLensDirection.back).toList();

  Future<void> init() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        error = 'No camera found on this device.';
        notifyListeners();
        return;
      }
      _cameraIndex = _cameras.indexWhere((c) => c.lensDirection == CameraLensDirection.back);
      if (_cameraIndex < 0) _cameraIndex = 0;
      await _open(_cameras[_cameraIndex]);
    } on CameraException catch (e) {
      error = _describe(e);
      notifyListeners();
    }
  }

  Future<void> _open(CameraDescription desc) async {
    final old = controller;
    controller = null;
    _streaming = false;
    notifyListeners();
    await old?.dispose();

    final c = CameraController(
      desc,
      ResolutionPreset.max,
      enableAudio: true,
      fps: 30,
      imageFormatGroup: Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
    );
    try {
      await c.initialize();
      await c.setFlashMode(flash);
      minZoom = await c.getMinZoomLevel();
      maxZoom = await c.getMaxZoomLevel();
      zoom = minZoom.clamp(1.0, maxZoom);
      await c.setZoomLevel(zoom);
      minEv = await c.getMinExposureOffset();
      maxEv = await c.getMaxExposureOffset();
      ev = 0;
      controller = c;
      error = null;
      await _syncStream();
    } on CameraException catch (e) {
      error = _describe(e);
      await c.dispose();
    }
    notifyListeners();
  }

  String _describe(CameraException e) => switch (e.code) {
    'CameraAccessDenied' || 'CameraAccessDeniedWithoutPrompt' =>
      'Camera access is off. Enable it in Settings to start shooting.',
    'AudioAccessDenied' || 'AudioAccessDeniedWithoutPrompt' =>
      'Microphone access is off. Enable it in Settings to record video.',
    _ => e.description ?? e.code,
  };

  Future<void> pause() async {
    final c = controller;
    controller = null;
    _streaming = false;
    await c?.dispose();
  }

  Future<void> resume() async {
    if (controller == null && _cameras.isNotEmpty) await _open(_cameras[_cameraIndex]);
  }

  Future<void> flipCamera() async {
    if (_cameras.length < 2 || isRecording) return;
    final want = isFront ? CameraLensDirection.back : CameraLensDirection.front;
    final idx = _cameras.indexWhere((c) => c.lensDirection == want);
    if (idx < 0) return;
    _cameraIndex = idx;
    await _open(_cameras[idx]);
  }

  Future<void> selectLens(CameraDescription lens) async {
    final idx = _cameras.indexOf(lens);
    if (idx < 0 || idx == _cameraIndex || isRecording) return;
    _cameraIndex = idx;
    await _open(lens);
  }

  Future<void> setMode(CaptureMode m) async {
    if (isRecording || m == mode) return;
    mode = m;
    if (m == CaptureMode.video) {
      await controller?.prepareForVideoRecording();
    }
    await _syncStream();
    notifyListeners();
  }

  Future<void> setZoom(double z) async {
    zoom = z.clamp(minZoom, maxZoom);
    notifyListeners();
    await controller?.setZoomLevel(zoom);
  }

  Future<void> setEv(double v) async {
    ev = v.clamp(minEv, maxEv);
    notifyListeners();
    try {
      await controller?.setExposureOffset(ev);
    } on CameraException catch (e) {
      debugPrint('EV: ${e.description}');
    }
  }

  Future<void> cycleFlash() async {
    const order = [FlashMode.off, FlashMode.auto, FlashMode.always, FlashMode.torch];
    flash = order[(order.indexOf(flash) + 1) % order.length];
    notifyListeners();
    await controller?.setFlashMode(flash);
  }

  /// Tap-to-focus/expose at a normalised preview point.
  Future<void> focusAt(Offset p) async {
    final c = controller;
    if (c == null) return;
    try {
      await c.setFocusPoint(p);
      await c.setExposurePoint(p);
    } on CameraException catch (e) {
      debugPrint('Focus point unsupported: ${e.description}');
    }
  }

  void setLook({String? lut, bool clear = false}) {
    lutName = clear ? null : (lut ?? lutName);
    notifyListeners();
  }

  void update(void Function(CameraService s) fn) {
    fn(this);
    unawaited(_syncStream());
    notifyListeners();
  }

  // --- Live analysis ----------------------------------------------------

  bool get _wantsStream => guidanceOn && mode != CaptureMode.video && !isRecording;

  Future<void> _syncStream() async {
    final c = controller;
    if (c == null || !c.value.isInitialized) return;
    if (_wantsStream && !_streaming) {
      try {
        await c.startImageStream(_onFrame);
        _streaming = true;
      } on CameraException catch (e) {
        debugPrint('Image stream unavailable: ${e.description}');
      }
    } else if (!_wantsStream && _streaming) {
      _streaming = false;
      try {
        await c.stopImageStream();
      } on CameraException catch (_) {}
      analysis = SceneAnalysis.empty;
      guidance = FramingGuidance.empty;
    }
  }

  void _onFrame(CameraImage image) {
    final now = DateTime.now();
    if (now.difference(_lastAnalysis).inMilliseconds < 120) return;
    _lastAnalysis = now;
    final desc = description;
    final c = controller;
    if (desc == null || c == null) return;
    vision.analyzeFrame(image, desc, c.value.deviceOrientation).then((a) {
      if (a == null || controller == null) return;
      analysis = a;
      final att = motion.value;
      guidance = _engine.guide(
        width: a.width,
        height: a.height,
        subjects: a.subjects,
        horizonTiltDegrees: att.isReliable ? att.horizonTilt : 0,
      );
      notifyListeners();
      _maybeSmartShutter();
    });
  }

  DateTime? _goodSince;
  Future<void> Function()? onSmartShutter;

  void _maybeSmartShutter() {
    if (!smartShutter || busy || mode != CaptureMode.autoFrame) {
      _goodSince = null;
      return;
    }
    final good =
        guidance.score >= 78 && analysis.subjects.isNotEmpty && motion.value.roll.abs() < 2;
    if (!good) {
      _goodSince = null;
      return;
    }
    _goodSince ??= DateTime.now();
    if (DateTime.now().difference(_goodSince!).inMilliseconds > 700) {
      _goodSince = null;
      onSmartShutter?.call();
    }
  }

  // --- Capture ------------------------------------------------------------

  void setBusy(String? label) {
    busy = label != null;
    busyLabel = label;
    notifyListeners();
  }

  Future<XFile?> takePhoto() async {
    final c = controller;
    if (c == null || c.value.isTakingPicture) return null;
    try {
      HapticFeedback.mediumImpact();
      return await c.takePicture();
    } on CameraException catch (e) {
      error = e.description;
      notifyListeners();
      return null;
    }
  }

  /// Exposure bracket for HDR fusion: 0 EV first, then under, then over.
  Future<List<XFile>> captureBracket({double spread = 2}) async {
    final c = controller;
    if (c == null) return [];
    final offsets = [0.0, -spread, spread].map((v) => v.clamp(minEv, maxEv)).toSet().toList();
    final shots = <XFile>[];
    try {
      await c.setFocusMode(FocusMode.locked);
    } on CameraException catch (_) {}
    try {
      for (final o in offsets) {
        await c.setExposureOffset(o);
        // Let auto-exposure converge on the new bias.
        await Future<void>.delayed(const Duration(milliseconds: 380));
        HapticFeedback.selectionClick();
        shots.add(await c.takePicture());
      }
    } on CameraException catch (e) {
      error = e.description;
    } finally {
      try {
        await c.setExposureOffset(ev);
        await c.setFocusMode(FocusMode.auto);
      } on CameraException catch (_) {}
    }
    return shots;
  }

  Future<void> startRecording() async {
    final c = controller;
    if (c == null || isRecording) return;
    if (_streaming) {
      _streaming = false;
      await c.stopImageStream();
    }
    try {
      await c.startVideoRecording();
      isRecording = true;
      recordingStarted = DateTime.now();
      HapticFeedback.heavyImpact();
    } on CameraException catch (e) {
      error = e.description;
    }
    notifyListeners();
  }

  Future<XFile?> stopRecording() async {
    final c = controller;
    if (c == null || !isRecording) return null;
    try {
      final f = await c.stopVideoRecording();
      return f;
    } on CameraException catch (e) {
      error = e.description;
      return null;
    } finally {
      isRecording = false;
      recordingStarted = null;
      HapticFeedback.heavyImpact();
      notifyListeners();
      unawaited(_syncStream());
    }
  }

  @override
  void dispose() {
    controller?.dispose();
    super.dispose();
  }
}
