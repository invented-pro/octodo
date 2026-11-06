// Chats already greeted (the `/help` card sent on a chat's first
// message — see `FeishuIntegration`'s greeting hook). Persisted so a
// restart doesn't re-introduce the bot to chats that have long been
// using it:
//
//   <userHome>/.config/Octodo/feishu/greeted.json
//
// The store is file-system only; the router owns the policy (greet
// whitelisted senders only, once per chat, ever).

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Loads / saves the greeted-chats file. Same contract as the
/// binding and approval stores: a missing or broken file means "no
/// chats greeted", and a failed write is swallowed — persistence
/// must never break the chat.
class FeishuGreetingStore {
  final File file;

  FeishuGreetingStore(this.file);

  factory FeishuGreetingStore.resolve({String? userHome}) {
    final home = userHome ??
        Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '';
    return FeishuGreetingStore(
      File(p.join(home, '.config', 'Octodo', 'feishu', 'greeted.json')),
    );
  }

  Future<Set<String>> load() async {
    try {
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! List) return {};
      return {
        for (final entry in decoded)
          if (entry is String && entry.isNotEmpty) entry,
      };
    } on FileSystemException {
      return {};
    } on FormatException {
      return {};
    }
  }

  Future<void> save(Set<String> chatIds) async {
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(chatIds.toList()..sort()));
    } on FileSystemException {
      // Ignored on purpose — see the class comment.
    }
  }
}
