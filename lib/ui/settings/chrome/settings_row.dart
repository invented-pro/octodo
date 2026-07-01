// A single row inside a settings card. Title + optional subtitle
// on the left, control widget on the right, optional "managed in
// settings.json" chip when the row is backed by the JSON store.
//
// The row is given a [GlobalKey] via [rowKey] so the search/nav
// layer can scroll to it.

import 'package:flutter/material.dart';
import 'configuration_review_chip.dart';

class SettingsCardRow extends StatelessWidget {
  /// The dotted settings key. When non-null, a small chip is
  /// shown next to the title (gated by [showJsonPaths]) so power
  /// users can see where in `settings.json` the value lives.
  final String? jsonKey;
  final String title;
  final String? subtitle;
  final IconData? leadingIcon;
  final Widget trailing;
  final GlobalKey? rowKey;
  final bool showJsonPaths;
  final VoidCallback? onTap;

  const SettingsCardRow({
    super.key,
    this.rowKey,
    this.jsonKey,
    required this.title,
    this.subtitle,
    this.leadingIcon,
    required this.trailing,
    this.showJsonPaths = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final body = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          if (leadingIcon != null) ...[
            Icon(leadingIcon, size: 16, color: const Color(0xFF89B4FA)),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        style: const TextStyle(
                          color: Color(0xFFEFF1F5),
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (showJsonPaths && jsonKey != null) ...[
                      const SizedBox(width: 8),
                      ConfigurationReviewChip(jsonKey: jsonKey!),
                    ],
                  ],
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    subtitle!,
                    style: const TextStyle(
                      color: Color(0xFF9CA0B0),
                      fontSize: 11,
                      height: 1.3,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          trailing,
        ],
      ),
    );

    if (onTap == null) return Container(key: rowKey, child: body);
    return Container(
      key: rowKey,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: body,
        ),
      ),
    );
  }
}
