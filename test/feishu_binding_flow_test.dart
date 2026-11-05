// State-machine tests for the QR binding flow. The device-flow
// client is faked (scripted poll responses + domain recording),
// sleeps are recorded instead of awaited, and the clock is virtual
// so the expiry branch is reachable without real time passing.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/feishu/feishu_binding_flow.dart';
import 'package:octodo/src/feishu/feishu_credentials.dart';
import 'package:octodo/src/feishu/feishu_device_flow_client.dart';

class _FakeDeviceFlowClient implements FeishuDeviceFlowClient {
  final List<String> pollDomains = [];
  final List<FeishuPollResult> pollResponses;
  int beginCount = 0;

  _FakeDeviceFlowClient(this.pollResponses);

  @override
  final Duration requestTimeout = const Duration(seconds: 30);

  @override
  String get feishuDomain => 'https://accounts.feishu.cn';

  @override
  String get larkDomain => 'https://accounts.larksuite.com';

  @override
  Future<FeishuDeviceFlowBegin> begin({String? domain}) async {
    beginCount++;
    // Uri.parse is not a const expression — no `const` here.
    return FeishuDeviceFlowBegin(
      deviceCode: 'dc_test',
      verificationUriComplete:
          Uri.parse('https://open.feishu.cn/connect/qr?user_code=xyz'),
      interval: Duration.zero, // exercises the 5 s default
      expiresIn: Duration.zero, // exercises the 10 min default
    );
  }

  int _pollIndex = 0;

  @override
  Future<FeishuPollResult> poll(String deviceCode, {String? domain}) async {
    pollDomains.add(domain ?? feishuDomain);
    final i = _pollIndex++;
    return i < pollResponses.length
        ? pollResponses[i]
        : const FeishuPollResult(error: 'authorization_pending');
  }

  @override
  void close() {}
}

class _FakeClock {
  DateTime value = DateTime.utc(2026, 1, 1);
  DateTime call() => value;
}

FeishuBindingFlow _flow({
  required _FakeDeviceFlowClient client,
  required FeishuCredentialStore store,
  required _FakeClock clock,
  List<Duration>? sleeps,
}) {
  return FeishuBindingFlow(
    client: client,
    credentialStore: store,
    // The sleep seam must yield to the event loop (like a real
    // delay would) — otherwise the polling loop runs as an
    // unbroken microtask chain and the tests' `Future.delayed`
    // timers can never interrupt it mid-flow.
    sleepOverride: (d) async {
      sleeps?.add(d);
      await Future<void>.delayed(Duration.zero);
    },
    nowOverride: clock.call,
  );
}

FeishuCredentialStore _tempStore() {
  final dir = Directory.systemTemp.createTempSync('feishu_flow_test');
  addTearDown(() => dir.deleteSync(recursive: true));
  return FeishuCredentialStore(
      File('${dir.path}${Platform.pathSeparator}credentials.json'));
}

void main() {
  test('happy path: pending → success saves credentials and connects',
      () async {
    final client = _FakeDeviceFlowClient([
      const FeishuPollResult(error: 'authorization_pending'),
      const FeishuPollResult(error: 'authorization_pending'),
      const FeishuPollResult(
        appId: 'cli_abc',
        appSecret: 'sec',
        openId: 'ou_owner',
        tenantBrand: 'feishu',
      ),
    ]);
    final store = _tempStore();
    final clock = _FakeClock();
    final sleeps = <Duration>[];
    final flow = _flow(
        client: client, store: store, clock: clock, sleeps: sleeps);

    final phases = <FeishuBindingPhase>[];
    flow.addListener(() => phases.add(flow.phase));

    await flow.start();

    expect(flow.phase, FeishuBindingPhase.connected);
    expect(phases, [
      FeishuBindingPhase.requestingCode,
      FeishuBindingPhase.waitingForScan,
      FeishuBindingPhase.connected,
    ]);
    // First poll fires immediately, later ones after the interval.
    expect(sleeps.length, 2);
    expect(sleeps.every((d) => d == const Duration(seconds: 5)), isTrue);
    // QR URL carries the SDK identity + compressed addons payload.
    final qr = flow.qrUri!;
    expect(qr.queryParameters['from'], 'sdk');
    expect(qr.queryParameters['tp'], 'sdk');
    expect(qr.queryParameters['source'], 'octodo-sdk');
    expect(qr.queryParameters['createOnly'], 'true');
    expect(qr.queryParameters['addons'], isNotEmpty);
    // Credentials persisted with the owner allowlisted.
    final saved = await store.load();
    expect(saved!.appId, 'cli_abc');
    expect(saved.ownerOpenId, 'ou_owner');
    expect(saved.allowedOpenIds, ['ou_owner']);
    expect(flow.credentials!.appIdPreview, startsWith('cli_'));
  });

  test('slow_down widens the interval by 5 s', () async {
    final client = _FakeDeviceFlowClient([
      const FeishuPollResult(error: 'slow_down'),
      const FeishuPollResult(error: 'authorization_pending'),
      const FeishuPollResult(appId: 'cli_x', appSecret: 's'),
    ]);
    final store = _tempStore();
    final sleeps = <Duration>[];
    final flow = _flow(
      client: client,
      store: store,
      clock: _FakeClock(),
      sleeps: sleeps,
    );

    await flow.start();

    // poll #1 comes back slow_down *before* the first sleep, so
    // every sleep already runs at the widened 10 s interval.
    expect(sleeps, [
      const Duration(seconds: 10),
      const Duration(seconds: 10),
    ]);
  });

  test('lark tenant re-targets the Lark domain and re-polls immediately',
      () async {
    final client = _FakeDeviceFlowClient([
      const FeishuPollResult(
        error: 'authorization_pending',
        tenantBrand: 'lark',
      ),
      const FeishuPollResult(
        appId: 'cli_l',
        appSecret: 's',
        openId: 'ou_l',
        tenantBrand: 'lark',
      ),
    ]);
    final sleeps = <Duration>[];
    final flow = _flow(
      client: client,
      store: _tempStore(),
      clock: _FakeClock(),
      sleeps: sleeps,
    );

    await flow.start();

    // poll #1 (feishu) reports a Lark scanner: the very next poll
    // goes to the Lark accounts domain with no sleep in between.
    expect(client.pollDomains, [
      'https://accounts.feishu.cn',
      'https://accounts.larksuite.com',
    ]);
    expect(flow.phase, FeishuBindingPhase.connected);
    expect(flow.credentials!.isLark, isTrue);
  });

  test('expired_token maps to the expired phase', () async {
    final client = _FakeDeviceFlowClient([
      const FeishuPollResult(
        error: 'expired_token',
        errorDescription: 'too late',
      ),
    ]);
    final flow = _flow(
      client: client,
      store: _tempStore(),
      clock: _FakeClock(),
    );

    await flow.start();

    expect(flow.phase, FeishuBindingPhase.expired);
    expect(flow.errorMessage, 'too late');
  });

  test('access_denied maps to the failed phase', () async {
    final client = _FakeDeviceFlowClient([
      const FeishuPollResult(
        error: 'access_denied',
        errorDescription: 'user said no',
      ),
    ]);
    final flow = _flow(
      client: client,
      store: _tempStore(),
      clock: _FakeClock(),
    );

    await flow.start();

    expect(flow.phase, FeishuBindingPhase.failed);
    expect(flow.errorCode, kFeishuFlowErrorAccessDenied);
    expect(flow.errorMessage, 'user said no');
  });

  test('deadline passing while sleeping expires the flow', () async {
    final client = _FakeDeviceFlowClient([
      const FeishuPollResult(error: 'authorization_pending'),
      const FeishuPollResult(error: 'authorization_pending'),
    ]);
    final clock = _FakeClock();
    final flow = _flow(
      client: client,
      store: _tempStore(),
      clock: clock,
      sleeps: [],
    );

    // begin() reports expire_in = 0 → normalized to 10 min.
    final started = flow.start();
    // Simulate: first poll immediate, then advance past deadline
    // before the next wake-up.
    await Future<void>.delayed(Duration.zero);
    clock.value = clock.value.add(const Duration(minutes: 11));
    await started;

    expect(flow.phase, FeishuBindingPhase.expired);
    expect(flow.errorCode, kFeishuFlowErrorExpiredToken);
  });

  test('cancel aborts the loop and returns to idle', () async {
    final client = _FakeDeviceFlowClient([
      const FeishuPollResult(error: 'authorization_pending'),
      const FeishuPollResult(appId: 'cli_never', appSecret: 's'),
    ]);
    final flow = _flow(
      client: client,
      store: _tempStore(),
      clock: _FakeClock(),
      sleeps: [], // instant sleeps — the loop must not stall the test
    );

    final started = flow.start();
    await Future<void>.delayed(Duration.zero);
    flow.cancel();
    await started;

    expect(flow.phase, FeishuBindingPhase.idle);
    // The scripted success response was never consumed.
    expect(flow.credentials, isNull);
    expect(client.pollDomains.length, 1);
  });

  test('start is a no-op while a flow is running', () async {
    final client = _FakeDeviceFlowClient([
      const FeishuPollResult(error: 'authorization_pending'),
    ]);
    // Fallback keeps the first flow pending forever, so it is
    // genuinely still running when the second start() lands.
    final flow = _flow(
      client: client,
      store: _tempStore(),
      clock: _FakeClock(),
      sleeps: [],
    );

    final first = flow.start();
    await Future<void>.delayed(Duration.zero);
    final second = flow.start(); // must be ignored
    flow.cancel();
    await first;
    await second;

    expect(flow.phase, FeishuBindingPhase.idle);
    // A second flow would have issued a second begin().
    expect(client.beginCount, 1);
  });

  test('unbind clears state and deletes the file', () async {
    final client = _FakeDeviceFlowClient([
      const FeishuPollResult(appId: 'cli_a', appSecret: 's', openId: 'ou_o'),
    ]);
    final store = _tempStore();
    final flow = _flow(
      client: client, store: store, clock: _FakeClock(), sleeps: []);

    await flow.start();
    expect(flow.phase, FeishuBindingPhase.connected);

    await flow.unbind();
    expect(flow.phase, FeishuBindingPhase.idle);
    expect(flow.credentials, isNull);
    expect(await store.load(), isNull);
  });
}
