// "Always approve" grants (design doc §4.2, phase 2): the workspace +
// dangerous-pattern pairs a user whitelisted from an approval card's
// "Always" button — the same command pattern in the same workspace no
// longer asks for confirmation.
//
// The grants live next to the bindings so a restart keeps them:
//
//   <userHome>/.config/Octodo/feishu/approvals.json
//
// The store is file-system only; the router owns the policy — a grant
// never bypasses the hard-deny patterns (those always confirm), and a
// grant is keyed to a *bound* workspace, never to "the active one"
// (the active target moves under the user's feet).

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// One grant: commands matching [pattern] in [workspaceId] no longer
/// ask for confirmation.
class FeishuApproval {
  final String workspaceId;
  final String pattern;
  final DateTime grantedAt;

  /// The `open_id` of whoever pressed "Always".
  final String grantedBy;

  const FeishuApproval({
    required this.workspaceId,
    required this.pattern,
    required this.grantedAt,
    required this.grantedBy,
  });

  /// The grant's key in the store — a workspace + pattern pair.
  static String keyOf(String workspaceId, String pattern) =>
      '$workspaceId\n$pattern';

  Map<String, dynamic> toJson() => {
        'workspaceId': workspaceId,
        'pattern': pattern,
        'grantedAt': grantedAt.toIso8601String(),
        'grantedBy': grantedBy,
      };

  static FeishuApproval? fromJson(Map<String, dynamic> json) {
    final workspaceId = json['workspaceId'];
    final pattern = json['pattern'];
    if (workspaceId is! String || workspaceId.isEmpty) return null;
    if (pattern is! String || pattern.isEmpty) return null;
    final grantedAt = DateTime.tryParse('${json['grantedAt'] ?? ''}');
    return FeishuApproval(
      workspaceId: workspaceId,
      pattern: pattern,
      grantedAt: grantedAt ?? DateTime.now(),
      grantedBy: json['grantedBy'] is String ? json['grantedBy'] as String : '',
    );
  }
}

/// Loads / saves the approvals file. Same contract as the binding
/// store: a missing or broken file means "no grants", and a failed
/// write is swallowed — persistence must never break the chat.
class FeishuApprovalStore {
  final File file;

  FeishuApprovalStore(this.file);

  factory FeishuApprovalStore.resolve({String? userHome}) {
    final home = userHome ??
        Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '';
    return FeishuApprovalStore(
      File(p.join(home, '.config', 'Octodo', 'feishu', 'approvals.json')),
    );
  }

  Future<Map<String, FeishuApproval>> load() async {
    try {
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return {};
      final out = <String, FeishuApproval>{};
      for (final entry in decoded.entries) {
        final value = entry.value;
        if (value is! Map<String, dynamic>) continue;
        final approval = FeishuApproval.fromJson(value);
        if (approval != null) {
          out[FeishuApproval.keyOf(approval.workspaceId, approval.pattern)] =
              approval;
        }
      }
      return out;
    } on FileSystemException {
      return {};
    } on FormatException {
      return {};
    }
  }

  Future<void> save(Map<String, FeishuApproval> approvals) async {
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({
        for (final entry in approvals.entries)
          entry.key: entry.value.toJson(),
      }));
    } on FileSystemException {
      // Ignored on purpose — see the class comment.
    }
  }
}
