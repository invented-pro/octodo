import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:octodo/src/terminal/osc7_scanner.dart';

Uint8List b(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  group('Osc7Scanner', () {
    test('extracts a complete BEL-terminated sequence', () {
      final scanner = Osc7Scanner();
      final out = scanner.scan(b('\x1b]7;file://host/tmp\x07'));
      expect(out, ['file://host/tmp']);
    });

    test('extracts a complete ST-terminated sequence', () {
      final scanner = Osc7Scanner();
      final out = scanner.scan(b('\x1b]7;file://host/tmp\x1b\\'));
      expect(out, ['file://host/tmp']);
    });

    test('extracts multiple sequences in one chunk', () {
      final scanner = Osc7Scanner();
      final out = scanner.scan(
        b('before\x1b]7;file://a/one\x07mid\x1b]7;file://a/two\x1b\\after'),
      );
      expect(out, ['file://a/one', 'file://a/two']);
    });

    test('ignores other OSC sequences entirely', () {
      final scanner = Osc7Scanner();
      final out = scanner.scan(
        b(
          '\x1b]2;title\x07\x1b]1;tab\x07\x1b]777;notify;x;y\x07'
          '\x1b]8;;http://x\x1b\\link\x1b]8;;\x1b\\',
        ),
      );
      expect(out, isEmpty);
    });

    test('extracts OSC 7 that follows unknown OSCs in the same batch '
        '(upstream engine drops these)', () {
      final scanner = Osc7Scanner();
      final out = scanner.scan(
        b('\x1b]2;cd /tmp\x07\x1b]1;cd\x07text\x1b]7;file://h/tmp\x1b\\'),
      );
      expect(out, ['file://h/tmp']);
    });

    test('does not match OSC 77/777 introducers', () {
      final scanner = Osc7Scanner();
      final out = scanner.scan(b('\x1b]77;extra\x07\x1b]777;notify;a;b\x07'));
      expect(out, isEmpty);
      // A following real OSC 7 still extracts.
      final out2 = scanner.scan(b('\x1b]7;file://h/x\x07'));
      expect(out2, ['file://h/x']);
    });

    group('chunk-boundary splits', () {
      test('introducer split across chunks', () {
        final scanner = Osc7Scanner();
        expect(scanner.scan(b('junk\x1b]')), isEmpty);
        expect(scanner.scan(b('7;file://h/tmp\x07')), ['file://h/tmp']);
      });

      test('introducer split one byte at a time', () {
        final scanner = Osc7Scanner();
        expect(scanner.scan(b('x\x1b')), isEmpty);
        expect(scanner.scan(b(']')), isEmpty);
        expect(scanner.scan(b('7')), isEmpty);
        expect(scanner.scan(b(';file://h/tmp\x07')), ['file://h/tmp']);
      });

      test('payload split across chunks', () {
        final scanner = Osc7Scanner();
        expect(scanner.scan(b('\x1b]7;file://ho')), isEmpty);
        expect(scanner.scan(b('st/tmp\x07')), ['file://host/tmp']);
      });

      test('ST terminator split across chunks', () {
        final scanner = Osc7Scanner();
        expect(scanner.scan(b('\x1b]7;file://h/tmp\x1b')), isEmpty);
        expect(scanner.scan(b('\\next')), ['file://h/tmp']);
      });

      test('two sequences split across chunks', () {
        final scanner = Osc7Scanner();
        expect(
          scanner.scan(b('\x1b]7;file://a/one\x07text\x1b]7;file://a/t')),
          ['file://a/one'],
        );
        expect(scanner.scan(b('wo\x07')), ['file://a/two']);
      });
    });

    test('garbage without terminator is bounded and discarded', () {
      final scanner = Osc7Scanner();
      // A partial sequence longer than the payload cap must not accumulate
      // forever; subsequent chunks still scan cleanly.
      final big = 'x' * 5000;
      expect(scanner.scan(b('\x1b]7;$big')), isEmpty);
      expect(scanner.scan(b('\x1b]7;file://h/ok\x07')), ['file://h/ok']);
    });

    test('oversized payload is dropped, scanning continues', () {
      final scanner = Osc7Scanner();
      final big = 'y' * 5000;
      final out = scanner.scan(b('\x1b]7;$big\x07\x1b]7;file://h/small\x07'));
      expect(out, ['file://h/small']);
    });

    test('UTF-8 payload decodes lossily like the engine', () {
      final scanner = Osc7Scanner();
      final bytes = Uint8List.fromList([
        0x1b, 0x5d, 0x37, 0x3b, // ESC ] 7 ;
        0x66, 0x69, 0x6c, 0x65, 0x3a, 0x2f, 0x2f, 0x68, 0x2f, // file://h/
        0xe4, 0xb8, 0xad, 0xe6, 0x96, 0x87, // 中文 (UTF-8)
        0x07, // BEL
      ]);
      expect(scanner.scan(bytes), ['file://h/中文']);
    });

    test('payload with ESC not followed by backslash keeps scanning', () {
      final scanner = Osc7Scanner();
      // A raw ESC inside the payload that isn't an ST (malformed) — the
      // scanner keeps looking for a real terminator afterwards.
      final out = scanner.scan(b('\x1b]7;bad\x1bXthen\x07'));
      // The scan continued to the BEL; the payload includes everything up
      // to it (permissive like the engine's find_st, which only matches
      // ESC \ pairs and BEL).
      expect(out, ['bad\x1bXthen']);
    });

    test('empty stream yields nothing', () {
      final scanner = Osc7Scanner();
      expect(scanner.scan(b('')), isEmpty);
      expect(scanner.scan(Uint8List(0)), isEmpty);
    });
  });
}
