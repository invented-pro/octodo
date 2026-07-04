// Update pill — small capsule in the workspace drawer, under the
// Settings button.
//
// Two modes:
//   * Urgent — surfaces a real status (Checking / Update available
//     / Downloading / Error). Renders the accent-colored styles.
//   * Compact — when [alwaysShow] is true and there's no urgent
//     status, renders a subdued "Octodo · 1.0.0+1 · info" row that
//     reuses the dialog as an About panel.

import 'package:flutter/material.dart';

import '../../src/app_info.dart';
import '../../src/theme/palette_context.dart';
import '../../src/update/update_controller.dart';
import '../../src/update/update_state.dart';
import 'update_popover_view.dart';

class UpdatePill extends StatelessWidget {
  final UpdateStateModel model;
  final UpdateController controller;
  final bool collapsed;

  /// When true, the pill renders even when there's no urgent update
  /// status — uses a low-key style so the same dialog stays
  /// reachable as an About panel.
  final bool alwaysShow;

  const UpdatePill({
    super.key,
    required this.model,
    required this.controller,
    this.collapsed = false,
    this.alwaysShow = false,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        final urgent = model.showsPill;
        if (!urgent && !alwaysShow) return const SizedBox.shrink();
        if (collapsed) {
          return _CollapsedPill(
            model: model,
            controller: controller,
            urgent: urgent,
          );
        }
        return _ExpandedPill(
          model: model,
          controller: controller,
          urgent: urgent,
        );
      },
    );
  }
}

class _ExpandedPill extends StatelessWidget {
  final UpdateStateModel model;
  final UpdateController controller;
  final bool urgent;
  const _ExpandedPill({
    required this.model,
    required this.controller,
    required this.urgent,
  });

  @override
  Widget build(BuildContext context) {
    final isError = model.state == UpdateState.error;
    final isAvailable = model.state == UpdateState.updateAvailable;
    final isChecking = model.state == UpdateState.checking;
    final palette = context.palette;

    Color bg;
    Color fg;
    Color border;
    String label;

    if (urgent) {
      if (isError) {
        bg = palette.rowSurface;
        fg = palette.accentYellow;
        border = palette.outline;
      } else if (isAvailable) {
        bg = palette.accentBlue.withValues(alpha: 0.15);
        fg = palette.accentBlue;
        border = palette.accentBlue.withValues(alpha: 0.5);
      } else {
        bg = palette.surface2;
        fg = palette.textSecondary;
        border = palette.outline;
      }
      label = model.text;
    } else {
      bg = palette.surface2;
      fg = palette.textSecondary;
      border = palette.rowSurface;
      label = '$kAppName · ${model.currentVersion}';
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 2),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => showUpdatePopover(
            context,
            model: model,
            controller: controller,
          ),
          behavior: HitTestBehavior.opaque,
          child: Tooltip(
            message: urgent
                ? model.text
                : 'About $kAppName',
            waitDuration: const Duration(milliseconds: 400),
              child: Container(
                height: 28,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: border, width: 1),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _Badge(
                      state: model.state,
                      color: fg,
                      isChecking: isChecking,
                      urgent: urgent,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      label,
                      style: TextStyle(
                        color: fg,
                        fontSize: 11,
                        fontWeight: urgent
                            ? FontWeight.w500
                            : FontWeight.w400,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ],
                ),
              ),
          ),
        ),
      ),
    );
  }
}

class _CollapsedPill extends StatelessWidget {
  final UpdateStateModel model;
  final UpdateController controller;
  final bool urgent;
  const _CollapsedPill({
    required this.model,
    required this.controller,
    required this.urgent,
  });

  @override
  Widget build(BuildContext context) {
    final isAvailable = model.state == UpdateState.updateAvailable;
    final isError = model.state == UpdateState.error;
    final isChecking = model.state == UpdateState.checking;
    final palette = context.palette;

    final Color fg = isError
        ? palette.accentYellow
        : isAvailable
            ? palette.accentBlue
            : urgent
                ? palette.textSecondary
                : palette.textOverlay;
    final Color border = isAvailable
        ? palette.accentBlue.withValues(alpha: 0.5)
        : urgent
            ? palette.outline
            : palette.rowSurface;

    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 2),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => showUpdatePopover(
            context,
            model: model,
            controller: controller,
          ),
          behavior: HitTestBehavior.opaque,
          child: Tooltip(
            message: urgent ? model.text : 'About $kAppName',
            waitDuration: const Duration(milliseconds: 400),
            child: Container(
              height: 28,
              decoration: BoxDecoration(
                color: isAvailable
                    ? palette.accentBlue.withValues(alpha: 0.15)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: border, width: 1),
              ),
              child: Center(
                child: _Badge(
                  state: model.state,
                  color: fg,
                  isChecking: isChecking,
                  urgent: urgent,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final UpdateState state;
  final Color color;
  final bool isChecking;
  final bool urgent;
  const _Badge({
    required this.state,
    required this.color,
    required this.isChecking,
    required this.urgent,
  });

  @override
  Widget build(BuildContext context) {
    if (isChecking) {
      return SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(
          strokeWidth: 1.6,
          valueColor: AlwaysStoppedAnimation<Color>(color),
        ),
      );
    }
    if (!urgent) {
      return Icon(Icons.info_outline,
          size: 14, color: context.palette.textOverlay);
    }
    return Icon(_iconFor(state), size: 14, color: color);
  }

  IconData _iconFor(UpdateState s) {
    switch (s) {
      case UpdateState.checking:
        return Icons.sync;
      case UpdateState.updateAvailable:
        return Icons.system_update_alt;
      case UpdateState.downloading:
        return Icons.downloading;
      case UpdateState.downloaded:
      case UpdateState.installing:
        return Icons.restart_alt;
      case UpdateState.error:
        return Icons.error_outline;
      // `idle` and `notFound` both have `showsPill == false`, so
      // this badge is never rendered for them — but the switch
      // has to be exhaustive, so fall through to a sensible
      // default.
      case UpdateState.idle:
      case UpdateState.notFound:
        return Icons.check_circle_outline;
    }
  }
}
