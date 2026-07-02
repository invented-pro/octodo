// Reusable card chrome for the settings dialog. A card is a
// rounded, tinted container holding a list of rows separated by
// 1px dividers. A section is a vertical stack of cards.

import 'package:flutter/material.dart';
import '../../../src/theme/palette_context.dart';

class SettingsCard extends StatelessWidget {
  final List<Widget> children;
  final EdgeInsetsGeometry margin;
  const SettingsCard({
    super.key,
    required this.children,
    this.margin = const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        // Card surface sits one tier above the dialog so a row's
        // hover/focus overlay (which uses surface1 with alpha) has
        // somewhere to fade toward. Outline + shadow stay constant
        // across palettes so the chrome reads as "elevated" the same
        // way in light and dark themes.
        color: palette.surface2,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.outline, width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            children[i],
            if (i < children.length - 1) const SettingsCardDivider(),
          ],
        ],
      ),
    );
  }
}

class SettingsCardDivider extends StatelessWidget {
  const SettingsCardDivider({super.key});
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      margin: const EdgeInsets.symmetric(horizontal: 14),
      color: context.palette.outline,
    );
  }
}

class SettingsSectionHeader extends StatelessWidget {
  final String text;
  const SettingsSectionHeader(this.text, {super.key});
  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 6),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 12,
            decoration: BoxDecoration(
              color: palette.accentBlue,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              color: palette.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}
