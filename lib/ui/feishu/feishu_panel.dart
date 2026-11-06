// The Mobile App panel — a standalone dialog (opened from the
// drawer, below the "New workspace" button) covering the mobile-app
// integrations. Feishu is the first; more are planned, so each app
// renders as its own card and the dialog chrome stays app-neutral.
//
// Feishu binding states map 1:1 to [FeishuBindingFlow] phases:
//
//   idle            → "Connect Feishu…" button + explainer
//   requestingCode  → progress spinner
//   waitingForScan  → QR dialog (auto-opened, countdown)
//   connected       → bound-app summary + Unbind
//   expired/failed  → reason + Retry
//
// When another octodo instance holds the Feishu connection (the
// multi-instance connection lease), the card shows that instead —
// one line, no buttons.
//
// Remote control is always on once a bot is bound — credentials are
// the only gate, so the panel has no switch at all.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart' as url_launcher;

import '../../src/feishu/feishu_binding_flow.dart';
import '../../src/feishu/feishu_lease.dart';
import '../../src/theme/palette_context.dart';
import '../../src/theme/palettes.dart';
import '../settings/chrome/settings_card.dart';
import '../settings/chrome/settings_row.dart';

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

class MobileAppsPanel extends StatefulWidget {
  /// Non-null while another octodo instance holds the Feishu
  /// connection — the Feishu card then shows who holds it (with a
  /// Claim button) instead of the binding lifecycle.
  final ValueListenable<FeishuStandby?>? standby;

  /// Force-takes the connection lease (the standby card's Claim).
  final VoidCallback? onClaim;

  const MobileAppsPanel({super.key, this.standby, this.onClaim});

  @override
  State<MobileAppsPanel> createState() => _MobileAppsPanelState();
}

class _MobileAppsPanelState extends State<MobileAppsPanel> {
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
    return Dialog(
      child: SizedBox(
        width: 560,
        height: 520,
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
                    // Feishu — the first mobile app. The whole
                    // binding lifecycle lives in this one card;
                    // future apps get their own card beside it.
                    SettingsCard(
                      children: [_bindingCard(palette)],
                    ),
                    const SizedBox(height: 16),
                    _usageSection(palette),
                    const SizedBox(height: 16),
                    Text(
                      'More mobile apps are coming soon.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: palette.textMuted,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// What a bound bot understands — the same listing `/help` sends,
  /// with a hand-drawn (theme-aware, no assets) illustration of the
  /// round trip: a chat command on the phone, the command landing
  /// in this app's terminal, the result coming back.
  Widget _usageSection(ThemePalette palette) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'USAGE',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
            color: palette.textMuted,
          ),
        ),
        const SizedBox(height: 8),
        SettingsCard(
          children: [
            _usageIllustration(palette),
            _usageRow(palette, '/status',
                'Workspaces, panes, tabs — what this chat drives.'),
            _usageRow(palette, '/attach 1.2.3',
                'Bind to a terminal by its numbers; /detach follows '
                'the desktop.'),
            _usageRow(palette, '/newtab · /closetab',
                'Manage tabs in the bound pane.'),
            _usageRow(palette, '/raw <keys>',
                'Raw keystrokes into the terminal — TUIs included '
                '(/raw /quit).'),
            _usageRow(palette, '/history',
                "Replay the target terminal's last screen."),
            _usageRow(palette, 'plain text',
                'Runs in the bound terminal and answers with its '
                'output.'),
          ],
        ),
      ],
    );
  }

  Widget _usageRow(ThemePalette palette, String command,
      String description) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Row(
        children: [
          Container(
            width: 126,
            padding:
                const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: palette.accentBlue.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              command,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: palette.accentBlue,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              description,
              style: TextStyle(
                fontSize: 11,
                height: 1.3,
                color: palette.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Phone → chevrons → terminal window, all palette chrome.
  Widget _usageIllustration(ThemePalette palette) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _illustrationPhone(palette),
          const SizedBox(width: 8),
          _illustrationSignal(palette),
          const SizedBox(width: 8),
          _illustrationTerminal(palette),
        ],
      ),
    );
  }

  /// The phone with a chat bubble carrying a command.
  Widget _illustrationPhone(ThemePalette palette) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: 30,
          height: 56,
          decoration: BoxDecoration(
            color: palette.surface2,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: palette.accentBlue.withValues(alpha: 0.7),
              width: 1.5,
            ),
          ),
          padding: const EdgeInsets.all(3.5),
          child: Container(
            decoration: BoxDecoration(
              color: palette.surface1,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Container(
                  width: 10,
                  height: 2,
                  margin: const EdgeInsets.only(bottom: 2),
                  decoration: BoxDecoration(
                    color: palette.outline,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ],
            ),
          ),
        ),
        // The command bubble, drifting off the phone's corner.
        Positioned(
          right: -26,
          top: -9,
          child: Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: palette.accentBlue.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: palette.accentBlue.withValues(alpha: 0.4),
              ),
            ),
            child: Text(
              '/status',
              style: TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w600,
                color: palette.accentBlue,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Fading chevrons — the message on its way.
  Widget _illustrationSignal(ThemePalette palette) {
    return Row(
      children: [
        for (final alpha in const [0.85, 0.55, 0.3])
          Icon(
            Icons.chevron_right,
            size: 13,
            color: palette.textMuted.withValues(alpha: alpha),
          ),
      ],
    );
  }

  /// The desktop terminal window: title-bar dots, a prompt, a
  /// finished task, a waiting cursor.
  Widget _illustrationTerminal(ThemePalette palette) {
    return Container(
      width: 172,
      decoration: BoxDecoration(
        color: palette.surface2,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: palette.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 15,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: palette.surface1,
              borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(7)),
              border: Border(
                bottom: BorderSide(color: palette.outline),
              ),
            ),
            child: Row(
              children: [
                for (final color in [
                  palette.accentPink,
                  palette.accentYellow,
                  palette.accentGreen,
                ])
                  Container(
                    width: 5,
                    height: 5,
                    margin: const EdgeInsets.only(right: 4),
                    decoration:
                        BoxDecoration(color: color, shape: BoxShape.circle),
                  ),
              ],
            ),
          ),
          Padding(
            padding:
                const EdgeInsets.fromLTRB(9, 7, 9, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(style: TextStyle(fontSize: 10, height: 1.35), children: [
                    TextSpan(
                      text: '\$ ',
                      style: TextStyle(
                          color: palette.accentGreen,
                          fontWeight: FontWeight.w600),
                    ),
                    TextSpan(
                        text: 'cargo test',
                        style: TextStyle(color: palette.textBody)),
                  ]),
                ),
                Text(
                  '  ✓ done · 4m12s',
                  style: TextStyle(
                    fontSize: 10,
                    height: 1.35,
                    color: palette.accentGreen,
                  ),
                ),
                Text.rich(
                  TextSpan(style: TextStyle(fontSize: 10, height: 1.35), children: [
                    TextSpan(
                      text: '\$ ',
                      style: TextStyle(
                          color: palette.accentGreen,
                          fontWeight: FontWeight.w600),
                    ),
                    TextSpan(
                        text: '_',
                        style: TextStyle(color: palette.textMuted)),
                  ]),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bindingCard(ThemePalette palette) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        _flow,
        if (widget.standby != null) widget.standby,
      ]),
      builder: (context, _) {
        // Another instance holds the Feishu connection — this one
        // shows that, whatever the local binding phase says (the
        // binding is disk state; the connection is not ours).
        final standby = widget.standby?.value;
        if (standby != null) return _standbyRow(palette, standby);
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

  /// This instance lost the lease — one factual line plus Claim,
  /// which force-takes the lease (the previous holder demotes on
  /// its next heartbeat). No bind/unbind buttons: the holder
  /// ignores disk changes until it re-syncs.
  Widget _standbyRow(ThemePalette palette, FeishuStandby standby) {
    final holder = standby.ownerPid == null
        ? 'another octodo instance'
        : 'another octodo instance (PID ${standby.ownerPid})';
    return SettingsCardRow(
      leading: _brandLeading(palette),
      title: 'Feishu',
      subtitle: 'Held by $holder.',
      trailing: FilledButton(
        onPressed: widget.onClaim,
        child: const Text('Claim'),
      ),
    );
  }

  /// The Feishu brand mark as a row leading widget.
  Widget _brandLeading(ThemePalette palette) {
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        color: palette.accentBlue.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Center(
        child: FeishuBrandIcon(color: palette.accentBlue, size: 14),
      ),
    );
  }

  Widget _idleRow(ThemePalette palette) {
    return SettingsCardRow(
      leading: _brandLeading(palette),
      title: 'Feishu',
      subtitle:
          'Not connected. Scan once with Feishu to create a private bot '
          'app with the permissions Octodo needs. Credentials stay on '
          'this machine.',
      trailing: FilledButton.icon(
        onPressed: () => _flow.start(),
        icon: const Icon(Icons.link, size: 16),
        label: const Text('Connect Feishu…'),
      ),
    );
  }

  Widget _inProgressRow(ThemePalette palette) {
    return SettingsCardRow(
      leading: _brandLeading(palette),
      title: 'Feishu',
      subtitle: 'Starting QR binding — contacting the Feishu accounts '
          'service for a device code.',
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
      leading: _brandLeading(palette),
      title: 'Feishu · Connected',
      subtitle:
          'Bound to ${creds?.appIdPreview ?? 'app'}, created '
          '${creds == null ? '' : _formatBoundAt(creds.boundAt)}. '
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
      leading: _brandLeading(palette),
      title: expired ? 'Feishu · QR code expired' : 'Feishu · Binding failed',
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
              child: Icon(Icons.phonelink, size: 16, color: palette.accentBlue),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            'Mobile App Access',
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

Future<void> showMobileAppsPanel(
  BuildContext context, {
  ValueListenable<FeishuStandby?>? standby,
  VoidCallback? onClaim,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    builder: (_) => MobileAppsPanel(standby: standby, onClaim: onClaim),
  );
}
