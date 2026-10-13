import 'package:flutter/material.dart';

import '../theme.dart';

/// Full-screen scrim with a progress label for long-running processing.
class BusyOverlay extends StatelessWidget {
  const BusyOverlay({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black54,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          decoration: BoxDecoration(
            color: AfColors.surfaceHigh,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2.5, color: AfColors.gold),
              ),
              const SizedBox(height: 14),
              Text(label, style: const TextStyle(color: AfColors.text)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Round translucent icon button used across the viewfinder.
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.active = false,
    this.tooltip,
    this.size = 40,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final bool active;
  final String? tooltip;
  final double size;

  @override
  Widget build(BuildContext context) {
    final btn = Material(
      color: active ? AfColors.gold.withValues(alpha: 0.18) : Colors.white10,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, size: size * 0.5, color: active ? AfColors.gold : AfColors.text),
        ),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip!, child: btn);
  }
}

/// A labelled slider row; double-tap the label to reset.
class AdjustSlider extends StatelessWidget {
  const AdjustSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.defaultValue = 0,
    this.decimals = 0,
    this.track,
    this.onChangeEnd,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final double defaultValue;
  final int decimals;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;

  /// Optional gradient painted behind the track (HSL / colour wheels).
  final Gradient? track;

  @override
  Widget build(BuildContext context) {
    final changed = (value - defaultValue).abs() > 1e-6;
    final text = value > 0 && min < 0
        ? '+${value.toStringAsFixed(decimals)}'
        : value.toStringAsFixed(decimals);
    Widget slider = Slider(
      value: value.clamp(min, max),
      min: min,
      max: max,
      onChanged: onChanged,
      onChangeEnd: onChangeEnd,
    );
    if (track != null) {
      slider = Stack(
        alignment: Alignment.center,
        children: [
          Container(
            height: 4,
            margin: const EdgeInsets.symmetric(horizontal: 24),
            decoration: BoxDecoration(gradient: track, borderRadius: BorderRadius.circular(2)),
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: Colors.transparent,
              inactiveTrackColor: Colors.transparent,
            ),
            child: slider,
          ),
        ],
      );
    }
    return GestureDetector(
      onDoubleTap: () {
        onChanged(defaultValue);
        onChangeEnd?.call(defaultValue);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      color: changed ? AfColors.text : AfColors.textDim,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    text,
                    style: TextStyle(
                      fontSize: 13,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: changed ? AfColors.gold : AfColors.textDim,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: 32, child: slider),
          ],
        ),
      ),
    );
  }
}

void showToast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 2)));
}
