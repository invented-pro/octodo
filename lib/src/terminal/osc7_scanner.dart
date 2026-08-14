import 'dart:convert';
import 'dart:typed_data';

/// Dart-side scanner that extracts OSC 7 cwd reports
/// (`ESC ] 7 ; file://host/path ST`) from the raw PTY byte stream.
///
/// ## Why a second OSC 7 channel exists at all
///
/// The Rust engine (`rust_lib_flutter_alacritty`) extracts OSC 7 via a
/// pre-parser (`osc_preparse.rs`) before handing bytes to the vte parser.
/// That pre-parser has an early-termination bug: any OSC whose parameter is
/// not 7 / 9 / 777 — most notably the OSC 2 / OSC 1 *title* sequences that
/// oh-my-zsh's `termsupport` emits around every zsh prompt, or shell-
/// integration OSC 133 marks — is handled as
/// `Passthrough { end: len }`, which copies through **and stops scanning
/// the remainder of the batch**. Any OSC 7 later in the same batch is
/// therefore never extracted and is silently dropped by vte's `unhandled`
/// path. Empirically this kills every post-`cd` OSC 7 in a zsh + omz
/// prompt cycle (the spawn-time emission survives only because it happens
/// to precede the first OSC 2 in its batch).
///
/// Rather than patching the prebuilt engine crate, we scan the same bytes
/// on the Dart side (in `TerminalView._flushOutput`, before feeding the
/// engine) and drive the identical `onPwdChanged` path. Payloads are
/// reported exactly as the engine would report them (the raw
/// `file://host/path` string — no percent-decoding, matching the Rust
/// `String::from_utf8_lossy` behavior); callers run [stripFileUri] on
/// them. Duplicate reports (engine + scanner both firing, e.g. at shell
/// spawn) are collapsed by the caller's last-value check.
///
/// ## Chunk-boundary handling
///
/// PTY output arrives in arbitrary chunks, so a sequence may straddle a
/// chunk boundary anywhere: inside the 4-byte introducer (`ESC ] 7 ;`),
/// inside the payload, or inside the 2-byte ST terminator (`ESC \`).
/// The scanner keeps a small carry buffer ([_pending]) of at most
/// [_maxPayload] bytes; a carry larger than that is discarded as garbage
/// (mirroring the engine's `MAX_PAYLOAD` guard against unbounded memory).
class Osc7Scanner {
  /// Maximum payload length accepted (matches the engine's `MAX_PAYLOAD`).
  static const int _maxPayload = 4096;

  /// Bytes of an in-flight (possibly partial) sequence carried across
  /// chunk boundaries — either an introducer prefix (`ESC ]`, `ESC ] 7`,
  /// `ESC ] 7 ;`) or an introducer + partial payload awaiting its
  /// terminator.
  final List<int> _pending = [];

  /// The OSC 7 introducer: `ESC ] 7 ;` (0x1b 0x5d 0x37 0x3b).
  static const List<int> _intro = [0x1b, 0x5d, 0x37, 0x3b];

  /// Scan [chunk] for complete OSC 7 sequences and return their payloads.
  ///
  /// Any trailing bytes that could be the start of a sequence continued in
  /// the next chunk are retained internally; call [scan] with each chunk in
  /// arrival order. Payloads are UTF-8 decoded lossily, matching the
  /// engine's behavior.
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
      // Scan for the terminator (BEL, or ST = ESC \) after the introducer.
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
        // No terminator yet — carry the partial sequence, bounded.
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

  /// Index of the next `\x1b]7;` introducer at or after [from], or -1.
  static int _findIntro(Uint8List data, int from) {
    for (var i = from; i + _intro.length <= data.length; i++) {
      if (data[i] == 0x1b &&
          data[i + 1] == 0x5d &&
          data[i + 2] == 0x37 &&
          data[i + 3] == 0x3b) {
        return i;
      }
    }
    return -1;
  }

  /// If [data] ends with a strict prefix of the introducer (`ESC`,
  /// `ESC ]`, `ESC ] 7`), retain it so a sequence whose introducer straddles
  /// the chunk boundary is still recognized next scan.
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
