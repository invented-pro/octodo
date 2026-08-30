// Persistent in-app notification banners — the top-right overlay
// that complements the native desktop notifications.
//
// Both macOS and Windows auto-dismiss native banners after a few
// seconds; only a user-level style change ("Alerts" on macOS) makes
// them persist. Rather than leave a ~5 s window to catch a
// finished-task notification, the hub additionally maintains one
// coalesced banner per surface (see [NotificationHub.banners]) and
// this overlay renders them inside the Octodo window until the user
// clicks or dismisses them.
//
// Interaction:
//   * click card  → same navigation as a native-banner click
//     (activate window, select workspace, focus surface) + mark read
//   * click ✕     → mark read (withdraws the native banner too)
//
// Pointer behavior: the overlay only hit-tests the cards; the
// surrounding align returns false on hit tests, so terminal
// interaction is unaffected.

import 'package:flutter/material.dart';

import '../app_info.dart';
import '../theme/palette_context.dart';
import 'notification_hub.dart';

class InAppBannerOverlay extends StatelessWidget {
  const InAppBannerOverlay({
    super.key,
    required this.hub,
    required this.onActivate,
    required this.onDismiss,
  });

  final NotificationHub hub;

  /// Card click: navigate to the banner's workspace/surface. The
  /// caller marks it read.
  final void Function(String workspaceId, String surfaceId) onActivate;

  /// ✕ click: mark read without navigating.
  final void Function(String workspaceId, String surfaceId) onDismiss;

  static const int _maxVisible = 4;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: hub,
      builder: (context, _) {
        final banners = hub.banners;
        if (banners.isEmpty) return const SizedBox.shrink();
        final visible = banners.take(_maxVisible).toList(growable: false);
        final overflow = banners.length - visible.length;
        return Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.only(top: 12, right: 12),
            // Width cap: without it each card's Row stretches to the
            // full workspace width.
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (final b in visible)
                    _BannerCard(
                      banner: b,
                      onActivate: onActivate,
                      onDismiss: onDismiss,
                    ),
                  if (overflow > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 2, right: 4),
                      child: Text(
                        '+$overflow more',
                        style: TextStyle(color: context.palette.textMuted),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _BannerCard extends StatelessWidget {
  const _BannerCard({
    required this.banner,
    required this.onActivate,
    required this.onDismiss,
  });

  final InAppBanner banner;
  final void Function(String workspaceId, String surfaceId) onActivate;
  final void Function(String workspaceId, String surfaceId) onDismiss;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 180),
        builder: (context, t, child) => Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset((1 - t) * 24, 0),
            child: child,
          ),
        ),
        child: Material(
          elevation: 6,
          color: palette.dialogSurface,
          shadowColor: Colors.black.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => onActivate(banner.workspaceId, banner.surfaceId),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              // IntrinsicHeight bounds the Row's height so the
              // stretch cross-alignment (full-height accent bar +
              // card background) is legal — the overlay Column is
              // min-size and would otherwise pass unbounded height,
              // which stretch turns into
              // `BoxConstraints.tightFor(height: ∞)`.
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(width: 3, color: palette.accentBlue),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(0, 8, 8, 8),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    kAppName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: palette.textPrimary,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                if (banner.count > 1)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 6),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 1,
                                      ),
                                      decoration: BoxDecoration(
                                        color: palette.accentBlue.withValues(
                                          alpha: 0.18,
                                        ),
                                        borderRadius: BorderRadius.circular(
                                          999,
                                        ),
                                      ),
                                      child: Text(
                                        '×${banner.count}',
                                        style: TextStyle(
                                          color: palette.accentBlue,
                                          fontSize: 10,
                                        ),
                                      ),
                                    ),
                                  ),
                                _DismissButton(
                                  onPressed: () => onDismiss(
                                    banner.workspaceId,
                                    banner.surfaceId,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              banner.display,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: palette.textBody,
                                fontSize: 11,
                                height: 1.35,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DismissButton extends StatelessWidget {
  const _DismissButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return SizedBox(
      width: 22,
      height: 22,
      child: IconButton(
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        iconSize: 14,
        onPressed: onPressed,
        tooltip: 'Dismiss',
        icon: Icon(Icons.close, color: palette.textMuted),
      ),
    );
  }
}
