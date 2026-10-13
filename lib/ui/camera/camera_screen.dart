import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/edit/edit_params.dart';
import '../../services/camera_service.dart';
import '../../services/capture_pipeline.dart';
import '../../services/lut_library.dart';
import '../../services/media_store.dart';
import '../../services/motion_service.dart';
import '../../services/shader_service.dart';
import '../../services/image_io.dart';
import '../common/widgets.dart';
import '../editor/editor_screen.dart';
import '../gallery/gallery_screen.dart';
import '../review/aperture_review_screen.dart';
import '../review/framing_review_screen.dart';
import '../review/video_review_screen.dart';
import '../theme.dart';
import 'controls.dart';
import 'viewfinder.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({
    super.key,
    required this.camera,
    required this.motion,
    required this.pipeline,
  });

  final CameraService camera;
  final MotionService motion;
  final CapturePipeline pipeline;

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  CameraService get cam => widget.camera;
  bool _showEv = false;
  Timer? _recTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    cam.onSmartShutter = _capture;
    widget.motion.start();
    cam.init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _recTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      if (!cam.isRecording) cam.pause();
      widget.motion.stop();
    } else if (state == AppLifecycleState.resumed) {
      cam.resume();
      widget.motion.start();
    }
  }

  // --- Capture flows ------------------------------------------------------

  Future<void> _capture() async {
    if (cam.busy) return;
    switch (cam.mode) {
      case CaptureMode.autoFrame:
        await _captureAutoFrame();
      case CaptureMode.photo:
        await _capturePhoto();
      case CaptureMode.hdr:
        await _captureHdr();
      case CaptureMode.aperture:
        await _captureAperture();
      case CaptureMode.video:
        await _toggleRecording();
    }
  }

  Future<void> _captureAutoFrame() async {
    final tilt = widget.motion.value;
    final shot = await cam.takePhoto();
    if (shot == null) return;
    cam.setBusy('Finding the best frame…');
    try {
      final file = await MediaStore.instance.ingest(shot.path);
      final result = await widget.pipeline.frame(
        file,
        horizonTilt: tilt.isReliable ? tilt.horizonTilt : 0,
      );
      if (!mounted) return;
      cam.setBusy(null);
      await _pauseWhile(
        () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => FramingReviewScreen(
              result: result,
              pipeline: widget.pipeline,
              lutName: cam.lutName,
              lutIntensity: cam.lutMix,
            ),
          ),
        ),
      );
    } catch (e) {
      _fail(e);
    } finally {
      cam.setBusy(null);
    }
  }

  Future<void> _capturePhoto() async {
    final shot = await cam.takePhoto();
    if (shot == null) return;
    cam.setBusy('Saving…');
    try {
      final file = await MediaStore.instance.ingest(shot.path);
      await _saveWithLook(file);
      if (mounted) showToast(context, 'Saved to Auto Frame album');
    } catch (e) {
      _fail(e);
    } finally {
      cam.setBusy(null);
    }
  }

  Future<void> _captureHdr() async {
    cam.setBusy('Capturing bracket…');
    try {
      final shots = await cam.captureBracket();
      if (shots.isEmpty) return;
      cam.setBusy('Merging ${shots.length} exposures…');
      final file = await widget.pipeline.mergeHdr([for (final s in shots) s.path]);
      if (!mounted) return;
      cam.setBusy(null);
      await _pauseWhile(
        () => _openEditor(file, EditParams(lutName: cam.lutName, lutIntensity: cam.lutMix)),
      );
    } catch (e) {
      _fail(e);
    } finally {
      cam.setBusy(null);
    }
  }

  Future<void> _captureAperture() async {
    final shot = await cam.takePhoto();
    if (shot == null) return;
    cam.setBusy('Rendering apertures f/1.4 – f/8…');
    try {
      final file = await MediaStore.instance.ingest(shot.path);
      final renders = await widget.pipeline.apertureBracket(file);
      if (!mounted) return;
      cam.setBusy(null);
      await _pauseWhile(
        () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ApertureReviewScreen(
              source: file,
              renders: renders,
              pipeline: widget.pipeline,
              lutName: cam.lutName,
            ),
          ),
        ),
      );
    } catch (e) {
      _fail(e);
    } finally {
      cam.setBusy(null);
    }
  }

  Future<void> _toggleRecording() async {
    if (!cam.isRecording) {
      await cam.startRecording();
      _recTimer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
      return;
    }
    _recTimer?.cancel();
    final clip = await cam.stopRecording();
    if (clip == null || !mounted) return;
    final file = await MediaStore.instance.ingest(clip.path, prefix: 'AF_VID');
    if (!mounted) return;
    await _pauseWhile(
      () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => VideoReviewScreen(
            file: file,
            profile: cam.videoProfile,
            lutName: cam.lutName,
            lutIntensity: cam.lutMix,
            bakeLook: cam.bakeLookIntoVideo,
          ),
        ),
      ),
    );
  }

  /// Photo mode: keep the original, record the look as a non-destructive
  /// edit and export a developed copy to the gallery.
  Future<void> _saveWithLook(File file) async {
    final lut = LutLibrary.instance.byName(cam.lutName);
    if (lut == null) {
      await MediaStore.instance.exportToGallery(file, MediaKind.photo);
      return;
    }
    final params = EditParams(lutName: cam.lutName, lutIntensity: cam.lutMix);
    final item = MediaStore.instance.items.firstWhere(
      (i) => i.file.path == file.path,
      orElse: () => MediaItem(file, MediaKind.photo, DateTime.now()),
    );
    await MediaStore.instance.saveEdit(item, params);
    final image = await loadUiImage(file.path);
    final out = await renderDeveloped(image: image, params: params, lut: lut);
    image.dispose();
    final jpg = await encodeJpeg(out.rgba, out.width, out.height);
    final graded = await MediaStore.instance.writeBytes(jpg, prefix: 'AF_LOOK');
    await MediaStore.instance.exportToGallery(graded, MediaKind.photo);
  }

  Future<void> _openEditor(File file, [EditParams? initial]) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EditorScreen(file: file, initial: initial),
      ),
    );
  }

  /// Release the camera while a full-screen editor/review is open.
  Future<void> _pauseWhile(Future<Object?> Function() route) async {
    await cam.pause();
    await route();
    if (mounted) await cam.resume();
  }

  void _fail(Object e) {
    debugPrint('Capture failed: $e');
    if (mounted) showToast(context, 'Something went wrong: $e');
  }

  // --- UI -------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AfColors.black,
      body: ListenableBuilder(
        listenable: cam,
        builder: (context, _) {
          return Stack(
            children: [
              SafeArea(
                child: Column(
                  children: [
                    _topBar(),
                    Expanded(child: _viewfinderArea()),
                    _bottomControls(),
                  ],
                ),
              ),
              if (cam.busy) BusyOverlay(label: cam.busyLabel ?? 'Working…'),
            ],
          );
        },
      ),
    );
  }

  Widget _rotating(Widget child) {
    return ValueListenableBuilder<Attitude>(
      valueListenable: widget.motion,
      builder: (context, a, _) => AnimatedRotation(
        turns: -a.quadrant / 4,
        duration: const Duration(milliseconds: 250),
        child: child,
      ),
    );
  }

  Widget _topBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          _rotating(
            GlassIconButton(
              icon: flashIcon(cam.flash),
              tooltip: 'Flash',
              active: cam.flash.index != 0,
              onPressed: cam.cycleFlash,
            ),
          ),
          const SizedBox(width: 8),
          _rotating(
            GlassIconButton(
              icon: Icons.grid_on_rounded,
              tooltip: 'Grid',
              active: cam.grid != GridStyle.off,
              onPressed: () => cam.update(
                (s) => s.grid = GridStyle.values[(s.grid.index + 1) % GridStyle.values.length],
              ),
            ),
          ),
          const Spacer(),
          if (cam.isRecording) _recordingTimer() else _modeTitle(),
          const Spacer(),
          _rotating(
            GlassIconButton(
              icon: Icons.palette_outlined,
              tooltip: 'Looks & LUTs',
              active: cam.lutName != null || cam.logView,
              onPressed: () => showLookSheet(context, cam),
            ),
          ),
          const SizedBox(width: 8),
          _rotating(
            GlassIconButton(
              icon: Icons.tune_rounded,
              tooltip: 'Pro settings',
              active: cam.zebra || cam.peaking || cam.smartShutter,
              onPressed: () => showProSheet(context, cam),
            ),
          ),
        ],
      ),
    );
  }

  Widget _modeTitle() {
    final sub = switch (cam.mode) {
      CaptureMode.autoFrame => cam.smartShutter ? 'SMART SHUTTER' : 'AI COMPOSITION',
      CaptureMode.photo => 'NATURAL',
      CaptureMode.hdr => '3-SHOT FUSION',
      CaptureMode.aperture => 'f/1.4 – f/8',
      CaptureMode.video => cam.videoProfile == VideoProfile.afLog ? 'AF-LOG' : 'STANDARD',
    };
    return Text(
      sub,
      style: const TextStyle(fontSize: 11, letterSpacing: 1.6, color: AfColors.textDim),
    );
  }

  Widget _recordingTimer() {
    final d = DateTime.now().difference(cam.recordingStarted ?? DateTime.now());
    String two(int n) => n.toString().padLeft(2, '0');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: AfColors.record, borderRadius: BorderRadius.circular(4)),
      child: Text(
        '${two(d.inMinutes)}:${two(d.inSeconds % 60)}',
        style: const TextStyle(
          fontWeight: FontWeight.w700,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    );
  }

  Widget _viewfinderArea() {
    if (cam.error != null && !cam.isReady) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.no_photography_outlined, size: 48, color: AfColors.textDim),
              const SizedBox(height: 12),
              Text(cam.error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: cam.init, child: const Text('Try again')),
            ],
          ),
        ),
      );
    }
    return Stack(
      alignment: Alignment.center,
      children: [
        Center(
          child: Viewfinder(camera: cam, motion: widget.motion),
        ),
        Positioned(
          bottom: 12,
          child: Column(
            children: [
              if (_showEv)
                Container(
                  width: 280,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: EvControl(camera: cam),
                ),
              const SizedBox(height: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ZoomChips(camera: cam),
                  const SizedBox(width: 6),
                  GlassIconButton(
                    icon: Icons.exposure_rounded,
                    size: 38,
                    active: _showEv || cam.ev != 0,
                    onPressed: () => setState(() => _showEv = !_showEv),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _bottomControls() {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 12),
      child: Column(
        children: [
          ModeSelector(
            mode: cam.mode,
            enabled: !cam.isRecording && !cam.busy,
            onSelect: cam.setMode,
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _rotating(
                  _GalleryThumb(
                    onTap: () => _pauseWhile(
                      () =>
                          Navigator.of(context)
                              .push(MaterialPageRoute(builder: (_) => const GalleryScreen())),
                    ),
                  ),
                ),
                ShutterButton(
                  mode: cam.mode,
                  recording: cam.isRecording,
                  busy: cam.busy,
                  onPressed: _capture,
                ),
                _rotating(
                  GlassIconButton(
                    icon: Icons.cameraswitch_rounded,
                    size: 48,
                    tooltip: 'Flip camera',
                    onPressed: cam.isRecording ? null : cam.flipCamera,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GalleryThumb extends StatelessWidget {
  const _GalleryThumb({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: MediaStore.instance,
      builder: (context, _) {
        final latest = MediaStore.instance.items
            .where((i) => i.kind == MediaKind.photo)
            .firstOrNull;
        return GestureDetector(
          onTap: onTap,
          child: Container(
            width: 48,
            height: 48,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white54, width: 1.5),
              color: AfColors.surfaceHigh,
            ),
            child: latest == null
                ? const Icon(Icons.photo_library_outlined, size: 22)
                : Image.file(
                    latest.file,
                    fit: BoxFit.cover,
                    cacheWidth: 144,
                    gaplessPlayback: true,
                  ),
          ),
        );
      },
    );
  }
}
