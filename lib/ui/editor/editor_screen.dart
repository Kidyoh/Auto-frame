import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/color/lut.dart';
import '../../core/composition/composition_engine.dart';
import '../../core/composition/geometry.dart';
import '../../core/edit/edit_params.dart';
import '../../core/edit/presets.dart';
import '../../services/capture_pipeline.dart';
import '../../services/image_io.dart';
import '../../services/lut_library.dart';
import '../../services/media_store.dart';
import '../../services/shader_service.dart';
import '../../services/vision_service.dart';
import '../common/widgets.dart';
import '../theme.dart';
import 'crop_overlay.dart';
import 'panels.dart';

enum EditorTab {
  presets('Presets', Icons.auto_awesome_outlined),
  light('Light', Icons.wb_sunny_outlined),
  color('Color', Icons.thermostat_outlined),
  effects('Effects', Icons.blur_on_outlined),
  detail('Detail', Icons.details_outlined),
  hsl('HSL', Icons.palette_outlined),
  curve('Curve', Icons.show_chart_rounded),
  grade('Grading', Icons.contrast_rounded),
  looks('Looks', Icons.movie_filter_outlined),
  crop('Crop', Icons.crop_rotate_rounded);

  const EditorTab(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// The develop module: Lightroom-style, non-destructive, GPU-rendered.
class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.file, this.initial});

  final File file;
  final EditParams? initial;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  ui.Image? _preview;
  ui.Image? _thumbSource;
  ui.FragmentShader? _shader;
  ui.Image? _lutImage;
  ui.Image? _curveImage;
  ui.Image? _blank;
  String? _lutLoadedFor;
  Map<CurveChannel, Object>? _curvesFor;

  EditParams _params = EditParams();
  final List<EditParams> _undo = [];
  final List<EditParams> _redo = [];
  EditorTab _tab = EditorTab.presets;
  bool _showOriginal = false;
  String? _busy;
  String? _presetName;

  // Crop tab state.
  AspectSpec? _cropAspect;
  bool _autoFraming = false;

  final Map<String, ui.Image> _presetThumbs = {};
  final Map<String, ui.Image> _lutThumbs = {};
  Uint32List? _histogram;
  Timer? _histTimer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final svc = ShaderService.instance;
    await svc.load();
    final saved = widget.initial ?? await MediaStore.instance.loadEdit(widget.file);
    final preview = await loadUiImage(widget.file.path, maxSide: 2400);
    final thumb = await loadUiImage(widget.file.path, maxSide: 200);
    _blank = await svc.blankLut();
    if (!mounted) return;
    setState(() {
      _preview = preview;
      _thumbSource = thumb;
      _shader = svc.developShader();
      _params = saved ?? EditParams();
    });
    await _syncTextures();
    _scheduleHistogram();
    _buildPresetThumbs();
  }

  @override
  void dispose() {
    _histTimer?.cancel();
    _shader?.dispose();
    _preview?.dispose();
    _thumbSource?.dispose();
    for (final t in [..._presetThumbs.values, ..._lutThumbs.values]) {
      t.dispose();
    }
    super.dispose();
  }

  Lut3D? get _lut => LutLibrary.instance.byName(_params.lutName);

  Future<void> _syncTextures() async {
    final svc = ShaderService.instance;
    if (_params.lutName != _lutLoadedFor) {
      _lutLoadedFor = _params.lutName;
      final lut = _lut;
      _lutImage = lut == null ? null : await svc.lutImage(lut);
    }
    if (_curvesFor == null || !_sameCurves(_curvesFor!, _params.curves)) {
      _curvesFor = Map.of(_params.curves);
      final old = _curveImage;
      _curveImage = await svc.curveImage(_params);
      old?.dispose();
    }
    if (mounted) setState(() {});
  }

  bool _sameCurves(Map<CurveChannel, Object> a, Map<CurveChannel, Object> b) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (!identical(b[e.key], e.value)) return false;
    }
    return true;
  }

  /// Apply [p]. Live slider/drag updates pass `commit: false`; the end of
  /// the gesture (or a discrete action) commits one undo step holding the
  /// state from before the gesture began.
  void _edit(EditParams p, {bool commit = false}) {
    _gestureStart ??= _params;
    if (commit) {
      if (!identical(_gestureStart, p)) {
        _undo.add(_gestureStart!);
        _redo.clear();
      }
      _gestureStart = null;
    }
    setState(() => _params = p);
    _syncTextures();
    _scheduleHistogram();
  }

  EditParams? _gestureStart;

  void _undoStep() {
    if (_undo.isEmpty) return;
    _redo.add(_params);
    setState(() => _params = _undo.removeLast());
    _syncTextures();
    _scheduleHistogram();
  }

  void _redoStep() {
    if (_redo.isEmpty) return;
    _undo.add(_params);
    setState(() => _params = _redo.removeLast());
    _syncTextures();
    _scheduleHistogram();
  }

  // --- Histogram & thumbnails ---------------------------------------------

  void _scheduleHistogram() {
    _histTimer?.cancel();
    _histTimer = Timer(const Duration(milliseconds: 250), _computeHistogram);
  }

  Future<void> _computeHistogram() async {
    final src = _thumbSource;
    if (src == null || !mounted) return;
    final img = await renderDevelopedImage(image: src, params: _params, lut: _lut, maxSide: 160);
    final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    img.dispose();
    if (data == null || !mounted) return;
    final px = data.buffer.asUint8List();
    final hist = Uint32List(64 * 3);
    for (var i = 0; i < px.length; i += 4) {
      hist[px[i] >> 2]++;
      hist[64 + (px[i + 1] >> 2)]++;
      hist[128 + (px[i + 2] >> 2)]++;
    }
    setState(() => _histogram = hist);
  }

  Future<void> _buildPresetThumbs() async {
    final src = _thumbSource;
    if (src == null) return;
    for (final e in Presets.all.entries) {
      final img = await renderDevelopedImage(
        image: src,
        params: e.value.copyWith(rotationDegrees: _params.rotationDegrees, crop: _params.crop),
        maxSide: 160,
      );
      if (!mounted) return;
      setState(() => _presetThumbs[e.key] = img);
    }
  }

  Future<void> _buildLutThumbs() async {
    final src = _thumbSource;
    if (src == null) return;
    final base = _params.copyWith(clearLut: true);
    for (final n in ['None', ...LutLibrary.instance.allNames]) {
      if (_lutThumbs.containsKey(n)) continue;
      final lut = n == 'None' ? null : LutLibrary.instance.byName(n);
      final img = await renderDevelopedImage(
        image: src,
        params: lut == null ? base : base.copyWith(lutName: n, lutIntensity: 1),
        lut: lut,
        maxSide: 160,
      );
      if (!mounted) return;
      setState(() => _lutThumbs[n] = img);
    }
  }

  // --- Export ---------------------------------------------------------------

  Future<void> _export() async {
    setState(() => _busy = 'Developing full resolution…');
    try {
      final full = await loadUiImage(widget.file.path);
      final out = await renderDeveloped(image: full, params: _params, lut: _lut);
      full.dispose();
      setState(() => _busy = 'Encoding…');
      final jpg = await encodeJpeg(out.rgba, out.width, out.height, quality: 96);
      final file = await MediaStore.instance.writeBytes(jpg, prefix: 'AF_EDIT');
      await _saveSidecar();
      final ok = await MediaStore.instance.exportToGallery(file, MediaKind.photo);
      if (mounted) {
        showToast(
          context,
          ok ? 'Exported to Photos (${out.width}×${out.height})' : 'Saved in Auto Frame library',
        );
      }
    } catch (e) {
      if (mounted) showToast(context, 'Export failed: $e');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _saveSidecar() async {
    final item = MediaItem(widget.file, MediaKind.photo, DateTime.now());
    await MediaStore.instance.saveEdit(item, _params);
  }

  // --- Auto framing inside the editor ----------------------------------

  Future<void> _autoFrame() async {
    setState(() => _autoFraming = true);
    final vision = VisionService();
    try {
      final result = await CapturePipeline(vision: vision).frame(widget.file);
      result.preview.dispose();
      final want = _cropAspect;
      final pick = want == null
          ? result.suggestions.first
          : result.suggestions.firstWhere(
              (s) => s.aspect.label == want.label,
              orElse: () => result.suggestions.first,
            );
      _edit(_params.copyWith(crop: pick.crop, rotationDegrees: pick.rotationDegrees), commit: true);
      if (mounted) {
        showToast(
          context,
          '${pick.aspect.label} · score ${pick.score.round()}'
          '${pick.notes.isEmpty ? '' : ' · ${pick.notes.join(', ')}'}',
        );
      }
    } catch (e) {
      if (mounted) showToast(context, 'Auto Frame failed: $e');
    } finally {
      await vision.dispose();
      if (mounted) setState(() => _autoFraming = false);
    }
  }

  void _setCropAspect(AspectSpec? a) {
    setState(() => _cropAspect = a);
    final img = _preview;
    if (img == null) return;
    if (a == null || a.ratio == null) {
      _edit(_params.copyWith(clearCrop: true), commit: true);
      return;
    }
    // Largest centred crop at the new ratio.
    final imageAspect = img.width / img.height;
    double w = 1, h = imageAspect / a.ratio!;
    if (h > 1) {
      h = 1;
      w = a.ratio! / imageAspect;
    }
    _edit(_params.copyWith(crop: Box((1 - w) / 2, (1 - h) / 2, w, h)), commit: true);
  }

  // --- UI -------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final ready = _preview != null && _shader != null && _curveImage != null && _blank != null;
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) unawaited(_saveSidecar());
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('DEVELOP'),
          actions: [
            IconButton(
              icon: const Icon(Icons.undo_rounded),
              onPressed: _undo.isEmpty ? null : _undoStep,
            ),
            IconButton(
              icon: const Icon(Icons.redo_rounded),
              onPressed: _redo.isEmpty ? null : _redoStep,
            ),
            IconButton(
              tooltip: 'Export',
              icon: const Icon(Icons.ios_share_rounded, color: AfColors.gold),
              onPressed: ready && _busy == null ? _export : null,
            ),
          ],
        ),
        body: Stack(
          children: [
            Column(
              children: [
                Expanded(
                  child: ready ? _canvas() : const Center(child: CircularProgressIndicator()),
                ),
                SizedBox(
                  height: _tab == EditorTab.curve ? 250 : 210,
                  child: ready ? _panel() : null,
                ),
                _tabBar(),
              ],
            ),
            if (_busy != null) BusyOverlay(label: _busy!),
          ],
        ),
      ),
    );
  }

  Widget _canvas() {
    final img = _preview!;
    final cropping = _tab == EditorTab.crop;
    // While cropping show the whole rotated frame; otherwise the result.
    final shown = _showOriginal
        ? EditParams(crop: _params.crop, rotationDegrees: _params.rotationDegrees)
        : _params;
    final params = cropping ? shown.copyWith(clearCrop: true) : shown;
    final crop = params.crop ?? const Box(0, 0, 1, 1);
    final aspect = (img.width * crop.width) / (img.height * crop.height);
    final lut = _showOriginal ? null : _lut;

    final painter = CustomPaint(
      painter: DevelopPainter(
        shader: _shader!,
        image: img,
        params: params,
        lutImage: (lut == null ? null : _lutImage) ?? _blank!,
        curveImage: _curveImage!,
        lut: lut == null || _lutImage == null ? null : lut,
      ),
    );

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Stack(
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: aspect,
              child: cropping
                  ? Stack(
                      fit: StackFit.expand,
                      children: [
                        painter,
                        CropOverlay(
                          crop: _params.crop ?? const Box(0, 0, 1, 1),
                          imageAspect: img.width / img.height,
                          aspect: _cropAspect?.ratio,
                          onChanged: (b) => _edit(_params.copyWith(crop: b)),
                          onChangeEnd: () => _edit(_params, commit: true),
                        ),
                      ],
                    )
                  : GestureDetector(
                      onLongPressStart: (_) => setState(() => _showOriginal = true),
                      onLongPressEnd: (_) => setState(() => _showOriginal = false),
                      child: InteractiveViewer(maxScale: 8, child: SizedBox.expand(child: painter)),
                    ),
            ),
          ),
          if (_histogram != null && !cropping)
            Positioned(
              left: 0,
              top: 0,
              child: IgnorePointer(
                child: Container(
                  width: 120,
                  height: 56,
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: CustomPaint(painter: _HistogramPainter(_histogram!)),
                ),
              ),
            ),
          if (_showOriginal)
            const Positioned(
              right: 0,
              top: 0,
              child: Chip(label: Text('ORIGINAL', style: TextStyle(fontSize: 10))),
            ),
        ],
      ),
    );
  }

  Widget _panel() {
    void onEdit(EditParams p, {bool commit = false}) => _edit(p, commit: commit);
    return switch (_tab) {
      EditorTab.presets => PresetPanel(
        params: _params,
        thumbs: _presetThumbs,
        selected: _presetName,
        onEdit: onEdit,
        onSelected: (n) => setState(() => _presetName = n),
      ),
      EditorTab.light => AdjustPanel(group: AdjustGroup.light, params: _params, onEdit: onEdit),
      EditorTab.color => AdjustPanel(group: AdjustGroup.color, params: _params, onEdit: onEdit),
      EditorTab.effects => AdjustPanel(group: AdjustGroup.effects, params: _params, onEdit: onEdit),
      EditorTab.detail => AdjustPanel(group: AdjustGroup.detail, params: _params, onEdit: onEdit),
      EditorTab.hsl => HslPanel(params: _params, onEdit: onEdit),
      EditorTab.curve => CurvePanel(params: _params, onEdit: onEdit),
      EditorTab.grade => GradePanel(params: _params, onEdit: onEdit),
      EditorTab.looks => LookPanel(params: _params, thumbs: _lutThumbs, onEdit: onEdit),
      EditorTab.crop => _cropPanel(),
    };
  }

  Widget _cropPanel() {
    final aspects = <AspectSpec?>[
      null,
      AspectSpec.square,
      AspectSpec.portrait45,
      AspectSpec.classic32,
      AspectSpec.wide169,
      AspectSpec.story,
      AspectSpec.cinema,
    ];
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: FilledButton.icon(
            onPressed: _autoFraming ? null : _autoFrame,
            icon: _autoFraming
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_fix_high_rounded),
            label: Text(_cropAspect == null ? 'Auto Frame' : 'Auto Frame ${_cropAspect!.label}'),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final a in aspects)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(a?.label ?? 'Free'),
                    selected: _cropAspect?.label == a?.label,
                    onSelected: (_) => _setCropAspect(a),
                  ),
                ),
            ],
          ),
        ),
        AdjustSlider(
          label: 'Straighten',
          value: _params.rotationDegrees,
          min: -15,
          max: 15,
          decimals: 1,
          onChanged: (v) => _edit(_params.copyWith(rotationDegrees: v)),
          onChangeEnd: (v) => _edit(_params.copyWith(rotationDegrees: v), commit: true),
        ),
        Center(
          child: TextButton(
            onPressed: () =>
                _edit(_params.copyWith(clearCrop: true, rotationDegrees: 0), commit: true),
            child: const Text('Reset crop'),
          ),
        ),
      ],
    );
  }

  Widget _tabBar() {
    return SafeArea(
      top: false,
      child: SizedBox(
        height: 64,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          children: [
            for (final t in EditorTab.values)
              InkWell(
                onTap: () {
                  setState(() => _tab = t);
                  if (t == EditorTab.looks) _buildLutThumbs();
                },
                child: SizedBox(
                  width: 64,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(t.icon, size: 22, color: t == _tab ? AfColors.gold : AfColors.textDim),
                      const SizedBox(height: 4),
                      Text(
                        t.label,
                        style: TextStyle(
                          fontSize: 10.5,
                          color: t == _tab ? AfColors.gold : AfColors.textDim,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _HistogramPainter extends CustomPainter {
  _HistogramPainter(this.hist);

  final Uint32List hist;

  @override
  void paint(Canvas canvas, Size size) {
    var maxV = 1;
    for (final v in hist) {
      maxV = math.max(maxV, v);
    }
    const colors = [Color(0xAAFF4D4D), Color(0xAA4DFF7A), Color(0xAA4DA6FF)];
    for (var c = 0; c < 3; c++) {
      final path = Path()..moveTo(0, size.height);
      for (var i = 0; i < 64; i++) {
        final x = i / 63 * size.width;
        final y = size.height - math.sqrt(hist[c * 64 + i] / maxV) * (size.height - 4);
        path.lineTo(x, y);
      }
      path
        ..lineTo(size.width, size.height)
        ..close();
      canvas.drawPath(
        path,
        Paint()
          ..color = colors[c]
          ..blendMode = BlendMode.plus,
      );
    }
  }

  @override
  bool shouldRepaint(_HistogramPainter old) => old.hist != hist;
}
