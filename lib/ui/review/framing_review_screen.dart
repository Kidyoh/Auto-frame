import 'package:flutter/material.dart';

import '../../core/composition/composition_engine.dart';
import '../../core/edit/edit_params.dart';
import '../../services/capture_pipeline.dart';
import '../../services/image_io.dart';
import '../../services/lut_library.dart';
import '../../services/media_store.dart';
import '../../services/shader_service.dart';
import '../common/developed_image.dart';
import '../common/widgets.dart';
import '../editor/editor_screen.dart';
import '../theme.dart';

/// Swipe through Auto Frame's proposed compositions for the shot you just
/// took. Each is a different aspect ratio, ranked by frame score.
class FramingReviewScreen extends StatefulWidget {
  const FramingReviewScreen({
    super.key,
    required this.result,
    required this.pipeline,
    this.lutName,
    this.lutIntensity = 1,
  });

  final FramingResult result;
  final CapturePipeline pipeline;
  final String? lutName;
  final double lutIntensity;

  @override
  State<FramingReviewScreen> createState() => _FramingReviewScreenState();
}

class _FramingReviewScreenState extends State<FramingReviewScreen> {
  final _page = PageController(viewportFraction: 0.88);
  int _index = 0;
  String? _busy;

  /// Original first, then suggestions by score.
  late final List<CropSuggestion?> _options = [null, ...widget.result.suggestions];

  EditParams _paramsFor(CropSuggestion? s) => EditParams(
    crop: s?.crop,
    rotationDegrees: s?.rotationDegrees ?? 0,
    lutName: widget.lutName,
    lutIntensity: widget.lutIntensity,
  );

  @override
  void dispose() {
    _page.dispose();
    widget.result.preview.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final params = _paramsFor(_options[_index]);
    setState(() => _busy = 'Saving full resolution…');
    try {
      final file = widget.result.file;
      final item = MediaItem(file, MediaKind.photo, DateTime.now());
      await MediaStore.instance.saveEdit(item, params);
      final full = await loadUiImage(file.path);
      final out = await renderDeveloped(
        image: full,
        params: params,
        lut: LutLibrary.instance.byName(params.lutName),
      );
      full.dispose();
      final jpg = await encodeJpeg(out.rgba, out.width, out.height);
      final saved = await MediaStore.instance.writeBytes(jpg, prefix: 'AF_FRAME');
      final ok = await MediaStore.instance.exportToGallery(saved, MediaKind.photo);
      if (!mounted) return;
      showToast(context, ok ? 'Saved to Photos' : 'Saved in Auto Frame library');
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showToast(context, 'Save failed: $e');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  void _edit() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) =>
            EditorScreen(file: widget.result.file, initial: _paramsFor(_options[_index])),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final current = _options[_index];
    return Scaffold(
      appBar: AppBar(title: const Text('AUTO FRAME')),
      body: Stack(
        children: [
          Column(
            children: [
              Expanded(
                child: PageView.builder(
                  controller: _page,
                  itemCount: _options.length,
                  onPageChanged: (i) => setState(() => _index = i),
                  itemBuilder: (context, i) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
                    child: Center(
                      child: DevelopedImage(
                        image: widget.result.preview,
                        params: _paramsFor(_options[i]),
                      ),
                    ),
                  ),
                ),
              ),
              _info(current),
              const SizedBox(height: 8),
              _dots(),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _edit,
                          icon: const Icon(Icons.tune_rounded),
                          label: const Text('Edit'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _busy == null ? _save : null,
                          icon: const Icon(Icons.check_rounded),
                          label: const Text('Save'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (_busy != null) BusyOverlay(label: _busy!),
        ],
      ),
    );
  }

  Widget _info(CropSuggestion? s) {
    if (s == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 24),
        child: Text(
          'Original — swipe for Auto Frame compositions',
          style: TextStyle(color: AfColors.textDim),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                s.aspect.label,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: AfColors.forScore(s.score).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'Score ${s.score.round()}',
                  style: TextStyle(color: AfColors.forScore(s.score), fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final n in s.notes)
                Chip(
                  label: Text(n, style: const TextStyle(fontSize: 11)),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _dots() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < _options.length; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            margin: const EdgeInsets.symmetric(horizontal: 3),
            width: i == _index ? 16 : 6,
            height: 6,
            decoration: BoxDecoration(
              color: i == _index ? AfColors.gold : AfColors.outline,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
      ],
    );
  }
}
