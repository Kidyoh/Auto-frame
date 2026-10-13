import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../services/camera_service.dart';
import '../../services/lut_library.dart';
import '../../services/media_store.dart';
import '../../services/shader_service.dart';
import '../../services/video_lut_service.dart';
import '../common/widgets.dart';
import '../theme.dart';

/// Review a clip with its look previewed live on the GPU, then save it as
/// shot, as flat AF-Log, or with the look burned in.
class VideoReviewScreen extends StatefulWidget {
  const VideoReviewScreen({
    super.key,
    required this.file,
    required this.profile,
    this.lutName,
    this.lutIntensity = 1,
    this.bakeLook = true,
  });

  final File file;
  final VideoProfile profile;
  final String? lutName;
  final double lutIntensity;
  final bool bakeLook;

  @override
  State<VideoReviewScreen> createState() => _VideoReviewScreenState();
}

enum _Output { original, afLog, look }

class _VideoReviewScreenState extends State<VideoReviewScreen> {
  late final VideoPlayerController _player = VideoPlayerController.file(widget.file);
  ui.FragmentShader? _shader;
  ui.Image? _lutImage;
  ui.Image? _blank;
  late _Output _output;
  String? _busy;

  @override
  void initState() {
    super.initState();
    _output = widget.profile == VideoProfile.afLog
        ? _Output.afLog
        : (widget.lutName != null && widget.bakeLook ? _Output.look : _Output.original);
    _player
      ..setLooping(true)
      ..initialize().then((_) {
        if (mounted) {
          setState(() {});
          _player.play();
        }
      });
    _prepare();
  }

  Future<void> _prepare() async {
    final svc = ShaderService.instance;
    await svc.load();
    final lut = LutLibrary.instance.byName(widget.lutName);
    _blank = await svc.blankLut();
    _lutImage = lut == null ? null : await svc.lutImage(lut);
    if (mounted) setState(() => _shader = svc.cameraShader());
  }

  @override
  void dispose() {
    _player.dispose();
    _shader?.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(
      () => _busy = switch (_output) {
        _Output.original => 'Saving…',
        _Output.afLog => 'Encoding AF-Log…',
        _Output.look => 'Burning in ${widget.lutName}…',
      },
    );
    try {
      File out = widget.file;
      // AVFoundation writes QuickTime; Media3 writes MP4.
      final dest = MediaStore.instance.newPath('AF_VID', Platform.isIOS ? 'mov' : 'mp4');
      switch (_output) {
        case _Output.original:
          break;
        case _Output.afLog:
          out = File(await VideoLutService.bakeLog(input: widget.file.path, output: dest));
        case _Output.look:
          final lut = LutLibrary.instance.byName(widget.lutName)!;
          out = File(
            await VideoLutService.bakeLook(
              input: widget.file.path,
              output: dest,
              look: lut,
              intensity: widget.lutIntensity,
            ),
          );
      }
      await MediaStore.instance.refresh();
      final ok = await MediaStore.instance.exportToGallery(out, MediaKind.video);
      if (!mounted) return;
      showToast(context, ok ? 'Saved to Photos' : 'Saved in Auto Frame library');
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showToast(context, 'Video export failed: $e');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final lut = LutLibrary.instance.byName(widget.lutName);
    final look = CameraLook(
      lut: _output == _Output.look ? lut : null,
      lutImage: _output == _Output.look ? _lutImage : null,
      lutMix: widget.lutIntensity,
      logEncode: _output == _Output.afLog,
    );
    Widget video = _player.value.isInitialized
        ? AspectRatio(aspectRatio: _player.value.aspectRatio, child: VideoPlayer(_player))
        : const Center(child: CircularProgressIndicator());
    if (_shader != null &&
        _blank != null &&
        !look.isNeutral &&
        ui.ImageFilter.isShaderFilterSupported) {
      look.apply(_shader!, _blank!, 0);
      video = ImageFiltered(imageFilter: ui.ImageFilter.shader(_shader!), child: video);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('CLIP')),
      body: Stack(
        children: [
          Column(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () =>
                      setState(() => _player.value.isPlaying ? _player.pause() : _player.play()),
                  child: Center(child: video),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: SegmentedButton<_Output>(
                  segments: [
                    const ButtonSegment(value: _Output.original, label: Text('As shot')),
                    const ButtonSegment(value: _Output.afLog, label: Text('AF-Log')),
                    if (lut != null)
                      ButtonSegment(value: _Output.look, label: Text(widget.lutName!)),
                  ],
                  selected: {_output},
                  onSelectionChanged: (s) => setState(() => _output = s.first),
                ),
              ),
              if (_output == _Output.afLog)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    'Flat, 14-stop AF-Log for grading. Apply "AF-Log → Rec.709" or '
                    '"AF Cinematic" in Resolve/Premiere (export the .cube from Looks).',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AfColors.textDim, fontSize: 12),
                  ),
                ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _busy == null ? _save : null,
                      icon: const Icon(Icons.check_rounded),
                      label: const Text('Save clip'),
                    ),
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
