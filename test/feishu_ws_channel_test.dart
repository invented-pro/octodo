// Session-level tests for the Feishu long connection: acks, split
// reassembly, pong settings, endpoint request shape, and the
// `im.message.receive_v1` field extraction. No sockets involved —
// the session is pure bytes-in/bytes-out.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:octodo/src/feishu/feishu_credentials.dart';
import 'package:octodo/src/feishu/feishu_ws_channel.dart';
import 'package:octodo/src/feishu/pbbp_frame.dart';

FeishuCredentials _creds({String brand = 'feishu'}) => FeishuCredentials(
      appId: 'cli_x',
      appSecret: 'secret',
      ownerOpenId: 'ou_owner',
      tenantBrand: brand,
      boundAt: DateTime.utc(2026),
    );

/// Give-up-after-one-attempt settings so tests never leave the
/// 30 s reconnect-nonce timer pending.
const _kTestSettings = FeishuWsSettings(
    reconnectCount: 0, reconnectInterval: 1, reconnectNonce: 0);

PbbpFrame _dataFrame({
  required String messageId,
  String kind = 'event',
  int sum = 1,
  int seq = 0,
  List<int> payload = const [],
}) {
  return PbbpFrame(
    service: 5,
    method: kPbbpData,
    headers: [
      PbbpHeader(kPbbpType, kind),
      PbbpHeader(kPbbpMessageId, messageId),
      PbbpHeader(kPbbpSum, '$sum'),
      PbbpHeader(kPbbpSeq, '$seq'),
    ],
    payload: Uint8List.fromList(payload),
  );
}

void main() {
  group('FeishuWsSession', () {
    test('a valid event is emitted and acknowledged with code 200',
        () async {
      final session = FeishuWsSession(service: 5);
      addTearDown(session.dispose);

      final emitted = <_Event>[];
      final sub = session.events
          .listen((e) => emitted.add(_Event(e.messageId, e.payload)));
      final reply = session.handleBinary(_dataFrame(
        messageId: 'om_1',
        payload: utf8.encode('{"schema":"2.0"}'),
      ).encode());

      expect(reply, isNotNull);
      final decoded = PbbpFrame.decode(reply!);
      expect(decoded.header(kPbbpBizRt), isNotNull);
      expect(utf8.decode(decoded.payload!), '{"code":200}');
      await Future<void>.delayed(Duration.zero);
      expect(emitted.map((e) => e.id), ['om_1']);
      await sub.cancel();
    });

    test('non-JSON payload is refused with code 500', () {
      final session = FeishuWsSession(service: 5);
      addTearDown(session.dispose);

      final reply =
          session.handleBinary(_dataFrame(messageId: 'om_2', payload: utf8.encode('oops')).encode());
      final decoded = PbbpFrame.decode(reply!);
      expect(utf8.decode(decoded.payload!), '{"code":500}');
    });

    test('card callbacks are not acknowledged', () {
      final session = FeishuWsSession(service: 5);
      addTearDown(session.dispose);

      final reply = session.handleBinary(
          _dataFrame(messageId: 'om_3', kind: 'card', payload: utf8.encode('{}')).encode());
      expect(reply, isNull);
    });

    test('split frames are combined in arrival order (out-of-order parts)',
        () async {
      final session = FeishuWsSession(service: 5);
      addTearDown(session.dispose);

      final emitted = <List<int>>[];
      final sub = session.events.listen((e) => emitted.add(e.payload));

      // Second half first: no ack until the message is whole.
      expect(
        session
            .handleBinary(_dataFrame(messageId: 'm', sum: 2, seq: 1, payload: utf8.encode('2}')).encode()),
        isNull,
      );
      final reply = session.handleBinary(
          _dataFrame(messageId: 'm', sum: 2, seq: 0, payload: utf8.encode('{"a":')).encode());
      expect(reply, isNotNull);

      await Future<void>.delayed(Duration.zero);
      expect(emitted.single, utf8.encode('{"a":2}'));
      await sub.cancel();
    });

    test('expired split parts are dropped', () {
      var clock = DateTime(2026, 1, 1);
      final session = FeishuWsSession(service: 5, now: () => clock);
      addTearDown(session.dispose);

      session.handleBinary(
          _dataFrame(messageId: 'm', sum: 2, seq: 0, payload: utf8.encode('{"a":')).encode());
      clock = clock.add(const Duration(seconds: 6)); // past the 5 s TTL

      final reply = session.handleBinary(
          _dataFrame(messageId: 'm', sum: 2, seq: 1, payload: utf8.encode('1}')).encode());
      // The stale half is gone; the lone second part waits forever.
      expect(reply, isNull);
    });

    test('undecodable frames are ignored', () {
      final session = FeishuWsSession(service: 5);
      addTearDown(session.dispose);
      expect(
        session.handleBinary(Uint8List.fromList([0xff, 0xff, 0xff])),
        isNull,
      );
    });
  });

  group('FeishuWsSettings', () {
    test('endpoint-style PascalCase JSON is applied', () {
      const s0 = FeishuWsSettings();
      final s1 = s0.applyJson({
        'PingInterval': 90,
        'ReconnectCount': 3,
        'ReconnectInterval': 60,
      });
      expect(s1.pingInterval, 90);
      expect(s1.reconnectCount, 3);
      expect(s1.reconnectInterval, 60);
      expect(s1.reconnectNonce, s0.reconnectNonce);
    });

    test('zero ping interval is ignored', () {
      const s0 = FeishuWsSettings(pingInterval: 90);
      final s1 = s0.applyJson({'PingInterval': 0});
      expect(s1.pingInterval, 90);
    });
  });

  group('FeishuWsChannel endpoint fetch', () {
    test('posts AppID/AppSecret and extracts the URL + settings',
        () async {
      Uri? seenUrl;
      String? seenBody;
      final channel = FeishuWsChannel(
        httpClient: MockClient((req) async {
          seenUrl = req.url;
          seenBody = req.body;
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {
                'URL':
                    'wss://frontier.feishu.cn/ws/v5?service_id=42&device_id=d1',
                'ClientConfig': {'PingInterval': 55},
              },
            }),
            200,
          );
        }),
        // Never actually connect: the connector failing is fine, we
        // only assert the endpoint exchange here.
        connector: (url) async => throw StateError('no socket in test'),
        initialSettings: _kTestSettings,
      );
      addTearDown(channel.dispose);

      await channel.start(_creds());
      // Give the async loop a moment to perform the endpoint fetch
      // and fail at the connector (then give up per settings).
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await channel.stop();

      expect(seenUrl.toString(),
          'https://open.feishu.cn/callback/ws/endpoint');
      final body = jsonDecode(seenBody!) as Map<String, dynamic>;
      expect(body['AppID'], 'cli_x');
      expect(body['AppSecret'], 'secret');
    });

    test('lark credentials use the larksuite domain', () async {
      Uri? seenUrl;
      final channel = FeishuWsChannel(
        httpClient: MockClient((req) async {
          seenUrl = req.url;
          return http.Response(
            jsonEncode({'code': 1, 'msg': 'busy'}),
            200,
          );
        }),
        connector: (url) async => throw StateError('no socket in test'),
        initialSettings: _kTestSettings,
      );
      addTearDown(channel.dispose);

      await channel.start(_creds(brand: 'lark'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await channel.stop();

      expect(seenUrl.toString(),
          'https://open.larksuite.com/callback/ws/endpoint');
    });
  });

  group('parseImMessageEvent', () {
    Uint8List eventPayload({
      String eventType = 'im.message.receive_v1',
      String messageType = 'text',
      Object? content,
    }) {
      return Uint8List.fromList(utf8.encode(jsonEncode({
            'schema': '2.0',
            'header': {'event_type': eventType},
            'event': {
              'sender': {
                'sender_id': {'open_id': 'ou_owner'},
              },
              'message': {
                'chat_id': 'oc_chat',
                'message_id': 'om_msg',
                'message_type': messageType,
                'content': content ?? jsonEncode({'text': 'echo hi'}),
              },
            },
          })));
    }

    test('extracts sender, chat, id and text', () {
      final e = FeishuWsChannel.parseImMessageEvent(eventPayload());
      expect(e!.senderOpenId, 'ou_owner');
      expect(e.chatId, 'oc_chat');
      expect(e.messageId, 'om_msg');
      expect(e.text, 'echo hi');
    });

    test('non-text messages yield empty text', () {
      final e = FeishuWsChannel.parseImMessageEvent(
          eventPayload(messageType: 'image', content: '{"image_key":"k"}'));
      expect(e, isNotNull);
      expect(e!.text, isEmpty);
    });

    test('other event types yield null', () {
      final e = FeishuWsChannel.parseImMessageEvent(
          eventPayload(eventType: 'contact.user.updated_v3'));
      expect(e, isNull);
    });

    test('missing ids yield null', () {
      final broken = Uint8List.fromList(
          utf8.encode(jsonEncode({'header': {}, 'event': {}})));
      expect(FeishuWsChannel.parseImMessageEvent(broken), isNull);
    });
  });
}

class _Event {
  final String id;
  final List<int> payload;
  _Event(this.id, this.payload);
}
