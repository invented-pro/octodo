// Unit tests for the off-screen TUI capture's reply extraction —
// see lib/src/feishu/tui_reply_extract.dart. Pure text in, reply
// text out; the fixtures are synthetic full-screen renders (the
// layout opencode's TUI produces at capture size, plus generic
// variations other TUIs could produce).

import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/feishu/tui_reply_extract.dart';

void main() {
  group('extractTuiReply', () {
    test('returns the reply between our message and the composer',
        () async {
      final reply = extractTuiReply([
        ' opencode  ⟨build⟩  glm-5.3',
        '',
        '🧑 list the files',
        'here they are:',
        '  a.txt',
        '  b.txt',
        '🧑 status?',
        'All green — 2 files tracked, nothing dirty.',
        '',
        '┌─ composer ─────────────┐',
        '│ >                      │',
        '└────────────────────────┘',
        ' ? for shortcuts  128 tokens',
      ], 'status?');
      expect(reply, 'All green — 2 files tracked, nothing dirty.');
    });

    test('multi-line replies keep their paragraphs', () async {
      final reply = extractTuiReply([
        '🧑 explain both options',
        'Option A is simpler:',
        '  fewer moving parts, one binary.',
        '',
        'Option B is more flexible,',
        '  but needs a config file.',
        '┌─────────────────────────┐',
        '│ >                       │',
        '└─────────────────────────┘',
      ], 'explain both options');
      expect(reply, 'Option A is simpler:\n fewer moving parts, one '
          'binary.\n\nOption B is more flexible,\n but needs a config '
          'file.');
    });

    test('a wrapped message matches by its leading fragment', () async {
      final reply = extractTuiReply([
        '🧑 please review the auth refactor before I',
        '   continue',
        'Reviewed — two notes: the token cache never invalidates,',
        'and the retry loop lacks a backoff cap.',
        '┌─────────────────────────┐',
        '│ >                       │',
        '└─────────────────────────┘',
      ], 'please review the auth refactor before I continue');
      expect(reply, 'Reviewed — two notes: the token cache never '
          'invalidates,\nand the retry loop lacks a backoff cap.');
    });

    test('the newest occurrence of a repeated message wins', () async {
      final reply = extractTuiReply([
        '🧑 status?',
        'first answer',
        '🧑 status?',
        'second answer',
        '┌─────────────────────────┐',
        '│ >                       │',
        '└─────────────────────────┘',
      ], 'status?');
      expect(reply, 'second answer');
    });

    test('a message that is nowhere on screen yields null', () async {
      final reply = extractTuiReply([
        ' opencode  ⟨build⟩',
        '┌─ sessions ────────────┐',
        '│ ses_1  yesterday      │',
        '└───────────────────────┘',
      ], 'hello?');
      expect(reply, isNull,
          reason: 'a modal swallowed the text — the caller must not '
              'guess a reply');
    });

    test('footer hints and status lines under the composer are dropped',
        () async {
      final reply = extractTuiReply([
        '🧑 hi',
        'Hello!',
        '┌─────────────────────────┐',
        '│ >                       │',
        '└─────────────────────────┘',
        '',
        ' ? for shortcuts  sonnet-4  128 tokens  42%',
      ], 'hi');
      expect(reply, 'Hello!');
    });

    test('a rule inside the reply (markdown separator) is decoration '
        'and drops', () async {
      final reply = extractTuiReply([
        '🧑 compare',
        'A — fast',
        '────────',
        'B — safe',
        '┌─────────────────────────┐',
        '│ >                       │',
        '└─────────────────────────┘',
      ], 'compare');
      // Symbol-only rows carry no content — they are the TUI's own
      // decoration, whatever their position.
      expect(reply, 'A — fast\nB — safe');
    });

    test('oversized replies are capped with a truncation note',
        () async {
      final lines = <String>['🧑 dump everything'];
      for (var i = 0; i < 500; i++) {
        lines.add('line $i — ${'x' * 60}');
      }
      lines.addAll([
        '┌─────────────────────────┐',
        '│ >                       │',
        '└─────────────────────────┘',
      ]);
      final reply = extractTuiReply(lines, 'dump everything')!;
      expect(reply.length, lessThan(4000));
      expect(reply, endsWith('…(truncated — see TUI)'));
    });

    test('blank runs inside the reply collapse', () async {
      final reply = extractTuiReply([
        '🧑 go',
        'part one',
        '',
        '',
        '',
        'part two',
        '┌─────────────────────────┐',
        '│ >                       │',
        '└─────────────────────────┘',
      ], 'go');
      expect(reply, 'part one\n\npart two');
    });

    test('an empty reply block yields null, not an empty message',
        () async {
      final reply = extractTuiReply([
        '🧑 hello?',
        '┌─────────────────────────┐',
        '│ >                       │',
        '└─────────────────────────┘',
      ], 'hello?');
      expect(reply, isNull);
    });
  });

  group('extractTuiReply — opencode block layout', () {
    // The shapes opencode's TUI actually renders: USER, reasoning
    // and tool blocks carry the thick left rail, assistant text is
    // un-railed Glamour markdown, metadata footers open with a meta
    // glyph, and the whole thing sits between a header/tab strip
    // above and a status bar below.

    test('railed reasoning and tool blocks drop; assistant text stays',
        () async {
      final reply = extractTuiReply([
        ' opencode   normal·build·plan   tabs: 2', // header/tabs
        '',
        '┃  fix the login bug', // USER block (railed)
        '',
        '┃  The token cache never invalidates, so…', // reasoning
        '',
        '┃  Read  lib/auth.dart  8 lines', // tool call (railed)
        '┃  (no output)', // tool output (railed)
        '',
        'Fixed: the cache now invalidates on refresh.', // reply
        '',
        '▣ build · glm-5.3 · 4s', // metadata footer
        '',
        ' esc to interrupt   12/200K', // status bar
      ], 'fix the login bug');
      expect(reply, 'Fixed: the cache now invalidates on refresh.');
    });

    test(' Glamour code fences inside the reply survive, rails stripped',
        () async {
      final reply = extractTuiReply([
        '┃  show the config',
        '',
        'Set it like this:',
        '│ final port = 4096; │', // fence interior (light rails)
        '',
        '▣ build · glm-5.3 · 2s',
      ], 'show the config');
      expect(reply, 'Set it like this:\nfinal port = 4096;');
    });

    test('collapsed thought rows and spinner frames drop', () async {
      final reply = extractTuiReply([
        '┃  summarize',
        '+ Thought', // collapsed reasoning toggle
        '',
        '⠋ Thinking', // spinner frame (also a busy signal)
        '',
        'Two sentences, one idea.',
        '▣ build · glm-5.3 · 9s',
      ], 'summarize');
      expect(reply, 'Two sentences, one idea.');
    });

    test('runs of identical rows collapse to one', () async {
      final reply = extractTuiReply([
        '┃  run it',
        'ok',
        'ok',
        'ok',
        'done',
      ], 'run it');
      expect(reply, 'ok\ndone');
    });

    test('a wrapped USER block continuation is not mistaken for the reply',
        () async {
      final reply = extractTuiReply([
        '┃  please review the auth refactor',
        '┃  before I continue', // wrapped under the same rail
        '',
        'Reviewed — looks good.',
      ], 'please review the auth refactor before I continue');
      expect(reply, 'Reviewed — looks good.');
    });

    test('prose hard-wrapped at the render width re-joins', () async {
      // columns=100 → Glamour wraps at ~92; both rows fill that, so
      // they were one sentence before the TUI wrapped them.
      final long1 = 'a' * 92;
      final long2 = 'b' * 92;
      final reply = extractTuiReply([
        '┃  go',
        long1,
        long2,
        '',
        '▣ build · glm-5.3 · 2s',
      ], 'go', columns: 100);
      expect(reply, '$long1 $long2');
    });

    test('markdown structure keeps its line breaks under re-flow',
        () async {
      final full = 'x' * 92;
      final reply = extractTuiReply([
        '┃  go',
        full,
        '- bullet one', // starts a list item — never a continuation
        full,
        '## Heading', // starts a heading
      ], 'go', columns: 100);
      expect(reply, '$full\n- bullet one\n$full\n## Heading');
    });
  });

  group('opencode 2.x tab layout (field-captured shapes)', () {
    // The exact shapes a user's WSL opencode 2.x rendered: a tab
    // strip with SESSION titles instead of the brand header, thick
    // message rails, glyph-less metadata footers with tok/s, a
    // right sidebar with a scrollbar column, and the busy status
    // bar at the bottom.

    test('sniffAppFromScreen detects opencode without the brand', () {
      expect(
        sniffAppFromScreen([
          'Greeting                Greeting               ⠹ Greeting'
              '                  +',
          '  ┃',
          '  ┃  hi',
          '  ┃',
          '',
          '     Hi! 👋 I am here and ready.',
          '',
          '     Build · MiniMax-M3.1-Flash · 17.6s · 6.0 tok/s',
          '  ┃',
          '  ┃  hi there',
          '  ┃',
          ' ⬝⬝⬝■■■■■ esc interrupt'
              '                                7.0K (1%)  ctrl+p commands',
        ]),
        'opencode',
        reason: 'status-bar hints + structural rails must identify the '
            'app when tabs hide the brand',
      );
    });

    test('sniffAppFromScreen leaves other full-screen apps alone', () {
      expect(sniffAppFromScreen([
        '~/.config/octodo/src/main.rs',
        'pub fn main() {',
        '  println("hi") once;',
        '~                     1,1          All',
      ]), isNull);
      // An interrupt hint without opencode structure is not enough.
      expect(sniffAppFromScreen(['some app', ' esc to interrupt']), isNull);
    });

    test('the reply region comes out clean from a 2.x capture', () {
      final reply = extractTuiReply([
        'Greeting              Greeting             ⠹ Greeting'
            '                +',
        '  ┃',
        '  ┃  what is your name',
        '  ┃',
        '',
        '     I am GLM, an AI assistant.                          █',
        '                                                          █',
        '     Build · MiniMax-M3.1-Flash · 1.7s · 32.9 tok/s      █',
        '  ┃  Build · MiniMax-M3.1-Flash MiniMax Token Plan'
            ' (minimax.cn)',
        '  ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀'
            '▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀',
        ' ⬝⬝⬝■■■■■ esc interrupt'
            '                              7.0K (1%)  ctrl+p commands',
      ], 'what is your name');
      expect(reply, 'I am GLM, an AI assistant.',
          reason: 'rails, sidebar, scrollbar column, metadata, and the '
              'status bar all drop');
    });

    test('the glyph-less 2.x metadata footer is busy-free decoration',
        () {
      expect(screenShowsBusy([
        'Build · MiniMax-M3.1-Flash · 17.6s · 6.0 tok/s',
      ]), isFalse,
          reason: 'a finished message footer is not a busy indicator');
    });
  });

  group('screenShowsBusy / busySignature', () {    test('a spinner frame row means busy', () {
      expect(
        screenShowsBusy([
          '┃  go',
          '⠙ Thinking',
          ' esc to interrupt',
        ]),
        isTrue,
      );
    });

    test('an interrupt hint without a spinner means busy', () {
      expect(screenShowsBusy([' esc to interrupt   12/200K']), isTrue);
    });

    test('an idle screen (shortcuts hint, meters) is not busy', () {
      expect(screenShowsBusy([' ? for shortcuts   128 tokens']), isFalse);
    });

    test('prose that merely contains phase words is not busy', () {
      expect(screenShowsBusy(['Working with the registry took hours.']),
          isFalse);
    });

    test('the signature tracks the animating indicator', () {
      final a = busySignature(['⠋ Thinking']);
      final b = busySignature(['⠙ Thinking']);
      final c = busySignature(['⠙ Thinking']);
      expect(a, isNotNull);
      expect(a, isNot(b), reason: 'the spinner frame moved — still alive');
      expect(b, c, reason: 'frozen frame — the same signature repeats');
    });
  });

  group('captureHasMessage', () {
    test('true when the message is in the transcript', () {
      expect(
        captureHasMessage([
          ' opencode  ⟨build⟩',
          '🧑 status?',
          'All green.',
          '┌────────────────────────┐',
        ], 'status?'),
        isTrue,
      );
    });

    test('true when the message still sits in the composer', () {
      // A modal swallowed the Enter: the text is on screen but no
      // turn will start. Presence is still true — the caller needs
      // the empty-region signal to conclude "never submitted".
      expect(
        captureHasMessage([
          '┌─ sessions ────────────┐',
          '│ ses_1  yesterday      │',
          '└───────────────────────┘',
          '┌─ composer ─────────────┐',
          '│ > status?              │',
          '└────────────────────────┘',
        ], 'status?'),
        isTrue,
      );
    });

    test('false when the message is nowhere on screen', () {
      expect(
        captureHasMessage([
          ' opencode  ⟨build⟩',
          '┌─ sessions ────────────┐',
          '│ ses_1  yesterday      │',
          '└───────────────────────┘',
        ], 'status?'),
        isFalse,
      );
    });
  });

  group('replyRegionTail', () {
    test('keeps the last readable lines below the message', () {
      final tail = replyRegionTail([
        '🧑 status?',
        'All green — 2 files tracked.',
        '',
        'Run `octodo status` for details.',
        '',
        '┌─ composer ─────────────┐',
        '│ >                      │',
        '└────────────────────────┘',
        ' ? for shortcuts',
      ], 'status?');
      expect(tail, [
        'All green — 2 files tracked.',
        'Run `octodo status` for details.',
      ]);
    });

    test('caps at [max] lines from the end', () {
      final tail = replyRegionTail([
        '🧑 summarize',
        'line 1',
        'line 2',
        'line 3',
        'line 4',
        'line 5',
        'line 6',
        'line 7',
        '┌────────────────────────┐',
        '│ >                      │',
        '└────────────────────────┘',
      ], 'summarize', max: 3);
      expect(tail, ['line 5', 'line 6', 'line 7']);
    });

    test('empty when the message is not on screen', () {
      expect(
        replyRegionTail(['nothing here'], 'status?'),
        isEmpty,
      );
    });
  });
}
