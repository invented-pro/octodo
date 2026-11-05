// Feishu's long connection ("使用长连接接收事件"): the WebSocket the
// official SDKs open so an app receives events without a public
// callback URL.
//
// Protocol (mirrors the official SDKs / the feishu-ws reference):
//   1. POST {domain}/callback/ws/endpoint with {AppID, AppSecret} →
//      {code, data: {URL, ClientConfig{Reconnect*, PingInterval}}}.
//      The URL carries the frame `service_id` as a query param.
//   2. Open the WebSocket; every binary message is a pbbp2 frame
//      (see `pbbp_frame.dart`).
//   3. Ping every PingInterval seconds; pongs may carry an updated
//      ClientConfig in their payload.
//   4. Data frames with type "event" carry one JSON event
//      ({"schema":"2.0","header":{…},"event":{…}}), possibly split
//      across frames (sum/seq headers; parts reassembled in order,
//      5 s TTL). Acknowledge each by echoing the frame with a
//      biz_rt header and {"code":200} payload — within 3 s or
//      Feishu re-sends.
//   5. On disconnect: wait a random slice of ReconnectNonce before
//      the first retry, then ReconnectInterval apart, at most
//      ReconnectCount attempts (-1 = unlimited).
//
// Transport seams: the HTTP client and the WebSocket factory are
// injectable so tests drive the session logic without a network.

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../log.dart';
import 'feishu_credentials.dart';
import 'feishu_event_channel.dart';
import 'pbbp_frame.dart';

const String kFeishuOpenDomain = 'https://open.feishu.cn';
const String kLarkOpenDomain = 'https://open.larksuite.com';
const String _endpointPath = '/callback/ws/endpoint';

/// Connection settings Feishu hands out with the endpoint URL (and
/// refreshes in pongs).
class FeishuWsSettings {
  /// Reconnect attempts per outage; -1 = no limit.
  final int reconnectCount;

  /// Seconds between reconnect attempts.
  final int reconnectInterval;

  /// Up to this many seconds before the first retry (client jitter).
  final int reconnectNonce;

  /// Seconds between pings.
  final int pingInterval;

  const FeishuWsSettings({
    this.reconnectCount = -1,
    this.reconnectInterval = 120,
    this.reconnectNonce = 30,
    this.pingInterval = 120,
  });

  FeishuWsSettings applyJson(Map<String, dynamic> json) {
    int? asInt(Object? v) =>
        v is int ? v : (v is num ? v.toInt() : int.tryParse('$v'));
    return FeishuWsSettings(
      reconnectCount: asInt(json['ReconnectCount']) ?? reconnectCount,
      reconnectInterval: asInt(json['ReconnectInterval']) ?? reconnectInterval,
      reconnectNonce: asInt(json['ReconnectNonce']) ?? reconnectNonce,
      pingInterval:
          // A zero interval would ping without pause — keep current.
          (asInt(json['PingInterval']) ?? 0) > 0
              ? asInt(json['PingInterval'])!
              : pingInterval,
    );
  }
}

/// The minimal WebSocket transport the channel needs — implemented
/// by dart:io in production, faked in tests.
abstract class FeishuWsConnection {
  Stream<Uint8List> get binaryMessages;
  void send(Uint8List bytes);
  Future<void> close();
}

typedef FeishuWsConnector = Future<FeishuWsConnection> Function(Uri url);

class _IoWsConnection implements FeishuWsConnection {
  final io.WebSocket _ws;
  _IoWsConnection(this._ws);

  @override
  Stream<Uint8List> get binaryMessages => _ws.where((m) => m is List<int>).map(
        (m) => Uint8List.fromList(m as List<int>),
      );

  @override
  void send(Uint8List bytes) => _ws.add(bytes);

  @override
  Future<void> close() => _ws.close();
}

/// One event frame reassembled from (possibly split) data frames —
/// the raw JSON payload plus its ids, before message extraction.
class FeishuWsRawEvent {
  final String messageId;
  final String traceId;
  final Uint8List payload;
  const FeishuWsRawEvent(this.messageId, this.traceId, this.payload);
}

/// Pure per-connection session logic: feed frames in, get reply
/// bytes and events out. Kept side-effect-free (no sockets) so the
/// ack / reassembly / pong-settings rules are unit-testable.
class FeishuWsSession {
  final int service;
  final FeishuWsSettings settings;

  /// Split-message parts by message id, with a 5 s TTL.
  final _parts = <String, _Parts>{};
  final DateTime Function() _now;

  FeishuWsSession({required this.service, FeishuWsSettings? settings, DateTime Function()? now})
      : settings = settings ?? const FeishuWsSettings(),
        _now = now ?? DateTime.now;

  /// Handle one inbound binary message. Returns the binary reply to
  /// send (an ack), or null. Emits assembled events via [events].
  final _eventController = StreamController<FeishuWsRawEvent>.broadcast();
  Stream<FeishuWsRawEvent> get events => _eventController.stream;

  Uint8List? handleBinary(Uint8List data) {
    final PbbpFrame frame;
    try {
      frame = PbbpFrame.decode(data);
    } on FormatException {
      return null; // Undecodable — ignore, per the reference SDKs.
    }
    switch (frame.method) {
      case kPbbpControl:
        return null; // Pongs carry no reply (settings read by caller).
      case kPbbpData:
        return _handleData(frame);
      default:
        return null;
    }
  }

  Uint8List? _handleData(PbbpFrame frame) {
    final messageId = frame.header(kPbbpMessageId);
    final kind = frame.header(kPbbpType);
    if (messageId == null || kind == null) return null;

    final traceId = frame.header(kPbbpTraceId) ?? '';
    final sum = int.tryParse(frame.header(kPbbpSum) ?? '') ?? 1;
    final seq = int.tryParse(frame.header(kPbbpSeq) ?? '') ?? 0;
    final piece = frame.payload ?? Uint8List(0);

    Uint8List payload;
    if (sum > 1) {
      final assembled = _combine(messageId, sum, seq, piece);
      if (assembled == null) return null; // Waiting for more parts.
      payload = assembled;
    } else {
      payload = piece;
    }

    // Card callbacks are not received in this build; like the
    // official SDKs, they go unanswered.
    if (kind != 'event') return null;

    final stopwatch = Stopwatch()..start();
    var code = 200;
    try {
      // Validate JSON before forwarding.
      jsonDecode(utf8.decode(payload, allowMalformed: true));
      _eventController.add(FeishuWsRawEvent(messageId, traceId, payload));
    } on FormatException {
      code = 500;
    }
    return frame
        .ack(code, stopwatch.elapsedMilliseconds)
        .encode();
  }

  Uint8List? _combine(String messageId, int sum, int seq, Uint8List piece) {
    final now = _now();
    _parts.removeWhere((_, p) => !p.isAlive(now));
    if (seq < 0 || seq >= sum) return null;
    var parts = _parts[messageId];
    if (parts == null || parts.pieces.length != sum) {
      parts = _Parts(sum, now);
      _parts[messageId] = parts;
    }
    parts.pieces[seq] = piece;
    parts.expires = now.add(const Duration(seconds: 5));
    if (parts.pieces.any((p) => p == null)) return null;
    _parts.remove(messageId);
    final out = BytesBuilder();
    for (final p in parts.pieces) {
      out.add(p!);
    }
    return out.takeBytes();
  }

  void dispose() => _eventController.close();
}

class _Parts {
  final List<Uint8List?> pieces;
  DateTime expires;
  _Parts(int sum, DateTime now)
      : pieces = List<Uint8List?>.filled(sum, null),
        expires = now.add(const Duration(seconds: 5));
  bool isAlive(DateTime now) => expires.isAfter(now);
}

/// The production channel: endpoint → WebSocket → session loop,
/// reconnecting per Feishu's settings until stopped.
class FeishuWsChannel implements FeishuEventChannel {
  final http.Client _http;
  final FeishuWsConnector _connect;
  final Logger _log = moduleLogger('feishu.ws');
  final math.Random _random = math.Random();

  StreamController<FeishuConnectionState>? _state;
  final _eventController = StreamController<FeishuInboundEvent>.broadcast();

  FeishuCredentials? _credentials;
  FeishuWsSettings _settings;
  FeishuWsSession? _session;
  FeishuWsConnection? _connection;
  Timer? _pingTimer;
  int _generation = 0;
  bool _stopping = false;

  FeishuWsChannel({
    http.Client? httpClient,
    FeishuWsConnector? connector,
    FeishuWsSettings? initialSettings,
  })  : _http = httpClient ?? http.Client(),
        _connect = connector ?? _ioConnect,
        _settings = initialSettings ?? const FeishuWsSettings();

  static Future<FeishuWsConnection> _ioConnect(Uri url) async {
    final ws = await io.WebSocket.connect(url.toString());
    return _IoWsConnection(ws);
  }

  @override
  Stream<FeishuConnectionState> get stateChanges =>
      (_state ??= StreamController<FeishuConnectionState>.broadcast())
          .stream;

  @override
  FeishuConnectionState get currentState =>
      _state?.hasListener == true ? _lastState : _lastState;

  FeishuConnectionState _lastState = FeishuConnectionState.disconnected;

  void _setState(FeishuConnectionState value) {
    if (_lastState == value) return;
    _lastState = value;
    if (_state != null && !_state!.isClosed) _state!.add(value);
  }

  @override
  Stream<FeishuInboundEvent> get events => _eventController.stream;

  @override
  Future<void> start(FeishuCredentials credentials) async {
    await stop();
    _stopping = false;
    _credentials = credentials;
    final generation = ++_generation;
    unawaited(_keepConnected(generation));
  }

  @override
  Future<void> stop() async {
    _stopping = true;
    _generation++;
    _pingTimer?.cancel();
    _pingTimer = null;
    try {
      await _connection?.close();
    } catch (_) {}
    _connection = null;
    _session?.dispose();
    _session = null;
    _setState(FeishuConnectionState.disconnected);
  }

  Future<void> _keepConnected(int generation) async {
    var failures = 0;
    var firstFailure = true;
    while (!_stopping && generation == _generation) {
      if (failures > 0 || !firstFailure) {
        if (_settings.reconnectCount >= 0 && failures >= _settings.reconnectCount) {
          _log.warning('feishu: giving up after $failures reconnect attempts');
          return;
        }
        final wait = firstFailure
            ? _settings.reconnectNonce * _random.nextDouble()
            : _settings.reconnectInterval.toDouble();
        await Future<void>.delayed(Duration(milliseconds: wait.round()));
        if (_stopping || generation != _generation) return;
        if (!firstFailure) failures++;
      }
      firstFailure = false;
      _setState(FeishuConnectionState.connecting);
      try {
        await _connectOnce(generation);
        failures = 0;
        firstFailure = true;
      } catch (e) {
        _log.info('feishu: connection attempt failed: $e');
        _setState(FeishuConnectionState.disconnected);
        if (firstFailure) {
          firstFailure = false; // nonce jitter before the next try
        } else {
          failures++;
        }
      }
    }
  }

  Future<void> _connectOnce(int generation) async {
    final creds = _credentials!;
    final domain =
        creds.isLark ? kLarkOpenDomain : kFeishuOpenDomain;
    final url = await _fetchEndpointUrl(domain);
    if (_stopping || generation != _generation) return;

    final service =
        int.tryParse(url.queryParameters['service_id'] ?? '') ?? 0;
    final device = url.queryParameters['device_id'] ?? '';
    final connection = await _connect(url);
    if (_stopping || generation != _generation) {
      await connection.close();
      return;
    }
    _connection = connection;
    final session = FeishuWsSession(
        service: service, settings: _settings);
    _session = session;
    session.events.listen(
      (e) => _emitEvent(e),
      onError: (_) {},
    );

    _setState(FeishuConnectionState.connected);
    _log.info('feishu: long connection established '
        '(service_id=$service, device_id=$device)');

    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(
      Duration(seconds: _settings.pingInterval),
      (_) {
        try {
          connection.send(PbbpFrame.ping(service).encode());
        } catch (_) {}
      },
    );

    try {
      await for (final message in connection.binaryMessages) {
        if (generation != _generation) return;
        // Diagnostics first: every inbound frame is logged (data
        // frames at INFO — they're rare; control at FINE) so a
        // silent event pipeline is visible without a debugger.
        _logInbound(message);
        // Pong settings updates.
        final reply = session.handleBinary(message);
        _applyPongSettings(message);
        if (reply != null) {
          try {
            connection.send(reply);
          } catch (_) {}
        }
      }
    } finally {
      _pingTimer?.cancel();
      _pingTimer = null;
    }
    _setState(FeishuConnectionState.disconnected);
    _log.info('feishu: long connection closed');
    throw StateError('connection closed'); // triggers reconnect loop
  }

  void _applyPongSettings(Uint8List data) {
    try {
      final frame = PbbpFrame.decode(data);
      if (frame.method == kPbbpControl &&
          frame.header(kPbbpType) == 'pong' &&
          frame.payload != null &&
          frame.payload!.isNotEmpty) {
        final decoded =
            jsonDecode(utf8.decode(frame.payload!));
        if (decoded is Map<String, dynamic>) {
          _settings = _settings.applyJson(decoded);
        }
      }
    } on FormatException {
      // Not a pong we can read — fine.
    }
  }

  /// Log one inbound frame for diagnostics. Data frames (events,
  /// cards) are rare, so they log at INFO; control frames (pong per
  /// ping interval) at FINE. Undecodable frames warn.
  void _logInbound(Uint8List data) {
    try {
      final frame = PbbpFrame.decode(data);
      if (frame.method == kPbbpControl) {
        _log.fine('feishu: control frame '
            'type=${frame.header(kPbbpType) ?? "?"}');
        return;
      }
      _log.info('feishu: data frame '
          'kind=${frame.header(kPbbpType) ?? "?"} '
          'message_id=${frame.header(kPbbpMessageId) ?? "-"} '
          'bytes=${frame.payload?.length ?? 0} '
          'event_type=${_peekEventType(frame.payload) ?? "-"}');
    } on FormatException {
      _log.warning('feishu: undecodable frame (${data.length} bytes)');
    }
  }

  static String? _peekEventType(Uint8List? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      final decoded = jsonDecode(utf8.decode(payload, allowMalformed: true));
      if (decoded is Map<String, dynamic>) {
        final header = decoded['header'];
        if (header is Map<String, dynamic>) {
          // Type-check instead of cast: a non-string value here must
          // not throw from inside the logging path.
          final type = header['event_type'] ?? header['event'];
          return type is String ? type : null;
        }
      }
    } on FormatException {
      // Payload isn't JSON — leave the event type unset.
    }
    return null;
  }

  Future<Uri> _fetchEndpointUrl(String domain) async {
    final response = await _http
        .post(
          Uri.parse('$domain$_endpointPath'),
          headers: {'locale': 'zh'},
          body: jsonEncode({
            'AppID': _credentials!.appId,
            'AppSecret': _credentials!.appSecret,
          }),
        )
        .timeout(const Duration(seconds: 30));
    final body =
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final code = (body['code'] as num?)?.toInt() ?? -1;
    if (code != 0) {
      throw StateError('endpoint refused: $code ${body['msg']}');
    }
    final data = body['data'] as Map<String, dynamic>?;
    if (data != null && data['ClientConfig'] is Map) {
      _settings = _settings
          .applyJson(data['ClientConfig'] as Map<String, dynamic>);
    }
    final url = data?['URL'] ?? data?['url'];
    if (url is! String || url.isEmpty) {
      throw StateError('endpoint response has no URL');
    }
    return Uri.parse(url);
  }

  void _emitEvent(FeishuWsRawEvent e) {
    final event = parseImMessageEvent(e.payload);
    if (event != null) _eventController.add(event);
  }

  /// Extract the fields of `im.message.receive_v1` we route on.
  /// Other event types yield null (already acked by the session).
  /// Public + pure so routing tests don't need a socket.
  static FeishuInboundEvent? parseImMessageEvent(Uint8List payload) {
    Map<String, dynamic> json;
    try {
      json = jsonDecode(utf8.decode(payload, allowMalformed: true))
          as Map<String, dynamic>;
    } on FormatException {
      return null;
    }
    final header = json['header'];
    if (header is! Map<String, dynamic> ||
        header['event_type'] != 'im.message.receive_v1') {
      return null;
    }
    final event = json['event'];
    if (event is! Map<String, dynamic>) return null;
    final sender = event['sender'];
    final senderId = sender is Map<String, dynamic>
        ? sender['sender_id']
        : null;
    final openId = senderId is Map<String, dynamic>
        ? (senderId['open_id'] as String? ?? '')
        : '';
    final message = event['message'];
    if (message is! Map<String, dynamic>) return null;
    final chatId = message['chat_id'] as String? ?? '';
    final messageId = message['message_id'] as String? ?? '';
    if (chatId.isEmpty || messageId.isEmpty) return null;
    var text = '';
    if (message['message_type'] == 'text') {
      final content = message['content'];
      if (content is String && content.isNotEmpty) {
        try {
          final decoded = jsonDecode(content);
          if (decoded is Map<String, dynamic>) {
            text = decoded['text'] as String? ?? '';
          }
        } on FormatException {
          // Non-JSON content — treated as empty.
        }
      }
    }
    return FeishuInboundEvent(
      senderOpenId: openId,
      chatId: chatId,
      messageId: messageId,
      text: text.trim(),
    );
  }

  void dispose() {
    stop();
    _state?.close();
    _eventController.close();
    _http.close();
  }
}
