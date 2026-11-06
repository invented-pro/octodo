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
// Bindings are session-scoped, in memory only: workspace ids
// (`ws-0`, …) are per-process, so a binding saved to disk could only
// ever point at a dead session.

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

  /// The pane inside that workspace this chat drives, when the
  /// binding is pane-level (the design's optional `pane_id`). Null =
  /// the workspace's focused pane.
  final String? paneId;

  /// The pane's number in the layout at binding time — for display
  /// only; the id is what counts.
  final int? paneNumber;

  /// The tab (surface) inside that pane this chat drives, when the
  /// binding is tab-level (`/attach <ws>.<pane>.<tab>`). Null = the
  /// pane's focused tab.
  final String? surfaceId;

  /// The tab's number within its pane at binding time — for display
  /// only; the id is what counts.
  final int? surfaceNumber;

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
    this.paneId,
    this.paneNumber,
    this.surfaceId,
    this.surfaceNumber,
  });

  Map<String, dynamic> toJson() => {
        'chatId': chatId,
        'chatType': chatType,
        'workspaceId': workspaceId,
        'workspaceName': workspaceName,
        'paneId': paneId,
        'paneNumber': paneNumber,
        'surfaceId': surfaceId,
        'surfaceNumber': surfaceNumber,
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
      paneId: json['paneId'] is String ? json['paneId'] as String : null,
      paneNumber: json['paneNumber'] is int ? json['paneNumber'] as int : null,
      surfaceId: json['surfaceId'] is String ? json['surfaceId'] as String : null,
      surfaceNumber:
          json['surfaceNumber'] is int ? json['surfaceNumber'] as int : null,
      boundAt: boundAt ?? DateTime.now(),
      boundBy: json['boundBy'] is String ? json['boundBy'] as String : '',
    );
  }
}

