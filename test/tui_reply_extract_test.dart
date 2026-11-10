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

    test('a rule inside the reply (markdown separator) survives', () async {
      final reply = extractTuiReply([
        '🧑 compare',
        'A — fast',
        '────────',
        'B — safe',
        '┌─────────────────────────┐',
        '│ >                       │',
        '└─────────────────────────┘',
      ], 'compare');
      // The table rule sits mid-reply (not within the bottom chrome
      // window) and stays.
      expect(reply, 'A — fast\n────────\nB — safe');
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
