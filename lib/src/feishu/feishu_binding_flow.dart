// The QR-binding state machine (design doc §2.2). One instance
// drives the whole device flow: request a device code → show the
// QR → poll until the user confirms (or the code expires) →
// persist credentials.
//
// Phase mapping (doc lists a separate "PollingCredentials" state —
// the platform gives no "user scanned" signal, only pending →
// success, so `waitingForScan` spans both):
//
//   Idle ──start()──► RequestingCode
//     RequestingCode ── begin() ok ──► WaitingForScan (QR shown)
//     WaitingForScan ── poll ok ─────► Connected (creds saved)
//     WaitingForScan ── expire_in ───► Expired
//     any ── network / denied ──────► Failed
//   Connected/Expired/Failed ── unbind()/cancel() ──► Idle
//
// The loop mirrors the official SDK semantics: first poll fires
// immediately, `slow_down` adds +5 s to the interval, a Lark-tenant
// poll response re-targets the larksuite.com domain and re-polls
// without waiting, and the deadline is checked before each sleep.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'feishu_credentials.dart';
import 'feishu_device_flow_client.dart';

/// The minimal capability set Octodo asks for on the QR confirm
/// page (design doc §2.2): read P2P messages, reply as the bot,
/// subscribe to receive events, and react to card actions.
const FeishuAppAddons kFeishuDefaultAddons = FeishuAppAddons(
  minimalPreset: true,
  scopesTenant: [
    'im:message.p2p_msg:readonly',
    'im:message:send_as_bot',
  ],
  eventsTenant: ['im.message.receive_v1'],
  callbacks: ['card.action.trigger'],
);

enum FeishuBindingPhase { idle, requestingCode, waitingForScan, connected, expired, failed }

class FeishuBindingFlow extends ChangeNotifier {
  final FeishuDeviceFlowClient client;
  final FeishuCredentialStore credentialStore;

  /// Test seams: injectable delay and clock so the polling loop is
  /// deterministic under test without real waiting.
  final Future<void> Function(Duration) sleep;
  final DateTime Function() now;

  FeishuBindingPhase _phase = FeishuBindingPhase.idle;
  FeishuBindingPhase get phase => _phase;

  Uri? _qrUri;
  Uri? get qrUri => _qrUri;

  DateTime? _expiresAt;
  DateTime? get expiresAt => _expiresAt;

  String? _errorCode;
  String? get errorCode => _errorCode;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  FeishuCredentials? _credentials;
  FeishuCredentials? get credentials => _credentials;

  bool _running = false;
  bool get isRunning =>
      _running ||
      _phase == FeishuBindingPhase.requestingCode ||
      _phase == FeishuBindingPhase.waitingForScan;

  /// Cancellation generation: `cancel()` bumps this and any
  /// in-flight loop from an older generation stops itself.
  int _generation = 0;

  FeishuBindingFlow({
    required this.client,
    required this.credentialStore,
    Future<void> Function(Duration)? sleepOverride,
    DateTime Function()? nowOverride,
  }) : sleep = sleepOverride ?? Future.delayed,
       now = nowOverride ?? DateTime.now;

  static FeishuBindingFlow? _shared;

  /// Process-wide instance used by the settings UI. Lazily built
  /// from the real HTTP client + the user's config directory.
  static FeishuBindingFlow get shared =>
      _shared ??= FeishuBindingFlow(
        client: FeishuDeviceFlowClient(),
        credentialStore: FeishuCredentialStore.resolve(),
      );

  @visibleForTesting
  static set sharedForTesting(FeishuBindingFlow? value) => _shared = value;

  /// Pre-load persisted credentials (called before first render of
  /// the settings section so a previous bind shows as Connected).
  Future<void> loadPersisted() async {
    if (_phase != FeishuBindingPhase.idle) return;
    final stored = await credentialStore.load();
    if (stored == null) return;
    _credentials = stored;
    _phase = FeishuBindingPhase.connected;
    notifyListeners();
  }

  /// Kick off the QR device flow. No-op while one is already
  /// running. Terminal failures land in [errorCode]/[errorMessage]
  /// with phase [FeishuBindingPhase.failed] (or `expired`).
  Future<void> start() async {
    if (isRunning) return;
    _running = true;
    final generation = ++_generation;
    _errorCode = null;
    _errorMessage = null;
    _qrUri = null;
    _expiresAt = null;
    _setPhase(FeishuBindingPhase.requestingCode);
    try {
      await _run(generation);
    } on FeishuDeviceFlowException catch (e) {
      // Network / protocol errors from begin(), poll() or the
      // credential save — the common case is simply being offline.
      // Without this catch the exception escapes the fire-and-forget
      // UI call and the phase would stick at `requestingCode`.
      if (generation == _generation) {
        _fail(
          e.code,
          e.description.isEmpty ? e.code : e.description,
          expired: e.code == kFeishuFlowErrorExpiredToken,
        );
      }
    } catch (e) {
      if (generation == _generation) {
        _fail(kFeishuFlowErrorNetwork, 'binding failed: $e');
      }
    } finally {
      if (generation == _generation) _running = false;
    }
  }

  Future<void> _run(int generation) async {
    bool mine() => generation == _generation;

    final begin = await client.begin();
    if (!mine()) return;
    final qr = FeishuDeviceFlowClient.buildQrUri(
      begin.verificationUriComplete,
      source: 'octodo-sdk',
      presetName: 'Octodo {user}',
      presetDesc: 'Remote-control bot created by Octodo',
      addons: kFeishuDefaultAddons,
      createOnly: true,
    );
    final expireIn = begin.expiresIn == Duration.zero
        ? const Duration(minutes: 10)
        : begin.expiresIn;
    final deadline = now().add(expireIn);
    _qrUri = qr;
    _expiresAt = deadline;
    _setPhase(FeishuBindingPhase.waitingForScan);

    var interval = begin.interval == Duration.zero
        ? const Duration(seconds: 5)
        : begin.interval;
    var domain = client.feishuDomain;
    var switchedDomain = false;
    var waitBeforePoll = false;

    while (true) {
      if (waitBeforePoll) {
        if (now().isAfter(deadline)) {
          _fail(kFeishuFlowErrorExpiredToken, 'QR code expired', expired: true);
          return;
        }
        await sleep(interval);
        if (!mine()) return;
      }
      waitBeforePoll = true;

      final poll = await client.poll(begin.deviceCode, domain: domain);
      if (!mine()) return;

      // A Lark-tenant scanner: re-target the Lark accounts domain
      // and poll again immediately (before sleeping).
      if (poll.tenantBrand == 'lark' && !switchedDomain) {
        domain = client.larkDomain;
        switchedDomain = true;
        waitBeforePoll = false;
        continue;
      }

      if (poll.hasCredentials) {
        final creds = FeishuCredentials(
          appId: poll.appId,
          appSecret: poll.appSecret,
          ownerOpenId: poll.openId,
          tenantBrand: poll.tenantBrand,
          boundAt: now(),
          allowedOpenIds: poll.openId.isEmpty ? const [] : [poll.openId],
        );
        await credentialStore.save(creds);
        if (!mine()) return;
        _credentials = creds;
        _setPhase(FeishuBindingPhase.connected);
        return;
      }

      switch (poll.error) {
        case 'authorization_pending' || '':
          break;
        case 'slow_down':
          interval += const Duration(seconds: 5);
        case 'expired_token':
          // The server-side expiry (device code lifetime reached);
          // distinct from a local deadline miss only by origin —
          // both land in the `expired` phase.
          _fail(
            kFeishuFlowErrorExpiredToken,
            poll.errorDescription.isEmpty
                ? 'QR code expired'
                : poll.errorDescription,
            expired: true,
          );
          return;
        default:
          _fail(
            poll.error,
            poll.errorDescription.isEmpty ? 'registration failed' : poll.errorDescription,
          );
          return;
      }
    }
  }

  /// Abort an in-flight flow and return to idle. The terminal
  /// states (connected / expired / failed) keep their payload
  /// until [unbind] or a new [start].
  void cancel() {
    if (_running) {
      _generation++;
      _running = false;
    }
    if (_phase == FeishuBindingPhase.requestingCode ||
        _phase == FeishuBindingPhase.waitingForScan) {
      _setPhase(FeishuBindingPhase.idle);
    }
  }

  /// Forget the binding entirely: delete the stored credentials
  /// and go idle. Also used to leave connected / expired / failed.
  Future<void> unbind() async {
    _generation++;
    _running = false;
    await credentialStore.delete();
    _credentials = null;
    _qrUri = null;
    _expiresAt = null;
    _errorCode = null;
    _errorMessage = null;
    _setPhase(FeishuBindingPhase.idle);
  }

  void _fail(String code, String message, {bool expired = false}) {
    _errorCode = code;
    _errorMessage = message;
    _setPhase(
      expired ? FeishuBindingPhase.expired : FeishuBindingPhase.failed,
    );
  }

  void _setPhase(FeishuBindingPhase value) {
    if (_phase == value) return;
    _phase = value;
    notifyListeners();
  }
}
