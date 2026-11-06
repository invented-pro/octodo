import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/feishu/feishu_greetings.dart';

void main() {
  test('greeting store roundtrip and error tolerance', () async {
    final dir = Directory.systemTemp.createTempSync('feishu_greetings');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}${Platform.pathSeparator}greeted.json');
    final store = FeishuGreetingStore(file);

    // Missing file means "no chats greeted".
    expect(await store.load(), isEmpty);

    await store.save({'oc_b', 'oc_a'});
    expect(await store.load(), {'oc_a', 'oc_b'});

    // A broken file degrades to "no chats greeted" — persistence
    // must never break the chat.
    await file.writeAsString('{not json');
    expect(await store.load(), isEmpty);
  });
}
