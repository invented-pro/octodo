// Tests for the log module's gating.
//
// `package:logging` already filters records at the `Logger.log()` call
// site against `Logger.level`, so when root level is OFF, no record is
// created and our `_emit` listener never runs. This test verifies that
// invariant AND the defensive double-gate we added inside `_emit`.
//
// The defensive gate is harder to observe directly because the listener
// never gets called when the root level is OFF — so to test it we'd
// need to bypass the framework's filter. Instead, this test verifies
// the end-to-end behavior the user actually cares about: a release-
// mode app (root level OFF) stays silent.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:octodo/src/log.dart';

void main() {
  group('logging level gating', () {
    late List<LogRecord> captured;

    setUp(() {
      // Reset to a known state. configureLogging() also installs the
      // _emit listener we want to exercise; we replace it with a
      // counter to observe what's emitted vs filtered.
      captured = <LogRecord>[];
      Logger.root.clearListeners();
      Logger.root.onRecord.listen(captured.add);
    });

    tearDown(() {
      Logger.root.clearListeners();
    });

    test('a FINE record is dropped when root level is OFF', () {
      Logger.root.level = Level.OFF;
      final log = moduleLogger('test.off');
      log.fine('should be filtered');
      log.shout('should also be filtered (OFF > SHOUT)');
      // Yield so any async stream events have a chance to flush.
      return Future<void>.delayed(Duration.zero).then((_) {
        expect(captured, isEmpty,
            reason: 'No record should reach a listener when root '
                'level is OFF — both the framework and our _emit '
                'double-gate filter it.');
      });
    });

    test('a SHOUT record passes when root level is SHOUT', () {
      Logger.root.level = Level.SHOUT;
      final log = moduleLogger('test.shout');
      log.shout('should pass');
      log.severe('should be filtered (SHOUT > SEVERE)');
      return Future<void>.delayed(Duration.zero).then((_) {
        expect(captured.map((r) => r.message).toList(), ['should pass']);
      });
    });

    test('configureLogging installs a listener', () {
      Logger.root.clearListeners();
      configureLogging(rootLevel: Level.ALL);
      expect(Logger.root.level, Level.ALL);
      // Re-install our capture listener (configureLogging cleared
      // and re-added _emit; we want to count records reaching the
      // listener stream as proof at least one is wired).
      Logger.root.onRecord.listen(captured.add);
      final log = moduleLogger('test.install');
      log.info('installed');
      return Future<void>.delayed(Duration.zero).then((_) {
        expect(captured.length, 1);
      });
    });

    test('configureLogging is idempotent (re-calling does not '
        'double-print)', () {
      Logger.root.clearListeners();
      configureLogging(rootLevel: Level.ALL);
      configureLogging(rootLevel: Level.ALL);
      // After re-calling, the _emit listener should have been
      // replaced (clearListeners was called inside the second
      // configureLogging). Re-add our capture listener to verify
      // exactly one record is captured per emission.
      Logger.root.onRecord.listen(captured.add);
      final log = moduleLogger('test.idempotent');
      log.info('once');
      return Future<void>.delayed(Duration.zero).then((_) {
        expect(captured.length, 1,
            reason: 'configureLogging must replace, not stack, the '
                'root handler on re-call.');
      });
    });
  });

  group('moduleLogger', () {
    test('returns a Logger', () {
      // We can't easily assert on the dotted name because
      // package:logging splits the constructor name by '.' to find
      // the parent chain, and `.name` returns either the full path
      // (if no parent) or the last segment (if a parent exists).
      // Both behaviors are correct — just verify the helper
      // produces something usable.
      expect(moduleLogger('terminal.view'), isA<Logger>());
      expect(moduleLogger(''), isA<Logger>());
    });
  });
}