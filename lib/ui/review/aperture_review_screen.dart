import 'dart:io';

import 'package:flutter/material.dart';

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

/// Pick your depth of field after the shot: one capture rendered at
/// f/1.4 through f/8.
class ApertureReviewScreen extends StatefulWidget {
  const ApertureReviewScreen({
    super.key,
    required this.source,
    required this.renders,
    required this.pipeline,
    this.lutName,
  });

  final File source;
  final List<ApertureRender> renders;
  final CapturePipeline pipeline;
  final String? lutName;

  @override
  State<ApertureReviewScreen> createState() => _ApertureReviewScreenState();
}

class _ApertureReviewScreenState extends State<ApertureReviewScreen> {
  int _index = 0;
  String? _busy;

  @override
  void dispose() {
    for (final r in widget.renders) {
      r.image.dispose();
    }
    super.dispose();
  }

  Future<File> _saveSelected({bool withLook = true}) async {
    final r = widget.renders[_index];
    final prefix = 'AF_F${r.fNumber.toStringAsFixed(1)}';
    final lut = LutLibrary.instance.byName(widget.lutName);
    if (!withLook || lut == null) return widget.pipeline.saveImage(r.image, prefix: prefix);
    final out = await renderDeveloped(
      image: r.image,
      params: EditParams(lutName: widget.lutName),
      lut: lut,
    );
    final jpg = await encodeJpeg(out.rgba, out.width, out.height);
    return MediaStore.instance.writeBytes(jpg, prefix: prefix);
  }

  Future<void> _save() async {
    setState(() => _busy = 'Saving f/${widget.renders[_index].fNumber}…');
    try {
      final f = await _saveSelected();
      final ok = await MediaStore.instance.exportToGallery(f, MediaKind.photo);
      if (!mounted) return;
      showToast(context, ok ? 'Saved to Photos' : 'Saved in Auto Frame library');
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showToast(context, 'Save failed: $e');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _edit() async {
    setState(() => _busy = 'Preparing…');
    // The editor applies the look non-destructively, so save it clean.
    final f = await _saveSelected(withLook: false);
    if (!mounted) return;
    setState(() => _busy = null);
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => EditorScreen(
          file: f,
          initial: EditParams(lutName: widget.lutName),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.renders[_index];
    return Scaffold(
      appBar: AppBar(title: const Text('APERTURE')),
      body: Stack(
        children: [
          Column(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Center(
                    child: DevelopedImage(
                      image: r.image,
                      params: EditParams(lutName: widget.lutName),
                    ),
                  ),
                ),
              ),
              Text(
                'f/${r.fNumber % 1 == 0 ? r.fNumber.toStringAsFixed(0) : r.fNumber.toStringAsFixed(1)}',
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w300,
                  color: AfColors.gold,
                ),
              ),
              const Text(
                'Shallow  ←  depth of field  →  Deep',
                style: TextStyle(color: AfColors.textDim, fontSize: 12),
              ),
              Slider(
                value: _index.toDouble(),
                min: 0,
                max: (widget.renders.length - 1).toDouble(),
                divisions: widget.renders.length - 1,
                onChanged: (v) => setState(() => _index = v.round()),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _busy == null ? _edit : null,
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
}
