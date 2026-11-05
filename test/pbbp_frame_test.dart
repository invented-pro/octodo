// Wire-format tests for the pbbp2 frames, including the reference
// byte vector from the official SDKs.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/feishu/pbbp_frame.dart';

import 'feishu_frame_vectors.dart';

Uint8List _bytesOf(String hex) => Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);

void main() {
  test('a ping encodes like the official SDKs', () {
    // From the Python SDK:
    // Frame(SeqID=0, LogID=0, service=7, method=0,
    //       headers=[type: ping]).SerializeToString()
    const expected = [
      0x08, 0x00, 0x10, 0x00, 0x18, 0x07, 0x20, 0x00, //
      0x2a, 0x0c, 0x0a, 0x04, 0x74, 0x79, 0x70, 0x65, // "type"
      0x12, 0x04, 0x70, 0x69, 0x6e, 0x67, // "ping"
    ];
    expect(PbbpFrame.ping(7).encode(), expected);
  });

  test('frames round-trip with every field set', () {
    final frame = PbbpFrame(
      seqId: 42,
      logId: 7,
      service: 5,
      method: kPbbpData,
      headers: const [
        PbbpHeader('type', 'event'),
        PbbpHeader('message_id', 'om_123'),
        PbbpHeader('sum', '2'),
      ],
      payloadEncoding: 'json',
      payloadType: 'application/json',
      payload: Uint8List.fromList(utf8.encode('{"a":1}')),
      logIdNew: 'log-new',
    );
    final decoded = PbbpFrame.decode(frame.encode());
    expect(decoded.seqId, 42);
    expect(decoded.logId, 7);
    expect(decoded.service, 5);
    expect(decoded.method, kPbbpData);
    expect(decoded.headers.length, 3);
    expect(decoded.header('type'), 'event');
    expect(decoded.header('message_id'), 'om_123');
    expect(decoded.header('sum'), '2');
    expect(decoded.payloadEncoding, 'json');
    expect(decoded.payloadType, 'application/json');
    expect(decoded.payload, frame.payload);
    expect(decoded.logIdNew, 'log-new');
  });

  test('large varints (multi-byte) round-trip', () {
    final frame =
        PbbpFrame(seqId: 0x7fffffff, logId: 300, service: 1, method: 0);
    final decoded = PbbpFrame.decode(frame.encode());
    expect(decoded.seqId, 0x7fffffff);
    expect(decoded.logId, 300);
  });

  test('ack appends biz_rt and replaces the payload', () {
    final frame = PbbpFrame(
      seqId: 9,
      service: 3,
      method: kPbbpData,
      headers: const [PbbpHeader('type', 'event')],
      payload: Uint8List.fromList(utf8.encode('{"schema":"2.0"}')),
    );
    final ack = frame.ack(200, 12);
    final decoded = PbbpFrame.decode(ack.encode());
    expect(decoded.header('type'), 'event');
    expect(decoded.header(kPbbpBizRt), '12');
    expect(utf8.decode(decoded.payload!), '{"code":200}');
  });

  test('unknown fields are skipped on decode', () {
    // Hand-build: field 15 varint (tag 0x78), then field 3 service.
    final bytes = <int>[0x78, 0x2a, 0x18, 0x07];
    final decoded = PbbpFrame.decode(Uint8List.fromList(bytes));
    expect(decoded.service, 7);
  });

  test('truncated input throws FormatException', () {
    expect(
      () => PbbpFrame.decode(Uint8List.fromList([0x0a, 0x05, 0x61])),
      throwsFormatException,
    );
  });

  group('real captured frames (2026-11-05 long connection)', () {
    // These two regression vectors are the exact bytes Feishu sent
    // over the WebSocket. They carry fields 12–14 and 20–22 behind
    // the SDK-documented schema — tags that only fit in multi-byte
    // varints, which is what broke the codec originally: it read
    // tags as single bytes and derailed every field after the first
    // one (surfacing as "truncated varint" at the frame tail).
    test('captured pong decodes with its ClientConfig payload', () {
      final f = PbbpFrame.decode(_bytesOf(kCapturedPongFrameHex));
      expect(f.method, kPbbpControl);
      expect(f.service, 33554678);
      expect(f.header('type'), 'pong');
      expect(f.header('is_ack'), '1');
      expect(f.header('code'), '0');
      final cfg = jsonDecode(utf8.decode(f.payload!)) as Map<String, dynamic>;
      expect(cfg['PingInterval'], 90);
      expect(cfg['ReconnectCount'], -1);
    });

    test('captured event decodes across the multi-byte-tag tail', () {
      final f = PbbpFrame.decode(_bytesOf(kCapturedEventFrameHex));
      expect(f.method, kPbbpData);
      expect(f.service, 33554678);
      expect(f.header('type'), 'event');
      expect(f.header('sum'), '1');
      expect(f.header('seq'), '0');
      expect(f.header('message_id'), isNotNull);
      expect(f.logIdNew, isNotNull);
      final json = jsonDecode(utf8.decode(f.payload!)) as Map<String, dynamic>;
      expect(json['header']['event_type'], 'im.message.receive_v1');
      expect(json['event']['message']['content'], '{"text":"ls"}');
    });
  });
}
