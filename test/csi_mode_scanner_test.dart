import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:octodo/src/terminal/csi_mode_scanner.dart';

Uint8List b(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  group('DECSET/DECRST 1004', () {
    test('CSI ? 1004 h reports enabled', () {
      expect(CsiModeScanner().scan(b('\x1b[?1004h')), isTrue);
    });

    test('CSI ? 1004 l reports disabled', () {
      expect(CsiModeScanner().scan(b('\x1b[?1004l')), isFalse);
    });

    test('combined parameter lists are honored', () {
      final s = CsiModeScanner();
      expect(s.scan(b('\x1b[?1049;1004h')), isTrue);
      expect(s.scan(b('\x1b[?1004;2004l')), isFalse);
    });

    test('other modes report no transition', () {
      final s = CsiModeScanner();
      expect(s.scan(b('\x1b[?1000h\x1b[?2004h')), isNull);
    });

    test('non-private modes are ignored', () {
      expect(CsiModeScanner().scan(b('\x1b[4h')), isNull);
    });
  });

  group('false-positive guards', () {
    test('literal [?1004h inside an OSC title is not matched', () {
      final s = CsiModeScanner();
      expect(s.scan(b('\x1b]0;my title \x1b[?1004h fake\x07')), isNull);
    });

    test('literal [?1004h inside OSC payload with ST terminator', () {
      final s = CsiModeScanner();
      expect(
        s.scan(b('\x1b]133;C\x1b\\')), // keep parser warm
        isNull,
      );
      expect(s.scan(b('\x1b]2;nvim \x1b[?1004h\x1b\\')), isNull);
    });

    test('DCS payloads are skipped', () {
      final s = CsiModeScanner();
      expect(s.scan(b('\x1bP+x\x1b[?1004h\x1b\\')), isNull);
    });
  });

  group('chunk boundaries', () {
    test('sequence split mid-params still reports', () {
      for (var split = 1; split < '\x1b[?1004h'.length; split++) {
        final s = CsiModeScanner();
        final first = s.scan(b('\x1b[?1004h'.substring(0, split)));
        expect(first, isNull);
        expect(
          s.scan(b('\x1b[?1004h'.substring(split))),
          isTrue,
          reason: 'split at $split',
        );
      }
    });

    test('OSC split across chunks does not leak a false event', () {
      final s = CsiModeScanner();
      const seq = '\x1b]0;title with ?1004h inside\x07';
      final mid = seq.indexOf('1');
      expect(s.scan(b(seq.substring(0, mid))), isNull);
      expect(s.scan(b(seq.substring(mid))), isNull);
    });
  });

  group('osc99 and focus traffic in one stream', () {
    test('mixed sequences: notification then focus enable', () {
      final s = CsiModeScanner();
      expect(s.scan(b('\x1b]99;i=x:p=body:d=1;done\x1b\\\x1b[?1004h')), isTrue);
    });
  });
}
