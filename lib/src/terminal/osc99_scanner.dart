// Dart-side scanner for the kitty desktop-notification protocol
// (OSC 99), extracted from the raw PTY byte stream.
//
// ## Why this exists
//
// opencode's TUI (via @opentui/core) delivers its "attention"
// notifications — question needs input, permission needs input,
// session error, session done — using the kitty OSC 99 protocol,
// *not* OSC 9 / OSC 777. The Rust engine's OSC pre-parser only
// extracts OSC 7 / 9 / 777; every other OSC is copied through and
// silently dropped by vte's `unhandled` path. Without this scanner
// those notifications simply vanish. Same seam as [Osc7Scanner] and
// [Osc133Scanner]: scan the same bytes the engine sees (in
// `TerminalView._flushOutput`, before feeding the engine).
//
// ## Protocol summary (kitty desktop notifications)
//
//   `ESC ] 99 ; <metadata> ; <payload> BEL|ST`
//
// metadata is `:`-separated `key=value` groups (keys are single
// letters). Relevant keys:
//
//   * `i=<id>`  — notification identifier; payloads with the same id
//                 are concatenated until a `d=1` (done) payload.
//   * `p=<type>` — payload type: `title` (default), `body`, `close`,
//                 or `?` (capability probe).
//   * `d=<0|1>` — 0 = more payloads follow; 1 (the default) =
//                 notification is complete.
//   * `e=1`     — payload is base64-encoded UTF-8.
//
// The capability probe (`p=?`, sent by OpenTUI at startup) expects a
// reply on the app's stdin:
//
//   `ESC ] 99 ; i=<id> : p=? ; p=title,body : o=always ST`
//
// Without that reply OpenTUI treats the terminal as not supporting
// the protocol. [Osc99ProbeReply.reply] builds it.
//
// ## Chunk-boundary handling
//
// PTY output arrives in arbitrary chunks, so a sequence may straddle
// a chunk boundary anywhere. The carry-buffer approach mirrors
// [Osc7Scanner]: a partial sequence is retained (bounded by
// [_maxPayload]) and stitched with the next chunk.
library;

import 'dart:convert';
import 'dart:typed_data';

/// One parsed OSC 99 sequence.
sealed class Osc99Event {
  const Osc99Event();
}

/// The app is probing protocol support. [identifier] is the `i=`
/// value (may be empty when the app sent none).
final class Osc99Probe extends Osc99Event {
  const Osc99Probe({required this.identifier});
  final String identifier;
}

/// A notification payload arrived. [done] is false when `d=0`
/// (more payloads follow for this identifier); true otherwise.
final class Osc99Payload extends Osc99Event {
  const Osc99Payload({
    required this.identifier,
    required this.isTitle,
    required this.done,
    required this.text,
  });
  final String identifier;
  final bool isTitle;
  final bool done;
  final String text;
}

/// The app asked to close the notification [identifier]
/// (`p=close`).
final class Osc99Close extends Osc99Event {
  const Osc99Close({required this.identifier});
  final String identifier;
}

/// Builds the terminal reply to an OSC 99 `p=?` capability probe.
///
/// Advertises the payload types Octodo consumes (`title`, `body`)
/// and that notifications are honored `always` (the hub's own
/// suppression decides whether the user actually sees a banner —
/// honoring "always" keeps the protocol honest: we *accept* the
/// request at the terminal layer).
abstract final class Osc99ProbeReply {
  static List<int> reply(String identifier) {
    final id = identifier.isEmpty ? '' : 'i=$identifier:';
    final seq = '\x1b]99;${id}p=?;p=title,body:o=always\x1b\\';
    // utf8 (not ascii): the probe's i= identifier is remote-controlled
    // input and may contain code units > 127, which ascii.encode
    // rejects with an ArgumentError that would escape into the PTY
    // output flush path. Identical bytes for ASCII identifiers.
    return utf8.encode(seq);
  }
}

class Osc99Scanner {
  /// Maximum payload length accepted (matches the engine's
  /// `MAX_PAYLOAD`; kitty allows up to 4096 encoded bytes).
  static const int _maxPayload = 4096;

  /// Bytes of an in-flight (possibly partial) sequence carried
  /// across chunk boundaries.
  final List<int> _pending = [];

  /// The OSC 99 introducer: `ESC ] 9 9 ;`.
  static const List<int> _intro = [0x1b, 0x5d, 0x39, 0x39, 0x3b];

  /// Scan [chunk] for complete OSC 99 sequences and return the
  /// parsed events. Sequences split across chunks are stitched via
  /// the carry buffer.
  List<Osc99Event> scan(Uint8List chunk) {
    final Uint8List data;
    if (_pending.isEmpty) {
      data = chunk;
    } else {
      data = Uint8List.fromList([..._pending, ...chunk]);
      _pending.clear();
    }

    final events = <Osc99Event>[];
    var i = 0;
    while (true) {
      final start = _findIntro(data, i);
      if (start < 0) {
        _carryIntroPrefix(data);
        return events;
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
        return events;
      }
      final payloadLen = end - (start + _intro.length);
      if (payloadLen <= _maxPayload) {
        final raw = utf8.decode(
          data.sublist(start + _intro.length, end),
          allowMalformed: true,
        );
        final event = _parse(raw);
        if (event != null) events.add(event);
      }
      i = end + termLen;
    }
  }

  /// Parse one complete OSC 99 body (everything the scanner retained
  /// after the `99 ;` introducer).
  ///
  /// Grammar: `<metadata> ; <payload>`. Exactly one `;` separates
  /// them (metadata groups are `:`-joined and cannot contain `;`);
  /// the payload is plain UTF-8 and *may* contain `;`, so the split
  /// is at the first `;` only.
  static Osc99Event? _parse(String body) {
    final semi = body.indexOf(';');
    final metaPart = semi < 0 ? body : body.substring(0, semi);
    final text = semi < 0 ? '' : body.substring(semi + 1);

    var identifier = '';
    var payloadType = 'title'; // kitty default
    var done = true; // kitty default d=1
    var base64Encoded = false;
    if (metaPart.isNotEmpty) {
      for (final group in metaPart.split(':')) {
        if (group.length < 2 ||
            !_isAlpha(group.codeUnitAt(0)) ||
            group.codeUnitAt(1) != 0x3d /* '=' */ ) {
          continue; // unrecognized group — skip, keep defaults
        }
        final key = group[0];
        final value = group.substring(2);
        switch (key) {
          case 'i':
            identifier = value;
          case 'p':
            payloadType = value;
          case 'd':
            done = value != '0';
          case 'e':
            base64Encoded = value == '1';
        }
      }
    }
    var decodedText = text;
    if (base64Encoded && decodedText.isNotEmpty) {
      try {
        decodedText = utf8.decode(
          base64.decode(decodedText),
          allowMalformed: true,
        );
      } on FormatException {
        // Malformed base64 — treat as plain text.
      }
    }

    switch (payloadType) {
      case '?':
        return Osc99Probe(identifier: identifier);
      case 'close':
        return Osc99Close(identifier: identifier);
      case 'body':
        return Osc99Payload(
          identifier: identifier,
          isTitle: false,
          done: done,
          text: decodedText,
        );
      default: // 'title' and anything unrecognized
        return Osc99Payload(
          identifier: identifier,
          isTitle: true,
          done: done,
          text: decodedText,
        );
    }
  }

  static bool _isAlpha(int c) =>
      (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a);

  /// Index of the next `\x1b]99;` introducer at or after [from], or
  /// -1.
  static int _findIntro(Uint8List data, int from) {
    for (var i = from; i + _intro.length <= data.length; i++) {
      if (data[i] == 0x1b &&
          data[i + 1] == 0x5d &&
          data[i + 2] == 0x39 &&
          data[i + 3] == 0x39 &&
          data[i + 4] == 0x3b) {
        return i;
      }
    }
    return -1;
  }

  /// If [data] ends with a strict prefix of the introducer, retain
  /// it so a sequence whose introducer straddles the chunk boundary
  /// is still recognized next scan.
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
