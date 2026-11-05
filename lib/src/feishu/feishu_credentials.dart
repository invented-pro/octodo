// Feishu bot credentials + the sender allowlist, persisted under
// the user's config directory next to `settings.json`:
//
//   <userHome>/.config/Octodo/feishu/credentials.json
//
// The file holds the App ID / App Secret obtained from the QR
// registration flow plus the allowlist of `open_id`s allowed to
// drive the terminal remotely (§4.2 of the integration design:
// long-connection transport is authenticated/encrypted by the
// platform, but *sender* authorization is the app's job — the
// creator's open_id is recorded automatically on first bind).
//
// Storage posture (phase 1): plain JSON with owner-only file
// permissions on POSIX (chmod 600; on Windows the user-profile ACL
// already restricts access). Phase 3 moves the secret into the OS
// keychain (DPAPI / Keychain / libsecret) — the store interface
// below is the seam for that swap.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class FeishuCredentials {
  /// `cli_…` App ID of the self-built app created by the QR flow.
  final String appId;

  /// App secret. Never log, never render — the settings UI only
  /// ever shows the App ID prefix.
  final String appSecret;

  /// `open_id` of the user who scanned the QR code. Auto-added to
  /// [allowedOpenIds] on save (see [FeishuCredentialStore.save]).
  final String ownerOpenId;

  /// `feishu` or `lark` — decides the accounts/API base domain.
  final String tenantBrand;

  final DateTime boundAt;

  /// Senders allowed to trigger terminal commands. Empty entry
  /// means "nobody" (integration idle) — the owner is always in
  /// here after a successful bind.
  final List<String> allowedOpenIds;

  const FeishuCredentials({
    required this.appId,
    required this.appSecret,
    required this.ownerOpenId,
    required this.tenantBrand,
    required this.boundAt,
    this.allowedOpenIds = const [],
  });

  bool get isLark => tenantBrand == 'lark';

  /// Redacted form safe for logs and UI: keeps the `cli_` prefix
  /// and a short suffix only.
  String get appIdPreview {
    if (appId.length <= 8) return appId;
    return '${appId.substring(0, 8)}…${appId.substring(appId.length - 3)}';
  }

  Map<String, dynamic> toJson() => {
    'appId': appId,
    'appSecret': appSecret,
    'ownerOpenId': ownerOpenId,
    'tenantBrand': tenantBrand,
    'boundAt': boundAt.toIso8601String(),
    'allowedOpenIds': allowedOpenIds,
  };

  static FeishuCredentials? fromJson(Map<String, dynamic> json) {
    final appId = json['appId'];
    final appSecret = json['appSecret'];
    if (appId is! String || appSecret is! String || appId.isEmpty) {
      return null;
    }
    final boundAt = DateTime.tryParse('${json['boundAt'] ?? ''}');
    final allowRaw = json['allowedOpenIds'];
    return FeishuCredentials(
      appId: appId,
      appSecret: appSecret,
      ownerOpenId: json['ownerOpenId'] is String
          ? json['ownerOpenId'] as String
          : '',
      tenantBrand: json['tenantBrand'] is String
          ? json['tenantBrand'] as String
          : '',
      // Unknown timestamps (corrupt/legacy file) fall back to now
      // rather than the epoch, which would render as 1970-01-01.
      boundAt: boundAt ?? DateTime.now(),
      allowedOpenIds: allowRaw is List
          ? allowRaw.whereType<String>().where((s) => s.isNotEmpty).toList()
          : const [],
    );
  }
}

/// Loads / saves / deletes the credentials file. File-system only;
/// keep UI and network concerns out (they live in the binding flow
/// and the settings section respectively).
class FeishuCredentialStore {
  final File file;

  FeishuCredentialStore(this.file);

  factory FeishuCredentialStore.resolve({String? userHome}) {
    final home = userHome ??
        Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '';
    return FeishuCredentialStore(
      File(p.join(home, '.config', 'Octodo', 'feishu', 'credentials.json')),
    );
  }

  Future<FeishuCredentials?> load() async {
    try {
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return FeishuCredentials.fromJson(decoded);
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// Persist [credentials]. The owner's open_id is force-merged
  /// into the allowlist so the binding user can always drive the
  /// bot, and duplicates are collapsed while preserving order
  /// (owner first).
  Future<void> save(FeishuCredentials credentials) async {
    final owner = credentials.ownerOpenId;
    final seen = <String>{};
    final merged = <String>[
      if (owner.isNotEmpty) owner,
      ...credentials.allowedOpenIds.where(
        (id) => id != owner && id.isNotEmpty && seen.add(id),
      ),
    ];
    final normalized = FeishuCredentials(
      appId: credentials.appId,
      appSecret: credentials.appSecret,
      ownerOpenId: credentials.ownerOpenId,
      tenantBrand: credentials.tenantBrand,
      boundAt: credentials.boundAt,
      allowedOpenIds: merged.toList(),
    );
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(normalized.toJson()),
      flush: true,
    );
    _restrictPermissions(file);
  }

  Future<void> delete() async {
    try {
      await file.delete();
    } on FileSystemException {
      // Already gone — unbind is idempotent.
    }
  }

  static void _restrictPermissions(File file) {
    if (Platform.isWindows) return;
    // POSIX: owner read/write only. Best effort — a chmod failure
    // must not fail the whole bind.
    try {
      final result = Process.runSync('chmod', ['600', file.path]);
      assert(result.exitCode == 0, 'chmod 600 failed for ${file.path}');
    } catch (_) {
      // Ignore: file remains with default umask permissions.
    }
  }
}
