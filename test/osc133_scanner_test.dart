import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:octodo/src/notifications/osc133_scanner.dart';

Uint8List b(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  group('Osc133Scanner', () {
    test('extracts a C mark (command started)', () {
      final scanner = Osc133Scanner();
      expect(scanner.scan(b('\x1b]133;C\x07')), ['C']);
    });

    test('extracts a D mark with exit code, ST-terminated', () {
      final scanner = Osc133Scanner();
      expect(scanner.scan(b('\x1b]133;D;0\x1b\\')), ['D;0']);
    });

    test('extracts prompt marks A and B too (future features)', () {
      final scanner = Osc133Scanner();
      final out = scanner.scan(b('\x1b]133;A\x07cmd\x1b]133;B\x07'));
      expect(out, ['A', 'B']);
    });

    test('extracts multiple marks in one chunk', () {
      final scanner = Osc133Scanner();
      final out = scanner.scan(
        b('out\x1b]133;C\x07build...\x1b]133;D;0\x07\x1b]133;C\x07'),
      );
      expect(out, ['C', 'D;0', 'C']);
    });

    test('ignores other OSC sequences (7 / 9 / 777 / 2 / 8)', () {
      final scanner = Osc133Scanner();
      final out = scanner.scan(
        b(
          '\x1b]7;file://host/tmp\x07\x1b]9;4;1;6\x07\x1b]2;title\x07'
          '\x1b]777;notify;t;b\x07\x1b]8;;http://x\x1b\\',
        ),
      );
      expect(out, isEmpty);
    });

    test('does not match a 1333 / 13 introducer', () {
      final scanner = Osc133Scanner();
      expect(scanner.scan(b('\x1b]1333;C\x07')), isEmpty);
      expect(scanner.scan(b('\x1b]13;C\x07')), isEmpty);
      // A real mark after the near-misses still extracts.
      expect(scanner.scan(b('\x1b]133;D;2\x07')), ['D;2']);
    });

    group('chunk-boundary splits', () {
      test('introducer split across chunks', () {
        final scanner = Osc133Scanner();
        expect(scanner.scan(b('junk\x1b]13')), isEmpty);
        expect(scanner.scan(b('3;C\x07')), ['C']);
      });

      test('introducer split one byte at a time', () {
        final scanner = Osc133Scanner();
        expect(scanner.scan(b('x\x1b')), isEmpty);
        expect(scanner.scan(b(']')), isEmpty);
        expect(scanner.scan(b('1')), isEmpty);
        expect(scanner.scan(b('3')), isEmpty);
        expect(scanner.scan(b('3')), isEmpty);
        expect(scanner.scan(b(';D;0\x07')), ['D;0']);
      });

      test('payload split across chunks', () {
        final scanner = Osc133Scanner();
        expect(scanner.scan(b('\x1b]133;D')), isEmpty);
        expect(scanner.scan(b(';12\x07')), ['D;12']);
      });

      test('ST terminator split across chunks', () {
        final scanner = Osc133Scanner();
        expect(scanner.scan(b('\x1b]133;C\x1b')), isEmpty);
        expect(scanner.scan(b('\\')), ['C']);
      });
    });

    test('accepts BEL and ST terminators interchangeably', () {
      final scanner = Osc133Scanner();
      expect(scanner.scan(b('\x1b]133;D;127\x07')), ['D;127']);
      expect(scanner.scan(b('\x1b]133;D;127\x1b\\')), ['D;127']);
    });

    test('non-numeric / malformed exit codes are passed through verbatim '
        '(caller parses defensively)', () {
      final scanner = Osc133Scanner();
      expect(scanner.scan(b('\x1b]133;D;oops\x07')), ['D;oops']);
    });

    test('oversized payload is dropped, scanning continues', () {
      final scanner = Osc133Scanner();
      final huge = 'D;${'9' * 5000}';
      expect(scanner.scan(b('\x1b]133;$huge\x07')), isEmpty);
      expect(scanner.scan(b('\x1b]133;C\x07')), ['C']);
    });
  });
}
