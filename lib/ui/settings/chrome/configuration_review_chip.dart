// Small monospaced chip that surfaces a row's settings.json path
// (e.g. `terminal.fontSize`). Toggled globally by the "Show JSON
// paths" debug switch.

import 'package:flutter/material.dart';
import '../../../src/theme/palette_context.dart';

class ConfigurationReviewChip extends StatelessWidget {
  final String jsonKey;
  const ConfigurationReviewChip({super.key, required this.jsonKey});

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: palette.rowSurface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(
          color: palette.accentBlue.withValues(alpha: 0.3),
          width: 0.5,
        ),
      ),
      child: Text(
        jsonKey,
        style: TextStyle(
          color: palette.accentBlue,
          fontSize: 9,
          fontFamily: 'monospace',
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
