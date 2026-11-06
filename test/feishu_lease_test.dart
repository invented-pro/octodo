import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/feishu/feishu_lease.dart';

void main() {
  late Directory root;
  late Directory lockDir;

  setUp(() {
    root = Directory.systemTemp.createTempSync('feishu_lease');
    lockDir = Directory('${root.path}${Platform.pathSeparator}lock');
    addTearDown(() => root.deleteSync(recursive: true));
  });

  test('acquire on an empty machine wins and writes the owner file',
      () async {
    final lease = FeishuConnectionLease(lockDir, pid: 111);
    final result = lease.tryAcquire();
    expect(result.acquired, isTrue);
    expect(lockDir.existsSync(), isTrue);
    final owner = File(
        '${lockDir.path}${Platform.pathSeparator}owner.json');
    expect(owner.readAsStringSync(), contains('111'));
  });

  test('a second instance loses and learns the holder', () async {
    FeishuConnectionLease(lockDir, pid: 111).tryAcquire();
    final second = FeishuConnectionLease(lockDir, pid: 222);
    final result = second.tryAcquire();
    expect(result.acquired, isFalse);
    expect(result.holderPid, 111);
  });

  test('re-acquire while leading wins (refresh, no second claim)',
      () async {
    final lease = FeishuConnectionLease(lockDir, pid: 111);
    expect(lease.tryAcquire().acquired, isTrue);
    expect(lease.tryAcquire().acquired, isTrue);
  });

  test('release deletes the lock and lets the next instance win',
      () async {
    final first = FeishuConnectionLease(lockDir, pid: 111)
      ..tryAcquire();
    first.release();
    expect(lockDir.existsSync(), isFalse);

    final second = FeishuConnectionLease(lockDir, pid: 222);
    expect(second.tryAcquire().acquired, isTrue);
  });

  test('release never touches a foreign lease', () async {
    FeishuConnectionLease(lockDir, pid: 111).tryAcquire();
    // A standby instance calling release (e.g. unbind while
    // standby) must leave the holder's directory alone.
    FeishuConnectionLease(lockDir, pid: 222).release();
    expect(lockDir.existsSync(), isTrue);
    expect(
      File('${lockDir.path}${Platform.pathSeparator}owner.json')
          .readAsStringSync(),
      contains('111'),
    );
  });

  test('a stale heartbeat is taken over', () async {
    final dead = FeishuConnectionLease(lockDir, pid: 111,
        staleAfter: const Duration(milliseconds: 40));
    expect(dead.tryAcquire().acquired, isTrue);

    // The holder dies hard — no release, no heartbeats.
    await Future<void>.delayed(const Duration(milliseconds: 80));

    final next = FeishuConnectionLease(lockDir, pid: 222,
        staleAfter: const Duration(milliseconds: 40));
    final result = next.tryAcquire();
    expect(result.acquired, isTrue);
    expect(next.inspectHolder(), isNull, reason: 'we are the holder');
  });

  test('a fresh heartbeat from another pid is respected', () async {
    final first = FeishuConnectionLease(lockDir, pid: 111,
        staleAfter: const Duration(seconds: 30));
    expect(first.tryAcquire().acquired, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    final second = FeishuConnectionLease(lockDir, pid: 222,
        staleAfter: const Duration(seconds: 30));
    expect(second.tryAcquire().acquired, isFalse);
  });

  test('renew fails and fences once the lease names another pid',
      () async {
    final first = FeishuConnectionLease(lockDir, pid: 111,
        heartbeatEvery: const Duration(milliseconds: 20),
        staleAfter: const Duration(seconds: 30));
    expect(first.tryAcquire().acquired, isTrue);

    var lost = false;
    first.onLost = () => lost = true;

    // Another instance claims (e.g. this one was declared stale
    // while suspended and someone took over).
    final second = FeishuConnectionLease(lockDir, pid: 222);
    // Force the claim by writing a fresh foreign owner record.
    File('${lockDir.path}${Platform.pathSeparator}owner.json')
        .writeAsStringSync('{"pid": 222, "heartbeat": '
            '${DateTime.now().millisecondsSinceEpoch}}');

    expect(first.renew(), isFalse, reason: 'fenced: pid mismatch');
    expect(lost, isTrue);
    expect(second.renew(), isTrue);
  });

  test('inspectHolder reports a fresh foreign holder only', () async {
    final first = FeishuConnectionLease(lockDir, pid: 111,
        staleAfter: const Duration(seconds: 30));
    expect(first.tryAcquire().acquired, isTrue);
    expect(first.inspectHolder(), isNull, reason: 'we hold it');

    // A takeover by another instance flips the owner record.
    File('${lockDir.path}${Platform.pathSeparator}owner.json')
        .writeAsStringSync('{"pid": 222, "heartbeat": '
            '${DateTime.now().millisecondsSinceEpoch}}');
    expect(first.inspectHolder(), 222);
  });
}
