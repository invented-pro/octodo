// Tests for `compareSemver` from `lib/src/update/semver.dart`.
// Pure functions; no I/O.

import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/update/semver.dart';

void main() {
  group('compareSemver', () {
    test('equal versions compare as 0', () {
      expect(compareSemver('1.0.0', '1.0.0'), 0);
      expect(compareSemver('2.4.0', '2.4.0'), 0);
    });

    test('major/minor/patch compare as integers', () {
      expect(compareSemver('2.0.0', '1.99.99') > 0, isTrue);
      expect(compareSemver('1.1.0', '1.0.99') > 0, isTrue);
      expect(compareSemver('1.0.1', '1.0.0') > 0, isTrue);
      expect(compareSemver('1.0.0', '2.0.0') < 0, isTrue);
    });

    test('release > prerelease of same core', () {
      expect(compareSemver('2.4.0', '2.4.0-rc.1') > 0, isTrue);
      expect(compareSemver('2.4.0-beta.5', '2.4.0') < 0, isTrue);
    });

    test('numeric prerelease identifiers compare numerically', () {
      expect(compareSemver('2.4.0-rc.1', '2.4.0-rc.2') < 0, isTrue);
      expect(compareSemver('2.4.0-rc.10', '2.4.0-rc.9') > 0,
          isTrue); // NOT lexical
    });

    test('numeric prerelease id < alphanumeric (SemVer 2.0 §11)', () {
      expect(compareSemver('2.4.0-1', '2.4.0-alpha') < 0, isTrue);
    });

    test('build metadata is ignored for ordering', () {
      expect(compareSemver('2.4.0+build.5', '2.4.0+build.9'), 0);
      expect(compareSemver('2.4.0+build.5', '2.4.1+build.0') < 0, isTrue);
    });

    test('prerelease ordering: shorter is greater when prefix matches', () {
      // 2.4.0-alpha < 2.4.0-alpha.1 (SemVer 2.0 §11.4.4)
      expect(compareSemver('2.4.0-alpha', '2.4.0-alpha.1') < 0, isTrue);
      expect(compareSemver('2.4.0-alpha.1', '2.4.0-alpha') > 0, isTrue);
    });

    test('falls back to lexical when shape is malformed', () {
      expect(compareSemver('abc', 'abd') < 0, isTrue);
      expect(compareSemver('1.0.0', 'not-a-version') < 0, isTrue);
    });
  });
}
