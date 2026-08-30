// Dart-side scanner that extracts shell-integration OSC 133 marks
// (`ESC ] 133 ; <mark>[; <arg>] ST`) from the raw PTY byte stream.
//
// ## Why a Dart-side scanner (same reason as Osc7Scanner)
//
// The Rust engine's OSC pre-parser only extracts OSC 7 / 9 / 777; every
// other OSC — including the 133 marks emitted by the shell hooks Octodo
// injects (`terminal_workspace.dart`) or by the user's own shell
// integration (VS Code, WezTerm, iTerm2 scripts define the same
// protocol) — is copied through to the vte parser and silently dropped
// by its `unhandled` path. Scanning the same bytes on the Dart side (in
// `TerminalView._flushOutput`, before feeding the engine) is the seam
// that makes the marks visible without patching the prebuilt engine.
//
// ## Marks reported
//
//   * `C`   — command execution started (prompt → running). Used to
//             timestamp the start of a task.
//   * `D`   — command finished. The payload carries the exit status:
//             `D;0`, `D;127`, …
//   * `A`/`B` (prompt start / input start) are also extracted so future
//     features (prompt-aware scrollback, "last command" selection) can
//     consume them; the notification state machine ignores them today.
//
// Payloads are reported verbatim (mark + optional `;arg`); callers
// parse. Chunk-boundary handling mirrors [Osc7Scanner]: a carry buffer
// retains a partial sequence across PTY chunks, bounded by the same
// 4096-byte payload guard the engine uses.
library;

import 'dart:convert';
import 'dart:typed_data';

class Osc133Scanner {
  /// Maximum payload length accepted (matches the engine's `MAX_PAYLOAD`).
  static const int _maxPayload = 4096;

  /// Bytes of an in-flight (possibly partial) sequence carried across
  /// chunk boundaries.
  final List<int> _pending = [];

  /// The OSC 133 introducer: `ESC ] 1 3 3 ;`
  /// (0x1b 0x5d 0x31 0x33 0x33 0x3b).
  static const List<int> _intro = [0x1b, 0x5d, 0x31, 0x33, 0x33, 0x3b];

  /// Scan [chunk] for complete OSC 133 sequences and return their
  /// payloads (e.g. `'C'`, `'D;0'`). Sequences split across chunks are
  /// stitched via the carry buffer.
  List<String> scan(Uint8List chunk) {
    final Uint8List data;
    if (_pending.isEmpty) {
      data = chunk;
    } else {
      data = Uint8List.fromList([..._pending, ...chunk]);
      _pending.clear();
    }

    final payloads = <String>[];
    var i = 0;
    while (true) {
      final start = _findIntro(data, i);
      if (start < 0) {
        _carryIntroPrefix(data);
        return payloads;
      }
      var j = start + _intro.length;
      int? end;
      var termLen = 0;
      while (j < data.length) {
        final b = data[j];
        if (b == 0x07) {
          end = j;
          termLen = 1;
          break;
        }
        if (b == 0x1b && j + 1 < data.length && data[j + 1] == 0x5c) {
          end = j;
          termLen = 2;
          break;
        }
        j++;
      }
      if (end == null) {
        final partial = data.length - start;
        if (partial <= _maxPayload + _intro.length + 2) {
          _pending.addAll(data.sublist(start));
        }
        return payloads;
      }
      final payloadLen = end - (start + _intro.length);
      if (payloadLen <= _maxPayload) {
        final payloadBytes = data.sublist(start + _intro.length, end);
        payloads.add(utf8.decode(payloadBytes, allowMalformed: true));
      }
      i = end + termLen;
    }
  }

  /// Index of the next `\x1b]133;` introducer at or after [from], or -1.
  static int _findIntro(Uint8List data, int from) {
    for (var i = from; i + _intro.length <= data.length; i++) {
      var match = true;
      for (var k = 0; k < _intro.length; k++) {
        if (data[i + k] != _intro[k]) {
          match = false;
          break;
        }
      }
      if (match) return i;
    }
    return -1;
  }

  /// If [data] ends with a strict prefix of the introducer, retain it
  /// so a sequence whose introducer straddles the chunk boundary is
  /// still recognized next scan.
  void _carryIntroPrefix(Uint8List data) {
    final maxCheck = data.length < _intro.length - 1
        ? data.length
        : _intro.length - 1;
    for (var len = maxCheck; len > 0; len--) {
      var match = true;
      for (var k = 0; k < len; k++) {
        if (data[data.length - len + k] != _intro[k]) {
          match = false;
          break;
        }
      }
      if (match) {
        _pending.addAll(data.sublist(data.length - len));
        return;
      }
    }
  }
}
