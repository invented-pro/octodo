// Reply extraction for the Feishu router's off-screen TUI capture
// ("resize to read"): the terminal briefly grows its PTY under a
// frozen view, a private clone engine renders the TUI's FULL screen
// (the whole conversation), and this module turns that raw grid text
// into the assistant's reply.
//
// TUI-agnostic by design: everything here works on generic
// full-screen-app layouts — a transcript where the user's message
// appears somewhere, the reply after it, and chrome (box-drawing
// frames, rules, status/footer lines) around and between. No app
// brand is load-bearing; per-app profiles can refine the heuristics
// later if field captures demand it.
//
// Quality bar: the reply is terminal-rendered text, so markdown is
// approximate (reflowed at the TUI's width, syntax colors lost —
// colors never reach the grid text anyway). Good enough to answer;
// the TUI itself stays the source of truth on screen.

/// Extract the reply that follows the user's [sentMessage] in a
/// full-screen TUI's rendered [lines] (top row first, trailing
/// blanks already trimmed by the grid reader).
///
/// Returns null when [sentMessage] does not appear — the strongest
/// signal that the text never reached the app (a modal held the
/// keyboard), which the caller reports honestly instead of guessing.
String? extractTuiReply(List<String> lines, String sentMessage) {
  final norm = _normalize(lines);
  final sent = _locateSentMessage(norm, sentMessage);
  if (sent == null) return null;

  // The message wraps at the TUI's width: skip the lines that carry
  // its remainder (fragments of the message text), so they are not
  // mistaken for the reply.
  var start = sent + 1;
  for (var skips = 0;
      start < norm.length &&
          skips < 4 &&
          norm[start].trim().isNotEmpty &&
          sentMessage.contains(norm[start].trim());
      skips++) {
    start++;
  }

  // The reply is what the app rendered between our message and the
  // bottom chrome (composer frame, status/footer lines).
  final tail = _dropBottomChrome(norm.sublist(start));
  return _tidy(tail);
}

/// Does the capture show the user's message at all? False means the
/// text never made it into the transcript or the composer — a modal
/// held the keyboard and no reply will ever follow, which the caller
/// reports immediately instead of waiting out the cap.
bool captureHasMessage(List<String> lines, String sentMessage) {
  return _locateSentMessage(_normalize(lines), sentMessage) != null;
}

/// The last readable lines of the region below the user's message —
/// the diagnostic tail sent when a reply could not be extracted
/// before the wait cap (better than leaving the chat silent). Empty
/// when the message is not on screen or nothing readable follows it.
List<String> replyRegionTail(List<String> lines, String sentMessage,
    {int max = 5}) {
  final norm = _normalize(lines);
  final sent = _locateSentMessage(norm, sentMessage);
  if (sent == null) return const [];
  // Same wrapped-continuation skip as [extractTuiReply].
  var start = sent + 1;
  for (var skips = 0;
      start < norm.length &&
          skips < 4 &&
          norm[start].trim().isNotEmpty &&
          sentMessage.contains(norm[start].trim());
      skips++) {
    start++;
  }
  final region = _dropBottomChrome(norm.sublist(start));
  final readable = region.where((l) => l.trim().isNotEmpty).toList();
  return readable.length <= max
      ? readable
      : readable.sublist(readable.length - max);
}

List<String> _normalize(List<String> lines) => [
      for (final line in lines) line.trimRight().replaceAll(_kSpaceRun, ' '),
    ];

/// Whitespace runs — grid text can carry runs from double-width
/// glyph joins and layout padding.
final RegExp _kSpaceRun = RegExp(r'[ \t\u00a0]+');

/// Find the LAST line carrying the start of the user's message —
/// the newest turn in the transcript. The message wraps at the
/// TUI's width, so only a leading fragment can be matched reliably.
int? _locateSentMessage(List<String> norm, String sentMessage) {
  final needle = _leadingFragment(sentMessage);
  if (needle.isEmpty) return null;
  for (var i = norm.length - 1; i >= 0; i--) {
    if (norm[i].contains(needle)) return i;
  }
  return null;
}

/// The longest word-boundary-bounded prefix of [message] that fits
/// [max] chars — short enough to survive wrapping, long enough not
/// to match random chrome.
String _leadingFragment(String message, {int max = 24}) {
  final words = message.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  var needle = '';
  for (final word in words) {
    final candidate = needle.isEmpty ? word : '$needle $word';
    if (candidate.length > max) break;
    needle = candidate;
  }
  if (needle.isEmpty && words.isNotEmpty) {
    final first = words.first;
    needle = first.length > max ? first.substring(0, max) : first;
  }
  return needle;
}

/// Box-drawing frames and rules: a line made only of these (plus
/// blanks) is chrome — pane borders, the composer frame, separators.
const String _kBoxChars = '─│┌┐└┘├┤┬┴┼═║╔╗╚╝╠╣╦╩╌╍┄┅┈┉';

bool _isBorderLine(String line) {
  final bare = line.replaceAll(' ', '');
  if (bare.isEmpty) return false;
  for (final r in bare.runes) {
    if (!_kBoxChars.contains(String.fromCharCode(r))) return false;
  }
  return true;
}

/// Drop the trailing chrome block: the bottom-most frame (the
/// composer outline or a footer rule) and everything under it
/// (footer hints, status lines). The cut starts at the TOP of that
/// frame block and only applies near the bottom — a rule inside the
/// reply (a markdown table row, a code fence) stays.
List<String> _dropBottomChrome(List<String> lines) {
  // The bottom-most border-only line within the last 12 lines
  // anchors the bottom frame block.
  for (var i = lines.length - 1; i >= 0 && i >= lines.length - 12; i--) {
    if (_isBorderLine(lines[i])) {
      // Walk up over the block: border lines, framed interiors
      // (`│ > │`, `┌─ composer ─┐`), and blanks — until real
      // content shows. Content ends the block; the cut starts there.
      var j = i;
      while (j >= 0) {
        final line = lines[j];
        if (_isBorderLine(line) || _isFramedInterior(line) ||
            line.trim().isEmpty) {
          j--;
          continue;
        }
        break;
      }
      return lines.sublist(0, j + 1);
    }
  }
  // No frame at the bottom (frameless TUI): keep everything — the
  // blank-run collapse in [_tidy] still applies.
  return lines;
}

/// A line inside a box frame: first and last visible chars are box
/// drawing (the side rails or the top/bottom edge, title included).
bool _isFramedInterior(String line) {
  final t = line.trim();
  if (t.length < 2) return false;
  final first = String.fromCharCode(t.runes.first);
  final last = String.fromCharCode(t.runes.last);
  return _kBoxChars.contains(first) && _kBoxChars.contains(last);
}

/// Trim blank edges, collapse blank runs to one, and cap the length
/// for one chat message. Null when nothing readable is left.
String? _tidy(List<String> lines) {
  final out = <String>[];
  var blanks = 0;
  for (final line in lines) {
    if (line.trim().isEmpty) {
      blanks++;
      if (blanks > 1) continue;
      out.add('');
      continue;
    }
    blanks = 0;
    out.add(line.trimRight());
  }
  while (out.isNotEmpty && out.first.trim().isEmpty) {
    out.removeAt(0);
  }
  while (out.isNotEmpty && out.last.trim().isEmpty) {
    out.removeLast();
  }
  if (out.isEmpty) return null;
  var text = out.join('\n');
  if (text.length > _kMaxReplyChars) {
    text = '${text.substring(0, _kMaxReplyChars)}\n…(truncated — see TUI)';
  }
  return text;
}

/// One chat message's worth of capture — the TUI on screen stays the
/// source of truth beyond this.
const int _kMaxReplyChars = 3500;
