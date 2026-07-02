// Update popover — themed dialog mirroring the settings palette:
// every color is read from `context.palette` so it retints when
// the user switches themes. The dialog is one of two surfaces
// (alongside the workspace drawer) that are palette-aware.
//
// One body per [UpdateState]. Click handlers call back into the
// [UpdateController] passed in at show time.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../src/app_info.dart';
import '../../src/theme/palette_context.dart';
import '../../src/update/release_resolver.dart';
import '../../src/update/update_controller.dart';
import '../../src/update/update_state.dart';

Future<void> showUpdatePopover(
  BuildContext context, {
  required UpdateStateModel model,
  required UpdateController controller,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    builder: (_) => UpdatePopoverView(model: model, controller: controller),
  );
}

class UpdatePopoverView extends StatelessWidget {
  final UpdateStateModel model;
  final UpdateController controller;
  const UpdatePopoverView({
    super.key,
    required this.model,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Dialog(
      backgroundColor: palette.dialogSurface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: palette.outline, width: 1),
      ),
      child: SizedBox(
        width: 380,
        child: AnimatedBuilder(
          animation: model,
          builder: (context, _) {
            return switch (model.state) {
              UpdateState.updateAvailable =>
                _AvailableBody(model: model, controller: controller),
              UpdateState.downloading => _DownloadingBody(
                  model: model, controller: controller),
              UpdateState.downloaded =>
                _DownloadedBody(model: model, controller: controller),
              UpdateState.installing => const _InstallingBody(),
              UpdateState.error => _ErrorBody(model: model, controller: controller),
              UpdateState.checking => const _CheckingBody(),
              UpdateState.idle || UpdateState.notFound =>
                _AboutBody(model: model, controller: controller),
            };
          },
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String title;
  final IconData? icon;
  final Color iconColor;
  /// Optional widget rendered in the 26x26 leading slot instead
  /// of the Material [icon] badge. Use this when the dialog's
  /// state deserves a non-Material glyph — e.g. the bundled app
  /// logo in the About body. Caller is responsible for fitting
  /// the child inside 26x26; no decorative backdrop is applied
  /// when [leading] is non-null.
  final Widget? leading;
  const _Header({
    required this.title,
    required this.icon,
    required this.iconColor,
    this.leading,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 18),
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
          if (leading != null)
            SizedBox(width: 26, height: 26, child: leading!)
          else
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(icon, size: 15, color: iconColor),
            ),
          const SizedBox(width: 10),
          Text(
            title,
            style: TextStyle(
              color: palette.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            color: palette.textSecondary,
            visualDensity: VisualDensity.compact,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  const _PrimaryButton({required this.label, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: palette.accentBlue,
        foregroundColor: palette.brightness == Brightness.dark
            ? palette.surface0
            : Colors.white,
      ),
      child: Text(label),
    );
  }
}

class _SecondaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  const _SecondaryButton({required this.label, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: palette.textSecondary,
      ),
      child: Text(label),
    );
  }
}

class _Footer extends StatelessWidget {
  final Widget left;
  final List<Widget> right;
  const _Footer({required this.left, required this.right});

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final rightChildren = <Widget>[];
    for (var i = 0; i < right.length; i++) {
      if (i > 0) rightChildren.add(const SizedBox(width: 8));
      rightChildren.add(right[i]);
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: palette.rowSurface, width: 1)),
      ),
      child: Row(
        children: [
          left,
          const Spacer(),
          ...rightChildren,
        ],
      ),
    );
  }
}

class _AvailableBody extends StatelessWidget {
  final UpdateStateModel model;
  final UpdateController controller;
  const _AvailableBody({required this.model, required this.controller});

  @override
  Widget build(BuildContext context) {
    final release = model.detected;
    final palette = context.palette;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          title: 'Update Available',
          icon: Icons.system_update_alt,
          iconColor: palette.accentBlue,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (release != null) _Metadata(release: release),
              const SizedBox(height: 14),
              Text(
                'The download is fetched from GitHub. The SHA-256 of '
                'the zip is checked against the sidecar before the '
                'running app is replaced.',
                style: TextStyle(
                    color: palette.textSecondary, fontSize: 11),
              ),
            ],
          ),
        ),
        _NotesLink(url: release?.htmlUrl),
        _Footer(
          left: _SecondaryButton(
            label: 'Skip this version',
            onPressed: () {
              if (release != null) {
                controller.skipVersion(release.version);
              } else {
                model.reset();
              }
              Navigator.of(context).pop();
            },
          ),
          right: [
            _SecondaryButton(
              label: 'Later',
              onPressed: () => Navigator.of(context).pop(),
            ),
            _PrimaryButton(
              label: _downloadLabel(release),
              onPressed: () {
                Navigator.of(context).pop();
                controller.downloadLatest();
              },
            ),
          ],
        ),
      ],
    );
  }

  String _downloadLabel(ReleaseInfo? release) {
    if (release == null) return 'Download';
    final mb = release.zipSizeBytes / 1024.0 / 1024.0;
    if (mb <= 0) return 'Download';
    return 'Download ${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
  }
}

class _DownloadingBody extends StatelessWidget {
  final UpdateStateModel model;
  final UpdateController controller;
  const _DownloadingBody({required this.model, required this.controller});

  @override
  Widget build(BuildContext context) {
    final progress = model.progress;
    final fraction = progress?.fraction ?? 0;
    final received = progress?.receivedBytes ?? 0;
    final total = progress?.totalBytes ?? 0;
    final version = progress?.version ?? '';
    final palette = context.palette;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          title: 'Downloading Update',
          icon: Icons.downloading,
          iconColor: palette.accentBlue,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (version.isNotEmpty)
                _MetaRow(label: 'Version:', value: version),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: total <= 0 ? null : fraction,
                  minHeight: 8,
                  backgroundColor: palette.rowSurface,
                  valueColor:
                      AlwaysStoppedAnimation<Color>(palette.accentBlue),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                total <= 0
                    ? '${_formatBytes(received)} downloaded…'
                    : '${_formatBytes(received)} of '
                        '${_formatBytes(total)} '
                        '(${(fraction * 100).toStringAsFixed(0)}%)',
                style: TextStyle(
                    color: palette.textSecondary, fontSize: 11),
              ),
            ],
          ),
        ),
        _Footer(
          left: const SizedBox.shrink(),
          right: [
            _SecondaryButton(
              label: 'Cancel',
              onPressed: () async {
                Navigator.of(context).pop();
                await controller.cancelDownload();
              },
            ),
          ],
        ),
      ],
    );
  }
}

class _DownloadedBody extends StatelessWidget {
  final UpdateStateModel model;
  final UpdateController controller;
  const _DownloadedBody({required this.model, required this.controller});

  @override
  Widget build(BuildContext context) {
    final d = model.downloaded;
    final verified = d?.digestVerified ?? false;
    final size = d?.sizeBytes ?? 0;
    final palette = context.palette;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          title: 'Ready to Install',
          icon: Icons.restart_alt,
          iconColor: palette.accentBlue,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (d != null) _MetaRow(label: 'Version:', value: d.version),
              const SizedBox(height: 6),
              _MetaRow(
                label: 'Size:',
                value: _formatBytes(size),
              ),
              const SizedBox(height: 6),
              _MetaRow(
                label: 'Integrity:',
                value: verified
                    ? 'SHA-256 verified'
                    : 'No SHA-256 published',
                valueColor: verified
                    ? palette.accentGreen
                    : palette.accentYellow,
              ),
              const SizedBox(height: 14),
              Text(
                'Pressing "Restart to install" closes the running '
                'app, swaps the staged payload over the install '
                'directory, then relaunches.',
                style: TextStyle(
                    color: palette.textSecondary, fontSize: 11),
              ),
            ],
          ),
        ),
        _Footer(
          left: const SizedBox.shrink(),
          right: [
            _SecondaryButton(
              label: 'Later',
              onPressed: () => Navigator.of(context).pop(),
            ),
            _PrimaryButton(
              label: 'Restart to install',
              onPressed: () {
                Navigator.of(context).pop();
                controller.applyDownloaded();
              },
            ),
          ],
        ),
      ],
    );
  }
}

class _InstallingBody extends StatelessWidget {
  const _InstallingBody();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          title: 'Applying Update',
          icon: Icons.restart_alt,
          iconColor: palette.accentBlue,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 24, 18, 24),
          child: Row(
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor:
                      AlwaysStoppedAnimation<Color>(palette.accentBlue),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                'Restarting to apply update…',
                style: TextStyle(
                    color: palette.textSecondary, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _NotesLink extends StatelessWidget {
  final Uri? url;
  const _NotesLink({required this.url});

  @override
  Widget build(BuildContext context) {
    final target = url;
    if (target == null) return const SizedBox.shrink();
    final palette = context.palette;
    return InkWell(
      onTap: () async {
        final ok = await launchUrl(target,
            mode: LaunchMode.externalApplication);
        if (!ok && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Could not open $target'),
              backgroundColor: palette.accentPink,
              duration: const Duration(seconds: 3),
            ),
          );
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        child: Row(
          children: [
            Icon(Icons.description_outlined,
                size: 14, color: palette.textSecondary),
            const SizedBox(width: 8),
            Text('View release notes',
                style: TextStyle(color: palette.textPrimary, fontSize: 12)),
            const Spacer(),
            Icon(Icons.open_in_new,
                size: 12, color: palette.textOverlay),
          ],
        ),
      ),
    );
  }
}

class _Metadata extends StatelessWidget {
  final ReleaseInfo release;
  const _Metadata({required this.release});

  static const _labelWidth = 90.0;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _MetaRow(label: 'Latest:', value: release.version),
        if (release.publishedAt != null)
          _MetaRow(
            label: 'Released:',
            value: _formatDate(release.publishedAt!),
          ),
        _MetaRow(
          label: 'Tag:',
          value: release.tagName,
        ),
      ],
    );
  }

  String _formatDate(DateTime d) {
    final local = d.toLocal();
    final mm = local.month.toString().padLeft(2, '0');
    final dd = local.day.toString().padLeft(2, '0');
    return '${local.year}-$mm-$dd';
  }
}

class _MetaRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  const _MetaRow({
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: _Metadata._labelWidth,
            child: Text(
              label,
              style: TextStyle(color: palette.textMuted, fontSize: 11),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(
                color: valueColor ?? palette.textPrimary,
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CheckingBody extends StatelessWidget {
  const _CheckingBody();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          title: 'Checking for Updates',
          icon: Icons.sync,
          iconColor: palette.accentBlue,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 24, 18, 24),
          child: Row(
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor:
                      AlwaysStoppedAnimation<Color>(palette.accentBlue),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                'Probing GitHub…',
                style: TextStyle(
                    color: palette.textSecondary, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Rendered when there's no pending update and no error — the
/// dialog doubles as an "About this build" panel: app name, current
/// version, repository link, and the author credit. Reachable
/// from the always-visible compact pill in the drawer footer.
class _AboutBody extends StatelessWidget {
  final UpdateStateModel model;
  final UpdateController controller;
  const _AboutBody({required this.model, required this.controller});

  @override
  Widget build(BuildContext context) {
    final version = model.currentVersion;
    final palette = context.palette;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          title: 'About $kAppName',
          icon: Icons.info_outline,
          iconColor: palette.accentBlue,
          leading: Image.asset(
            kAppLogoAsset,
            width: 26,
            height: 26,
            fit: BoxFit.contain,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                kAppName,
                style: TextStyle(
                  color: palette.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'A terminal complex for Windows, Linux, and macOS.',
                style:
                    TextStyle(color: palette.textSecondary, fontSize: 11),
              ),
              const SizedBox(height: 14),
              Container(
                height: 1,
                color: palette.rowSurface,
              ),
              const SizedBox(height: 12),
              _AboutRow(label: 'Version:', value: version.isEmpty ? '—' : version),
              const SizedBox(height: 6),
              _AboutLinkRow(
                label: 'Source:',
                url: Uri.parse(kAppRepository),
              ),
              const SizedBox(height: 6),
              _AboutLinkRow(
                label: 'Author:',
                url: Uri.parse(kAppAuthorUrl),
              ),
            ],
          ),
        ),
        _Footer(
          left: const SizedBox.shrink(),
          right: [
            _SecondaryButton(
              label: 'Close',
              onPressed: () => Navigator.of(context).pop(),
            ),
            _PrimaryButton(
              label: 'Open releases page',
              onPressed: () {
                Navigator.of(context).pop();
                launchUrl(
                  Uri.parse(kAppRepositoryReleases),
                  mode: LaunchMode.externalApplication,
                );
              },
            ),
          ],
        ),
      ],
    );
  }
}

class _AboutRow extends StatelessWidget {
  final String label;
  final String value;
  const _AboutRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: TextStyle(color: palette.textMuted, fontSize: 11),
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: TextStyle(
              color: palette.textPrimary,
              fontSize: 12,
              fontFamily: 'monospace',
            ),
          ),
        ),
      ],
    );
  }
}

class _AboutLinkRow extends StatelessWidget {
  final String label;
  final Uri url;
  const _AboutLinkRow({
    required this.label,
    required this.url,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: TextStyle(color: palette.textMuted, fontSize: 11),
          ),
        ),
        Expanded(
          child: InkWell(
            onTap: () async {
              final ok = await launchUrl(
                url,
                mode: LaunchMode.externalApplication,
              );
              if (!ok && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Could not open $url'),
                    backgroundColor: palette.accentPink,
                    duration: const Duration(seconds: 3),
                  ),
                );
              }
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      url.host + (url.path.isEmpty ? '' : url.path),
                      style: TextStyle(
                        color: palette.accentBlue,
                        fontSize: 12,
                        fontFamily: 'monospace',
                        decoration: TextDecoration.underline,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    Icons.open_in_new,
                    size: 11,
                    color: palette.textOverlay,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ErrorBody extends StatelessWidget {
  final UpdateStateModel model;
  final UpdateController controller;
  const _ErrorBody({required this.model, required this.controller});

  @override
  Widget build(BuildContext context) {
    final err = model.error;
    final palette = context.palette;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          title: 'Update Failed',
          icon: Icons.error_outline,
          iconColor: palette.accentYellow,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                err?.message ?? 'Update failed.',
                style: TextStyle(
                    color: palette.textPrimary, fontSize: 12),
              ),
              if (err?.technicalDetails != null) ...[
                const SizedBox(height: 10),
                _DetailsBox(text: err!.technicalDetails!),
              ],
            ],
          ),
        ),
        _Footer(
          left: _SecondaryButton(
            label: 'Copy details',
            onPressed: () {
              final details = err?.technicalDetails ?? '';
              if (details.isNotEmpty) {
                Clipboard.setData(ClipboardData(text: details));
              }
            },
          ),
          right: [
            _SecondaryButton(
              label: 'Close',
              onPressed: () => Navigator.of(context).pop(),
            ),
            if (err?.onRetry != null || err?.onDownload != null)
              _PrimaryButton(
                label: err?.onDownload != null ? 'Retry download' : 'Retry',
                onPressed: () {
                  Navigator.of(context).pop();
                  if (err?.onDownload != null) {
                    err!.onDownload!();
                  } else if (err?.onRetry != null) {
                    err!.onRetry!();
                  }
                },
              ),
          ],
        ),
      ],
    );
  }
}

class _DetailsBox extends StatelessWidget {
  final String text;
  const _DetailsBox({required this.text});

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: palette.surface0,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: palette.rowSurface, width: 1),
      ),
      child: SelectableText(
        text,
        style: TextStyle(
          color: palette.textSecondary,
          fontSize: 10,
          fontFamily: 'monospace',
        ),
        maxLines: 6,
      ),
    );
  }
}

String _formatBytes(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
  return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
}
