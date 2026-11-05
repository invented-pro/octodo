// Standalone long-connection probe (debugging only, not part of
// the app): connects with the stored credentials, prints EVERY
// inbound WebSocket message — full hex + decode attempt with the
// exact FormatException — so a frame our codec chokes on can be
// replayed offline as a regression vector.
//
//   dart run tool/feishu_probe.dart [seconds]
//
// Does NOT ack: Feishu will retry the event to the real app later.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:octodo/src/feishu/pbbp_frame.dart';

Future<void> main(List<String> args) async {
  final seconds = int.tryParse(args.isEmpty ? '' : args.first) ?? 240;
  final credsFile = File(
      '${Platform.environment['USERPROFILE']}${Platform.pathSeparator}'
      '.config${Platform.pathSeparator}Octodo${Platform.pathSeparator}'
      'feishu${Platform.pathSeparator}credentials.json');
  final creds = jsonDecode(credsFile.readAsStringSync()) as Map<String, dynamic>;
  final appId = creds['appId'] as String;
  final appSecret = creds['appSecret'] as String;
  final domain = creds['tenantBrand'] == 'lark'
      ? 'https://open.larksuite.com'
      : 'https://open.feishu.cn';

  print('[probe] endpoint request…');
  final resp = await http.post(Uri.parse('$domain/callback/ws/endpoint'),
      headers: {'locale': 'zh'},
      body: jsonEncode({'AppID': appId, 'AppSecret': appSecret}));
  print('[probe] endpoint ${resp.statusCode}: ${resp.body}');
  final body = jsonDecode(resp.body) as Map<String, dynamic>;
  final data = body['data'] as Map<String, dynamic>?;
  if (body['code'] != 0 || data == null) {
    print('[probe] endpoint refused, aborting');
    exit(1);
  }
  final config = data['ClientConfig'];
  if (config is Map<String, dynamic>) {
    print('[probe] ClientConfig: $config');
  }
  final url = Uri.parse(data['URL'] as String);
  final service = int.tryParse(url.queryParameters['service_id'] ?? '') ?? 0;
  print('[probe] connecting service=$service …');

  final ws = await WebSocket.connect(url.toString());
  print('[probe] CONNECTED');
  final ping = Timer.periodic(const Duration(seconds: 30),
      (_) => ws.add(PbbpFrame.ping(service).encode()));

  final sub = ws.listen((msg) {
    if (msg is! List<int>) {
      print('[probe] non-binary message: $msg');
      return;
    }
    final bytes = Uint8List.fromList(msg);
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    print('[probe] ── inbound ${bytes.length} bytes');
    print('[probe] hex: $hex');
    try {
      final f = PbbpFrame.decode(bytes);
      print('[probe] DECODED OK: seq=${f.seqId} log=${f.logId} '
          'service=${f.service} method=${f.method}');
      for (final h in f.headers) {
        print('[probe]   header ${h.key} = ${h.value}');
      }
      if (f.payload != null) {
        print('[probe]   payload(${f.payload!.length}B): '
            '${utf8.decode(f.payload!, allowMalformed: true)}');
      }
    } on FormatException catch (e) {
      print('[probe] DECODE FAILED: ${e.message}');
      print('[probe] raw-as-text: '
          '${utf8.decode(bytes, allowMalformed: true)}');
    } catch (e) {
      print('[probe] UNEXPECTED ERROR: $e');
    }
  }, onDone: () => print('[probe] socket closed by server'));

  await Future<void>.delayed(Duration(seconds: seconds));
  print('[probe] time up, closing');
  await sub.cancel();
  ping.cancel();
  await ws.close();
  exit(0);
}
