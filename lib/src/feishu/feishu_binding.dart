// Per-chat bindings (design doc §3, phase 2): which Octodo workspace
// a Feishu chat drives.
//
// Two levels of binding exist:
//
//   * application level — one Octodo instance ↔ one Feishu app
//     (App ID / Secret). That one is the credential store's job.
//   * conversation level — one Feishu chat ↔ one Octodo workspace (or
//     pane). This file.
//
// The bindings live next to the credentials so a restart keeps them:
//
//   <userHome>/.config/Octodo/feishu/bindings.json
//
// The store is file-system only; the router above owns the policy
// (auto-binding, /attach, /detach).

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// One chat's binding.
class FeishuChatBinding {
  /// The Feishu conversation (`oc_…`).
  final String chatId;

  /// 'p2p' or 'group' — informational (the doc's two-level model).
  final String chatType;

  /// The Octodo workspace this chat drives.
  final String workspaceId;

  /// The workspace's name at binding time — for display only; the id
  /// is what counts.
  final String workspaceName;

  /// When the binding was made.
  final DateTime boundAt;

  /// The `open_id` of whoever made it.
  final String boundBy;

  const FeishuChatBinding({
    required this.chatId,
    required this.chatType,
    required this.workspaceId,
    required this.workspaceName,
    required this.boundAt,
    required this.boundBy,
  });

  Map<String, dynamic> toJson() => {
        'chatId': chatId,
        'chatType': chatType,
        'workspaceId': workspaceId,
        'workspaceName': workspaceName,
        'boundAt': boundAt.toIso8601String(),
        'boundBy': boundBy,
      };

  static FeishuChatBinding? fromJson(Map<String, dynamic> json) {
    final chatId = json['chatId'];
    final workspaceId = json['workspaceId'];
    if (chatId is! String || chatId.isEmpty) return null;
    if (workspaceId is! String || workspaceId.isEmpty) return null;
    final boundAt = DateTime.tryParse('${json['boundAt'] ?? ''}');
    return FeishuChatBinding(
      chatId: chatId,
      chatType: json['chatType'] is String ? json['chatType'] as String : 'p2p',
      workspaceId: workspaceId,
      workspaceName:
          json['workspaceName'] is String ? json['workspaceName'] as String : '',
      boundAt: boundAt ?? DateTime.now(),
      boundBy: json['boundBy'] is String ? json['boundBy'] as String : '',
    );
  }
}

/// Loads / saves the bindings file.
class FeishuBindingStore {
  final File file;

  FeishuBindingStore(this.file);

  factory FeishuBindingStore.resolve({String? userHome}) {
    final home = userHome ??
        Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '';
    return FeishuBindingStore(
      File(p.join(home, '.config', 'Octodo', 'feishu', 'bindings.json')),
    );
  }

  /// The bindings, keyed by chat id. A missing or broken file means
  /// "no bindings" — never an error the user has to see.
  Future<Map<String, FeishuChatBinding>> load() async {
    try {
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return {};
      final out = <String, FeishuChatBinding>{};
      for (final entry in decoded.entries) {
        final value = entry.value;
        if (value is! Map<String, dynamic>) continue;
        final binding = FeishuChatBinding.fromJson(value);
        // The binding's own chat id is authoritative — the map key
        // is only a container.
        if (binding != null) out[binding.chatId] = binding;
      }
      return out;
    } on FileSystemException {
      return {};
    } on FormatException {
      return {};
    }
  }

  /// Persist [bindings] (keyed by chat id). Failures are swallowed:
  /// a binding that cannot be written must not break the chat.
  Future<void> save(Map<String, FeishuChatBinding> bindings) async {
    try {
      await file.parent.create(recursive: true);
      final payload = <String, dynamic>{
        for (final entry in bindings.entries) entry.key: entry.value.toJson(),
      };
      await file.writeAsString(jsonEncode(payload));
    } on FileSystemException {
      // Ignored on purpose — see above.
    }
  }
}
