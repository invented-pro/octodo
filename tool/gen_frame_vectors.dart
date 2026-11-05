// Regenerates test/feishu_frame_vectors.dart (and the constants in
// tool/feishu_decode_check.dart) from a feishu_probe.dart output
// capture — no hand transcription of hex strings.
//
//   dart run tool/gen_frame_vectors.dart <path-to-probe-output>

// ignore_for_file: avoid_print

import 'dart:io';

void main(List<String> args) {
  final src = args.isNotEmpty
      ? args.first
      : '${Platform.environment['USERPROFILE']}\\..\\..'; // guard
  final out = File(src).readAsStringSync();
  final pong =
      RegExp(r'inbound 497 bytes\r?\n\[probe\] hex: ([0-9a-f]+)').firstMatch(out);
  final event =
      RegExp(r'inbound 1294 bytes\r?\n\[probe\] hex: ([0-9a-f]+)').firstMatch(out);
  if (pong == null || event == null) {
    stderr.writeln('capture did not contain both frame sizes');
    exit(1);
  }
  final pongHex = pong.group(1)!;
  final eventHex = event.group(1)!;
  print('pong=${pongHex.length ~/ 2}B event=${eventHex.length ~/ 2}B');

  File('test/feishu_frame_vectors.dart').writeAsStringSync([
    '// Real pbbp2 frames captured from Feishu\'s long connection on',
    '// 2026-11-05 (tool/feishu_probe.dart), for codec regression.',
    '// The event frame\'s tail carries fields 20/21/22 whose tags are',
    '// two-byte varints — the exact shape that broke the codec when',
    '// it read tags as single bytes.',
    'const String kCapturedPongFrameHex =',
    "  '$pongHex';",
    '',
    'const String kCapturedEventFrameHex =',
    "  '$eventHex';",
    '',
  ].join('\n'));

  final checker = File('tool/feishu_decode_check.dart');
  if (checker.existsSync()) {
    checker.writeAsStringSync(checker.readAsStringSync()
        .replaceFirst(
            RegExp(r"const pongHex =\s*\n\s+'[0-9a-f]+';"),
            'const pongHex =\n    \'$pongHex\';')
        .replaceFirst(
            RegExp(r"const eventHex =\s*\n\s+'[0-9a-f]+';"),
            'const eventHex =\n    \'$eventHex\';'));
  }
  print('wrote test/feishu_frame_vectors.dart');
}
