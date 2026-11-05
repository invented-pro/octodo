// The Feishu settings section: the master toggle row plus the
// binding card driven by [FeishuBindingFlow.shared] (design doc
// §2.2 / §6). States map 1:1 to the flow's phases:
//
//   idle            → "Connect Feishu…" button + explainer
//   requestingCode  → progress spinner
//   waitingForScan  → QR dialog (opened by the button that started
//                     the flow; countdown until expiresAt)
//   connected       → bound-app summary + Unbind
//   expired/failed  → reason + Retry

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart' as url_launcher;

import '../../../src/feishu/feishu_binding_flow.dart';
import '../../../src/settings/settings_runtime.dart';
import '../../../src/theme/palette_context.dart';
import '../../../src/theme/palettes.dart';
import '../chrome/settings_card.dart';
import '../chrome/settings_row.dart';
import '../widgets/trailing_widgets.dart';

/// The settings-section widget. Named `FeishuSection` (not
/// `…SettingsSection`) to avoid clashing with the catalog section
/// class of the same intent in `settings_catalog.dart` — the
/// settings dialog imports both libraries.
class FeishuSection extends StatefulWidget {
  final bool showJsonPaths;
  const FeishuSection({super.key, required this.showJsonPaths});

  @override
  State<FeishuSection> createState() => _FeishuSectionState();
}

class _FeishuSectionState extends State<FeishuSection> {
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsSectionHeader('FEISHU'),
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
              showJsonPaths: widget.showJsonPaths,
            ),
          ],
        ),
        const SizedBox(height: 8),
        SettingsCard(children: [_bindingCard(palette)]),
      ],
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
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!expired)
            OutlinedButton(
              onPressed: () => _flow.start(),
              child: const Text('Retry'),
            )
          else
            FilledButton.icon(
              onPressed: () => _flow.start(),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('New QR code'),
            ),
        ],
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
                : QrImageView(
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
            // Only cancel — the section's phase listener pops this
            // dialog on the idle transition. Popping here too would
            // double-pop and dismiss the settings dialog as well.
            flow.cancel();
          },
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
