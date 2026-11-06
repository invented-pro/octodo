// Unit tests for the reply collection: which event frames belong to
// the current turn, and what the user gets back.
//
// The window that decides this is captured when the turn *starts*,
// not when the collector attaches — the session lookup takes a few
// seconds, and a fast model can answer within that gap. Measuring
// the window late dropped the reply's first chunks (the user saw
// "no reply" for an answered question).

import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/feishu/opencode_client.dart';

Map<String, dynamic> _text(String sessionId, String text, int created) => {
      'type': 'session.text.ended',
      'created': created,
      'data': {'sessionID': sessionId, 'text': text},
    };

Map<String, dynamic> _failed(String sessionId, int created, String message) => {
      'type': 'session.execution.failed',
      'created': created,
      'data': {
        'sessionID': sessionId,
        'error': {'type': 'provider.rate-limit', 'message': message},
      },
    };

Map<String, dynamic> _succeeded(String sessionId, int created) => {
      'type': 'session.execution.succeeded',
      'created': created,
      'data': {'sessionID': sessionId},
    };

void main() {
  test('only the events of the turn are collected', () {
    const t0 = 1000;
    final events = [
      // An earlier turn's answer — before the window.
      _text('ses_a', 'old answer', t0 - 500),
      // Another session's answer.
      _text('ses_b', 'someone else', t0 + 10),
      // This turn.
      _text('ses_a', 'first part', t0 + 20),
      _text('ses_a', 'second part', t0 + 30),
      _succeeded('ses_a', t0 + 40),
    ];
    expect(OpencodeLocalGateway.replyOf(events, 'ses_a', t0),
        'first part\n\nsecond part');
  });

  test('a failed turn reports the provider error', () {
    const t0 = 1000;
    final events = [
      _failed('ses_a', t0 + 5, '已达 5 小时的使用上限'),
    ];
    expect(OpencodeLocalGateway.replyOf(events, 'ses_a', t0),
        '⚠️ 已达 5 小时的使用上限');
  });

  test('a turn with neither text nor error has no reply', () {
    const t0 = 1000;
    expect(OpencodeLocalGateway.replyOf(const [], 'ses_a', t0), isNull);
    expect(
        OpencodeLocalGateway.replyOf(
            [_succeeded('ses_a', t0 + 5)], 'ses_a', t0),
        isNull);
  });

  test('the text of an event without a timestamp still counts', () {
    const t0 = 1000;
    final events = [
      {
        'type': 'session.text.ended',
        'data': {'sessionID': 'ses_a', 'text': 'no stamp'},
      },
    ];
    expect(OpencodeLocalGateway.replyOf(events, 'ses_a', t0), 'no stamp');
  });
}
