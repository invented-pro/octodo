// TEMPORARY diagnostic — field bug: Feishu input never lands in the
// opencode TUI running in WSL (native Linux binary). Leading theory:
// octodo's engine answers the TUI's `CSI ? u` capability query with
// advertisedFlags=0x0F; opencode then enables the kitty keyboard
// protocol and may stop treating a raw CR as Enter — so the router's
// text+CR writes (writeToPtyPublic) stop submitting.
//
// Two variants against the SAME native binary:
//   A: no answer to `CSI ? u` (control — input worked in earlier runs)
//   B: answer `CSI ? 15 u` exactly like the app's KittyKeyboardProtocol
//
// Run explicitly:
//   $env:PATH = "<flutter_pty dll dir>;$env:PATH"
//   $env:OCTODO_PTY_DIAG = "1"; flutter test test/diag_pty_wsl_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter_alacritty/flutter_alacritty.dart' as fa;
import 'package:flutter_test/flutter_test.dart';

/// Escape control bytes so a console dump stays readable.
String esc(List<int> bytes) {
  final out = StringBuffer();
  for (final b in bytes) {
    if (b == 0x1b) {
      out.write('<ESC>');
    } else if (b == 0x0d) {
      out.write('<CR>');
    } else if (b == 0x0a) {
      out.write('<LF>\n');
    } else if (b < 0x20) {
      out.write('<${b.toRadixString(16)}>');
    } else {
      out.writeCharCode(b);
    }
  }
  return out.toString();
}

List<int> flatten(List<Uint8List> chunks) =>
    chunks.fold<List<int>>([], (a, b) => a..addAll(b));

Future<void> runVariant(WidgetTester tester,
    {required String name, required bool answerKitty,
    bool viaEngine = false}) async {
  await tester.runAsync(() async {
    final pty = fa.FlutterPtyBackend(
      rows: 30,
      columns: 100,
      shell: fa.ShellConfig(
        program: r'C:\Windows\System32\wsl.exe',
        args: ['-d', 'Debian', '-e', 'bash', '--login', '-i'],
      ),
    );
    final chunks = <Uint8List>[];
    var answered = false;

    // Variant C routes input through a real engine exactly like the
    // app: feedWithKitty answers capability queries and tracks flag
    // pushes; writes go through engine.write (the Rust roundtrip).
    // pty.output is single-subscription — one listener, like the
    // app's flush pipeline.
    fa.TerminalEngine? engine;
    StreamSubscription<Uint8List>? ptySub;
    if (viaEngine) {
      await fa.RustLib.init();
      engine = fa.TerminalEngine(config: fa.TerminalConfig.defaults());
      engine.output.listen(pty.write);
      engine.resize(columns: 100, rows: 30);
    }

    void writeInput(List<int> bytes) {
      if (viaEngine) {
        engine!.write(Uint8List.fromList(bytes));
      } else {
        pty.write(Uint8List.fromList(bytes));
      }
    }

    if (viaEngine) {
      final engine0 = engine!;
      ptySub = pty.output.listen((batch) {
        chunks.add(batch);
        engine0.feedWithKitty(batch);
      });
    } else {
      ptySub = pty.output.listen(chunks.add);
    }

    Future<bool> waitFor(bool Function(List<int> all) probe,
        {required Duration limit}) async {
      final deadline = DateTime.now().add(limit);
      while (DateTime.now().isBefore(deadline)) {
        if (probe(flatten(chunks))) return true;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      return false;
    }

    try {
      // 1. Shell comes up.
      await Future<void>.delayed(const Duration(seconds: 5));

      // 2. Launch the NATIVE binary the user's shell resolves.
      writeInput(utf8.encode('/home/s1/.opencode/bin/opencode\r'));

      // 3. Variant B/C: answer the capability query like the app.
      if (answerKitty && !viaEngine) {
        await waitFor((all) {
          // `CSI ? u` may straddle chunks; scan the accumulated bytes.
          for (var i = 0; i + 3 < all.length; i++) {
            if (all[i] == 0x1b && all[i + 1] == 0x5b && all[i + 2] == 0x3f &&
                all[i + 3] == 0x75) {
              return true;
            }
          }
          return false;
        }, limit: const Duration(seconds: 30));
        pty.write(Uint8List.fromList([0x1b, 0x5b, 0x3f, 0x31, 0x35, 0x75]));
        answered = true;
        // give the TUI a moment to push its flag set
        await Future<void>.delayed(const Duration(seconds: 2));
      }

      // 4. Wait for the TUI's alternate screen.
      final altUp = await waitFor((all) {
        for (var i = 0; i + 5 < all.length; i++) {
          if (all[i] == 0x1b &&
              all[i + 1] == 0x5b &&
              all[i + 2] == 0x3f &&
              all[i + 3] == 0x31 &&
              all[i + 4] == 0x30 &&
              all[i + 5] == 0x34 &&
              all[i + 6] == 0x39 &&
              all[i + 7] == 0x68) {
            return true;
          }
        }
        return false;
      }, limit: const Duration(seconds: 40));
      // ignore: avoid_print
      print('[$name] alt-screen seen: $altUp (kitty answered: '
          '$answered${viaEngine ? ", via engine" : ""})');
      await Future<void>.delayed(const Duration(seconds: 4));
      final atText = flatten(chunks).length;

      // 5. Type like the router does: text first, Enter ~150ms later.
      writeInput(utf8.encode('hello from octodo'));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      writeInput(utf8.encode('\r'));
      await Future<void>.delayed(const Duration(seconds: 6));

      // 6. Evidence: does 'hello' appear contiguously after typing?
      final tail = flatten(chunks).sublist(atText);
      final text = utf8.decode(tail, allowMalformed: true);
      final echo = text.contains('hello from octodo') ||
          text.contains('hello from oct') ||
          (text.contains('hello') && text.contains('octodo'));
      // ignore: avoid_print
      print('[$name] composer echo of typed text: $echo');
      // ignore: avoid_print
      print('[$name] === RAW TAIL (last 3000 bytes of ${tail.length}) ===');
      final dump = esc(tail);
      // ignore: avoid_print
      print(dump.length > 4000 ? dump.substring(dump.length - 4000) : dump);
      // ignore: avoid_print
      print('[$name] === END ===');
    } finally {
      await ptySub.cancel();
      pty.kill();
      engine?.dispose();
    }
  });
}

void main() {
  final live = Platform.environment['OCTODO_PTY_DIAG'] == '1';
  testWidgets('variant A: no kitty answer (control)',
      (tester) => runVariant(tester, name: 'A', answerKitty: false),
      timeout: const Timeout(Duration(minutes: 3)), skip: !live);
  testWidgets('variant B: answer CSI ? 15 u like the app',
      (tester) => runVariant(tester, name: 'B', answerKitty: true),
      timeout: const Timeout(Duration(minutes: 3)), skip: !live);
  testWidgets('variant C: full app path — engine answers kitty, input '
      'via engine.write', (tester) => runVariant(tester, name: 'C',
          answerKitty: false, viaEngine: true),
      timeout: const Timeout(Duration(minutes: 3)), skip: !live);
}
