// Regression test for the WSL "TUI served elsewhere" hang: when the
// local opencode server has no session for the directory, tuiTurn
// returns null — and, crucially, RETURNS. _EventFeed.close() used to
// await a controller close that never completes without a listener,
// parking tuiTurn's finally forever and wedging the serialized
// tui-chat queue (every later Feishu message waited out the 4-minute
// watchdog before being typed).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/feishu/opencode_client.dart';

/// The minimal opencode server surface tuiTurn touches: a healthy
/// /api/info, a session list with nothing in it (the TUI is served
/// elsewhere), and an /api/event SSE stream held open until the
/// client cancels.
Future<HttpServer> _fakeServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final res = req.response;
    try {
      switch (req.uri.path) {
        case '/api/info':
          res.statusCode = 200;
          res.write('{}');
          await res.close();
        case '/api/session':
          res.statusCode = 200;
          res.write('{"data":[]}');
          await res.close();
        case '/api/event':
          res.statusCode = 200;
          res.headers.set(HttpHeaders.contentTypeHeader, 'text/event-stream');
          res.add(utf8.encode(': heartbeat\n\n'));
          await res.flush();
          // Held open on purpose — the feed cancels from its side;
          // the aborted socket must not surface as a test error.
          unawaited(res.done.catchError((_) {}));
        default:
          res.statusCode = 404;
          await res.close();
      }
    } catch (_) {
      // The cancelled event stream errors out server-side.
    }
  }, onError: (_) {});
  return server;
}

void main() {
  test('tuiTurn returns when the server has no session for the '
      'directory (the TUI is served elsewhere)', () async {
    final server = await _fakeServer();
    addTearDown(() => server.close(force: true));

    final base = 'http://127.0.0.1:${server.port}';
    final auth = 'Basic ${base64Encode(utf8.encode('opencode:test'))}';
    final gateway = OpencodeLocalGateway.forServer(base, auth);
    addTearDown(gateway.dispose);

    final typed = <String>[];
    final result = await gateway
        .tuiTurn(r'C:\nowhere', 'hello there', typed.add)
        .timeout(const Duration(seconds: 20), onTimeout: () {
      fail('tuiTurn never returned — the event feed close hung again');
    });

    expect(result.sessionId, isNull);
    expect(result.reply, isNull);
    expect(typed, ['hello there']);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('the null-session bail is quick (rounds, not the full window)',
      () async {
    final server = await _fakeServer();
    addTearDown(() => server.close(force: true));

    final base = 'http://127.0.0.1:${server.port}';
    final auth = 'Basic ${base64Encode(utf8.encode('opencode:test'))}';
    final gateway = OpencodeLocalGateway.forServer(base, auth);
    addTearDown(gateway.dispose);

    final sw = Stopwatch()..start();
    await gateway.tuiTurn(r'C:\nowhere', 'hello', (_) {});
    // 6 poll rounds × 400ms + HTTP ≈ 3s; the full 15-round window
    // would be ~7s+.
    expect(sw.elapsed, lessThan(const Duration(seconds: 6)));
  }, timeout: const Timeout(Duration(seconds: 30)));
}
