import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:octodo/src/terminal/osc99_scanner.dart';

Uint8List b(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  group('basic notification (body only)', () {
    test('parses a no-metadata payload as a complete title', () {
      final events = Osc99Scanner().scan(b('\x1b]99;;Hello world\x07'));
      expect(events, hasLength(1));
      final p = events.single as Osc99Payload;
      expect(p.text, 'Hello world');
      expect(p.isTitle, isTrue);
      expect(p.done, isTrue, reason: 'd=1 is the kitty default');
      expect(p.identifier, '');
    });
  });

  group('OpenTUI probe', () {
    test('parses p=? as a probe carrying the identifier', () {
      final events = Osc99Scanner().scan(
        b('\x1b]99;i=opentui-notifications:p=?;\x1b\\'),
      );
      final probe = events.single as Osc99Probe;
      expect(probe.identifier, 'opentui-notifications');
    });

    test('reply advertises title/body payloads and always-occasion', () {
      final reply = utf8.decode(Osc99ProbeReply.reply('my-id'));
      expect(reply, startsWith('\x1b]99;'));
      expect(reply, contains('i=my-id'));
      expect(reply, contains('p=title,body'));
      expect(reply, contains('o=always'));
      expect(reply, endsWith('\x1b\\'));
    });

    test('reply omits the identifier group when the probe had none', () {
      final reply = utf8.decode(Osc99ProbeReply.reply(''));
      expect(reply, '\x1b]99;p=?;p=title,body:o=always\x1b\\');
    });

    test(
      'reply tolerates a non-ASCII identifier (remote-controlled input)',
      () {
        // The i= value comes off the wire decoded as UTF-8; a code
        // unit > 127 must not throw (regression: ascii.encode did).
        final bytes = Osc99ProbeReply.reply('opentui-☕');
        final reply = utf8.decode(bytes);
        expect(reply, contains('i=opentui-☕'));
      },
    );
  });

  group('chunked title + body (kitty full form)', () {
    test('title d=0 then body d=1 accumulate under one identifier', () {
      final s = Osc99Scanner();
      final events = [
        ...s.scan(b('\x1b]99;i=1:d=0;Session done\x1b\\')),
        ...s.scan(b('\x1b]99;i=1:p=body:d=1;All tests passed\x1b\\')),
      ];
      final title = events[0] as Osc99Payload;
      expect(title.identifier, '1');
      expect(title.isTitle, isTrue);
      expect(title.done, isFalse);
      final body = events[1] as Osc99Payload;
      expect(body.identifier, '1');
      expect(body.isTitle, isFalse);
      expect(body.done, isTrue);
      expect(body.text, 'All tests passed');
    });
  });

  group('close', () {
    test('p=close maps to a close event with the identifier', () {
      final events = Osc99Scanner().scan(b('\x1b]99;i=abc:p=close;\x07'));
      final close = events.single as Osc99Close;
      expect(close.identifier, 'abc');
    });
  });

  group('payload edge cases', () {
    test('semicolons inside the payload are preserved', () {
      final events = Osc99Scanner().scan(b('\x1b]99;;a;b;c\x07'));
      final p = events.single as Osc99Payload;
      expect(p.text, 'a;b;c');
    });

    test('base64 payloads (e=1) are decoded', () {
      final encoded = base64.encode(utf8.encode('héllo 🎉'));
      final events = Osc99Scanner().scan(b('\x1b]99;e=1;$encoded\x1b\\'));
      final p = events.single as Osc99Payload;
      expect(p.text, 'héllo 🎉');
    });

    test('unrelated OSC 9 / OSC 777 traffic is ignored', () {
      final events = Osc99Scanner().scan(
        b('\x1b]9;plain growl\x07\x1b]777;notify;T;B\x07'),
      );
      expect(events, isEmpty);
    });
  });

  group('chunk boundaries', () {
    test('sequence split at every offset still parses once', () {
      const seq = '\x1b]99;i=xyz:p=body:d=1;done text\x1b\\';
      for (var split = 1; split < seq.length - 1; split++) {
        final s = Osc99Scanner();
        final first = s.scan(b(seq.substring(0, split)));
        final second = s.scan(b(seq.substring(split)));
        final payloads = [...first, ...second].whereType<Osc99Payload>();
        expect(
          payloads,
          hasLength(1),
          reason: 'split at $split lost or duplicated the sequence',
        );
        expect(payloads.single.text, 'done text');
      }
    });
  });
}
