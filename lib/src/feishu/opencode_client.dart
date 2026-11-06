// The opencode gateway — the client-server path of the Feishu
// remote control (design doc §6, "path 1"): instead of relaying
// bytes through the desktop TUI, the router talks to a local
// `opencode serve` HTTP/SSE server as a peer client. Sessions are
// shared with every other opencode client through the common
// opencode database, and replies are assembled from the server's
// `session.text.*` SSE events — pure response text. Thinking and
// tool activity are separate event types (`session.reasoning.*`,
// tool lifecycle) that are simply never collected.
//
// Wire facts below were verified live against opencode 2.2.5
// (tool/probe history in the branch log):
//
//   auth    Authorization: Basic base64("opencode:" + password)
//   info    GET  /api/info
//   list    GET  /api/session                       → {data, cursor}
//   create  POST /api/session  {"location":{"directory":…}} → {data:{id}}
//   send    POST /api/session/:id/prompt  {"text": …}
//   stream  GET  /api/event   (SSE: `data:` JSON frames, `: heartbeat`)
//   done    session.execution.succeeded / .failed / .aborted
//
// The manager owns a serve process: `opencode serve` prints its
// URL and a one-time password on stdout; both are parsed and kept
// in memory only (never persisted, never logged).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../log.dart';

/// What the Feishu router needs from the opencode integration —
/// an interface so routing tests run without a server.
abstract class OpencodeGateway {
  /// True when a server is reachable, starting one first when
  /// this gateway owns that. Stays cheap once healthy.
  Future<bool> ensure();

  /// Send [message] as one turn of the latest session rooted at
  /// [directory] (created when none exists) and complete with the
  /// assistant's response text — text parts only, no layout, no
  /// reasoning, no tool chatter. Null when anything failed.
  Future<String?> chat(String directory, String message);

  /// The last turns of the latest session rooted at [directory]
  /// as clean text ("🧑 …" / "🤖 …"), or null when there is no
  /// session or no server. Find-only — never creates a session.
  Future<String?> conversationTail(String directory, {int limit});
}

/// Gateway over a locally-managed `opencode serve` process.
class OpencodeLocalGateway implements OpencodeGateway {
  OpencodeLocalGateway({Duration? startupTimeout})
      : _startupTimeout = startupTimeout ?? const Duration(seconds: 45);

  final Logger _log = moduleLogger('feishu.opencode');
  final Duration _startupTimeout;

  /// First port tried for our serve instance; increments on
  /// conflict. The user's own serve (e.g. on 4096) is left alone —
  /// every opencode server shares the same session database.
  static const int _kBasePort = 4096;

  Process? _serve;
  String? _baseUrl;
  String? _authHeader; // "Basic …" — password stays in memory only
  bool _starting = false;

  /// Whether WE spawned the server (vs attaching to the user's
  /// background service, which must never be killed by us).
  bool _ownsServe = false;
  final List<StreamSubscription<String>> _serveLogs = [];

  @override
  Future<bool> ensure() async {
    if (await _healthy()) return true;
    // 1. Attach to the shared background service — the server
    //    every locally-running opencode TUI connects to. Chatting
    //    through IT is what keeps the desktop TUI in sync live.
    if (await _tryAttachBackgroundService()) return true;
    if (_starting) return false;
    _starting = true;
    try {
      // 2. No service yet: start one (a locally-launched TUI will
      //    join the same server) and attach to it.
      await _runCli(['service', 'start']);
      for (var i = 0; i < 8; i++) {
        if (await _tryAttachBackgroundService()) return true;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      // 3. Last resort: our own serve instance (sessions still
      //    share through the common database).
      await _killServe();
      for (var port = _kBasePort; port < _kBasePort + 6; port++) {
        final ok = await _tryStart(port);
        if (ok) {
          _log.info('opencode: serve on port $port');
          return true;
        }
      }
      _log.warning('opencode: could not start a serve instance');
      return false;
    } finally {
      _starting = false;
    }
  }

  /// Run the opencode CLI (npm .cmd shim → runInShell).
  Future<ProcessResult?> _runCli(List<String> args) async {
    try {
      return await Process.run('opencode', args, runInShell: true)
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      return null;
    }
  }

  /// Attach to the background service when one is reachable:
  /// URL from `opencode service status`, password from the user's
  /// opencode config (`~/.config/opencode/service.json`), auth
  /// Basic("opencode:" + password) — verified against 2.2.5.
  Future<bool> _tryAttachBackgroundService() async {
    try {
      final password = _servicePassword();
      if (password == null) return false;
      final status = await _runCli(['service', 'status']);
      final out = status == null ? '' : '${status.stdout}';
      final m = RegExp(r'https?://\S+').firstMatch(out);
      if (m == null) return false;
      final url = m.group(0)!;
      final auth =
          'Basic ${base64Encode(utf8.encode('opencode:$password'))}';
      if (!await _probe('$url/api/info', auth)) return false;
      _baseUrl = url;
      _authHeader = auth;
      _ownsServe = false;
      _log.info('opencode: attached to the background service');
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The background service's password from the opencode config
  /// (checked against the standard XDG and Windows layouts).
  static String? _servicePassword() {
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'];
    if (home == null) return null;
    final xdg = Platform.environment['XDG_CONFIG_HOME'];
    final candidates = [
      if (xdg != null) '$xdg${Platform.pathSeparator}opencode',
      '$home${Platform.pathSeparator}.config${Platform.pathSeparator}opencode',
    ];
    for (final dir in candidates) {
      try {
        final f = File(
            '$dir${Platform.pathSeparator}service.json');
        if (!f.existsSync()) continue;
        final j = jsonDecode(f.readAsStringSync());
        if (j is Map<String, dynamic>) {
          final pw = j['password'];
          if (pw is String && pw.isNotEmpty) return pw;
        }
      } catch (_) {}
    }
    return null;
  }

  Future<bool> _healthy() async {
    final url = _baseUrl;
    final auth = _authHeader;
    if (url == null || auth == null) return false;
    return _probe('$url/api/info', auth);
  }

  /// GET [url] with [auth]; true when 200. Drains and closes so
  /// no connection leaks.
  Future<bool> _probe(String url, String auth) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.authorizationHeader, auth);
      final res = await req.close().timeout(const Duration(seconds: 4));
      await res.drain<void>().catchError((_) {});
      return res.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  /// Spawn `opencode serve --port [port]` and adopt it when it
  /// prints its listening URL and password. False when the port
  /// is taken or the toolchain is missing.
  Future<bool> _tryStart(int port) async {
    Process proc;
    try {
      // `opencode` is an npm .cmd shim on Windows — resolve through
      // cmd.exe. stdout carries the URL + password lines we parse.
      proc = await Process.start('cmd.exe', [
        '/c',
        'opencode',
        'serve',
        '--port',
        '$port',
      ]);
    } catch (e) {
      _log.warning('opencode: spawn failed ($e)');
      return false;
    }
    final urlCompleter = Completer<String?>();
    final pwCompleter = Completer<String?>();
    var urlSeen = false;
    var pwSeen = false;
    final lines = <String>[];
    // Bounded ring of stdout for failure diagnostics (no secrets —
    // the password line is masked).
    void consume(String line, {required bool mask}) {
      lines.add(mask ? '<password line>' : line);
      if (line.contains('listening on') && !urlSeen) {
        urlSeen = true;
        final m = RegExp(r'https?://\S+').firstMatch(line);
        if (!urlCompleter.isCompleted) {
          urlCompleter.complete(m?.group(0));
        }
      }
      if (line.contains('server password') && !pwSeen) {
        pwSeen = true;
        final m = RegExp(r'server password\s+(\S+)').firstMatch(line);
        if (!pwCompleter.isCompleted) {
          pwCompleter.complete(m?.group(1));
        }
      }
    }

    final subs = <StreamSubscription<String>>[
      proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((l) => consume(l, mask: false), onError: (_) {}),
      proc.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((l) => consume(l, mask: false), onError: (_) {}),
    ];
    _serveLogs
      ..clear()
      ..addAll(subs);
    proc.exitCode.whenComplete(() {
      if (!urlCompleter.isCompleted) urlCompleter.complete(null);
      if (!pwCompleter.isCompleted) pwCompleter.complete(null);
      if (_baseUrl == null || _serve == proc) {
        _baseUrl = null;
        _authHeader = null;
      }
    });

    final results = <String?>[];
    try {
      final pair = await Future.wait<Object?>([
        urlCompleter.future,
        pwCompleter.future,
      ]).timeout(_startupTimeout);
      results.addAll(pair.cast<String?>());
    } on TimeoutException {
      // Serve never announced itself — give up on this port.
    }
    final url = results.isNotEmpty ? results[0] : null;
    final password = results.length > 1 ? results[1] : null;
    if (url == null || password == null) {
      await _kill(proc);
      if (lines.isNotEmpty) {
        _log.info('opencode: serve output: ${lines.take(6).join(' | ')}');
      }
      return false;
    }
    _serve = proc;
    _baseUrl = url;
    _authHeader =
        'Basic ${base64Encode(utf8.encode('opencode:$password'))}';
    _ownsServe = true;
    // Give the listener a beat; then confirm with /api/info.
    for (var i = 0; i < 20; i++) {
      if (await _healthy()) return true;
      // Bail out early when the process already exited (-999 = the
      // probe timed out, i.e. still running).
      final exited = await proc.exitCode
          .timeout(const Duration(milliseconds: 1), onTimeout: () => -999);
      if (exited != -999) break;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    final healthy = await _healthy();
    if (!healthy) await _killServe();
    return healthy;
  }

  Future<void> _kill(Process? proc) async {
    if (proc == null) return;
    if (Platform.isWindows) {
      // We spawn through cmd.exe (`opencode` is an npm .cmd shim),
      // and killing the wrapper does NOT cascade to the serve
      // child on Windows — kill the whole tree explicitly.
      try {
        await Process.run('taskkill', ['/PID', '${proc.pid}', '/T', '/F']);
      } catch (_) {}
    } else {
      proc.kill();
    }
    await proc.exitCode.catchError((_) => -1);
  }

  Future<void> _killServe() async {
    if (!_ownsServe) {
      // Attached to the user's background service — leave it be.
      _baseUrl = null;
      _authHeader = null;
      return;
    }
    final proc = _serve;
    _serve = null;
    _baseUrl = null;
    _authHeader = null;
    for (final s in _serveLogs) {
      await s.cancel();
    }
    _serveLogs.clear();
    await _kill(proc);
  }

  /// Stop a server we own (app shutdown). The user's background
  /// service outlives us.
  Future<void> dispose() => _killServe();

  // ── HTTP ──────────────────────────────────────────────────────

  Future<Map<String, dynamic>?> _json(
      String method, String url, String auth, String? body) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.openUrl(method, Uri.parse(url));
      req.headers.set(HttpHeaders.authorizationHeader, auth);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.add(utf8.encode(body));
      }
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode ~/ 100 != 2) {
        _log.warning('opencode: $method $url -> ${res.statusCode}');
        return null;
      }
      if (text.isEmpty) return <String, dynamic>{};
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (e) {
      _log.warning('opencode: $method $url failed ($e)');
      return null;
    } finally {
      client.close();
    }
  }

  // ── Chat ──────────────────────────────────────────────────────

  @override
  Future<String?> chat(String directory, String message) async {
    if (!await ensure()) return null;
    final base = _baseUrl!;
    final auth = _authHeader!;
    final sessionId = await _findOrCreateSession(base, auth, directory);
    if (sessionId == null) {
      _log.warning('opencode: no session for $directory');
      return null;
    }

    final texts = <String>[];
    var done = Completer<void>();
    final t0 = DateTime.now().millisecondsSinceEpoch - 3000;

    // Subscribe BEFORE sending so no completion event is missed.
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    StreamSubscription<String>? sseSub;
    try {
      final req = await client.getUrl(Uri.parse('$base/api/event'));
      req.headers.set(HttpHeaders.authorizationHeader, auth);
      req.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
      final res = await req.close();
      if (res.statusCode != 200) {
        _log.warning('opencode: /api/event -> ${res.statusCode}');
        return null;
      }
      var dataLine = <String>[];
      sseSub = res.transform(utf8.decoder).transform(const LineSplitter()).listen(
        (line) {
          if (line.isEmpty) {
            final payload = dataLine.join('\n');
            dataLine = [];
            if (!payload.startsWith('{')) return;
            final ev = jsonDecode(payload);
            if (ev is! Map<String, dynamic>) return;
            _onEvent(ev, sessionId, t0, texts, done);
          } else if (line.startsWith('data:')) {
            dataLine.add(line.substring(5).trimLeft());
          }
        },
        onError: (Object e) {
          if (!done.isCompleted) done.complete();
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
      );

      final sent = await _json('POST', '$base/api/session/$sessionId/prompt',
          auth, jsonEncode({'text': message}));
      if (sent == null) return null;

      await done.future.timeout(const Duration(minutes: 5), onTimeout: () {
        _log.warning('opencode: chat timed out (session $sessionId)');
      });
      return texts.isEmpty ? null : texts.join('\n\n');
    } catch (e) {
      _log.warning('opencode: chat failed ($e)');
      return texts.isEmpty ? null : texts.join('\n\n');
    } finally {
      await sseSub?.cancel();
      client.close();
    }
  }

  /// Route one SSE event: collect the response text for our
  /// session, finish on the execution terminators.
  void _onEvent(Map<String, dynamic> ev, String sessionId, int t0,
      List<String> texts, Completer<void> done) {
    final type = ev['type'];
    if (type is! String) return;
    final created = ev['created'];
    if (created is int && created < t0) return; // pre-send history
    final data = ev['data'];
    if (data is! Map<String, dynamic>) return;
    if (data['sessionID'] != sessionId) return;
    switch (type) {
      case 'session.text.ended':
        final text = data['text'];
        if (text is String && text.trim().isNotEmpty) texts.add(text.trim());
      case 'session.execution.succeeded':
      case 'session.execution.failed':
      case 'session.execution.aborted':
        if (!done.isCompleted) done.complete();
    }  }

  Future<String?> _findOrCreateSession(
      String base, String auth, String directory) async {
    final existing = await _findSession(base, auth, directory);
    if (existing != null) return existing;
    final created = await _json('POST', '$base/api/session', auth,
        jsonEncode({'location': {'directory': directory}}));
    final d = created?['data'];
    if (d is Map<String, dynamic>) return d['id'] as String?;
    return null;
  }

  /// Latest session for [directory], or null — never creates one.
  Future<String?> _findSession(String base, String auth, String directory) async {
    final list = await _json('GET', '$base/api/session', auth, null);
    final data = list?['data'];
    if (data is! List) return null;
    Map<String, dynamic>? best;
    var bestUpdated = -1;
    for (final raw in data) {
      if (raw is! Map<String, dynamic>) continue;
      final loc = raw['location'];
      if (loc is! Map<String, dynamic>) continue;
      final dir = loc['directory'];
      if (dir is! String || !_sameDir(dir, directory)) continue;
      final time = raw['time'];
      final updated =
          time is Map<String, dynamic> ? (time['updated'] as int? ?? -1) : -1;
      if (updated >= bestUpdated) {
        bestUpdated = updated;
        best = raw;
      }
    }
    return best?['id'] as String?;
  }

  // ── Conversation tail (/screen) ───────────────────────────────

  @override
  Future<String?> conversationTail(String directory, {int limit = 6}) async {
    if (!await ensure()) return null;
    final base = _baseUrl!;
    final auth = _authHeader!;
    final sessionId = await _findSession(base, auth, directory);
    if (sessionId == null) return null;
    final res = await _json(
        'GET', '$base/api/session/$sessionId/message', auth, null);
    final data = res?['data'];
    if (data is! List) return null;
    // Newest-first: walk back over messages, keep user/assistant
    // text turns, then present oldest → newest.
    final blocks = <String>[];
    for (final raw in data) {
      if (raw is! Map<String, dynamic>) continue;
      if (blocks.length >= limit) break;
      final type = raw['type'];
      if (type == 'user') {
        final text = raw['text'];
        if (text is String && text.trim().isNotEmpty) {
          blocks.add('🧑 ${text.trim()}');
        }
      } else if (type == 'assistant') {
        final content = raw['content'];
        if (content is! List) continue;
        final texts = content
            .whereType<Map<String, dynamic>>()
            .where((p) => p['type'] == 'text')
            .map((p) => (p['text'] as String?) ?? '')
            .where((t) => t.trim().isNotEmpty)
            .join('\n');
        if (texts.isNotEmpty) blocks.add('🤖 $texts');
      }
    }
    if (blocks.isEmpty) return null;
    return blocks.reversed.join('\n\n');
  }

  /// Windows paths arrive in both separator styles from different
  /// shells; compare case-insensitively on the common form.
  static bool _sameDir(String a, String b) {
    String norm(String s) => s.replaceAll('/', '\\').toLowerCase();
    return norm(a) == norm(b);
  }
}
