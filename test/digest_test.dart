// Tests for the SHA-256 helpers in `digest.dart`. Pure I/O over a
// small temp file — no Flutter SDK reaches into the test body, but
// `flutter_test` gives us the standard Dart VM test runner.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/update/digest.dart';

void main() {
  group('sha256HexOfFile', () {
    test('returns lowercase 64-hex digest of a file', () async {
      final tmp = await Directory.systemTemp.createTemp('digest_test_');
      addTearDown(() => tmp.delete(recursive: true));
      final f = File('${tmp.path}/blob.bin');
      // "hello world" → known SHA-256
      // sha256("hello world") = b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9
      await f.writeAsString('hello world');
      final hex = await sha256HexOfFile(f);
      expect(hex, 'b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9');
      expect(hex, hex.toLowerCase());
      expect(hex.length, 64);
    });

    test('read zeros for empty file', () async {
      final tmp = await Directory.systemTemp.createTemp('digest_test_');
      addTearDown(() => tmp.delete(recursive: true));
      final f = File('${tmp.path}/empty.bin');
      await f.writeAsBytes(<int>[]);
      final hex = await sha256HexOfFile(f);
      expect(hex,
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    });
  });

  group('normalizeSha256Hex', () {
    test('lowercases and strips whitespace', () {
      expect(
        normalizeSha256Hex(
            '  B94D27B9934D3E08A52E52D7DA7DABFAC484EFE37A5380EE9088F7ACE2EFCDE9\n'),
        'b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9',
      );
    });

    test('keeps already-lowercase unchanged', () {
      expect(
        normalizeSha256Hex(
            'b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9'),
        'b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9',
      );
    });

    test('rejects wrong length', () {
      expect(() => normalizeSha256Hex('abcd'), throwsFormatException);
    });

    test('rejects non-hex chars', () {
      // 64 chars but contains a 'g'.
      final bad = 'b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcdez';
      expect(() => normalizeSha256Hex(bad), throwsFormatException);
    });
  });

  group('verifySha256Hex', () {
    late Directory tmp;
    late File file;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('digest_verify_');
      file = File('${tmp.path}/blob.bin');
      await file.writeAsString('hello world');
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test('returns the actual hash on match', () async {
      final hex = await verifySha256Hex(
        file: file,
        expectedHex:
            'b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9',
      );
      expect(hex,
          'b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9');
    });

    test('tolerates case + whitespace in expectedHex', () async {
      await expectLater(
        verifySha256Hex(
          file: file,
          expectedHex:
              '  B94D27B9934D3E08A52E52D7DA7DABFAC484EFE37A5380EE9088F7ACE2EFCDE9\n',
        ),
        completion(
          'b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9',
        ),
      );
    });

    test('throws DigestMismatchException on mismatch', () async {
      final wrong = '0' * 64;
      await expectLater(
        verifySha256Hex(file: file, expectedHex: wrong),
        throwsA(
          isA<DigestMismatchException>()
              .having((e) => e.expected, 'expected', wrong)
              .having(
                (e) => e.actual,
                'actual',
                'b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9',
              )
              .having((e) => e.path, 'path', file.path),
        ),
      );
    });

    test('throws FormatException when expected is not 64-hex', () async {
      await expectLater(
        verifySha256Hex(file: file, expectedHex: 'not-hex'),
        throwsFormatException,
      );
    });
  });
}
