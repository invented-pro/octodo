// Reusable card chrome for the settings dialog. A card is a
// rounded, tinted container holding a list of rows separated by
// 1px dividers. A section is a vertical stack of cards.

import 'package:flutter/material.dart';

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
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A36),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF45475A), width: 1),
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
      color: const Color(0xFF45475A),
    );
  }
}

class SettingsSectionHeader extends StatelessWidget {
  final String text;
  const SettingsSectionHeader(this.text, {super.key});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 6),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 12,
            decoration: BoxDecoration(
              color: const Color(0xFF89B4FA),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            text,
            style: const TextStyle(
              color: Color(0xFFBAC2DE),
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
