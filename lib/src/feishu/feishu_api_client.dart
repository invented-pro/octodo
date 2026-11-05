// Feishu OpenAPI client for the outbound side of the remote control
// loop: tenant access tokens (cached, refreshed ahead of expiry)
// and sending text messages to a chat.
//
// All sends flow through a serialized queue with a fixed spacing
// (the platform throttles bots at ~5 QPS per user / 100 per minute;
// §5 of the integration design), and long outputs are chunked to
// stay well below the message size cap.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../log.dart';
import 'feishu_credentials.dart';

/// Hard cap per outbound text message — conservative versus the
/// platform's limits so a chunk never bounces.
const int kFeishuMaxMessageChars = 3000;

class FeishuApiException implements Exception {
  final int code;
  final String message;
  const FeishuApiException(this.code, this.message);

  @override
  String toString() => 'FeishuApiException($code): $message';
}

class FeishuApiClient {
  final http.Client _http;
  final Logger _log = moduleLogger('feishu.api');

  FeishuCredentials? _credentials;
  String? _token;
  DateTime _tokenExpiresAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Serialized outbound queue — spaces sends 250 ms apart.
  final _queue = StreamController<_ApiCall>.broadcast();
  DateTime? _lastSend;

  FeishuApiClient({http.Client? httpClient}) : _http = httpClient ?? http.Client() {
    // Subscribe at construction: a broadcast stream drops events
    // published before the listener exists, and callers enqueue
    // before anything else happens.
    _queue.stream.listen((call) async {
      // Serialize with 250 ms spacing between HTTP sends.
      while (_lastSend != null) {
        final wait = _lastSend!
            .add(const Duration(milliseconds: 250))
            .difference(DateTime.now());
        if (wait.isNegative) break;
        await Future<void>.delayed(wait);
      }
      _lastSend = DateTime.now();
      try {
        await _sendTextNow(chatId: call.chatId, text: call.text);
        call.done.complete();
      } catch (e) {
        call.done.completeError(e);
      }
    });
  }

  String get _domain =>
      (_credentials?.isLark ?? false)
          ? 'https://open.larksuite.com'
          : 'https://open.feishu.cn';

  /// Point the client at a (new) binding. Clears any cached token.
  void bind(FeishuCredentials credentials) {
    _credentials = credentials;
    _token = null;
    _tokenExpiresAt = DateTime.fromMillisecondsSinceEpoch(0);
  }

  bool get isBound => _credentials != null;

  Future<String> _tenantAccessToken() async {
    final creds = _credentials;
    if (creds == null) {
      throw const FeishuApiException(-1, 'not bound');
    }
    // Refresh 60 s before expiry.
    if (_token != null &&
        DateTime.now().isBefore(_tokenExpiresAt.subtract(const Duration(seconds: 60)))) {
      return _token!;
    }
    final response = await _http
        .post(
          Uri.parse('$_domain/open-apis/auth/v3/tenant_access_token/internal'),
          body: jsonEncode({
            'app_id': creds.appId,
            'app_secret': creds.appSecret,
          }),
          headers: {'content-type': 'application/json; charset=utf-8'},
        )
        .timeout(const Duration(seconds: 30));
    final body = _decode(response);
    final code = (body['code'] as num?)?.toInt() ?? -1;
    if (code != 0) {
      throw FeishuApiException(code, '${body['msg']}');
    }
    final token = body['tenant_access_token'] as String?;
    final expire = (body['expire'] as num?)?.toInt() ?? 0;
    if (token == null || token.isEmpty) {
      throw const FeishuApiException(-1, 'empty tenant_access_token');
    }
    _token = token;
    _tokenExpiresAt =
        DateTime.now().add(Duration(seconds: expire > 0 ? expire : 3600));
    return token;
  }

  /// Send [text] to chat [chatId]. Long texts are split into
  /// chunks; all chunks flow through the rate-limited queue.
  Future<void> sendText(String chatId, String text) async {
    if (!_queue.isClosed) {
      await _enqueueSend(chatId, text);
    }
  }

  Future<void> _enqueueSend(String chatId, String text) {
    final done = Completer<void>();
    _queue.add(_ApiCall(chatId, text, done));
    return done.future;
  }

  Future<void> _sendTextNow({required String chatId, required String text}) async {
    // Chunk by grapheme-safe length (code units are fine here — the
    // payload is JSON-encoded UTF-8 either way).
    final chunks = <String>[];
    var rest = text;
    while (rest.length > kFeishuMaxMessageChars) {
      chunks.add(rest.substring(0, kFeishuMaxMessageChars));
      rest = rest.substring(kFeishuMaxMessageChars);
    }
    chunks.add(rest);
    for (var i = 0; i < chunks.length; i++) {
      final suffix = chunks.length > 1 ? ' (${i + 1}/${chunks.length})' : '';
      await _sendMessageRaw(chatId, chunks[i] + suffix);
    }
  }

  Future<void> _sendMessageRaw(String chatId, String text) async {
    var token = await _tenantAccessToken();
    for (var attempt = 0; attempt < 2; attempt++) {
      final response = await _http
          .post(
            Uri.parse(
                '$_domain/open-apis/im/v1/messages?receive_id_type=chat_id'),
            headers: {
              'authorization': 'Bearer $token',
              'content-type': 'application/json; charset=utf-8',
            },
            body: jsonEncode({
              'receive_id': chatId,
              'msg_type': 'text',
              'content': jsonEncode({'text': text}),
            }),
          )
          .timeout(const Duration(seconds: 30));
      final body = _decode(response);
      final code = (body['code'] as num?)?.toInt() ?? -1;
      if (code == 0) return;
      // Token expired / invalid → refresh once and retry.
      if (attempt == 0 &&
          (code == 99991663 || code == 99991661 || code == 99991668)) {
        _token = null;
        token = await _tenantAccessToken();
        continue;
      }
      _log.warning('feishu: send failed: $code ${body['msg']}');
      throw FeishuApiException(code, '${body['msg']}');
    }
  }

  Map<String, dynamic> _decode(http.Response response) {
    return jsonDecode(utf8.decode(response.bodyBytes))
        as Map<String, dynamic>;
  }

  void dispose() {
    _queue.close();
    _http.close();
  }
}

class _ApiCall {
  final String chatId;
  final String text;
  final Completer<void> done;
  const _ApiCall(this.chatId, this.text, this.done);
}
