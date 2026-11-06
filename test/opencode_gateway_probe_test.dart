// Manual end-to-end probe for OpencodeLocalGateway against a real
// local `opencode serve`. Skipped unless OC_PROBE=1 — it spawns a
// serve process and spends one tiny model call.
//
//   $env:OC_PROBE='1'; flutter test test/opencode_gateway_probe_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/feishu/opencode_client.dart';

void main() {
  test('gateway chats with a real local opencode server', () async {
    if (Platform.environment['OC_PROBE'] != '1') {
      markTestSkipped('set OC_PROBE=1 to run the live probe');
      return;
    }
    final gateway = OpencodeLocalGateway();
    // LIFO teardown: dispose first; the temp dir may stay locked
    // by the shared background service (we don't own it) — best
    // effort only.
    final dir = Directory.systemTemp.createTempSync('oc_gateway_probe');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    addTearDown(gateway.dispose);

    final ready = await gateway.ensure();
    expect(ready, isTrue, reason: 'a serve instance should come up');

    final reply = await gateway.chat(dir.path, 'Reply with exactly: gateway-ok');
    // ignore: avoid_print
    print('reply: $reply');
    expect(reply, isNotNull);
    expect(reply!, contains('gateway-ok'));

    // Second turn continues the same directory session.
    final reply2 =
        await gateway.chat(dir.path, 'What exact word did you reply last time? Answer with just that word.');
    // ignore: avoid_print
    print('reply2: $reply2');
    expect(reply2, contains('gateway-ok'));
  }, timeout: const Timeout(Duration(minutes: 4)));
}
