// Round-trip tests for the Feishu credential store: save → load,
// owner force-merged into the allowlist, idempotent delete, and
// graceful handling of missing / corrupt files.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/feishu/feishu_credentials.dart';

FeishuCredentialStore _tempStore() {
  final dir = Directory.systemTemp.createTempSync('feishu_creds_test');
  addTearDown(() => dir.deleteSync(recursive: true));
  return FeishuCredentialStore(
      File('${dir.path}${Platform.pathSeparator}credentials.json'));
}

void main() {
  test('save → load round-trips every field', () async {
    final store = _tempStore();
    final creds = FeishuCredentials(
      appId: 'cli_roundtrip',
      appSecret: 'secret-value',
      ownerOpenId: 'ou_owner',
      tenantBrand: 'feishu',
      boundAt: DateTime.utc(2026, 11, 5, 10),
      allowedOpenIds: const ['ou_owner', 'ou_friend'],
    );

    await store.save(creds);
    final loaded = await store.load();

    expect(loaded!.appId, 'cli_roundtrip');
    expect(loaded.appSecret, 'secret-value');
    expect(loaded.ownerOpenId, 'ou_owner');
    expect(loaded.tenantBrand, 'feishu');
    expect(loaded.isLark, isFalse);
    expect(loaded.boundAt, DateTime.utc(2026, 11, 5, 10));
    expect(loaded.allowedOpenIds, ['ou_owner', 'ou_friend']);
  });

  test('save force-merges the owner into the allowlist, deduped, first',
      () async {
    final store = _tempStore();
    await store.save(FeishuCredentials(
      appId: 'cli_dedupe',
      appSecret: 's',
      ownerOpenId: 'ou_owner',
      tenantBrand: 'lark',
      boundAt: DateTime.utc(2026, 1, 1),
      allowedOpenIds: const ['ou_friend', 'ou_owner', 'ou_friend'],
    ));

    final loaded = await store.load();

    expect(loaded!.allowedOpenIds, ['ou_owner', 'ou_friend']);
    expect(loaded.isLark, isTrue);
  });

  test('load returns null when the file does not exist', () async {
    final store = _tempStore();
    expect(await store.load(), isNull);
  });

  test('load returns null for corrupt JSON', () async {
    final store = _tempStore();
    await store.file.parent.create(recursive: true);
    await store.file.writeAsString('{ not json');
    expect(await store.load(), isNull);
  });

  test('load returns null when required fields are missing', () async {
    final store = _tempStore();
    await store.file.parent.create(recursive: true);
    await store.file.writeAsString(jsonEncode({'appId': 'cli_x'}));
    expect(await store.load(), isNull);
  });

  test('delete removes the file and is idempotent', () async {
    final store = _tempStore();
    await store.save(FeishuCredentials(
      appId: 'cli_gone',
      appSecret: 's',
      ownerOpenId: 'ou_o',
      tenantBrand: 'feishu',
      boundAt: DateTime.utc(2026, 1, 1),
    ));
    expect(await store.file.exists(), isTrue);

    await store.delete();
    await store.delete(); // second call must not throw

    expect(await store.file.exists(), isFalse);
    expect(await store.load(), isNull);
  });

  test('appIdPreview keeps the prefix and a short suffix only', () {
    final creds = FeishuCredentials(
      appId: 'cli_abcdef123456789',
      appSecret: 's',
      ownerOpenId: 'ou_o',
      tenantBrand: 'feishu',
      boundAt: DateTime.utc(2026, 1, 1),
    );
    final preview = creds.appIdPreview;
    expect(preview, startsWith('cli_'));
    expect(preview, isNot(contains('abcdef123456789')));
    expect(preview.endsWith('789'), isTrue);
  });
}
