// Reply extraction for the Feishu router's off-screen TUI capture
// ("resize to read"): the terminal briefly grows its PTY under a
// frozen view, a private clone engine renders the TUI's FULL screen
// (the whole conversation), and this module turns that raw grid text
// into the assistant's reply.
//
// The reply contract matches the clean server path (see
// opencode_client.dart): ONLY the assistant's final text. Thinking/
// reasoning, tool calls and their output, message metadata, and all
// chrome — header/tab/session rows above the transcript, status
// bars/footer hints below it — are excluded. Two cheap generic
// rules run before any app-specific parsing: rows that carry no
// letters at all (borders, rules, dots, spinner padding) are pure
// decoration and drop out directly, and runs of adjacent identical
// rows (layout padding, blank/separator filler) collapse to one.
//
// TUI-agnostic by design: the block rules below work on generic
// full-screen-app layouts — a transcript where the user's message
// appears somewhere, the reply after it, and chrome around and
// between. Per-app refinements (opencode's thick block rails, its
// `▣ mode · model · duration` metadata footers) are expressed as
// row shapes, not app brands.
//
// Quality bar: the reply is terminal-rendered text, so markdown is
// approximate (reflowed at the TUI's width, syntax colors lost —
// colors never reach the grid text anyway). Good enough to answer;
// the TUI itself stays the source of truth on screen.

/// Spinner and progress animation runes — a row carrying one of
/// these is a live working indicator, not content.
const String _kSpinnerRunes = '⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏⠛⠟⠯⠷⠿⡿⢿⣟⣿'
    '◐◓◑◒◄▼◀▲▶▪▫○●□◘◙';

/// Structural block rails — the thick/double left border opencode
/// puts on USER, reasoning and tool blocks (LipGloss thick/double
/// borders). Glamour code fences use the light `│` rail instead,
/// which is decoration, not a block marker.
const String _kStructRails = '┃║▐';

/// Message metadata footer glyphs (`▣ mode · model · duration`).
const String _kMetaGlyphs = '▣▪■▸▶◄▫◻◼';

/// Extract the reply that follows the user's [sentMessage] in a
/// full-screen TUI's rendered [lines] (top row first, trailing
/// blanks already trimmed by the grid reader). [columns], when
/// known, lets prose hard-wrapped at the terminal width be re-joined
/// into paragraphs.
///
/// Returns null when [sentMessage] does not appear — the strongest
/// signal that the text never reached the app (a modal held the
/// keyboard), which the caller reports honestly instead of guessing.
String? extractTuiReply(List<String> lines, String sentMessage,
    {int? columns}) {
  final norm = _prePass(lines);
  final sent = _locateSentMessage(norm, sentMessage);
  if (sent == null) return null;
  final region = _dedent(_replyRegion(norm, sent, sentMessage));
  return _tidy(_reflow(region, columns));
}

/// Does the capture show the user's message at all? False means the
/// text never made it into the transcript or the composer — a modal
/// held the keyboard and no reply will ever follow, which the caller
/// reports immediately instead of waiting out the cap.
bool captureHasMessage(List<String> lines, String sentMessage) {
  return _locateSentMessage(_prePass(lines), sentMessage) != null;
}

/// The last readable lines of the region below the user's message —
/// the diagnostic tail sent when a reply could not be extracted
/// before the stall window (better than leaving the chat silent).
/// Cleaned by the same rules as the reply itself. Empty when the
/// message is not on screen or nothing readable follows it.
List<String> replyRegionTail(List<String> lines, String sentMessage,
    {int max = 5}) {
  final norm = _prePass(lines);
  final sent = _locateSentMessage(norm, sentMessage);
  if (sent == null) return const [];
  final region = _dedent(_replyRegion(norm, sent, sentMessage))
      .where((l) => l.isNotEmpty);
  final readable = region.toList();
  return readable.length <= max
      ? readable
      : readable.sublist(readable.length - max);
}

/// Remove the reply block's UNIFORM leading padding (Glamour pads
/// the whole assistant block a few columns in) while preserving
/// relative indentation — nested lists and code keep their extra
/// depth.
List<String> _dedent(List<String> lines) {
  var min = 1 << 30;
  for (final line in lines) {
    if (line.trim().isEmpty) continue;
    final pad = line.length - line.trimLeft().length;
    if (pad < min) min = pad;
  }
  if (min == 0 || min == 1 << 30) return lines;
  return [for (final line in lines) line.length >= min ? line.substring(min) : line];
}

/// Does the screen show the TUI still working on a turn? While a
/// model streams, the app animates a spinner and/or shows an
/// interrupt hint in its footer; either one means the turn is alive
/// — silence on the byte stream means nothing by itself.
bool screenShowsBusy(List<String> lines) => busySignature(lines) != null;

/// A fingerprint of the busy indicators on screen — the spinner row,
/// the interrupt hint, the live token counter. Two captures with
/// DIFFERENT signatures a moment apart mean the indicator is still
/// animating (a live turn); an unchanged one means it froze (a
/// wedged app). Null when the screen shows no busy indicator at all.
String? busySignature(List<String> lines) {
  final hits = <String>[];
  for (final line in lines) {
    final t = line.trim();
    if (t.isEmpty) continue;
    if (_isBusyRow(t)) hits.add(t);
  }
  return hits.isEmpty ? null : hits.join('\n');
}

bool _isBusyRow(String t) {
  if (_kSpinnerRunes.contains(String.fromCharCode(t.runes.first))) {
    return true;
  }
  if (RegExp(r'\besc\b.{0,24}\b(interrupt|cancel|stop)\b',
          caseSensitive: false)
      .hasMatch(t)) {
    return true;
  }
  // A near-standalone phase word ("Thinking…", "Working ...") —
  // prose rows that merely START with these words stay content.
  if (t.length <= 24 &&
      RegExp(r'^(thinking|working|queued|generating)\b[\s.…]*$',
              caseSensitive: false)
          .hasMatch(t)) {
    return true;
  }
  return false;
}

/// Recognize the app a full-screen capture belongs to from its
/// shape. opencode's TUI is the one app with a registered server
/// adapter, so this only answers 'opencode' or null.
///
/// The brand in the header is the classic signal, but opencode 2.x
/// tabs replace the header with SESSION TITLES ("Greeting … +") —
/// field-observed — so the sniffer also reads the app's status bar
/// (esc interrupt / ctrl+p / tok/s) and confirms structurally
/// (thick `┃` message rails, `· 12.3s · 5.0 tok/s` metadata rows).
/// A status hint alone is not enough (other agent TUIs show
/// interrupt hints); a structural confirmation must back it.
String? sniffAppFromScreen(List<String> lines) {
  var statusHit = false;
  var railed = 0;
  var metaHit = false;
  for (final line in lines) {
    if (line.toLowerCase().contains('opencode')) return 'opencode';
    if (_kSniffStatus.any((p) => p.hasMatch(line))) statusHit = true;
    if (_isStructRailRow(line)) railed++;
    if (_kSniffMetaFooter.hasMatch(_deScroll(line))) metaHit = true;
  }
  if (statusHit && (railed >= 2 || metaHit)) return 'opencode';
  return null;
}

/// A row with the right-edge scrollbar column removed — several
/// checks (metadata footers) must see through it.
String _deScroll(String line) =>
    line.trimRight().replaceFirst(_kScrollBarTail, '').trimRight();

/// opencode status-bar hints.
final List<RegExp> _kSniffStatus = [
  RegExp(r'\besc\s+interrupt\b', caseSensitive: false),
  RegExp(r'\bctrl\+p\b'),
  RegExp(r'\d+(\.\d+)?\s*tok/s'),
];

/// The per-message metadata footer, with or without the leading
/// glyph: `▣ build · glm-5.3 · 4s` (older) or
/// `Build · MiniMax-M3.1-Flash · 17.6s · 6.0 tok/s` (2.x tabs,
/// field-observed). The trailing duration(+rate) with `·`
/// separators is the signature; prose never ends that way.
final RegExp _kSniffMetaFooter =
    RegExp(r'^\S.*·\s*\d+(\.\d+)?s(\s*·\s*[\d.]+\s*tok/s)?\s*$');

// ── Row classification ─────────────────────────────────────────

/// A row with no letters, digits, or CJK/emoji-letters anywhere —
/// borders, rules, dots, rail-only padding. Pure decoration: it
/// carries no content and drops out directly. Blank rows are NOT
/// decoration (they separate paragraphs) and stay.
bool _isSymbolOnly(String line) {
  final t = line.trim();
  if (t.isEmpty) return false;
  for (final r in t.runes) {
    if (isAlnumRune(r)) return false;
  }
  return true;
}

/// Letters, digits, and other script runes (CJK, kana, Hangul) —
/// the runes that make a row "content".
bool isAlnumRune(int r) {
  return (r >= 0x30 && r <= 0x39) || // digits
      (r >= 0x41 && r <= 0x5A) || // A-Z
      (r >= 0x61 && r <= 0x7A) || // a-z
      (r >= 0x00C0 && r <= 0x024F) || // Latin-1 letters + Latin ext
      (r >= 0x0370 && r <= 0x1FFF) || // Greek … archaic (incl. CJK rad.)
      (r >= 0x3040 && r <= 0xD7FF) || // CJK, kana, Hangul
      (r >= 0xF900 && r <= 0xFDCF); // CJK compat ideographs
}

/// A run of adjacent identical rows collapses to one — layout
/// padding and blank/separator filler shrink, and repeated chrome
/// rows cannot masquerade as a wall of content.
List<String> _collapseIdentical(List<String> lines) {
  final out = <String>[];
  for (final line in lines) {
    if (out.isNotEmpty && out.last == line) continue;
    out.add(line);
  }
  return out;
}

/// The generic pre-pass every capture goes through: normalize
/// whitespace, drop symbol-only rows, collapse identical neighbors.
List<String> _prePass(List<String> lines) => _collapseIdentical([
      for (final line in lines)
        if (!_isSymbolOnly(line)) line.trimRight().replaceAll(_kSpaceRun, ' '),
    ]);

/// A message-metadata footer row — the per-assistant-message
/// footer (`▣ build · glm-5.3 · 4s`, or the glyph-less 2.x form
/// `Build · MiniMax-M3.1-Flash · 17.6s · 6.0 tok/s`). See
/// [_kSniffMetaFooter] for why the trailing duration(+rate) shape
/// is trusted.
bool _isMetaFooter(String line) {
  final t = _deScroll(line).trim();
  if (t.length < 2) return false;
  final first = String.fromCharCode(t.runes.first);
  if (_kMetaGlyphs.contains(first) && t.contains('·')) return true;
  return _kSniffMetaFooter.hasMatch(t);
}

/// Status-bar / footer-hint rows: shortcut hints, interrupt hints,
/// token and context counters. Tight by design — these fire inside
/// the bottom-chrome walk, where a false hit would eat the reply's
/// last content rows, so prose-shaped rows never match.
final List<RegExp> _kStatusRowPatterns = [
  RegExp(r'for shortcuts', caseSensitive: false),
  RegExp(r'\besc\b.{0,24}\b(interrupt|cancel|stop)\b', caseSensitive: false),
  RegExp(r'\b(tokens?|context)\b\s*[:·]?\s*\d', caseSensitive: false),
  RegExp(r'\d[\d.,]*\s*[kK]?\s*(tokens?|context)\b', caseSensitive: false),
  RegExp(r'\d[\d.,]*\s*[kK]?\s*/\s*\d[\d.,]*\s*[kK]?\b'), // 12/200K meters
  RegExp(r'\d+(\.\d+)?\s*[KMkm]?\s*\(\d+%\)'), // 7.0K (1%) context meter
  RegExp(r'\bctrl\+p\b'),
];

bool _isStatusRow(String line) {
  final t = line.trim();
  if (t.isEmpty) return false;
  for (final p in _kStatusRowPatterns) {
    if (p.hasMatch(t)) return true;
  }
  return _isBusyRow(t);
}

/// A structural block row: the thick/double rail that marks USER,
/// reasoning and tool blocks. Glamour code fences ride on the light
/// `│` rail and are NOT structural.
bool _isStructRailRow(String line) {
  final t = line.trimLeft();
  if (t.isEmpty) return false;
  final first = String.fromCharCode(t.runes.first);
  return _kStructRails.contains(first);
}

/// A collapsed thought/tool toggle row (`+ Thought`, `- Details`).
bool _isToggleRow(String line) {
  return RegExp(r'^[+-]\s*(thought|details|output|tools?)\b',
          caseSensitive: false)
      .hasMatch(line.trim());
}

// ── Region assembly ────────────────────────────────────────────

/// Whitespace runs — grid text can carry runs from double-width
/// glyph joins and layout padding.
final RegExp _kSpaceRun = RegExp(r'[ \t\u00a0]+');

/// The content rows of the reply: everything after the user's
/// message block, minus the footer chrome block at the bottom and
/// minus the excluded block kinds (reasoning, tool, metadata).
List<String> _replyRegion(List<String> norm, int sent, String sentMessage) {
  // The message wraps at the TUI's width: skip the lines that carry
  // its remainder (fragments of the message text), so they are not
  // mistaken for the reply. Block rails are stripped first — a
  // wrapped continuation under a rail is still the message.
  var start = sent + 1;
  for (var skips = 0; start < norm.length && skips < 6; skips++) {
    final bare = _stripRails(norm[start]).trim();
    if (bare.isEmpty) break; // the user block ended
    if (!sentMessage.contains(bare)) break;
    start++;
  }
  final tail = _dropBottomChrome(norm.sublist(start));
  // Mid-region, only structural exclusions fire — status/metadata
  // prose shapes are too easy to false-positive on real content, so
  // everything else the transcript shows between our message and
  // the footer is kept (rails stripped). Spinner animation frames
  // are the one exception: they are never prose. Rows that merely
  // echo our own message (a composer draft that never submitted)
  // are not a reply either.
  return [
    for (final line in tail)
      if (!_isStructRailRow(line) &&
          !_isMetaFooter(line) &&
          !_isToggleRow(line) &&
          !_isSpinnerRow(line))
        _stripRails(line),
  ].where((line) {
    final bare = line.trim();
    return bare.isEmpty ? true : !sentMessage.contains(bare);
  }).toList();
}

/// A row that opens with a spinner/progress rune — an animation
/// frame, not content.
bool _isSpinnerRow(String line) {
  final t = line.trimLeft();
  if (t.isEmpty) return false;
  return _kSpinnerRunes.contains(String.fromCharCode(t.runes.first));
}

/// Strip structural and decorative edge rails (with their padding)
/// from a row: `┃  text` → `text`, `│ code │` → `code`, and the
/// scrollbar block-glyph column that bleeds onto the right edge of
/// every row (`text            █` → `text`). Rows without an edge
/// rail keep their indentation — it is content (markdown nests,
/// code).
String _stripRails(String line) {
  var t = line;
  // Leading rail + padding.
  var lead = t.trimLeft();
  var first = lead.isEmpty ? '' : String.fromCharCode(lead.runes.first);
  if (first.isNotEmpty &&
      (_kStructRails.contains(first) || first == '│')) {
    t = lead.substring(first.length).trim();
  }
  // Trailing scrollbar blocks (and padding), then padding + rail.
  t = t.trimRight().replaceFirst(_kScrollBarTail, '');
  final trail = t.trimRight();
  final last = trail.isEmpty ? '' : String.fromCharCode(trail.runes.last);
  if (last.isNotEmpty &&
      (_kStructRails.contains(last) || last == '│')) {
    t = trail.substring(0, trail.length - last.length).trim();
  }
  return t;
}

/// A trailing run of scrollbar/progress block glyphs — the right
/// edge column some TUI sidebars paint across the whole screen.
final RegExp _kScrollBarTail = RegExp(r'[█▄▀▌▐░▒┆┇┊┋]+$');

/// Box-drawing frames and rules: a line made only of these (plus
/// blanks) is chrome — pane borders, the composer frame, separators.
const String _kBoxChars = '─│┌┐└┘├┤┬┴┼═║╔╗╚╝╠╣╦╩╬╌╍┄┅┈┉━┃┏┓┗┛┣┫┳┻╺╻╸╹';

bool _isBorderLine(String line) {
  final bare = line.replaceAll(' ', '');
  if (bare.isEmpty) return false;
  for (final r in bare.runes) {
    if (!_kBoxChars.contains(String.fromCharCode(r))) return false;
  }
  return true;
}

/// A line inside the composer frame: framed, with a blank, prompt
/// (`>`), or title (`composer`, `editor`, …) interior. Other
/// letter-bearing framed rows are NOT chrome — Glamour code fences
/// inside the reply share the shape (`│ code │`), and losing the
/// reply's last fence to the chrome walk is worse than keeping a
/// draft row, which the message-echo filter in [_replyRegion]
/// removes anyway.
bool _isComposerInterior(String line) {
  final t = line.trim();
  if (t.length < 2) return false;
  final first = String.fromCharCode(t.runes.first);
  final last = String.fromCharCode(t.runes.last);
  if (!_kBoxChars.contains(first) || !_kBoxChars.contains(last)) {
    return false;
  }
  final inner = t.substring(1, t.length - 1);
  final text = inner.replaceAll(_kBoxAndRule, '').trim();
  if (text.isEmpty || text.startsWith('>')) return true;
  return RegExp(r'^(composer|editor|prompt|input|message)$',
          caseSensitive: false)
      .hasMatch(text);
}

/// Box-drawing runes that carry no interior text — frame edges,
/// rules, connectors.
final RegExp _kBoxAndRule = RegExp('[─│┌┐└┘├┤┬┴┼═║╔╗╚╝╠╣╦╩╬╌╍┄┅┈┉━┃ ]');

/// Drop the trailing chrome block: walk up from the bottom over
/// everything that cannot be reply content — blanks, borders,
/// framed interiors (the composer), status/metadata rows — until a
/// real content row ends the walk. No distance cap: a tall footer
/// (frame + editor + hints + meters) is dropped whole, while a rule
/// INSIDE the reply (a markdown table row, a code fence) ends the
/// walk because it sits on content.
List<String> _dropBottomChrome(List<String> lines) {
  var i = lines.length - 1;
  while (i >= 0 && _isBottomChrome(lines[i])) {
    i--;
  }
  return lines.sublist(0, i + 1);
}

bool _isBottomChrome(String line) {
  return line.trim().isEmpty ||
      _isBorderLine(line) ||
      _isComposerInterior(line) ||
      _isMetaFooter(line) ||
      _isStatusRow(line);
}

/// Find the LAST line carrying the start of the user's message —
/// the newest turn in the transcript. The message wraps at the
/// TUI's width, so only a leading fragment can be matched reliably.
/// Railed rows (opencode's USER blocks) win over plain matches: a
/// reply that echoes the question would otherwise anchor the region
/// at itself and starve.
int? _locateSentMessage(List<String> norm, String sentMessage) {
  final needle = _leadingFragment(sentMessage);
  if (needle.isEmpty) return null;
  int? plain;
  for (var i = norm.length - 1; i >= 0; i--) {
    if (!norm[i].contains(needle)) continue;
    if (_isStructRailRow(norm[i])) return i;
    plain ??= i;
  }
  return plain;
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

/// Re-join prose the TUI hard-wrapped at its render width: when a
/// row fills the width (Glamour wraps a few columns short of it)
/// and the next row reads as a mid-sentence continuation, they were
/// one paragraph. Rows that start a markdown structure keep their
/// line break; code fences were never wrapped in the first place.
List<String> _reflow(List<String> lines, int? columns) {
  if (columns == null || columns < 20) return lines;
  final wrapWidth = columns - 8; // Glamour's word-wrap margin
  final out = <String>[];
  for (final line in lines) {
    final prev = out.isEmpty ? null : out.last;
    if (prev != null &&
        prev.isNotEmpty &&
        line.isNotEmpty &&
        prev.length >= wrapWidth &&
        _isContinuation(line)) {
      out[out.length - 1] = '$prev $line';
      continue;
    }
    out.add(line);
  }
  return out;
}

/// A row that continues the previous sentence: starts lowercase (or
/// with closing punctuation) and does not open a markdown structure.
bool _isContinuation(String line) {
  if (RegExp(r'^[a-z,;)\]»>…]').hasMatch(line)) {
    // `>` only counts as continuation as closing punctuation context
    // is rare; a leading `>` is markdown quote, not continuation.
    if (line.startsWith('>')) return false;
    return true;
  }
  return false;
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
