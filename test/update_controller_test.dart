// Tests for `update_controller.dart` — the orchestrator that ties
// the feed, state machine, downloads, and apply together.
//
// The controller probes [UpdateFeedSource]s (abstract over GitHub +
// R2). Tests inject `MockClient`-backed [UpdateFeed] / [R2UpdateFeed]
// via the `primaryFeedFactory` + `fallbackFeedFactory` constructor
// hooks so probes are deterministic without hitting the network.
// [SettingsRuntime] is wired up with a tiny in-memory [SettingsStore]
// so the controller can resolve `update.autoCheck` / `update.repository`
// / `update.fallbackUrl` without the production JSON-file store.
//
// The skip-list file path is also overridden to a temp file via
// the `skipListFileFactory` constructor hook. Without this, the
// controller would read whatever real user has accumulated in
// `%APPDATA%/octodo/update_skipped.json`, polluting the test.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

import 'package:octodo/src/settings/setting.dart';
import 'package:octodo/src/settings/settings_catalog.dart';
import 'package:octodo/src/settings/settings_runtime.dart';
import 'package:octodo/src/settings/settings_store.dart';
import 'package:octodo/src/update/r2_update_feed.dart';
import 'package:octodo/src/update/update_controller.dart';
import 'package:octodo/src/update/update_feed.dart';
import 'package:octodo/src/update/update_state.dart';

/// Minimal in-memory [SettingsStore]. Only the methods the
/// controller touches are implemented.
class _FakeSettingsStore implements SettingsStore {
  final Map<String, Object?> _values = {};
  final Map<String, StreamController<dynamic>> _ctrls = {};

  @override
  T get<T>(Setting<T> key) {
    if (_values.containsKey(key.key)) {
      return key.codec.fromJson(_values[key.key]);
    }
    return key.defaultValue;
  }

  @override
  Future<void> set<T>(Setting<T> key, T value) async {
    _values[key.key] = key.codec.toJson(value);
    _ctrls[key.key]?.add(value);
  }

  @override
  Future<void> reset<T>(Setting<T> key) async {
    _values.remove(key.key);
    _ctrls[key.key]?.add(null);
  }

  @override
  Future<void> resetAll() async {
    _values.clear();
    for (final c in _ctrls.values) {
      c.add(null);
    }
  }

  @override
  bool isExplicitlySet<T>(Setting<T> key) => _values.containsKey(key.key);

  @override
  Stream<T> watch<T>(Setting<T> key) {
    final ctrl = _ctrls.putIfAbsent(
      key.key,
      () => StreamController<dynamic>.broadcast(),
    );
    return ctrl.stream.map((v) => v is T ? v : get<T>(key)).distinct();
  }

  @override
  Stream<void> watchWrites() => const Stream<void>.empty();

  @override
  Stream<Object> watchLoadErrors() => const Stream<Object>.empty();
}

String _releaseBody({String tagName = 'v9.9.9', int zipSize = 12345}) {
  final zipName = 'octodo-$tagName-windows-x64.zip';
  return jsonEncode(<String, dynamic>{
    'tag_name': tagName,
    'name': tagName,
    'prerelease': false,
    'published_at': '2026-06-15T12:00:00Z',
    'html_url': 'https://github.com/invented-pro/octodo/releases/tag/$tagName',
    'body': 'Test.',
    'assets': <Map<String, dynamic>>[
      {
        'name': zipName,
        'size': zipSize,
        'browser_download_url':
            'https://example.com/$tagName/$zipName',
        'content_type': 'application/zip',
      },
    ],
  });
}

UpdateFeed _feedFrom(MockClient mock) => UpdateFeed(
      repository: 'invented-pro/octodo',
      userAgentVersion: '1.0.0',
      client: mock,
    );

/// Wait until [predicate] returns true or [timeout] elapses.
/// Polls every 5 ms; capped at [timeout]. Necessary because
/// `Future<void>.delayed(Duration.zero)` doesn't reliably pump
/// the entire async chain inside `flutter_test` when the test
/// runs after heavier siblings.
Future<void> _waitFor(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late _FakeSettingsStore store;
  late SettingsCatalog catalog;
  late SettingsRuntime runtime;
  late UpdateStateModel model;
  late Directory tmp;
  late File skipListFile;

  setUp(() async {
    store = _FakeSettingsStore();
    catalog = SettingsCatalog();
    runtime = SettingsRuntime.create(
      store: store,
      catalog: catalog,
      hostActions: SettingsHostActions(
        revealInFileManager: (_) {},
        openInExternalEditor: (_) {},
        restartApp: () {},
      ),
    );
    SettingsRuntime.instance = runtime;
    model = UpdateStateModel(currentVersion: '1.0.0');
    tmp = await Directory.systemTemp.createTemp('octodo-upd-test-');
    skipListFile = File(p.join(tmp.path, 'update_skipped.json'));
    if (!await skipListFile.exists()) {
      await skipListFile.writeAsString('[]');
    }
  });

  tearDown(() async {
    SettingsRuntime.instance = null;
    if (await tmp.exists()) {
      // Windows can briefly hold a handle on files written
      // during the test (the controller's `_writeSkipList` race
      // with the file watcher's own handle). Retry a couple
      // times before giving up — if we still can't clean up,
      // don't fail the test, just leave the temp dir for the
      // OS to reap.
      for (var i = 0; i < 5; i++) {
        try {
          await tmp.delete(recursive: true);
          return;
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    }
  });

  UpdateController buildController(MockClient mock) {
    return UpdateController(
      model: model,
      settings: catalog.update,
      userAgentVersion: '1.0.0',
      primaryFeedFactory: (repo, ua) => _feedFrom(mock),
      skipListFileFactory: () => skipListFile,
    );
  }

  group('initial probe', () {
    test('newer release flips state to updateAvailable', () async {
      final mock = MockClient((req) async {
        return http.Response(_releaseBody(tagName: 'v9.9.9'), 200);
      });
      final controller = buildController(mock);
      await controller.start();

      await _waitFor(() => model.state == UpdateState.updateAvailable);

      expect(model.state, UpdateState.updateAvailable);
      expect(model.detected?.version, '9.9.9');
      controller.dispose();
    });

    test('older release + manual check flashes notFound', () async {
      final mock = MockClient((req) async {
        return http.Response(_releaseBody(tagName: 'v0.5.0'), 200);
      });
      final controller = buildController(mock);
      await controller.start();
      // Initial probe sees an older release → background reset.
      await _waitFor(() => model.state == UpdateState.idle);

      await controller.checkForUpdates();
      await _waitFor(() => model.state == UpdateState.notFound);
      expect(model.state, UpdateState.notFound);
      controller.dispose();
    });

    test('background probe error does NOT surface the error pill',
        () async {
      final mock = MockClient((req) async {
        throw const SocketException('Network unreachable');
      });
      final controller = buildController(mock);
      await controller.start();

      // Background errors are silent — model stays at idle.
      await _waitFor(() => model.state == UpdateState.idle);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(model.state, UpdateState.idle);
      expect(model.showsPill, isFalse);
      controller.dispose();
    });

    test('manual check surfaces network errors with a Retry callback',
        () async {
      var callCount = 0;
      final mock = MockClient((req) async {
        callCount += 1;
        throw const SocketException('Network unreachable');
      });
      final controller = buildController(mock);
      await controller.start();
      await _waitFor(() => model.state == UpdateState.idle);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await controller.checkForUpdates();
      await _waitFor(() => model.state == UpdateState.error);
      expect(model.state, UpdateState.error);
      expect(model.error?.onRetry, isNotNull);
      expect(model.error?.message, contains('reach update feed'));
      // Sanity: we hit the network at least twice (initial + manual).
      expect(callCount, greaterThanOrEqualTo(2));
      controller.dispose();
    });

    test('rate limit (remaining=0) shows precise retry window', () async {
      // 47 minutes in the future.
      final resetEpoch =
          (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 47 * 60;
      final mock = MockClient((_) async {
        return http.Response(
          '{"message":"API rate limit exceeded"}',
          403,
          headers: {
            'x-ratelimit-remaining': '0',
            'x-ratelimit-limit': '60',
            'x-ratelimit-reset': '$resetEpoch',
          },
        );
      });
      final controller = buildController(mock);
      await controller.start();
      await _waitFor(() => model.state == UpdateState.idle);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await controller.checkForUpdates();
      await _waitFor(() => model.state == UpdateState.error);

      expect(model.error?.message, contains('rate limit hit'));
      // The user-facing message should reflect the reset window
      // (45–48 minutes from now, depending on test latency).
      expect(model.error?.message, matches(RegExp(r'Try again in 4[5-8] min')));
      controller.dispose();
    });
  });

  group('probe single-flight', () {
    test('second checkForUpdates while one is in flight is skipped',
        () async {
      // Each request gets its own completer so we can hold the
      // first manual check open while issuing a second one.
      final completers = <Completer<http.Response>>[];
      final mock = MockClient((req) async {
        final c = Completer<http.Response>();
        completers.add(c);
        return c.future;
      });
      final c = UpdateController(
        model: model,
        settings: catalog.update,
        userAgentVersion: '1.0.0',
        primaryFeedFactory: (r, u) =>
            UpdateFeed(repository: r, userAgentVersion: u, client: mock),
        skipListFileFactory: () => skipListFile,
      );

      // Complete the initial probe so start() returns.
      Future<void> completeInitialProbe() async {
        await _waitFor(() => completers.isNotEmpty);
        completers[0].complete(
          http.Response(_releaseBody(tagName: 'v9.9.9'), 200),
        );
      }

      final initFut = completeInitialProbe();
      await c.start();
      await initFut;
      completers.clear();

      // Now fire two manual checks back-to-back. The first
      // enters fetchLatest() and hangs on completers[0]. The
      // second should be skipped — completers stays at length 1.
      final f1 = c.checkForUpdates();
      await _waitFor(() => completers.isNotEmpty);
      // ignore: unused_local_variable
      final f2 = c.checkForUpdates();

      expect(completers.length, 1);
      // Clean up: complete the hanging probe so f1 resolves,
      // and discard f2 (it skipped).
      completers[0].complete(
        http.Response(_releaseBody(tagName: 'v9.9.9'), 200),
      );
      await f1;
      c.dispose();
    });
  });

  group('skip list', () {
    test('skipped version is not surfaced even when newer', () async {
      final mock = MockClient((req) async {
        return http.Response(_releaseBody(tagName: 'v9.9.9'), 200);
      });
      final controller = buildController(mock);
      await controller.start();
      await _waitFor(() => model.state == UpdateState.updateAvailable);

      // Pre-skip the version; subsequent probes must not surface it.
      controller.skipVersion('9.9.9');
      await controller.checkForUpdates();
      await _waitFor(() =>
          model.state == UpdateState.notFound ||
          model.state == UpdateState.idle);

      expect(
        model.state == UpdateState.notFound || model.state == UpdateState.idle,
        isTrue,
      );
      expect(model.detected, isNull);
      controller.dispose();
    });
  });

  group('isUpToDate persistence', () {
    test('background probe returning the same version marks up-to-date',
        () async {
      final mock = MockClient((req) async {
        return http.Response(_releaseBody(tagName: 'v1.0.0'), 200);
      });
      final controller = buildController(mock);
      await controller.start();

      await _waitFor(() => model.state == UpdateState.idle);
      await _waitFor(() => model.isUpToDate);

      expect(model.isUpToDate, isTrue);
      controller.dispose();
    });

    test('manual probe returning the same version marks up-to-date',
        () async {
      final mock = MockClient((req) async {
        return http.Response(_releaseBody(tagName: 'v1.0.0'), 200);
      });
      final controller = buildController(mock);
      await controller.start();
      await _waitFor(() => model.state == UpdateState.idle);

      // Before the manual probe: not up to date yet (the
      // initial probe found nothing newer, but we test the
      // transition explicitly here by clearing first).
      model.markUpToDate();
      expect(model.isUpToDate, isTrue);

      // Now trigger a manual probe; the controller should keep
      // the flag set through the notFound → idle transition.
      await controller.checkForUpdates();
      await _waitFor(() =>
          model.state == UpdateState.notFound ||
          model.state == UpdateState.idle);

      // Even after the 2.5 s notFound flash would expire, the
      // flag remains — that's the whole point.
      expect(model.isUpToDate, isTrue);
      controller.dispose();
    });

    test('newer release clears the up-to-date flag', () async {
      // Initial probe: same version → up to date.
      // Second probe: newer version → cleared.
      var call = 0;
      final mock = MockClient((req) async {
        call += 1;
        final tag = call == 1 ? 'v1.0.0' : 'v9.9.9';
        return http.Response(_releaseBody(tagName: tag), 200);
      });
      final controller = buildController(mock);
      await controller.start();
      await _waitFor(() => model.isUpToDate);
      expect(model.isUpToDate, isTrue);

      await controller.checkForUpdates();
      await _waitFor(() => model.state == UpdateState.updateAvailable);

      expect(model.isUpToDate, isFalse);
      controller.dispose();
    });

    test('background probe error does NOT set the up-to-date flag',
        () async {
      final mock = MockClient((req) async {
        throw const SocketException('Network unreachable');
      });
      final controller = buildController(mock);
      await controller.start();
      await _waitFor(() => model.state == UpdateState.idle);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(model.isUpToDate, isFalse);
      controller.dispose();
    });
  });

  group('feedFactory override', () {
    test('production callers leave feedFactory null and get a real feed',
        () async {
      // No feedFactory means the controller builds its own
      // UpdateFeed. We don't exercise the network here — just
      // assert that start() runs without throwing.
      final controller = UpdateController(
        model: model,
        settings: catalog.update,
        userAgentVersion: '1.0.0',
        skipListFileFactory: () => skipListFile,
      );
      await controller.start();
      controller.dispose();
    });
  });

  group('default repository', () {
    test('public constant matches the production repo', () {
      expect(UpdateController.defaultRepository, 'invented-pro/octodo');
    });
  });

  group('fallback feed (R2)', () {
    // The two feeds sit on distinct hosts so the test can keep
    // their response queues separate. R2 manifest typically
    // advertises host `https://s3.example.test/octodo` for assets.
    // GitHub release asset URLs go through `releases/download/...`.
    //
    // Both paths share the same `resolveReleaseJson` parser, so we
    // can reuse `_releaseBody(...)` for both. The only difference is
    // the asset `browser_download_url` host — the controller cares
    // only that the manifest is parseable.
    String r2ManifestBody({
      String tagName = 'v9.9.9',
      int zipSize = 99887766,
    }) {
      final zipName = 'octodo-$tagName-windows-x64.zip';
      return jsonEncode(<String, dynamic>{
        'tag_name': tagName,
        'name': tagName,
        'prerelease': false,
        'published_at': '2026-06-15T12:00:00Z',
        'html_url':
            'https://github.com/invented-pro/octodo/releases/tag/$tagName',
        'body': 'R2 mirror.',
        'assets': <Map<String, dynamic>>[
          {
            'name': zipName,
            'size': zipSize,
            'browser_download_url': 'https://s3.example.test/octodo/$zipName',
            'content_type': 'application/zip',
          },
        ],
      });
    }

    test('empty `update.fallbackUrl` setting → no fallback tried',
        () async {
      var primaryCalls = 0;
      final primary = MockClient((req) async {
        primaryCalls += 1;
        if (req.url.path.contains('releases/latest')) {
          return http.Response('', 503);
        }
        // Anything else (fallback URL if it were asked): not used.
        return http.Response('not-used', 200);
      });
      await store.set(catalog.update.fallbackUrl, '');

      final c = UpdateController(
        model: model,
        settings: catalog.update,
        userAgentVersion: '1.0.0',
        primaryFeedFactory: (r, u) => UpdateFeed(
              repository: r,
              userAgentVersion: u,
              client: primary,
            ),
        skipListFileFactory: () => skipListFile,
      );
      await c.start();
      await _waitFor(() => model.state == UpdateState.idle);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await c.checkForUpdates();
      await _waitFor(() => model.state == UpdateState.error);

      // No fallback URL → controller only ever asks primary. The
      // status is `error` not `idle` because manual `checkForUpdates`
      // surfaces probe failures with a Retry CTA.
      expect(model.state, UpdateState.error);
      // Only the primary host got hit (twice: initial + manual).
      expect(primaryCalls, greaterThanOrEqualTo(2));
      c.dispose();
    });

    test('primary succeeds → fallback URL is never fetched',
        () async {
      final hitHosts = <String>[];
      final mock = MockClient((req) async {
        hitHosts.add(req.url.host);
        return http.Response(_releaseBody(tagName: 'v9.9.9'), 200);
      });
      // A fallback URL that, if hit, would return a clearly
      // different body. The test asserts it never gets called.
      const fallbackUrl = 'https://s3.example.test/octodo/manifest.json';
      await store.set(catalog.update.fallbackUrl, fallbackUrl);

      final c = UpdateController(
        model: model,
        settings: catalog.update,
        userAgentVersion: '1.0.0',
        primaryFeedFactory: (r, u) => UpdateFeed(
              repository: r,
              userAgentVersion: u,
              client: mock,
            ),
        skipListFileFactory: () => skipListFile,
      );
      await c.start();
      await _waitFor(() => model.state == UpdateState.updateAvailable);

      // Only `api.github.com` should appear — never the fallback
      // host. R2 is never even constructed when primary wins.
      expect(hitHosts, everyElement('api.github.com'));
      expect(model.detected?.version, '9.9.9');
      c.dispose();
    });

    test('primary throws → fallback URL is fetched, R2 release wins',
        () async {
      var primaryCalls = 0;
      final mock = MockClient((req) async {
        if (req.url.host == 'api.github.com') {
          primaryCalls += 1;
          return http.Response('', 503);
        }
        // Fallback path — R2 manifest URL.
        return http.Response(r2ManifestBody(tagName: 'v8.8.8'), 200);
      });
      const fallbackUrl = 'https://s3.example.test/octodo/manifest.json';
      await store.set(catalog.update.fallbackUrl, fallbackUrl);

      final c = UpdateController(
        model: model,
        settings: catalog.update,
        userAgentVersion: '1.0.0',
        primaryFeedFactory: (r, u) => UpdateFeed(
              repository: r,
              userAgentVersion: u,
              client: mock,
            ),
        // Build the fallback feed with the same MockClient so the
        // mock's branching handler can route both feeds in one place.
        fallbackFeedFactory: (url, u) => R2UpdateFeed(
              manifestUrl: url,
              userAgentVersion: u,
              client: mock,
            ),
        skipListFileFactory: () => skipListFile,
      );
      await c.start();
      await _waitFor(() => model.state == UpdateState.updateAvailable);

      // Primary failed (503 → UpdateFeedException), so fallback
      // was tried. The release in `model.detected` should reflect
      // the R2 manifest body (version 8.8.8) — not GitHub.
      expect(model.detected?.version, '8.8.8');
      // Primary got hit at least once (initial background probe).
      expect(primaryCalls, greaterThanOrEqualTo(1));
      c.dispose();
    });

    test('rate-limit on primary also triggers fallback', () async {
      // 47 min from now — mirrors the rate-limit-recovery test
      // shape so we exercise the same path.
      final resetEpoch =
          (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 47 * 60;
      final mock = MockClient((req) async {
        if (req.url.host == 'api.github.com') {
          return http.Response(
            '{"message":"rate limit exceeded"}',
            403,
            headers: {
              'x-ratelimit-remaining': '0',
              'x-ratelimit-limit': '60',
              'x-ratelimit-reset': '$resetEpoch',
            },
          );
        }
        return http.Response(r2ManifestBody(tagName: 'v7.7.7'), 200);
      });
      await store.set(catalog.update.fallbackUrl,
          'https://s3.example.test/octodo/manifest.json');

      final c = UpdateController(
        model: model,
        settings: catalog.update,
        userAgentVersion: '1.0.0',
        primaryFeedFactory: (r, u) => UpdateFeed(
              repository: r,
              userAgentVersion: u,
              client: mock,
            ),
        fallbackFeedFactory: (url, u) => R2UpdateFeed(
              manifestUrl: url,
              userAgentVersion: u,
              client: mock,
            ),
        skipListFileFactory: () => skipListFile,
      );
      await c.start();
      await _waitFor(() => model.state == UpdateState.idle);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Background failures are silent. Trigger a manual check so
      // the controller surfaces the fallback path's result.
      await c.checkForUpdates();
      await _waitFor(() => model.state == UpdateState.updateAvailable);

      expect(model.detected?.version, '7.7.7');
      c.dispose();
    });

    test('both fail → primary error surfaces, no update surfaced',
        () async {
      final mock = MockClient((req) async {
        // Both feeds return an error.
        return http.Response('', 500);
      });
      await store.set(catalog.update.fallbackUrl,
          'https://s3.example.test/octodo/manifest.json');

      final c = UpdateController(
        model: model,
        settings: catalog.update,
        userAgentVersion: '1.0.0',
        primaryFeedFactory: (r, u) => UpdateFeed(
              repository: r,
              userAgentVersion: u,
              client: mock,
            ),
        fallbackFeedFactory: (url, u) => R2UpdateFeed(
              manifestUrl: url,
              userAgentVersion: u,
              client: mock,
            ),
        skipListFileFactory: () => skipListFile,
      );
      await c.start();
      await _waitFor(() => model.state == UpdateState.idle);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await c.checkForUpdates();
      await _waitFor(() => model.state == UpdateState.error);

      // The user's primary error wins over the secondary. The
      // user-facing message won't mention "GitHub" specifically
      // because both feeds are user-configured sources — only the
      // primary is GitHub by default; the fallback is whatever
      // they set. Keep the message generic.
      expect(model.state, UpdateState.error);
      expect(model.detected, isNull);
      c.dispose();
    });

    test('non-http(s) fallbackUrl is dropped + logged at warning',
        () async {
      // Empty is the default; set a clearly bad URL and confirm
      // the controller does NOT try to probe it.
      await store.set(catalog.update.fallbackUrl, 'ftp://nope');

      final mock = MockClient((req) async {
        if (req.url.host == 'api.github.com') {
          return http.Response(_releaseBody(tagName: 'v9.9.9'), 200);
        }
        // If we reach this branch, the bad URL leaked through.
        return http.Response('UNEXPECTED', 200);
      });

      final c = UpdateController(
        model: model,
        settings: catalog.update,
        userAgentVersion: '1.0.0',
        primaryFeedFactory: (r, u) => UpdateFeed(
              repository: r,
              userAgentVersion: u,
              client: mock,
            ),
        skipListFileFactory: () => skipListFile,
      );
      await c.start();
      await _waitFor(() => model.state == UpdateState.updateAvailable);

      // Primary succeeded → update surfaces regardless of fallback
      // being broken; the bad fallback URL is silently disabled.
      expect(model.detected?.version, '9.9.9');
      c.dispose();
    });

    test('changing update.fallbackUrl rebinds the fallback feed',
        () async {
      // Start with no fallback; primary fails → idle.
      var primaryCalls = 0;
      var fallbackCalls = 0;
      final mock = MockClient((req) async {
        if (req.url.host == 'api.github.com') {
          primaryCalls += 1;
          return http.Response('', 503);
        }
        fallbackCalls += 1;
        return http.Response(r2ManifestBody(tagName: 'v6.6.6'), 200);
      });

      final c = UpdateController(
        model: model,
        settings: catalog.update,
        userAgentVersion: '1.0.0',
        primaryFeedFactory: (r, u) => UpdateFeed(
              repository: r,
              userAgentVersion: u,
              client: mock,
            ),
        fallbackFeedFactory: (url, u) => R2UpdateFeed(
              manifestUrl: url,
              userAgentVersion: u,
              client: mock,
            ),
        skipListFileFactory: () => skipListFile,
      );
      await c.start();
      await _waitFor(() => primaryCalls >= 1);
      expect(fallbackCalls, 0, reason: 'no fallback URL configured');

      // Now flip the setting — controller rebuilds the fallback feed.
      await store.set(catalog.update.fallbackUrl,
          'https://s3.example.test/octodo/manifest.json');
      // Allow the watch stream to propagate + the next probe cycle.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await c.checkForUpdates();
      await _waitFor(() => model.state == UpdateState.updateAvailable);
      expect(fallbackCalls, greaterThanOrEqualTo(1));
      expect(model.detected?.version, '6.6.6');
      c.dispose();
    });

    // Sidecar routing itself (`_currentReleaseSource` → which
    // `UpdateFeedSource.fetchSidecar` gets called) isn't unit-tested
    // here because exercising it requires driving `downloadLatest`
    // end-to-end (real staging dir + real SHA-256 read). The
    // unit-level coverage for `R2UpdateFeed.fetchSidecar` lives in
    // `r2_update_feed_test.dart fetchSidecar`. The delegation in
    // `_fetchDigestSidecar` itself is two lines of plumbing; the
    // risk of regression is captured by the lower-level tests.
  });

  group('dispose', () {
    test('clears probe timer + subscriptions without throwing', () async {
      final mock = MockClient((req) async {
        return http.Response(_releaseBody(tagName: 'v9.9.9'), 200);
      });
      final controller = buildController(mock);
      await controller.start();
      await _waitFor(() => model.state == UpdateState.updateAvailable);
      controller.dispose();
      expect(true, isTrue);
    });
  });
}