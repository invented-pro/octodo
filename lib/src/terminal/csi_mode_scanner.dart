// Dart-side scanner that detects Focus Reporting (DECSET 1004)
// enable/disable requests in the raw PTY byte stream.
//
// ## Why this exists
//
// TUI frameworks that follow the terminal focus-reporting protocol
// (XT1004) — opencode via @opentui/core, Neovim, kitty-aware apps —
// write `CSI ? 1004 h` to ask the terminal to report focus changes,
// and expect `CSI I` (focus-in) / `CSI O` (focus-out) on their
// stdin whenever the focus actually changes. The alacritty engine
// parses mode 1004 into its internal `TermMode::FOCUS_IN_OUT` flag
// but — like the alacritty app's own event loop, which owns this in
// the real terminal — the *host* must observe the request and drive
// the reports. Without reports, OpenTUI's attention system keeps
// its focus state at `"unknown"` and silently drops every
// notification it would otherwise deliver.
//
// The engine answers the `DECRQM` probe (`CSI ? 1004 $ p`) itself,
// so apps already believe the terminal supports the mode; this
// scanner is the other half — recognizing the `h`/`l` requests so
// `TerminalView` knows when to emit `CSI I` / `CSI O`.
//
// ## Parsing
//
// A tiny state machine walks the byte stream: OSC (`ESC ] … BEL|ST`)
// and DCS/ APC/ PM (`ESC P|X|^|_ … ST`) payloads are skipped so a
// literal `[?1004h` inside e.g. a window title can't false-positive;
// CSI sequences (`ESC [` <params> <final byte>) are collected and,
// when private (`?`-prefixed) with a final byte of `h`/`l`, checked
// for the parameter `1004`. Partial sequences at the end of a chunk
// are carried into the next scan.
library;

import 'dart:typed_data';

class CsiModeScanner {
  /// Non-zero when a partial sequence at the end of the previous
  /// chunk is still in flight (state != _idle). The carry is bounded
  /// by [_maxCarry] — beyond that the bytes are garbage and the
  /// machine resets (an unterminated OSC from a misbehaving app
  /// would otherwise wedge the scanner forever).
  final List<int> _pending = [];
  static const int _maxCarry = 4096;

  static const int _idle = 0;
  static const int _sawEsc = 1;
  static const int _csi = 2; // collecting ESC [ …
  static const int _osc = 3; // inside ESC ] …
  static const int _oscSawEsc = 4; // ESC inside OSC (maybe ST)
  static const int _str = 5; // inside ESC P/X/^/_ … (DCS/PM/APC)
  static const int _strSawEsc = 6; // ESC inside a string sequence

  int _state = _idle;
  final List<int> _csiBuf = [];

  /// Scan [chunk]; returns `true` when a `CSI ? 1004 h` was seen,
  /// `false` when a `CSI ? 1004 l` was seen, `null` when the mode
  /// didn't change in this chunk. The *last* transition in the chunk
  /// wins.
  bool? scan(Uint8List chunk) {
    Uint8List data = chunk;
    if (_pending.isNotEmpty) {
      data = Uint8List.fromList([..._pending, ...chunk]);
      _pending.clear();
    }

    bool? result;
    var i = 0;
    while (i < data.length) {
      final b = data[i];
      switch (_state) {
        case _idle:
          if (b == 0x1b) {
            _state = _sawEsc;
          }
        case _sawEsc:
          if (b == 0x5b) {
            // '[' — CSI
            _state = _csi;
            _csiBuf.clear();
          } else if (b == 0x5d) {
            // ']' — OSC
            _state = _osc;
          } else if (b == 0x50 || b == 0x58 || b == 0x5e || b == 0x5f) {
            // DCS / SOS / PM / APC
            _state = _str;
          } else {
            // Two-byte escape (charset selection ESC ( X, ESC ) X,
            // ESC # X, …) — the next byte is a designator we can
            // treat as data.
            _state = _idle;
          }
        case _csi:
          if (b >= 0x40 && b <= 0x7e) {
            // Final byte — sequence complete.
            final transition = _evalCsi(_csiBuf, b);
            if (transition != null) result = transition;
            _state = _idle;
          } else if (b == 0x1b) {
            // Malformed: a new escape starts mid-CSI. Restart.
            _state = _sawEsc;
          } else if (b < 0x20 || b > 0x3f) {
            // Parameter bytes are 0x30–0x3F; anything else outside
            // the final range is garbage — drop the sequence.
            _state = _idle;
          } else {
            _csiBuf.add(b);
            if (_csiBuf.length > 64) _state = _idle;
          }
        case _osc:
          if (b == 0x07) {
            _state = _idle;
          } else if (b == 0x1b) {
            _state = _oscSawEsc;
          }
        case _oscSawEsc:
          if (b == 0x5c) {
            _state = _idle; // ST
          } else {
            // ESC inside OSC that isn't ST — keep skipping; a bare
            // ESC resets to OSC-saw-ESC state only for ST.
            _state = b == 0x1b ? _oscSawEsc : _osc;
          }
        case _str:
          if (b == 0x1b) {
            _state = _strSawEsc;
          }
        case _strSawEsc:
          if (b == 0x5c) {
            _state = _idle; // ST
          } else {
            _state = b == 0x1b ? _strSawEsc : _str;
          }
      }
      i++;
    }

    // Carry state across chunks: when mid-ESC or mid-CSI, retain the
    // partial bytes and restart the machine from idle so the
    // re-fed prefix re-enters the same path on the next scan.
    // OSC/STR states persist in the state machine itself (their
    // terminators are state-level) and need no byte carry.
    if (_state == _sawEsc || _state == _csi) {
      _pending.add(0x1b);
      if (_state == _csi) {
        _pending.add(0x5b);
        _pending.addAll(_csiBuf);
      }
      if (_pending.length > _maxCarry) {
        _pending.clear();
      }
      _csiBuf.clear();
      _state = _idle;
    }
    return result;
  }

  /// Evaluate a completed CSI sequence: private (`?`) DECSET/DECRST
  /// (`h`/`l`) whose parameters include `1004`.
  static bool? _evalCsi(List<int> params, int finalByte) {
    if (finalByte != 0x68 /* h */ && finalByte != 0x6c /* l */ ) {
      return null;
    }
    if (params.isEmpty || params[0] != 0x3f /* '?' */ ) return null;
    final paramStr = String.fromCharCodes(params.sublist(1));
    for (final p in paramStr.split(';')) {
      if (p == '1004') return finalByte == 0x68;
    }
    return null;
  }
}
