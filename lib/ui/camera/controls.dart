import 'dart:async';

import 'package:camera/camera.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/color/lut.dart';
import '../../services/camera_service.dart';
import '../../services/lut_library.dart';
import '../common/widgets.dart';
import '../theme.dart';

/// Horizontal mode carousel (AUTO FRAME · PHOTO · HDR+ · APERTURE · VIDEO).
class ModeSelector extends StatelessWidget {
  const ModeSelector({super.key, required this.mode, required this.onSelect, this.enabled = true});

  final CaptureMode mode;
  final ValueChanged<CaptureMode> onSelect;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Row(
          children: [
            for (final m in CaptureMode.values)
              GestureDetector(
                onTap: enabled ? () => onSelect(m) : null,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 180),
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.4,
                      color: m == mode ? AfColors.gold : AfColors.textDim,
                    ),
                    child: Text(m.label),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The shutter: white ring for stills, red for video, square while recording.
class ShutterButton extends StatelessWidget {
  const ShutterButton({
    super.key,
    required this.mode,
    required this.recording,
    required this.busy,
    required this.onPressed,
  });

  final CaptureMode mode;
  final bool recording;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final video = mode == CaptureMode.video;
    final inner = video
        ? AfColors.record
        : (mode == CaptureMode.autoFrame ? AfColors.gold : Colors.white);
    return GestureDetector(
      onTap: busy ? null : onPressed,
      child: Container(
        width: 78,
        height: 78,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 4),
        ),
        alignment: Alignment.center,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: recording ? 28 : 62,
          height: recording ? 28 : 62,
          decoration: BoxDecoration(
            color: busy ? Colors.white24 : inner,
            borderRadius: BorderRadius.circular(recording ? 6 : 31),
          ),
          child: mode == CaptureMode.autoFrame && !busy
              ? const Icon(Icons.crop_free_rounded, color: Colors.black87, size: 26)
              : null,
        ),
      ),
    );
  }
}

/// Zoom presets (0.5x when an ultra-wide is available, 1x, 2x, 3x...).
class ZoomChips extends StatelessWidget {
  const ZoomChips({super.key, required this.camera});

  final CameraService camera;

  @override
  Widget build(BuildContext context) {
    final presets = <double>[
      if (camera.minZoom < 0.95) camera.minZoom,
      1,
      if (camera.maxZoom >= 2) 2,
      if (camera.maxZoom >= 3) 3,
      if (camera.maxZoom >= 5) 5,
    ];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final z in presets)
          GestureDetector(
            onTap: () => camera.setZoom(z),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 4),
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black.withValues(alpha: 0.45),
              ),
              child: Text(
                _label(z, (camera.zoom - z).abs() < 0.05 ? camera.zoom : null),
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: (camera.zoom - z).abs() < 0.05 ? AfColors.gold : Colors.white,
                ),
              ),
            ),
          ),
      ],
    );
  }

  String _label(double z, double? active) {
    final v = active ?? z;
    final s = v < 1
        ? v.toStringAsFixed(1)
        : (v % 1 == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(1));
    return active != null ? '${s}x' : s;
  }
}

/// Exposure compensation scrubber.
class EvControl extends StatelessWidget {
  const EvControl({super.key, required this.camera});

  final CameraService camera;

  @override
  Widget build(BuildContext context) {
    if (camera.maxEv <= camera.minEv) return const SizedBox.shrink();
    return Row(
      children: [
        const Icon(Icons.exposure_rounded, size: 18, color: AfColors.textDim),
        Expanded(
          child: Slider(
            value: camera.ev,
            min: camera.minEv,
            max: camera.maxEv,
            onChanged: camera.setEv,
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            '${camera.ev >= 0 ? '+' : ''}${camera.ev.toStringAsFixed(1)}',
            style: const TextStyle(fontSize: 12, color: AfColors.gold),
          ),
        ),
      ],
    );
  }
}

/// Looks: built-in + imported LUTs, intensity, AF-Log monitoring.
Future<void> showLookSheet(BuildContext context, CameraService camera) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => ListenableBuilder(
      listenable: Listenable.merge([camera, LutLibrary.instance]),
      builder: (context, _) {
        final lib = LutLibrary.instance;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'LOOKS',
                  style: TextStyle(letterSpacing: 2, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('None'),
                      selected: camera.lutName == null,
                      onSelected: (_) => camera.setLook(clear: true),
                    ),
                    for (final n in lib.allNames)
                      ChoiceChip(
                        label: Text(n),
                        selected: camera.lutName == n,
                        onSelected: (_) => camera.setLook(lut: n),
                      ),
                    ActionChip(
                      avatar: const Icon(Icons.add, size: 18),
                      label: const Text('Import .cube'),
                      onPressed: () => importLut(context),
                    ),
                  ],
                ),
                if (camera.lutName != null) ...[
                  const SizedBox(height: 8),
                  AdjustSlider(
                    label: 'Intensity',
                    value: camera.lutMix * 100,
                    min: 0,
                    max: 100,
                    defaultValue: 100,
                    onChanged: (v) => camera.update((s) => s.lutMix = v / 100),
                  ),
                ],
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('AF-Log monitoring'),
                  subtitle: const Text('View the flat, 14-stop AF-Log signal'),
                  value: camera.logView,
                  onChanged: (v) => camera.update((s) => s.logView = v),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

/// Pick a `.cube` file and ask which colour space it expects.
Future<String?> importLut(BuildContext context) async {
  final files = await FilePicker.pickFiles(type: FileType.any);
  if (files.isEmpty || files.first.path == null || !context.mounted) return null;
  final path = files.first.path!;
  if (!path.toLowerCase().endsWith('.cube')) {
    showToast(context, 'Please choose a .cube LUT file');
    return null;
  }
  final space = await showDialog<LutInputSpace>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('This LUT expects…'),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, LutInputSpace.rec709),
          child: const Text('Rec.709 / normal footage (most creative LUTs)'),
        ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, LutInputSpace.afLog),
          child: const Text('AF-Log footage'),
        ),
      ],
    ),
  );
  if (space == null) return null;
  try {
    final name = await LutLibrary.instance.import(path, inputSpace: space);
    if (context.mounted) showToast(context, 'Imported "$name"');
    return name;
  } on FormatException catch (e) {
    if (context.mounted) showToast(context, 'Not a valid LUT: ${e.message}');
    return null;
  }
}

/// Pro settings: monitoring aids, video profile, lenses.
Future<void> showProSheet(BuildContext context, CameraService camera) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => ListenableBuilder(
      listenable: camera,
      builder: (context, _) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('PRO', style: TextStyle(letterSpacing: 2, fontWeight: FontWeight.w700)),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Composition coach'),
                subtitle: const Text('Live face tracking, frame score and hints'),
                value: camera.guidanceOn,
                onChanged: (v) => camera.update((s) => s.guidanceOn = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Smart shutter'),
                subtitle: const Text('Auto Frame mode fires when the shot is composed and level'),
                value: camera.smartShutter,
                onChanged: (v) => camera.update((s) => s.smartShutter = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Zebras'),
                subtitle: const Text('Stripes over clipping highlights'),
                value: camera.zebra,
                onChanged: (v) => camera.update((s) => s.zebra = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Focus peaking'),
                value: camera.peaking,
                onChanged: (v) => camera.update((s) => s.peaking = v),
              ),
              const Divider(),
              const Text('GRID', style: TextStyle(fontSize: 12, color: AfColors.textDim)),
              const SizedBox(height: 6),
              SegmentedButton<GridStyle>(
                segments: const [
                  ButtonSegment(value: GridStyle.off, label: Text('Off')),
                  ButtonSegment(value: GridStyle.thirds, label: Text('Thirds')),
                  ButtonSegment(value: GridStyle.golden, label: Text('Phi')),
                  ButtonSegment(value: GridStyle.both, label: Text('Both')),
                ],
                selected: {camera.grid},
                onSelectionChanged: (s) => camera.update((c) => c.grid = s.first),
              ),
              const SizedBox(height: 12),
              const Text('VIDEO PROFILE', style: TextStyle(fontSize: 12, color: AfColors.textDim)),
              const SizedBox(height: 6),
              SegmentedButton<VideoProfile>(
                segments: const [
                  ButtonSegment(value: VideoProfile.standard, label: Text('Standard')),
                  ButtonSegment(value: VideoProfile.afLog, label: Text('AF-Log')),
                ],
                selected: {camera.videoProfile},
                onSelectionChanged: (s) => camera.update((c) => c.videoProfile = s.first),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Burn look into video'),
                subtitle: const Text('Standard profile: bake the selected LUT after recording'),
                value: camera.bakeLookIntoVideo,
                onChanged: camera.videoProfile == VideoProfile.standard
                    ? (v) => camera.update((s) => s.bakeLookIntoVideo = v)
                    : null,
              ),
              if (camera.backLenses.length > 1) ...[
                const Divider(),
                const Text('LENS', style: TextStyle(fontSize: 12, color: AfColors.textDim)),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final (i, lens) in camera.backLenses.indexed)
                      ChoiceChip(
                        label: Text('Lens ${i + 1}'),
                        selected: camera.description == lens,
                        onSelected: (_) => unawaited(camera.selectLens(lens)),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

IconData flashIcon(FlashMode m) => switch (m) {
  FlashMode.off => Icons.flash_off_rounded,
  FlashMode.auto => Icons.flash_auto_rounded,
  FlashMode.always => Icons.flash_on_rounded,
  FlashMode.torch => Icons.highlight_rounded,
};
