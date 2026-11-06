// Manual end-to-end probe for OpencodeLocalGateway against a real
// local `opencode serve`. Skipped unless OC_PROBE=1 — it spawns a
// serve process and spends one tiny model call.
//
//   $env:OC_PROBE='1'; flutter test test/opencode_gateway_probe_test.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/feishu/opencode_client.dart';

/// The shared background service (the one locally-running opencode
/// TUIs connect to) — its URL and password.
Future<({String base, String auth})> _service() async {
  final home = Platform.environment['USERPROFILE'] ??
      Platform.environment['HOME'] ??
      '';
  final file = File('$home${Platform.pathSeparator}.config'
      '${Platform.pathSeparator}opencode'
      '${Platform.pathSeparator}service.json');
  final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final password = json['password'] as String;
  final status = await Process.run('opencode', ['service', 'status'],
      runInShell: true);
  final match = RegExp(r'https?://\S+').firstMatch('${status.stdout}');
  final base = match!.group(0)!;
  final auth = 'Basic ${base64Encode(utf8.encode('opencode:$password'))}';
  return (base: base, auth: auth);
}

/// A session in [directory] on the real server.
Future<String> _createSession(
    String base, String auth, String directory) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(Uri.parse('$base/api/session'));
    req.headers.set(HttpHeaders.authorizationHeader, auth);
    req.headers.contentType = ContentType.json;
    req.add(utf8.encode(jsonEncode({
      'location': {'directory': directory}
    })));
    final res = await req.close();
    final body = jsonDecode(await res.transform(utf8.decoder).join())
        as Map<String, dynamic>;
    return (body['data'] as Map<String, dynamic>)['id'] as String;
  } finally {
    client.close();
  }
}

/// Submit [text] to [sessionId] — what a desktop TUI does when the
/// user hits Enter.
Future<void> _submit(
    String base, String auth, String sessionId, String text) async {
  final client = HttpClient();
  try {
    final req =
        await client.postUrl(Uri.parse('$base/api/session/$sessionId/prompt'));
    req.headers.set(HttpHeaders.authorizationHeader, auth);
    req.headers.contentType = ContentType.json;
    req.add(utf8.encode(jsonEncode({'text': text})));
    final res = await req.close();
    await res.drain<void>();
  } finally {
    client.close();
  }
}

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

  test('the TUI-driven turn finds the session the TUI used and '
      'collects its reply', () async {
    if (Platform.environment['OC_PROBE'] != '1') {
      markTestSkipped('set OC_PROBE=1 to run the live probe');
      return;
    }
    final gateway = OpencodeLocalGateway();
    final dir = Directory.systemTemp.createTempSync('oc_tui_probe');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    addTearDown(gateway.dispose);

    final service = await _service();
    // The "desktop TUI": a session of its own, into which it
    // submits what was typed into its composer.
    final sessionId =
        await _createSession(service.base, service.auth, dir.path);

    final result = await gateway.tuiTurn(
      dir.path,
      'Reply with exactly: tui-ok',
      (text) {
        // The TUI submits into ITS session — the gateway has to
        // discover that on its own.
        unawaited(_submit(service.base, service.auth, sessionId, text));
      },
    );

    // ignore: avoid_print
    print('tui session: ${result.sessionId}  reply: ${result.reply}');
    expect(result.sessionId, sessionId,
        reason: 'the session the TUI submitted into must be found');
    expect(result.reply, isNotNull);
    expect(result.reply!, contains('tui-ok'));
  }, timeout: const Timeout(Duration(minutes: 4)));
}
