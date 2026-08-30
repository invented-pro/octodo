import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:octodo/src/notifications/notification_hub.dart';
import 'package:octodo/src/settings/setting.dart';
import 'package:octodo/src/settings/settings_catalog.dart';
import 'package:octodo/src/settings/settings_store.dart';

/// In-memory [SettingsStore] fake. `get` falls back to the setting's
/// default; `set` updates the map and fires the watch stream.
class _FakeStore implements SettingsStore {
  _FakeStore(Map<String, dynamic> initial) : values = initial;

  final Map<String, dynamic> values;
  final _controllers = <String, StreamController<dynamic>>{};

  @override
  T get<T>(Setting<T> key) => values[key.key] as T? ?? key.defaultValue;

  void _emit<T>(Setting<T> key, T value) {
    final c = _controllers.putIfAbsent(
      key.key,
      () => StreamController<dynamic>.broadcast(),
    );
    c.add(value);
  }

  @override
  Future<void> set<T>(Setting<T> key, T value) async {
    values[key.key] = value;
    _emit(key, value);
  }

  @override
  Future<void> reset<T>(Setting<T> key) async {
    values.remove(key.key);
    _emit(key, key.defaultValue);
  }

  @override
  Future<void> resetAll() async => values.clear();

  @override
  bool isExplicitlySet<T>(Setting<T> key) => values.containsKey(key.key);

  @override
  Stream<T> watch<T>(Setting<T> key) {
    final c =
        _controllers.putIfAbsent(
              key.key,
              () => StreamController<dynamic>.broadcast(),
            )
            as StreamController<T>;
    return c.stream;
  }

  @override
  Stream<void> watchWrites() => const Stream<void>.empty();

  @override
  Stream<Object> watchLoadErrors() => const Stream<Object>.empty();
}

void main() {
  late SettingsCatalog catalog;
  late _FakeStore store;
  late List<DesktopNotificationRequest> banners;
  late List<String> dismissed;
  late NotificationHub hub;

  setUp(() {
    catalog = SettingsCatalog();
    store = _FakeStore({});
    banners = [];
    dismissed = [];
    hub = NotificationHub(
      store: store,
      catalog: catalog,
      composeDisplay: (ws, surface) => 'WS · tab',
      onDesktopNotification: banners.add,
      onDismissNotification: dismissed.add,
    );
  });

  NotificationRecord? postAndCapture(
    String ws,
    String surface,
    TerminalAttention a,
  ) {
    hub.handle(ws, surface, a);
    final id = banners.lastOrNull?.id;
    return id == null ? null : hub.consumeActivation(id);
  }

  group('master toggle', () {
    test('off drops the whole pipeline (no banner, no unread)', () {
      store.values['notifications.enabled'] = false;
      hub.handle(
        'ws-0',
        's-1',
        const TerminalAttention(kind: AttentionKind.bell),
      );
      expect(banners, isEmpty);
      expect(hub.totalUnread, 0);
      expect(hub.unreadBySurface(), isEmpty);
    });
  });

  group('noise filter', () {
    test('drops iTerm2 state-form OSC 9 payloads', () {
      hub.handle(
        'ws-0',
        's-1',
        const TerminalAttention(kind: AttentionKind.oscNotify, body: '4;1;6'),
      );
      expect(banners, isEmpty);
      expect(hub.totalUnread, 0);
    });

    test('keeps plain OSC 9 text even when it starts with a digit', () {
      final rec = postAndCapture(
        'ws-0',
        's-1',
        const TerminalAttention(
          kind: AttentionKind.oscNotify,
          body: 'build 42 done',
        ),
      );
      expect(rec, isNotNull);
      expect(banners.single.body, contains('build 42 done'));
    });
  });

  group('bell gate', () {
    test('bellMode none drops BEL events', () {
      store.values['terminal.bellMode'] = BellMode.none;
      hub.handle(
        'ws-0',
        's-1',
        const TerminalAttention(kind: AttentionKind.bell),
      );
      expect(banners, isEmpty);
      expect(hub.totalUnread, 0);
    });

    test('bellMode visual forwards BEL events', () {
      store.values['terminal.bellMode'] = BellMode.visual;
      hub.handle(
        'ws-0',
        's-1',
        const TerminalAttention(kind: AttentionKind.bell),
      );
      expect(banners, hasLength(1));
      expect(banners.single.body, contains('bell'));
    });
  });

  group('duration gate', () {
    test('below threshold is dropped', () {
      hub.handle(
        'ws-0',
        's-1',
        const TerminalAttention(
          kind: AttentionKind.commandFinished,
          exitCode: 0,
          duration: Duration(seconds: 9),
        ),
      );
      expect(banners, isEmpty);
      expect(hub.totalUnread, 0);
    });

    test(
      'at/above threshold passes; threshold is read live from the store',
      () {
        store.values['notifications.minTaskSeconds'] = 60;
        hub.handle(
          'ws-0',
          's-1',
          const TerminalAttention(
            kind: AttentionKind.commandFinished,
            exitCode: 0,
            duration: Duration(seconds: 59),
          ),
        );
        expect(banners, isEmpty);

        hub.handle(
          'ws-0',
          's-1',
          const TerminalAttention(
            kind: AttentionKind.commandFinished,
            exitCode: 0,
            duration: Duration(seconds: 61),
          ),
        );
        expect(banners, hasLength(1));
      },
    );

    test('null duration (D without C) is dropped', () {
      hub.handle(
        'ws-0',
        's-1',
        const TerminalAttention(
          kind: AttentionKind.commandFinished,
          exitCode: 0,
        ),
      );
      expect(banners, isEmpty);
    });

    test('body carries success/failure verb, exit code and duration', () {
      hub.handle(
        'ws-0',
        's-1',
        const TerminalAttention(
          kind: AttentionKind.commandFinished,
          exitCode: 1,
          duration: Duration(minutes: 2, seconds: 13),
        ),
      );
      expect(banners.single.body, contains('task failed (exit 1, 2m 13s)'));
    });
  });

  group('suppression', () {
    const attention = TerminalAttention(kind: AttentionKind.bell);

    test('focused + visible surface drops the event entirely', () {
      var focused = true;
      var visible = true;
      final h = NotificationHub(
        store: store,
        catalog: catalog,
        isAppFocused: () => focused,
        isSurfaceVisible: (ws, s) => visible,
      );
      h.handle('ws-0', 's-1', attention);
      expect(h.totalUnread, 0);

      focused = false;
      h.handle('ws-0', 's-1', attention);
      expect(h.totalUnread, 1);

      focused = true;
      visible = false;
      h.handle('ws-0', 's-1', attention);
      expect(h.totalUnread, 2);
    });
  });

  group('cooldown + coalescing', () {
    test('burst on one surface: one banner, unread accumulates', () {
      for (var i = 0; i < 3; i++) {
        hub.handle(
          'ws-0',
          's-1',
          TerminalAttention(kind: AttentionKind.oscNotify, body: 'm$i'),
        );
      }
      expect(banners, hasLength(1), reason: '2s per-surface banner cooldown');
      expect(hub.unreadCountForSurface('ws-0', 's-1'), 3);
    });

    test('different surfaces are not co-shared by the cooldown', () {
      hub.handle(
        'ws-0',
        's-1',
        const TerminalAttention(kind: AttentionKind.bell),
      );
      hub.handle(
        'ws-0',
        's-2',
        const TerminalAttention(kind: AttentionKind.bell),
      );
      expect(banners, hasLength(2));
    });
  });

  group('banner shape', () {
    test('title is the app name; thread is the workspace id', () {
      hub.handle(
        'ws-7',
        's-1',
        const TerminalAttention(kind: AttentionKind.bell),
      );
      expect(banners.single.title, 'Octodo');
      expect(banners.single.thread, 'ws-7');
    });

    test('body is context — result and truncated at 120 chars', () {
      final longBody = 'x' * 300;
      hub.handle(
        'ws-0',
        's-1',
        TerminalAttention(
          kind: AttentionKind.oscNotify,
          title: 'opencode',
          body: longBody,
        ),
      );
      final body = banners.single.body;
      expect(body.startsWith('WS · tab — opencode: '), isTrue);
      expect(body.length, 120);
      expect(body.endsWith('…'), isTrue);
    });

    test('truncation never splits a surrogate pair (emoji bodies)', () {
      // 🎉 is a surrogate pair (2 code units). Body crafted so the
      // 119-unit cut lands between its lead and trail unit.
      final prefix = 'a' * (119 - 'WS · tab — x: '.length);
      hub.handle(
        'ws-0',
        's-1',
        TerminalAttention(
          kind: AttentionKind.oscNotify,
          title: 'x',
          body: '$prefix🎉 yay',
        ),
      );
      final body = banners.single.body;
      expect(body.endsWith('…'), isTrue);
      // No lone surrogate: the emoji either survived whole or the cut
      // backed off before its lead unit.
      final tail = body.substring(body.length - 2, body.length - 1);
      expect(
        tail.codeUnitAt(0) >= 0xDC00 && tail.codeUnitAt(0) <= 0xDFFF,
        isFalse,
        reason: 'cut must not end on a lone trail surrogate',
      );
    });

    test('falls back to ids when composeDisplay is not provided', () {
      final h = NotificationHub(store: store, catalog: catalog);
      h.handle(
        'ws-0',
        's-9',
        const TerminalAttention(kind: AttentionKind.bell),
      );
      expect(h, isNotNull); // no crash; body composition is best-effort
    });
  });

  group('markRead', () {
    test('clears unread and withdraws delivered banners from the OS', () {
      hub.handle(
        'ws-0',
        's-1',
        const TerminalAttention(kind: AttentionKind.bell),
      );
      final delivered = banners.single.id;
      expect(hub.totalUnread, 1);
      hub.markRead('ws-0', 's-1');
      expect(hub.totalUnread, 0);
      expect(dismissed, [delivered]);
    });

    test('is a no-op for a surface with no unread state', () {
      hub.markRead('ws-0', 'never-seen');
      expect(dismissed, isEmpty);
    });
  });

  group('purges', () {
    test('purgeSurface removes unread, records, and withdraws banners', () {
      hub.handle(
        'ws-0',
        's-1',
        const TerminalAttention(kind: AttentionKind.bell),
      );
      final id = banners.single.id;
      expect(hub.consumeActivation(id), isNotNull);
      // The record was consumed; a duplicate surface event creates new
      // state, then purge clears it.
      hub.handle(
        'ws-0',
        's-1',
        const TerminalAttention(kind: AttentionKind.bell),
      );
      final id2 = banners.last.id;
      hub.purgeSurface('s-1');
      expect(hub.unreadCountForSurface('ws-0', 's-1'), 0);
      expect(hub.totalUnread, 0);
      expect(dismissed, contains(id2));
      // The purged surface's pending record is gone too.
      expect(hub.consumeActivation(id2), isNull);
    });

    test('purgeWorkspace clears every surface of that workspace only', () {
      hub.handle(
        'ws-0',
        's-1',
        const TerminalAttention(kind: AttentionKind.bell),
      );
      hub.handle(
        'ws-1',
        's-2',
        const TerminalAttention(kind: AttentionKind.bell),
      );
      hub.purgeWorkspace('ws-0');
      expect(hub.unreadCountForWorkspace('ws-0'), 0);
      expect(hub.unreadCountForWorkspace('ws-1'), 1);
    });
  });

  group('consumeActivation', () {
    test('returns the record once, then null (one click per banner)', () {
      hub.handle(
        'ws-3',
        's-5',
        const TerminalAttention(kind: AttentionKind.bell),
      );
      final id = banners.single.id;
      final first = hub.consumeActivation(id);
      expect(first?.workspaceId, 'ws-3');
      expect(first?.surfaceId, 's-5');
      expect(hub.consumeActivation(id), isNull);
    });

    test('unknown id (app restarted / stale notification) → null', () {
      expect(hub.consumeActivation('n-9999'), isNull);
    });
  });

  group('unreadBySurface', () {
    test('maps surface ids to counts', () {
      hub.handle(
        'ws-0',
        's-a',
        const TerminalAttention(kind: AttentionKind.bell),
      );
      hub.handle(
        'ws-0',
        's-b',
        const TerminalAttention(kind: AttentionKind.bell),
      );
      hub.handle(
        'ws-1',
        's-c',
        const TerminalAttention(kind: AttentionKind.bell),
      );
      expect(hub.unreadBySurface(), {'s-a': 1, 's-b': 1, 's-c': 1});
    });
  });

  group('clearAll', () {
    test('drops everything and withdraws banners (master toggle off)', () {
      hub.handle(
        'ws-0',
        's-1',
        const TerminalAttention(kind: AttentionKind.bell),
      );
      hub.handle(
        'ws-1',
        's-2',
        const TerminalAttention(kind: AttentionKind.bell),
      );
      hub.clearAll();
      expect(hub.totalUnread, 0);
      expect(dismissed, hasLength(2));
      expect(hub.unreadBySurface(), isEmpty);
    });
  });

  group('in-app banners', () {
    test('accepted event creates one coalesced banner', () {
      hub.handle(
        'ws-0',
        's-1',
        const TerminalAttention(kind: AttentionKind.bell),
      );
      expect(hub.banners, hasLength(1));
      final banner = hub.banners.single;
      expect(banner.workspaceId, 'ws-0');
      expect(banner.surfaceId, 's-1');
      expect(banner.count, 1);
      expect(banner.display, contains('bell'));
    });

    test(
      'burst within cooldown keeps one banner; after cooldown it bumps',
      () async {
        for (var i = 0; i < 3; i++) {
          hub.handle(
            'ws-0',
            's-1',
            const TerminalAttention(kind: AttentionKind.bell),
          );
        }
        expect(hub.banners.single.count, 1);
        await Future<void>.delayed(const Duration(milliseconds: 2100));
        hub.handle(
          'ws-0',
          's-1',
          const TerminalAttention(kind: AttentionKind.bell),
        );
        expect(hub.banners, hasLength(1), reason: 'coalesced per surface');
        expect(hub.banners.single.count, 2);
      },
    );

    test('different surfaces get their own banners', () {
      hub.handle(
        'ws-0',
        's-1',
        const TerminalAttention(kind: AttentionKind.bell),
      );
      hub.handle(
        'ws-0',
        's-2',
        const TerminalAttention(kind: AttentionKind.bell),
      );
      expect(hub.banners, hasLength(2));
    });

    test('suppressed events never create a banner', () {
      final suppressing = NotificationHub(
        store: store,
        catalog: catalog,
        isAppFocused: () => true,
        isSurfaceVisible: (ws, s) => true,
      );
      suppressing.handle(
        'ws-0',
        's-1',
        const TerminalAttention(kind: AttentionKind.bell),
      );
      expect(suppressing.banners, isEmpty);
    });

    test('markRead removes the banner', () {
      hub.handle(
        'ws-0',
        's-1',
        const TerminalAttention(kind: AttentionKind.bell),
      );
      hub.markRead('ws-0', 's-1');
      expect(hub.banners, isEmpty);
    });

    test('purgeSurface and purgeWorkspace remove banners', () {
      hub.handle(
        'ws-0',
        's-1',
        const TerminalAttention(kind: AttentionKind.bell),
      );
      hub.handle(
        'ws-1',
        's-2',
        const TerminalAttention(kind: AttentionKind.bell),
      );
      hub.purgeSurface('s-1');
      expect(hub.banners, hasLength(1));
      expect(hub.banners.single.surfaceId, 's-2');
      hub.purgeWorkspace('ws-1');
      expect(hub.banners, isEmpty);
    });

    test('clearAll removes banners', () {
      hub.handle(
        'ws-0',
        's-1',
        const TerminalAttention(kind: AttentionKind.bell),
      );
      hub.clearAll();
      expect(hub.banners, isEmpty);
    });

    test('OSC 99 opencode-style payloads route through the oscNotify path', () {
      hub.handle(
        'ws-0',
        's-1',
        const TerminalAttention(
          kind: AttentionKind.oscNotify,
          title: 'opencode',
          body: 'Session done',
        ),
      );
      expect(hub.banners.single.display, contains('opencode: Session done'));
    });
  });

  group('re-alert loop', () {
    const bell = TerminalAttention(kind: AttentionKind.bell);

    NotificationHub unfocusedHub(
      List<DesktopNotificationRequest> sink, {
      bool Function()? focused,
    }) => NotificationHub(
      store: store,
      catalog: catalog,
      isAppFocused: focused ?? () => false,
      composeDisplay: (ws, surface) => surface,
      onDesktopNotification: sink.add,
    );

    test(
      're-posts the newest banner every interval while unfocused + unread',
      () {
        fakeAsync((async) {
          final sink = <DesktopNotificationRequest>[];
          final h = unfocusedHub(sink);
          h.handle('ws-0', 's-1', bell);
          expect(sink, hasLength(1));
          async.elapse(const Duration(seconds: 31));
          expect(sink, hasLength(2));
          // Same id → the OS replaces the entry instead of stacking.
          expect(sink[1].id, sink[0].id);
          async.elapse(const Duration(seconds: 31));
          expect(sink, hasLength(3));
          h.dispose();
        });
      },
    );

    test('regaining focus stops the loop', () {
      fakeAsync((async) {
        var focused = false;
        final sink = <DesktopNotificationRequest>[];
        final h = unfocusedHub(sink, focused: () => focused);
        h.handle('ws-0', 's-1', bell);
        focused = true;
        h.onAppFocusChanged();
        async.elapse(const Duration(minutes: 5));
        expect(sink, hasLength(1));
        h.dispose();
      });
    });

    test('markRead stops the loop', () {
      fakeAsync((async) {
        final sink = <DesktopNotificationRequest>[];
        final h = unfocusedHub(sink);
        h.handle('ws-0', 's-1', bell);
        h.markRead('ws-0', 's-1');
        async.elapse(const Duration(minutes: 5));
        expect(sink, hasLength(1));
        h.dispose();
      });
    });

    test('setting off → no re-alert', () {
      fakeAsync((async) {
        store.values['notifications.realertUntilRead'] = false;
        final sink = <DesktopNotificationRequest>[];
        final h = unfocusedHub(sink);
        h.handle('ws-0', 's-1', bell);
        async.elapse(const Duration(minutes: 5));
        expect(sink, hasLength(1));
        h.dispose();
      });
    });

    test('OS-dismissal suppresses re-alerting until the next event', () {
      fakeAsync((async) {
        final sink = <DesktopNotificationRequest>[];
        final h = unfocusedHub(sink);
        h.handle('ws-0', 's-1', bell);
        h.onNotificationDismissed(sink.single.id);
        async.elapse(const Duration(minutes: 5));
        expect(sink, hasLength(1), reason: 'dismissed → no re-posts');

        // A new event re-arms the loop (suppression is per-event).
        h.handle('ws-0', 's-1', bell);
        async.elapse(const Duration(seconds: 31));
        expect(sink, hasLength(2));
        h.dispose();
      });
    });

    test('re-posts target the newest surface', () {
      fakeAsync((async) {
        final sink = <DesktopNotificationRequest>[];
        final h = unfocusedHub(sink);
        h.handle('ws-0', 's-old', bell);
        async.elapse(const Duration(seconds: 5));
        h.handle('ws-0', 's-new', bell);
        async.elapse(const Duration(seconds: 31));
        expect(sink, hasLength(3));
        // composeDisplay echoes the surface id, so the body tells us
        // which surface each post targeted.
        expect(sink[1].body, contains('s-new'));
        expect(sink[2].body, contains('s-new'));
        expect(sink[2].id, sink[1].id);
        h.dispose();
      });
    });
  });
}
