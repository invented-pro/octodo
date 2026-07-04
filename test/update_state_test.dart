// Tests for `update_state.dart` — pure state machine, no I/O. Builds
// minimal `ReleaseInfo` fixtures inline so we don't need the
// resolver's full machinery.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:octodo/src/update/release_resolver.dart';
import 'package:octodo/src/update/update_state.dart';

ReleaseInfo _release({
  String version = '1.2.3',
  String tagName = 'v1.2.3',
  int sizeBytes = 12345,
}) =>
    ReleaseInfo(
      version: version,
      tagName: tagName,
      prerelease: false,
      htmlUrl: Uri.parse('https://example/release/$tagName'),
      zipUrl: Uri.parse(
          'https://example/$tagName/octodo-$tagName-windows-x64.zip'),
      zipSizeBytes: sizeBytes,
    );

File _fakeFile(String path) => File(path);

void main() {
  group('initial state', () {
    test('starts in idle', () {
      final m = UpdateStateModel(currentVersion: '1.0.0');
      expect(m.state, UpdateState.idle);
      expect(m.showsPill, isFalse);
      expect(m.text, '');
      expect(m.iconName, isNull);
    });
  });

  group('showsPill', () {
    test('hides for idle and notFound', () {
      final m = UpdateStateModel(currentVersion: '1.0.0');
      expect(m.showsPill, isFalse);
      m.setState(UpdateState.notFound);
      expect(m.showsPill, isFalse);
    });

    test('shows for non-idle non-notFound states', () {
      final m = UpdateStateModel(currentVersion: '1.0.0');
      for (final s in [
        UpdateState.checking,
        UpdateState.updateAvailable,
        UpdateState.downloading,
        UpdateState.downloaded,
        UpdateState.installing,
        UpdateState.error,
      ]) {
        m.setState(s);
        expect(m.showsPill, isTrue,
            reason: 'expected pill for $s');
      }
    });
  });

  group('setAvailable', () {
    test('transitions to updateAvailable with release set', () {
      final m = UpdateStateModel(currentVersion: '1.0.0');
      final r = _release();
      m.setAvailable(r);
      expect(m.state, UpdateState.updateAvailable);
      expect(m.detected, same(r));
      expect(m.text, contains('1.2.3'));
      expect(m.iconName, Icons.system_update_alt);
      expect(m.showsPill, isTrue);
    });
  });

  group('setDownloading + updateDownloadProgress', () {
    test('updates progress fraction', () {
      final m = UpdateStateModel(currentVersion: '1.0.0');
      m.setDownloading('1.2.3', receivedBytes: 0, totalBytes: 100);
      expect(m.state, UpdateState.downloading);
      expect(m.progress?.version, '1.2.3');
      expect(m.progress?.fraction, 0.0);

      m.updateDownloadProgress(
          version: '1.2.3', receivedBytes: 50, totalBytes: 100);
      expect(m.progress?.receivedBytes, 50);
      expect(m.progress?.fraction, 0.5);
    });

    test('handles unknown total (zero) without dividing by zero', () {
      final m = UpdateStateModel(currentVersion: '1.0.0');
      m.setDownloading('1.2.3', receivedBytes: 10, totalBytes: 0);
      expect(m.progress?.fraction, 0.0);
      expect(m.text, contains('Downloading'));
    });

    test('clamps fraction to 1.0 if received > total', () {
      final m = UpdateStateModel(currentVersion: '1.0.0');
      m.setDownloading('1.2.3', receivedBytes: 0, totalBytes: 100);
      m.updateDownloadProgress(
          version: '1.2.3', receivedBytes: 120, totalBytes: 100);
      expect(m.progress?.fraction, 1.0);
    });
  });

  group('setDownloaded', () {
    test('transitions to downloaded with payload', () {
      final m = UpdateStateModel(currentVersion: '1.0.0');
      m.setDownloaded(DownloadedPayload(
        version: '1.2.3',
        zipPath: _fakeFile('/tmp/octodo-v1.2.3-windows-x64.zip'),
        sizeBytes: 12345,
        digestVerified: true,
      ));
      expect(m.state, UpdateState.downloaded);
      expect(m.downloaded?.version, '1.2.3');
      expect(m.downloaded?.digestVerified, isTrue);
      expect(m.text, contains('Restart'));
      expect(m.iconName, Icons.restart_alt);
    });
  });

  group('setError / reset', () {
    test('setError transitions to error', () {
      final m = UpdateStateModel(currentVersion: '1.0.0');
      m.setError(const UpdateErrorPayload(message: 'boom'));
      expect(m.state, UpdateState.error);
      expect(m.error?.message, 'boom');
      expect(m.showsPill, isTrue);
    });

    test('reset returns to idle and clears payloads', () {
      final m = UpdateStateModel(currentVersion: '1.0.0');
      m.setAvailable(_release());
      m.reset();
      expect(m.state, UpdateState.idle);
      expect(m.detected, isNull);
      expect(m.error, isNull);
    });
  });

  group('setInstalling', () {
    test('refuses from idle (no-op)', () {
      final m = UpdateStateModel(currentVersion: '1.0.0');
      m.setInstalling();
      expect(m.state, UpdateState.idle);
    });

    test('transitions when state is downloaded', () {
      final m = UpdateStateModel(currentVersion: '1.0.0');
      m.setDownloaded(DownloadedPayload(
        version: '1.2.3',
        zipPath: _fakeFile('/tmp/x.zip'),
        sizeBytes: 1,
        digestVerified: false,
      ));
      m.setInstalling();
      expect(m.state, UpdateState.installing);
      expect(m.iconName, Icons.restart_alt);
    });
  });

  group('isUpToDate flag', () {
    test('starts false', () {
      final m = UpdateStateModel(currentVersion: '1.0.0');
      expect(m.isUpToDate, isFalse);
    });

    test('markUpToDate sets the flag', () {
      final m = UpdateStateModel(currentVersion: '1.0.0');
      m.markUpToDate();
      expect(m.isUpToDate, isTrue);
    });

    test('markUpToDate is idempotent (no duplicate notifications)', () {
      final m = UpdateStateModel(currentVersion: '1.0.0');
      var notifications = 0;
      m.addListener(() => notifications += 1);
      m.markUpToDate();
      m.markUpToDate();
      m.markUpToDate();
      expect(notifications, 1);
    });

    test('setAvailable clears the flag when a newer release is found', () {
      final m = UpdateStateModel(currentVersion: '1.0.0');
      m.markUpToDate();
      expect(m.isUpToDate, isTrue);
      m.setAvailable(_release(version: '1.2.3'));
      expect(m.isUpToDate, isFalse);
    });

    test('setError clears the flag (uncertainty)', () {
      final m = UpdateStateModel(currentVersion: '1.0.0');
      m.markUpToDate();
      m.setError(const UpdateErrorPayload(message: 'boom'));
      expect(m.isUpToDate, isFalse);
    });

    test('reset preserves the flag (idle after a clean probe)', () {
      final m = UpdateStateModel(currentVersion: '1.0.0');
      m.markUpToDate();
      m.reset();
      expect(m.state, UpdateState.idle);
      expect(m.isUpToDate, isTrue);
    });

    test('setState(notFound) does not touch the flag', () {
      // The 2.5 s flash is a transient UI signal — it mustn't
      // stomp the persistent "Latest" indicator.
      final m = UpdateStateModel(currentVersion: '1.0.0');
      m.markUpToDate();
      m.setState(UpdateState.notFound);
      expect(m.isUpToDate, isTrue);
    });
  });
}
