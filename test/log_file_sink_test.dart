// Tests for the WARNING+ rotating file sink (`attachLogFileSink`).
//
// The sink is the shipped-build diagnostics path: console output is
// compiled to silence in release, so the file is the only place a
// user-reported fallback (e.g. a stale `terminal.defaultShell`) leaves
// a trace. These tests pin the three properties that make it safe to
// run unconditionally in `main()`:
//
//   1. level gating — only WARNING+ records reach the file;
//   2. bounded rotation — `octodo.log` keeps the *newest* records,
//      `octodo.log.1` the previous generation, disk stays ~2× cap;
//   3. never-throws — an unwritable location detaches the sink
//      instead of taking the app down.
//
// package:logging delivers records asynchronously (broadcast stream
// controller), so every test pumps the event queue before reading
// files — the same yield `log_test.dart` does.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/log.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late Logger log;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('octodo_log_sink_test');
    // ALL/OFF keeps debugPrint quiet for records the file sink writes
    // and lets every level through to the root stream.
    configureLogging(rootLevel: Level.ALL, consoleLevel: Level.OFF);
    log = moduleLogger('test.file_sink');
  });

  tearDown(() {
    Logger.root.clearListeners();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {
      // Windows sometimes holds a handle for a moment; the temp dir
      // is cleaned up by the OS eventually.
    }
  });

  File sinkFile(String name) => File(p.join(tmp.path, name));

  testWidgets('writes WARNING+ records, skips lower levels', (tester) async {
    final file = sinkFile('octodo.log');
    final detach = attachLogFileSink(file);
    addTearDown(detach);

    log.fine('fine message');
    log.info('info message');
    log.warning('warning message');
    log.severe('severe message');
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    expect(file.existsSync(), isTrue, reason: 'created on first match');
    final text = file.readAsStringSync();
    expect(text, contains('WARNING'));
    expect(text, contains('warning message'));
    expect(text, contains('SEVERE'));
    expect(text, contains('severe message'));
    expect(text, contains('octodo.test.file_sink'),
        reason: 'the logger name is what makes a user-reported log '
            'actionable — it names the module that fell back');
    expect(text, isNot(contains('fine message')));
    expect(text, isNot(contains('info message')));
  });

  testWidgets('includes the error object when present', (tester) async {
    final file = sinkFile('octodo.log');
    final detach = attachLogFileSink(file);
    addTearDown(detach);

    log.warning('probe failed', 'error detail');
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    expect(file.readAsStringSync(), contains('error=error detail'));
  });

  testWidgets('respects a custom level (default is WARNING)', (tester) async {
    final file = sinkFile('octodo.log');
    final detach = attachLogFileSink(file, level: Level.SEVERE);
    addTearDown(detach);

    log.warning('filtered at custom level');
    log.severe('kept at custom level');
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    final text = file.readAsStringSync();
    expect(text, contains('kept at custom level'));
    expect(text, isNot(contains('filtered at custom level')));
  });

  testWidgets('rotates: newest records in the file, previous in .1, bounded',
      (tester) async {
    final file = sinkFile('octodo.log');
    // Cap chosen so a single ~100-byte record fits but two don't.
    final detach = attachLogFileSink(file, maxBytes: 160);
    addTearDown(detach);

    for (var i = 0; i < 6; i++) {
      log.warning('rotation message $i');
    }
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    final rotated = File('${file.path}.1');
    expect(rotated.existsSync(), isTrue, reason: 'at least one rotation');
    final current = file.readAsStringSync();
    final previous = rotated.readAsStringSync();
    // The newest record always lands in the live file...
    expect(current, contains('rotation message 5'));
    // ...and both generations stay bounded by the cap plus one record
    // of overshoot (rotation fires on the record *after* the cap is
    // reached, and timestamps vary a few bytes with microsecond
    // precision).
    expect(file.lengthSync(), lessThan(160 + 250));
    expect(rotated.lengthSync(), lessThan(160 + 250));
    // The .1 generation holds older records and not the newest one.
    expect(previous, contains('rotation message'));
    expect(previous, isNot(contains('rotation message 5')));
  });

  testWidgets('detach stops the sink and releases the file', (tester) async {
    final file = sinkFile('octodo.log');
    final detach = attachLogFileSink(file);

    log.warning('before detach');
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    detach();
    log.warning('after detach');
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    final text = file.readAsStringSync();
    expect(text, contains('before detach'));
    expect(text, isNot(contains('after detach')));
    // Detach is idempotent.
    detach();
  });

  testWidgets('does not create the file until a matching record arrives',
      (tester) async {
    final file = sinkFile('octodo.log');
    final detach = attachLogFileSink(file);
    addTearDown(detach);

    log.fine('not a match');
    log.info('not a match either');
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    expect(file.existsSync(), isFalse,
        reason: 'a clean run must not churn a log file into existence');
  });

  testWidgets('an unwritable location detaches silently instead of throwing',
      (tester) async {
    // A regular file where the sink wants a directory: every createSync
    // / openSync on the sink path throws FileSystemException.
    final blocker = sinkFile('blocker')..writeAsStringSync('not a dir');
    final file = File(p.join(blocker.path, 'octodo.log'));
    final detach = attachLogFileSink(file);

    // Must not throw — neither on attach nor on the first record.
    log.warning('this write cannot succeed');
    log.severe('nor can this one');
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    expect(blocker.readAsStringSync(), 'not a dir',
        reason: 'the blocker is untouched');
    detach();
  });

  testWidgets('survives rotation when .1 must be replaced', (tester) async {
    final file = sinkFile('octodo.log');
    // Pre-stage a stale .1 so rotation's delete+rename path runs.
    File('${file.path}.1').writeAsStringSync('stale generation');
    final detach = attachLogFileSink(file, maxBytes: 160);
    addTearDown(detach);

    for (var i = 0; i < 4; i++) {
      log.warning('replace stale $i');
    }
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    expect(file.readAsStringSync(), contains('replace stale 3'));
    expect(File('${file.path}.1').readAsStringSync(),
        isNot(contains('stale generation')));
  });
}
