import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/color/color_math.dart';
import '../../core/edit/edit_params.dart';
import '../../core/edit/presets.dart';
import '../../core/edit/tone_curve.dart';
import '../../services/lut_library.dart';
import '../camera/controls.dart' show importLut;
import '../common/widgets.dart';
import '../theme.dart';
import 'curve_editor.dart';

/// Callback the panels use to change the recipe. [commit] marks the end of
/// a gesture (one undo step).
typedef EditCallback = void Function(EditParams params, {bool commit});

/// Sliders for one [AdjustGroup].
class AdjustPanel extends StatelessWidget {
  const AdjustPanel({super.key, required this.group, required this.params, required this.onEdit});

  final AdjustGroup group;
  final EditParams params;
  final EditCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final adjusts = Adjust.values.where((a) => a.group == group).toList();
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        for (final a in adjusts)
          AdjustSlider(
            label: a.label,
            value: params[a],
            min: a.min,
            max: a.max,
            defaultValue: a.defaultValue,
            decimals: a == Adjust.exposure ? 2 : 0,
            track: _trackFor(a),
            onChanged: (v) => onEdit(params.set(a, v), commit: false),
            onChangeEnd: (v) => onEdit(params.set(a, v), commit: true),
          ),
      ],
    );
  }

  Gradient? _trackFor(Adjust a) => switch (a) {
    Adjust.temperature => const LinearGradient(colors: [Color(0xFF4A8BFF), Color(0xFFFFC14A)]),
    Adjust.tint => const LinearGradient(colors: [Color(0xFF4ADB6A), Color(0xFFE04AE0)]),
    _ => null,
  };
}

enum HslMode { hue, saturation, luminance }

class HslPanel extends StatefulWidget {
  const HslPanel({super.key, required this.params, required this.onEdit});

  final EditParams params;
  final EditCallback onEdit;

  @override
  State<HslPanel> createState() => _HslPanelState();
}

class _HslPanelState extends State<HslPanel> {
  HslMode mode = HslMode.saturation;

  Color _band(HslBand b, {double s = 0.85, double v = 0.95}) {
    final c = hsvToRgb(b.hue, s, v);
    return Color.fromARGB(255, (c[0] * 255).round(), (c[1] * 255).round(), (c[2] * 255).round());
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.params;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: SegmentedButton<HslMode>(
            segments: const [
              ButtonSegment(value: HslMode.hue, label: Text('Hue')),
              ButtonSegment(value: HslMode.saturation, label: Text('Saturation')),
              ButtonSegment(value: HslMode.luminance, label: Text('Luminance')),
            ],
            selected: {mode},
            onSelectionChanged: (s) => setState(() => mode = s.first),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              for (final b in HslBand.values)
                AdjustSlider(
                  label: b.label,
                  value: switch (mode) {
                    HslMode.hue => p.hslOf(b).hue,
                    HslMode.saturation => p.hslOf(b).saturation,
                    HslMode.luminance => p.hslOf(b).luminance,
                  },
                  min: -100,
                  max: 100,
                  track: switch (mode) {
                    HslMode.hue => LinearGradient(
                      colors: [
                        _band(HslBand.values[(b.index + 7) % 8]),
                        _band(b),
                        _band(HslBand.values[(b.index + 1) % 8]),
                      ],
                    ),
                    HslMode.saturation => LinearGradient(colors: [_band(b, s: 0.05), _band(b)]),
                    HslMode.luminance => LinearGradient(
                      colors: [_band(b, v: 0.25), _band(b, s: 0.4, v: 1)],
                    ),
                  },
                  onChanged: (v) => widget.onEdit(_set(p, b, v), commit: false),
                  onChangeEnd: (v) => widget.onEdit(_set(p, b, v), commit: true),
                ),
            ],
          ),
        ),
      ],
    );
  }

  EditParams _set(EditParams p, HslBand b, double v) {
    final cur = p.hslOf(b);
    return p.setHsl(b, switch (mode) {
      HslMode.hue => cur.copyWith(hue: v),
      HslMode.saturation => cur.copyWith(saturation: v),
      HslMode.luminance => cur.copyWith(luminance: v),
    });
  }
}

class CurvePanel extends StatefulWidget {
  const CurvePanel({super.key, required this.params, required this.onEdit});

  final EditParams params;
  final EditCallback onEdit;

  @override
  State<CurvePanel> createState() => _CurvePanelState();
}

class _CurvePanelState extends State<CurvePanel> {
  CurveChannel channel = CurveChannel.master;

  @override
  Widget build(BuildContext context) {
    final p = widget.params;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              for (final c in CurveChannel.values)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: ChoiceChip(
                    label: Text(switch (c) {
                      CurveChannel.master => 'RGB',
                      CurveChannel.red => 'R',
                      CurveChannel.green => 'G',
                      CurveChannel.blue => 'B',
                    }),
                    selected: channel == c,
                    onSelected: (_) => setState(() => channel = c),
                  ),
                ),
              TextButton(
                onPressed: () =>
                    widget.onEdit(p.setCurve(channel, ToneCurve.identity), commit: true),
                child: const Text('Reset'),
              ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Center(
              child: CurveEditor(
                curve: p.curveOf(channel),
                channel: channel,
                onChanged: (c) => widget.onEdit(widget.params.setCurve(channel, c), commit: false),
                onChangeEnd: () => widget.onEdit(widget.params, commit: true),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class GradePanel extends StatelessWidget {
  const GradePanel({super.key, required this.params, required this.onEdit});

  final EditParams params;
  final EditCallback onEdit;

  static const _rainbow = LinearGradient(
    colors: [
      Color(0xFFFF0000),
      Color(0xFFFFFF00),
      Color(0xFF00FF00),
      Color(0xFF00FFFF),
      Color(0xFF0000FF),
      Color(0xFFFF00FF),
      Color(0xFFFF0000),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final g = params.grade;
    void set(ColorGrade ng, bool commit) => onEdit(params.copyWith(grade: ng), commit: commit);
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        AdjustSlider(
          label: 'Shadows hue',
          value: g.shadowHue,
          min: 0,
          max: 360,
          defaultValue: 210,
          track: _rainbow,
          onChanged: (v) => set(g.copyWith(shadowHue: v), false),
          onChangeEnd: (v) => set(g.copyWith(shadowHue: v), true),
        ),
        AdjustSlider(
          label: 'Shadows saturation',
          value: g.shadowSat,
          min: 0,
          max: 100,
          onChanged: (v) => set(g.copyWith(shadowSat: v), false),
          onChangeEnd: (v) => set(g.copyWith(shadowSat: v), true),
        ),
        AdjustSlider(
          label: 'Highlights hue',
          value: g.highlightHue,
          min: 0,
          max: 360,
          defaultValue: 40,
          track: _rainbow,
          onChanged: (v) => set(g.copyWith(highlightHue: v), false),
          onChangeEnd: (v) => set(g.copyWith(highlightHue: v), true),
        ),
        AdjustSlider(
          label: 'Highlights saturation',
          value: g.highlightSat,
          min: 0,
          max: 100,
          onChanged: (v) => set(g.copyWith(highlightSat: v), false),
          onChangeEnd: (v) => set(g.copyWith(highlightSat: v), true),
        ),
        AdjustSlider(
          label: 'Balance',
          value: g.balance,
          min: -100,
          max: 100,
          onChanged: (v) => set(g.copyWith(balance: v), false),
          onChangeEnd: (v) => set(g.copyWith(balance: v), true),
        ),
      ],
    );
  }
}

/// Horizontal strip of thumbnails (presets or LUTs).
class ThumbStrip extends StatelessWidget {
  const ThumbStrip({
    super.key,
    required this.names,
    required this.selected,
    required this.thumbs,
    required this.onSelect,
    this.trailing,
  });

  final List<String> names;
  final String? selected;
  final Map<String, ui.Image> thumbs;
  final ValueChanged<String> onSelect;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 116,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          for (final n in names)
            GestureDetector(
              onTap: () => onSelect(n),
              child: Container(
                width: 76,
                margin: const EdgeInsets.only(right: 8),
                child: Column(
                  children: [
                    Container(
                      width: 76,
                      height: 76,
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        color: AfColors.surfaceHigh,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: n == selected ? AfColors.gold : Colors.transparent,
                          width: 2,
                        ),
                      ),
                      child: thumbs[n] == null
                          ? const Center(
                              child: SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 1.5),
                              ),
                            )
                          : RawImage(image: thumbs[n], fit: BoxFit.cover),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      n,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: n == selected ? AfColors.gold : AfColors.textDim,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ?trailing,
        ],
      ),
    );
  }
}

class PresetPanel extends StatelessWidget {
  const PresetPanel({
    super.key,
    required this.params,
    required this.thumbs,
    required this.selected,
    required this.onEdit,
    required this.onSelected,
  });

  final EditParams params;
  final Map<String, ui.Image> thumbs;
  final String? selected;
  final EditCallback onEdit;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        ThumbStrip(
          names: Presets.all.keys.toList(),
          selected: selected,
          thumbs: thumbs,
          onSelect: (n) {
            onSelected(n);
            onEdit(params.applyPreset(Presets.all[n]!), commit: true);
          },
        ),
      ],
    );
  }
}

class LookPanel extends StatelessWidget {
  const LookPanel({super.key, required this.params, required this.thumbs, required this.onEdit});

  final EditParams params;
  final Map<String, ui.Image> thumbs;
  final EditCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: LutLibrary.instance,
      builder: (context, _) => ListView(
        children: [
          ThumbStrip(
            names: ['None', ...LutLibrary.instance.allNames],
            selected: params.lutName ?? 'None',
            thumbs: thumbs,
            onSelect: (n) => onEdit(
              n == 'None' ? params.copyWith(clearLut: true) : params.copyWith(lutName: n),
              commit: true,
            ),
            trailing: GestureDetector(
              onTap: () async {
                final name = await importLut(context);
                if (name != null) onEdit(params.copyWith(lutName: name), commit: true);
              },
              child: Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  border: Border.all(color: AfColors.outline),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.add),
                    Text('.cube', style: TextStyle(fontSize: 11)),
                  ],
                ),
              ),
            ),
          ),
          if (params.lutName != null)
            AdjustSlider(
              label: 'Intensity',
              value: params.lutIntensity * 100,
              min: 0,
              max: 100,
              defaultValue: 100,
              onChanged: (v) => onEdit(params.copyWith(lutIntensity: v / 100), commit: false),
              onChangeEnd: (v) => onEdit(params.copyWith(lutIntensity: v / 100), commit: true),
            ),
        ],
      ),
    );
  }
}
