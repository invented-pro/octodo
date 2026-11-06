// Unit tests for the per-chat binding store (design doc §3 — the
// conversation-level binding: a Feishu chat ↔ an Octodo workspace).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/feishu/feishu_binding.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('feishu_bind');
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  FeishuBindingStore store() => FeishuBindingStore(
      File('${dir.path}${Platform.pathSeparator}bindings.json'));

  test('a binding survives a round trip', () async {
    final binding = FeishuChatBinding(
      chatId: 'oc_chat',
      chatType: 'p2p',
      workspaceId: 'ws_2',
      workspaceName: 'docs',
      boundAt: DateTime.utc(2026, 11, 6, 12),
      boundBy: 'ou_owner',
    );
    await store().save({'oc_chat': binding});

    final loaded = await store().load();
    expect(loaded['oc_chat']!.workspaceId, 'ws_2');
    expect(loaded['oc_chat']!.workspaceName, 'docs');
    expect(loaded['oc_chat']!.chatType, 'p2p');
    expect(loaded['oc_chat']!.boundBy, 'ou_owner');
    expect(loaded['oc_chat']!.boundAt, DateTime.utc(2026, 11, 6, 12));
  });

  test('a missing file means no bindings', () async {
    expect(await store().load(), isEmpty);
  });

  test('a broken file means no bindings, not a crash', () async {
    final file = File('${dir.path}${Platform.pathSeparator}bindings.json');
    await file.writeAsString('{not json');
    expect(await store().load(), isEmpty);
  });

  test('entries without a chat or a workspace are dropped', () async {
    final file = File('${dir.path}${Platform.pathSeparator}bindings.json');
    await file.writeAsString(
        '{"a":{"chatId":"oc_a","workspaceId":"ws_1"},'
        '"b":{"chatId":"oc_b"},'
        '"c":{"workspaceId":"ws_1"}}');
    final loaded = await store().load();
    expect(loaded.keys, ['oc_a']);
  });
}
