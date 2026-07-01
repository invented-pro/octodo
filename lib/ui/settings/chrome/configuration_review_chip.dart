// Small monospaced chip that surfaces a row's settings.json path
// (e.g. `terminal.fontSize`). Toggled globally by the "Show JSON
// paths" debug switch.

import 'package:flutter/material.dart';

class ConfigurationReviewChip extends StatelessWidget {
  final String jsonKey;
  const ConfigurationReviewChip({super.key, required this.jsonKey});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: const Color(0xFF313244).withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(
          color: const Color(0xFF89B4FA).withValues(alpha: 0.3),
          width: 0.5,
        ),
      ),
      child: Text(
        jsonKey,
        style: const TextStyle(
          color: Color(0xFF89B4FA),
          fontSize: 9,
          fontFamily: 'monospace',
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
