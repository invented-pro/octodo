// The Feishu panel — a standalone dialog (opened from the drawer,
// below the "New workspace" button) that owns everything Feishu:
// the master toggle and the QR-binding card. Kept out of the
// Settings dialog deliberately: the binding is an account-level
// connection flow, not a preferences row.
//
// Binding states map 1:1 to [FeishuBindingFlow] phases:
//
//   idle            → "Connect Feishu…" button + explainer
//   requestingCode  → progress spinner
//   waitingForScan  → QR dialog (auto-opened, countdown)
//   connected       → bound-app summary + Unbind
//   expired/failed  → reason + Retry

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart' as url_launcher;

import '../../src/feishu/feishu_binding_flow.dart';
import '../../src/settings/settings_runtime.dart';
import '../../src/theme/palette_context.dart';
import '../../src/theme/palettes.dart';
import '../settings/chrome/settings_card.dart';
import '../settings/chrome/settings_row.dart';
import '../settings/widgets/trailing_widgets.dart';

/// The official Lark/Feishu bird mark (ByteDance IconPark outline
/// variant) as a monochrome asset tinted to [color].
class FeishuBrandIcon extends StatelessWidget {
  final Color color;
  final double size;
  const FeishuBrandIcon({super.key, required this.color, this.size = 16});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: SvgPicture.asset(
        'assets/icons/feishu.svg',
        fit: BoxFit.contain,
        colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
      ),
    );
  }
}

class FeishuPanel extends StatefulWidget {
  const FeishuPanel({super.key});

  @override
  State<FeishuPanel> createState() => _FeishuPanelState();
}

class _FeishuPanelState extends State<FeishuPanel> {
  late final FeishuBindingFlow _flow = FeishuBindingFlow.shared;
  void _onFlowChanged() {
    if (!mounted) return;
    setState(() {});
    // Auto-open the QR dialog the moment the verification URL
    // lands; auto-close when the flow leaves the waiting phase.
    switch (_flow.phase) {
      case FeishuBindingPhase.waitingForScan:
        if (!_qrDialogOpen) _openQrDialog();
      case FeishuBindingPhase.requestingCode:
        break;
      default:
        if (_qrDialogOpen) Navigator.of(context, rootNavigator: true).pop();
    }
  }

  bool _qrDialogOpen = false;

  @override
  void initState() {
    super.initState();
    _flow.loadPersisted();
    _flow.addListener(_onFlowChanged);
  }

  @override
  void dispose() {
    _flow.removeListener(_onFlowChanged);
    super.dispose();
  }

  void _openQrDialog() {
    _qrDialogOpen = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _FeishuQrDialog(flow: _flow),
    ).whenComplete(() => _qrDialogOpen = false);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final catalog = SettingsRuntime.instance.catalog;
    return Dialog(
      child: SizedBox(
        width: 560,
        height: 420,
        child: Column(
          children: [
            _Header(onClose: () => Navigator.of(context).pop()),
            Container(width: 1, height: 1, color: palette.outline),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SettingsCard(
                      children: [
                        SettingsCardRow(
                          jsonKey: catalog.feishu.enabled.key,
                          title: catalog.feishu.enabled.title,
                          subtitle: catalog.feishu.enabled.subtitle,
                          leadingIcon: catalog.feishu.enabled.icon,
                          trailing: BoolToggleTrailing(
                            setting: catalog.feishu.enabled,
                            store: SettingsRuntime.instance.store,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SettingsCard(children: [_bindingCard(palette)]),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bindingCard(ThemePalette palette) {
    return ListenableBuilder(
      listenable: _flow,
      builder: (context, _) {
        switch (_flow.phase) {
          case FeishuBindingPhase.connected:
            return _connectedRow(palette);
          case FeishuBindingPhase.requestingCode:
          case FeishuBindingPhase.waitingForScan:
            return _inProgressRow(palette);
          case FeishuBindingPhase.expired:
          case FeishuBindingPhase.failed:
            return _terminalRow(palette);
          case FeishuBindingPhase.idle:
            return _idleRow(palette);
        }
      },
    );
  }

  Widget _idleRow(ThemePalette palette) {
    return SettingsCardRow(
      leadingIcon: Icons.qr_code_2,
      title: 'No bot bound',
      subtitle:
          'Scan once with Feishu to create a private bot app with the '
          'permissions Octodo needs. Credentials stay on this machine.',
      trailing: FilledButton.icon(
        onPressed: () => _flow.start(),
        icon: const Icon(Icons.link, size: 16),
        label: const Text('Connect Feishu…'),
      ),
    );
  }

  Widget _inProgressRow(ThemePalette palette) {
    return SettingsCardRow(
      leadingIcon: Icons.qr_code_2,
      title: 'Starting QR binding…',
      subtitle: 'Contacting the Feishu accounts service for a device code.',
      trailing: const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }

  Widget _connectedRow(ThemePalette palette) {
    final creds = _flow.credentials;
    final brand = creds == null || creds.tenantBrand.isEmpty
        ? 'Feishu'
        : (creds.isLark ? 'Lark' : 'Feishu');
    return SettingsCardRow(
      leadingIcon: Icons.verified_outlined,
      title: 'Bound to ${creds?.appIdPreview ?? 'app'}',
      subtitle:
          '$brand bot created ${creds == null ? '' : _formatBoundAt(creds.boundAt)}. '
          'Message the bot in $brand to run commands here.',
      trailing: OutlinedButton(
        onPressed: () => _flow.unbind(),
        child: const Text('Unbind'),
      ),
    );
  }

  Widget _terminalRow(ThemePalette palette) {
    final expired = _flow.phase == FeishuBindingPhase.expired;
    return SettingsCardRow(
      leadingIcon: expired ? Icons.timer_off_outlined : Icons.error_outline,
      title: expired ? 'QR code expired' : 'Binding failed',
      subtitle: _flow.errorMessage ?? 'Try again.',
      trailing: expired
          ? FilledButton.icon(
              onPressed: () => _flow.start(),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('New QR code'),
            )
          : OutlinedButton(
              onPressed: () => _flow.start(),
              child: const Text('Retry'),
            ),
    );
  }

  String _formatBoundAt(DateTime dt) {
    final local = dt.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}

class _Header extends StatelessWidget {
  final VoidCallback onClose;
  const _Header({required this.onClose});

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: palette.popupSurface,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(12),
          topRight: Radius.circular(12),
        ),
        border: Border(bottom: BorderSide(color: palette.outline, width: 1)),
      ),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: palette.accentBlue.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Center(
              child: FeishuBrandIcon(
                color: palette.accentBlue,
                size: 15,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            'Feishu',
            style: TextStyle(
              color: palette.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: onClose,
              child: Icon(Icons.close, size: 16, color: palette.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

/// The QR modal: renders the verification URL, counts down to the
/// device-code deadline, and offers a manual link for phone setups
/// where scanning a desktop-screen QR is awkward.
class _FeishuQrDialog extends StatefulWidget {
  final FeishuBindingFlow flow;
  const _FeishuQrDialog({required this.flow});

  @override
  State<_FeishuQrDialog> createState() => _FeishuQrDialogState();
}

class _FeishuQrDialogState extends State<_FeishuQrDialog> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final flow = widget.flow;
    final uri = flow.qrUri;
    final remaining = flow.expiresAt?.difference(DateTime.now());
    final mmss = remaining == null || remaining.isNegative
        ? '—'
        : '${(remaining.inSeconds ~/ 60)}:${(remaining.inSeconds % 60).toString().padLeft(2, '0')}';

    return AlertDialog(
      title: const Text('Scan with Feishu'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Open Feishu on your phone, scan this code, and confirm '
            'the pre-filled permissions to create your Octodo bot.',
            style: TextStyle(color: palette.textSecondary, fontSize: 12),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
            ),
            child: uri == null
                ? const SizedBox(
                    width: 220,
                    height: 220,
                    child: Center(
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                // AlertDialog wraps its content column in an
                // IntrinsicWidth, whose speculative intrinsic walk
                // reaches QrImageView's internal LayoutBuilder and
                // throws ("LayoutBuilder does not support returning
                // intrinsic dimensions") — the dialog's render box
                // then never gets a size, and every later hit test
                // over it fails ("Cannot hit test a render box with
                // no size"). A tight SizedBox short-circuits the
                // intrinsic walk at its own constraints
                // (RenderConstrainedBox), so it never reaches the
                // LayoutBuilder.
                : SizedBox(
                    width: 220,
                    height: 220,
                    child: QrImageView(
                      data: uri.toString(),
                      version: QrVersions.auto,
                      size: 220,
                      gapless: false,
                      backgroundColor: Colors.white,
                      eyeStyle: const QrEyeStyle(
                        eyeShape: QrEyeShape.square,
                        color: Colors.black,
                      ),
                      dataModuleStyle: const QrDataModuleStyle(
                        dataModuleShape: QrDataModuleShape.square,
                        color: Colors.black,
                      ),
                    ),
                  ),
          ),
          const SizedBox(height: 12),
          Text(
            'Expires in $mmss',
            style: TextStyle(color: palette.textMuted, fontSize: 11),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: uri == null
              ? null
              : () => url_launcher.launchUrl(
                  uri,
                  mode: url_launcher.LaunchMode.externalApplication,
                ),
          child: const Text('Open link instead'),
        ),
        TextButton(
          onPressed: () {
            // Only cancel — the panel's phase listener pops this
            // dialog on the idle transition. Popping here too would
            // double-pop and dismiss the Feishu panel as well.
            flow.cancel();
          },
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

// ── Show the panel ─────────────────────────────────────────────────

Future<void> showFeishuPanel(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    builder: (_) => const FeishuPanel(),
  );
}
