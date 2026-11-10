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

import 'package:meta/meta.dart';

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

  /// One turn driven through the desktop TUI itself.
  ///
  /// [type] writes the message into the TUI (the router owns the
  /// terminal); the TUI then submits it to whatever session it is
  /// displaying — creating a fresh one when its composer is empty.
  /// A TUI creates that session lazily (on its first local
  /// message), so the server cannot know about it beforehand, and
  /// guessing server-side is what made Feishu messages land in a
  /// stale conversation. Typing is deterministic by construction.
  ///
  /// Returns the session the TUI used and the assistant's reply
  /// text (collected from the server's event stream). A null
  /// session means the TUI never submitted (a modal had the
  /// keyboard).
  Future<({String? sessionId, String? reply})> tuiTurn(
      String directory, String message, void Function(String) type);
}

/// Gateway over a locally-managed `opencode serve` process.
class OpencodeLocalGateway implements OpencodeGateway {
  OpencodeLocalGateway({Duration? startupTimeout})
      : _startupTimeout = startupTimeout ?? const Duration(seconds: 45);

  /// A gateway pointed at a server we did not discover ourselves —
  /// tests drive a fake one. [baseUrl]/[authHeader] must already be
  /// healthy (`GET /api/info` → 200); `ensure()` then never falls
  /// back to spawning or attaching anything.
  @visibleForTesting
  OpencodeLocalGateway.forServer(String baseUrl, String authHeader)
      : _baseUrl = baseUrl,
        _authHeader = authHeader,
        _startupTimeout = const Duration(seconds: 45);

  /// A gateway for the opencode server inside a WSL [distro]. The
  /// TUI running in that distro shares the distro-side server's
  /// session database, so THAT server — not the Windows one — sees
  /// its turns. Everything resolves through `wsl.exe` (service
  /// status for the URL, the distro's own
  /// `~/.config/opencode/service.json` for the password), and the
  /// server is reached from Windows through WSL's localhost
  /// forwarding. [runWsl] lets tests fake the `wsl.exe` calls.
  OpencodeLocalGateway.forWsl(String distro,
      {Duration? startupTimeout,
      Future<ProcessResult?> Function(List<String> args)? runWsl})
      : _startupTimeout = startupTimeout ?? const Duration(seconds: 45) {
    _wslDistro = distro;
    _runWsl = runWsl;
  }

  final Logger _log = moduleLogger('feishu.opencode');
  final Duration _startupTimeout;

  /// WSL distro this gateway resolves inside, null for the local
  /// Windows machine. See [OpencodeLocalGateway.forWsl].
  String? _wslDistro;

  /// Injectable `wsl.exe` runner for tests; null = run the real
  /// `wsl.exe -d <distro> -- <args>`.
  Future<ProcessResult?> Function(List<String> args)? _runWsl;

  /// Slack between our clock and the server's when comparing event
  /// stamps — the window that decides which events belong to the
  /// current turn.
  static const int _kClockSkew = 250;

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

  /// Tail of the one-at-a-time chat chain — see [chat].
  Future<void> _chatQueue = Future<void>.value();

  /// The session the desktop TUI last used for a directory (the one
  /// our own typed message was submitted into), keyed by the
  /// normalized directory. A TUI creates its session lazily, so the
  /// session it just used may not carry a `viewed` stamp yet — this
  /// remembers it for /history and the next turn.
  final Map<String, String> _tuiSessions = {};

  @override
  Future<bool> ensure() async {
    if (await _healthy()) return true;
    // 1. Attach to the shared background service — the server
    //    every locally-running opencode TUI connects to. Chatting
    //    through IT is what keeps the desktop TUI in sync live.
    //    Inside WSL the same flow resolves through wsl.exe.
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
      if (_wslDistro != null) {
        // No own-serve fallback inside a distro: spawning Windows
        // processes there is not ours to do, and the caller falls
        // back to the TUI screen-capture path instead.
        _log.warning('opencode: no server in WSL $_wslDistro');
        return false;
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

  /// Run the opencode CLI (npm .cmd shim → runInShell). Inside a
  /// WSL distro the call routes through `wsl.exe -d <distro> --`.
  Future<ProcessResult?> _runCli(List<String> args) async {
    if (_wslDistro != null) return await _wslRun(['opencode', ...args]);
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
  /// Basic("opencode:" + password) — verified against 2.2.5. Inside
  /// a WSL distro both resolve through `wsl.exe` (the distro's own
  /// files and service, reached from Windows via localhost
  /// forwarding).
  Future<bool> _tryAttachBackgroundService() async {
    try {
      final password = await _servicePassword();
      if (password == null) return false;
      final status = await _runCli(['service', 'status']);
      final out = status == null ? '' : '${status.stdout}';
      final url = parseServiceUrl(out);
      if (url == null) return false;
      final auth =
          'Basic ${base64Encode(utf8.encode('opencode:$password'))}';
      if (!await _probe('$url/api/info', auth)) return false;
      _baseUrl = url;
      _authHeader = auth;
      _ownsServe = false;
      _log.info(_wslDistro == null
          ? 'opencode: attached to the background service'
          : 'opencode: attached to the service in WSL $_wslDistro');
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The first `http(s)://…` URL in a `service status` output, with
  /// wildcard bind hosts (`[::]`, `0.0.0.0`) normalized to
  /// localhost — the address a Windows client reaches a WSL-side
  /// listener through. Public for tests.
  static String? parseServiceUrl(String output) {
    final m = RegExp(r'https?://\S+').firstMatch(output);
    if (m == null) return null;
    return m
        .group(0)!
        .replaceFirst(RegExp(r'//(\[::\]|0\.0\.0\.0)(?=:)'), '//127.0.0.1');
  }

  /// The password field of a `service.json` payload. Public for
  /// tests.
  static String? parseServicePassword(String output) {
    try {
      final j = jsonDecode(output);
      if (j is Map<String, dynamic>) {
        final pw = j['password'];
        if (pw is String && pw.isNotEmpty) return pw;
      }
    } catch (_) {}
    return null;
  }

  /// The background service's password from the opencode config
  /// (checked against the standard XDG and Windows layouts); inside
  /// a WSL distro, from the distro's own home via `wsl.exe`.
  Future<String?> _servicePassword() async {
    if (_wslDistro != null) {
      final res = await _wslRun(
          ['cat', r'$HOME/.config/opencode/service.json']);
      final out = res == null ? '' : '${res.stdout}';
      return parseServicePassword(out);
    }
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
        final pw = parseServicePassword(f.readAsStringSync());
        if (pw != null) return pw;
      } catch (_) {}
    }
    return null;
  }

  /// Run a command inside the gateway's WSL distro (no opencode
  /// prefix); the injectable runner stands in for `wsl.exe` in
  /// tests.
  Future<ProcessResult?> _wslRun(List<String> argv) async {
    final runWsl = _runWsl;
    if (runWsl != null) return await runWsl(argv);
    try {
      return await Process.run('wsl.exe', ['-d', _wslDistro!, '--', ...argv])
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      return null;
    }
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

  /// One turn of the conversation, serialized: chats run strictly
  /// one at a time in arrival order. Two parallel prompts into
  /// one session would race — each SSE subscription collects any
  /// `session.text.ended` in that session, so interleaved turns
  /// return swapped or duplicated replies.
  @override
  Future<String?> chat(String directory, String message) {
    final task = _chatQueue
        .then((_) => _chatNow(directory, message))
        .catchError((_) => null);
    _chatQueue = task.then<void>((_) {}, onError: (_) {});
    return task;
  }

  Future<String?> _chatNow(String directory, String message) async {
    if (!await ensure()) return null;
    final base = _baseUrl!;
    final auth = _authHeader!;
    final sessionId = await _findOrCreateSession(base, auth, directory);
    if (sessionId == null) {
      _log.warning('opencode: no session for $directory');
      return null;
    }
    final feed = await _openFeed(base, auth);
    try {
      // The turn starts here: everything the server emits from now
      // on is ours. Captured before the prompt is sent — the reply
      // can start streaming within milliseconds of it.
      final t0 = DateTime.now().millisecondsSinceEpoch - _kClockSkew;
      final sent = await _json('POST', '$base/api/session/$sessionId/prompt',
          auth, jsonEncode({'text': message}));
      if (sent == null) return null;
      return await _collectReply(sessionId, feed, t0);
    } finally {
      await feed.close();
    }
  }

  // ── TUI-driven turn ───────────────────────────────────────────

  @override
  Future<({String? sessionId, String? reply})> tuiTurn(
      String directory, String message, void Function(String) type) async {
    if (!await ensure()) return (sessionId: null, reply: null);
    final base = _baseUrl!;
    final auth = _authHeader!;
    // Subscribe BEFORE typing: the reply can start streaming
    // within milliseconds of the submit.
    final feed = await _openFeed(base, auth);
    try {
      // The turn starts here — and the window has to be captured
      // BEFORE typing: the model can answer within milliseconds of
      // the submit, while the session lookup below polls for a few
      // seconds. Measuring the window when the collector attaches
      // dropped the reply's first chunks.
      final now = DateTime.now().millisecondsSinceEpoch;
      final t0 = now - _kClockSkew;
      final afterMs = now;
      type(message);
      final sessionId =
          await _awaitTuiSession(base, auth, directory, afterMs);
      if (sessionId == null) {
        _log.info('opencode: the TUI did not submit the message');
        return (sessionId: null, reply: null);
      }
      _tuiSessions[_dirKey(directory)] = sessionId;
      _log.info('opencode: TUI turn in session $sessionId');
      final reply = await _collectReply(sessionId, feed, t0);
      return (sessionId: sessionId, reply: reply);
    } finally {
      await feed.close();
    }
  }

  /// The session the TUI just submitted into: the one holding a
  /// user message created after [afterMs]. Null when nothing was
  /// submitted within the window — a modal (session picker, help
  /// overlay) had the keyboard and swallowed the text.
  Future<String?> _awaitTuiSession(
      String base, String auth, String directory, int afterMs) async {
    var sawCandidate = false;
    for (var round = 0; round < 15; round++) {
      final list = await _json('GET', '$base/api/session', auth, null);
      final data = list?['data'];
      if (data is List) {
        // Only sessions touched after our typing can hold the
        // message — the rest are pruned before any request.
        final candidates = _sessionsOf(data, directory);
        if (candidates.isNotEmpty) sawCandidate = true;
        for (final raw in candidates) {
          if (_stamp(raw) < afterMs) continue;
          final id = raw['id'];
          if (id is! String) continue;
          if (await _hasFreshUserMessage(base, auth, id, afterMs)) {
            return id;
          }
        }
      }
      // No session for this directory at all, several rounds in:
      // the TUI talks to another opencode server (a WSL one, or a
      // remote host's at any SSH hop) and polling the rest of the
      // window is a silent toll on every message. The caller falls
      // back to reading the reply off the TUI itself.
      if (round >= 5 && !sawCandidate) {
        _log.info('opencode: the local server has no session for this '
            'directory — the TUI is likely served elsewhere');
        return null;
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    return null;
  }

  /// The sessions rooted at [directory], freshest first.
  static List<Map<String, dynamic>> _sessionsOf(
      List<dynamic> data, String directory) {
    final out = <Map<String, dynamic>>[];
    for (final raw in data) {
      if (raw is! Map<String, dynamic>) continue;
      final loc = raw['location'];
      if (loc is! Map<String, dynamic>) continue;
      final dir = loc['directory'];
      if (dir is! String || !_sameDir(dir, directory)) continue;
      out.add(raw);
    }
    out.sort((a, b) => _stamp(b).compareTo(_stamp(a)));
    return out;
  }

  /// The newest activity stamp of a session (viewed / updated /
  /// created) — when the session was last touched.
  static int _stamp(Map<String, dynamic> raw) {
    final time = raw['time'];
    if (time is! Map<String, dynamic>) return -1;
    var stamp = -1;
    for (final key in const ['viewed', 'updated', 'created']) {
      final value = time[key] as int? ?? -1;
      if (value > stamp) stamp = value;
    }
    return stamp;
  }

  /// True when [sessionId] holds a user message created after
  /// [afterMs] — i.e. the TUI submitted our text there.
  Future<bool> _hasFreshUserMessage(
      String base, String auth, String sessionId, int afterMs) async {
    final res = await _json(
        'GET', '$base/api/session/$sessionId/message', auth, null);
    final data = res?['data'];
    if (data is! List) return false;
    for (final raw in data) {
      if (raw is! Map<String, dynamic>) continue;
      if (raw['type'] != 'user') continue;
      final time = raw['time'];
      if (time is! Map<String, dynamic>) continue;
      if ((time['created'] as int? ?? -1) >= afterMs) return true;
    }
    return false;
  }

  Future<_EventFeed> _openFeed(String base, String auth) async {
    final feed = _EventFeed(base, auth);
    await feed.open();
    return feed;
  }

  /// Collect the assistant's reply text of the turn running in
  /// [sessionId] — the feed's frames (buffered ones included),
  /// filtered to that session, until the execution terminates.
  /// [t0] is the turn's start stamp: frames created before it belong
  /// to an earlier turn and are ignored.
  /// When the execution failed (provider error, rate limit, …) the
  /// error message is returned instead: a silent "no reply" would
  /// be a dead end for the user.
  Future<String?> _collectReply(
      String sessionId, _EventFeed feed, int t0) async {
    final texts = <String>[];
    final errors = <String>[];
    final done = Completer<void>();
    final sub = feed.events.listen(
      (ev) => routeEvent(ev, sessionId, t0, texts, errors, done),
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
    );
    try {
      await done.future.timeout(const Duration(minutes: 5), onTimeout: () {
        _log.warning('opencode: reply timed out (session $sessionId)');
      });
      if (texts.isNotEmpty) return texts.join('\n\n');
      if (errors.isNotEmpty) return '⚠️ ${errors.join('\n')}';
      return null;
    } finally {
      await sub.cancel();
    }
  }

  /// The reply of a turn, computed from raw event frames — the
  /// collector's logic without the stream. Public for tests.
  static String? replyOf(
      List<Map<String, dynamic>> events, String sessionId, int t0) {
    final texts = <String>[];
    final errors = <String>[];
    final done = Completer<void>();
    for (final ev in events) {
      routeEvent(ev, sessionId, t0, texts, errors, done);
    }
    if (texts.isNotEmpty) return texts.join('\n\n');
    if (errors.isNotEmpty) return '⚠️ ${errors.join('\n')}';
    return null;
  }

  /// Route one SSE event: collect the response text for our
  /// session, finish on the execution terminators.
  static void routeEvent(Map<String, dynamic> ev, String sessionId, int t0,
      List<String> texts, List<String> errors, Completer<void> done) {
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
        if (type != 'session.execution.succeeded') {
          final error = data['error'];
          if (error is Map<String, dynamic>) {
            final message = (error['message'] ?? error['type'] ?? '').toString();
            if (message.isNotEmpty) errors.add(message);
          }
        }
        if (!done.isCompleted) done.complete();
    }
  }

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
    final picked = pickSessionId(data, directory);
    // The session the TUI used for our last message wins when it
    // was touched at least as recently as the viewed candidate: a
    // TUI creates its session lazily, so the one we typed into may
    // not carry a viewed stamp yet — while a session the user
    // picked in the TUI always does (and then it wins).
    final remembered = _tuiSessions[_dirKey(directory)];
    if (remembered != null && picked != null) {
      for (final raw in data) {
        if (raw is! Map<String, dynamic>) continue;
        if (raw['id'] != remembered) continue;
        if (_stamp(raw) >= _timeOf(data, picked, 'viewed')) {
          return remembered;
        }
      }
    }
    return picked;
  }

  /// The time field of the session [id] within [data], -1 when
  /// unknown.
  static int _timeOf(List<dynamic> data, String id, String key) {
    for (final raw in data) {
      if (raw is! Map<String, dynamic>) continue;
      if (raw['id'] != id) continue;
      return _timeInt(raw, key);
    }
    return -1;
  }

  /// A directory key for the session memory (case/separator
  /// insensitive, like [_sameDir]).
  static String _dirKey(String directory) =>
      directory.replaceAll('/', '\\').toLowerCase();

  /// One time field of a session, -1 when absent.
  static int _timeInt(Map<String, dynamic> raw, String key) {
    final time = raw['time'];
    if (time is! Map<String, dynamic>) return -1;
    return time[key] as int? ?? -1;
  }

  /// The session a Feishu message belongs to: the one a client is
  /// DISPLAYING, not the one most recently chatted into.
  ///
  /// `time.viewed` is stamped by opencode clients every time they
  /// show a session — a freshly launched TUI resumes the newest
  /// session and stamps it; a user switching sessions in the TUI
  /// picker stamps the new one. Ranking by `viewed` therefore
  /// follows the desktop TUI. Ranking by `updated` instead loses
  /// permanently: every Feishu message refreshes the session it
  /// lands in, so a once-wrong pick keeps outranking the session
  /// the TUI just switched to (field-observed: messages stuck in
  /// yesterday's session all day). `updated` only breaks ties
  /// among sessions no client has ever viewed (headless probes).
  static String? pickSessionId(List<dynamic> sessions, String directory) {
    Map<String, dynamic>? bestViewed, bestUpdated;
    var bestViewedAt = -1, bestUpdatedAt = -1;
    for (final raw in sessions) {
      if (raw is! Map<String, dynamic>) continue;
      final loc = raw['location'];
      if (loc is! Map<String, dynamic>) continue;
      final dir = loc['directory'];
      if (dir is! String || !_sameDir(dir, directory)) continue;
      final time = raw['time'];
      if (time is! Map<String, dynamic>) continue;
      final viewed = time['viewed'] as int? ?? -1;
      final updated = time['updated'] as int? ?? -1;
      if (viewed > bestViewedAt) {
        bestViewedAt = viewed;
        bestViewed = raw;
      }
      if (updated > bestUpdatedAt) {
        bestUpdatedAt = updated;
        bestUpdated = raw;
      }
    }
    return (bestViewed ?? bestUpdated)?['id'] as String?;
  }

  // ── Conversation tail (/history) ──────────────────────────────

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

/// A live subscription to the server's event stream. The frames are
/// buffered until a collector attaches, so a collector can come
/// after the interesting events already fired (the TUI's submit, the
/// first reply chunks) without missing them.
class _EventFeed {
  _EventFeed(this.base, this.auth);
  final String base;
  final String auth;
  final Logger _log = moduleLogger('feishu.opencode');
  final _controller = StreamController<Map<String, dynamic>>();
  HttpClient? _client;
  StreamSubscription<String>? _sub;

  Stream<Map<String, dynamic>> get events => _controller.stream;

  Future<void> open() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    _client = client;
    try {
      final req = await client.getUrl(Uri.parse('$base/api/event'));
      req.headers.set(HttpHeaders.authorizationHeader, auth);
      req.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
      final res = await req.close();
      if (res.statusCode != 200) {
        _log.warning('opencode: /api/event -> ${res.statusCode}');
        await close();
        return;
      }
      var dataLine = <String>[];
      _sub = res.transform(utf8.decoder).transform(const LineSplitter()).listen(
        (line) {
          if (line.isEmpty) {
            final payload = dataLine.join('\n');
            dataLine = [];
            if (!payload.startsWith('{')) return;
            try {
              final ev = jsonDecode(payload);
              if (ev is Map<String, dynamic>) _controller.add(ev);
            } catch (_) {}
          } else if (line.startsWith('data:')) {
            dataLine.add(line.substring(5).trimLeft());
          }
        },
        onError: (Object e) {
          _log.warning('opencode: event stream error ($e)');
        },
      );
    } catch (e) {
      _log.warning('opencode: event stream failed ($e)');
      await close();
    }
  }

  Future<void> close() async {
    await _sub?.cancel();
    _sub = null;
    _client?.close();
    _client = null;
    // Never await the controller's close: a single-subscription
    // controller's close future only completes once its done event
    // is delivered to a listener — and when the server never saw
    // the session (the TUI is served elsewhere, e.g. inside WSL)
    // no collector ever listens. Awaiting it parked tuiTurn's
    // finally forever, wedging the whole serialized tui-chat
    // queue. Nobody consumes the done future; drop it.
    if (!_controller.isClosed) unawaited(_controller.close());
  }
}
