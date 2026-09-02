// Tests for `manifest_signature.dart` — the Ed25519 release-signature
// gate (GH issue #5, item 2).
//
// Two key sets are exercised:
//   * a deterministic DEV keypair (fixed seed, generated in-process
//     with the same `cryptography` Ed25519 the app verifies with) —
//     used for round-trip and tamper-detection cases;
//   * the PRODUCTION key — the `kInterop*` fixture below is a real
//     `openssl pkeyutl -sign -rawin` signature produced with the
//     sops-encrypted private half of `kUpdateSigningPublicKey`. It
//     pins the CI(sign, openssl/bash) ↔ app(verify, Dart) contract:
//     if either side drifts (message format, hash casing, padding),
//     this test fails before a release ships that no build can
//     update from.

import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/update/manifest_signature.dart';

void main() {
  // Deterministic dev keypair — 32-byte seed, all bits owned by the
  // test. The public half is passed as `publicKeysBase64` to the
  // verifier the same way production passes the embedded const.
  final devSeed = List<int>.generate(32, (i) => i * 7 + 1);
  late SimpleKeyPair devKeyPair;
  late String devPubB64;

  setUpAll(() async {
    devKeyPair = await Ed25519().newKeyPairFromSeed(devSeed);
    final pub = await devKeyPair.extractPublicKey();
    devPubB64 = base64.encode(pub.bytes);
  });

  // Real openssl signature over this exact message, made with the
  // production private key — see file header.
  const kInteropVersion = '9.9.9';
  const kInteropAsset = 'octodo-v9.9.9-windows-x64.zip';
  final kInteropDigest = 'ab' * 32;
  const kInteropSigB64 =
      'Da4D97L7f3lioJrEGWqhbtsAEh1lCgt/0tHq/xcvgdHrBBZTW+RTkjnJTEKa2VIxlSJBI/2PcmyBYuKv2E2GBQ==';

  String sigBody(List<String> lines) =>
      '${[kSignatureFileHeader, ...lines].join('\n')}\n';

  Future<String> devSig(String version, String asset, String hex) async {
    final msg = canonicalUpdateMessage(version, asset, hex);
    final sig = await Ed25519()
        .sign(utf8.encode(msg), keyPair: devKeyPair);
    return base64.encode(sig.bytes);
  }

  group('openssl interop (production key)', () {
    test('CI-style signature verifies against the embedded key', () async {
      await verifyAssetSignature(
        body: sigBody(['$kInteropAsset $kInteropDigest $kInteropSigB64']),
        version: kInteropVersion,
        assetName: kInteropAsset,
        digestHex: kInteropDigest,
      );
    });

    test('canonical message matches the bash contract byte-for-byte', () {
      expect(
        canonicalUpdateMessage(kInteropVersion, kInteropAsset,
            kInteropDigest.toUpperCase()),
        'octodo-update-v1|$kInteropVersion|$kInteropAsset|$kInteropDigest',
      );
    });
  });

  group('verifyAssetSignature — happy path', () {
    test('dev-key round trip with multiple entries', () async {
      final sig = await devSig('1.2.3', 'octodo-v1.2.3-windows-x64.zip',
          'cd' * 32);
      await verifyAssetSignature(
        body: sigBody([
          'octodo-v1.2.3-macos-arm64.zip ${'ef' * 32} ignored-not-verified',
          'octodo-v1.2.3-windows-x64.zip ${'cd' * 32} $sig',
        ]),
        version: '1.2.3',
        assetName: 'octodo-v1.2.3-windows-x64.zip',
        digestHex: 'cd' * 32,
        publicKeysBase64: [devPubB64],
      );
    });

    test('sidecar digest casing is normalized before compare', () async {
      final sig = await devSig('1.2.3', 'a.zip', 'cd' * 32);
      await verifyAssetSignature(
        body: sigBody(['a.zip ${'cd' * 32} $sig']),
        version: '1.2.3',
        assetName: 'a.zip',
        digestHex: ('CD' * 32),
        publicKeysBase64: [devPubB64],
      );
    });
  });

  group('verifyAssetSignature — fail closed', () {
    test('no entry for the asset', () async {
      final sig = await devSig('1.2.3', 'other.zip', 'cd' * 32);
      await expectLater(
        verifyAssetSignature(
          body: sigBody(['other.zip ${'cd' * 32} $sig']),
          version: '1.2.3',
          assetName: 'a.zip',
          digestHex: 'cd' * 32,
          publicKeysBase64: [devPubB64],
        ),
        throwsA(isA<UpdateSignatureException>()),
      );
    });

    test('duplicate entries for the asset', () async {
      final sig = await devSig('1.2.3', 'a.zip', 'cd' * 32);
      await expectLater(
        verifyAssetSignature(
          body: sigBody([
            'a.zip ${'cd' * 32} $sig',
            'a.zip ${'cd' * 32} $sig',
          ]),
          version: '1.2.3',
          assetName: 'a.zip',
          digestHex: 'cd' * 32,
          publicKeysBase64: [devPubB64],
        ),
        throwsA(isA<UpdateSignatureException>()),
      );
    });

    test('signed digest disagrees with the sidecar (tamper signal)',
        () async {
      // Signature genuinely covers digest A; the sidecar claims B.
      // Whichever channel was tampered with, refuse.
      final sig = await devSig('1.2.3', 'a.zip', 'cd' * 32);
      await expectLater(
        verifyAssetSignature(
          body: sigBody(['a.zip ${'cd' * 32} $sig']),
          version: '1.2.3',
          assetName: 'a.zip',
          digestHex: 'ef' * 32,
          publicKeysBase64: [devPubB64],
        ),
        throwsA(isA<UpdateSignatureException>().having(
          (e) => e.reason,
          'reason',
          contains('sidecar'),
        )),
      );
    });

    test('signature by an unknown key', () async {
      final sig = await devSig('1.2.3', 'a.zip', 'cd' * 32);
      final otherSeed = List<int>.generate(32, (i) => 255 - i);
      final otherKey = await Ed25519().newKeyPairFromSeed(otherSeed);
      final otherPub = await otherKey.extractPublicKey();
      await expectLater(
        verifyAssetSignature(
          body: sigBody(['a.zip ${'cd' * 32} $sig']),
          version: '1.2.3',
          assetName: 'a.zip',
          digestHex: 'cd' * 32,
          publicKeysBase64: [base64.encode(otherPub.bytes)],
        ),
        throwsA(isA<UpdateSignatureException>()),
      );
    });

    test('signature replayed across versions does not verify', () async {
      final sig = await devSig('1.2.3', 'a.zip', 'cd' * 32);
      await expectLater(
        verifyAssetSignature(
          body: sigBody(['a.zip ${'cd' * 32} $sig']),
          version: '9.9.9', // different from what was signed
          assetName: 'a.zip',
          digestHex: 'cd' * 32,
          publicKeysBase64: [devPubB64],
        ),
        throwsA(isA<UpdateSignatureException>()),
      );
    });

    test('missing header line', () async {
      await expectLater(
        verifyAssetSignature(
          body: 'a.zip ${'cd' * 32} not-even-checked\n',
          version: '1.2.3',
          assetName: 'a.zip',
          digestHex: 'cd' * 32,
          publicKeysBase64: [devPubB64],
        ),
        throwsA(isA<UpdateSignatureException>()),
      );
    });

    test('empty body / garbage lines', () async {
      for (final body in ['', '# octodo-update-sig-v1\n', 'one two\n']) {
        await expectLater(
          verifyAssetSignature(
            body: body,
            version: '1.2.3',
            assetName: 'a.zip',
            digestHex: 'cd' * 32,
            publicKeysBase64: [devPubB64],
          ),
          throwsA(isA<UpdateSignatureException>()),
          reason: 'body: $body',
        );
      }
    });

    test('non-base64 / wrong-length signature fields', () async {
      for (final sigField in ['!!!notb64!!!', 'AAAA']) {
        await expectLater(
          verifyAssetSignature(
            body: sigBody(['a.zip ${'cd' * 32} $sigField']),
            version: '1.2.3',
            assetName: 'a.zip',
            digestHex: 'cd' * 32,
            publicKeysBase64: [devPubB64],
          ),
          throwsA(isA<UpdateSignatureException>()),
          reason: 'sig field: $sigField',
        );
      }
    });

    test('no public keys configured', () async {
      await expectLater(
        verifyAssetSignature(
          body: sigBody(['a.zip ${'cd' * 32} AAAA']),
          version: '1.2.3',
          assetName: 'a.zip',
          digestHex: 'cd' * 32,
          publicKeysBase64: const [],
        ),
        throwsA(isA<UpdateSignatureException>()),
      );
    });
  });

  group('parseSignatureFile', () {
    test('skips blanks and unrelated comments', () {
      final sig = 'x' * 88;
      final entries = parseSignatureFile(
        '$kSignatureFileHeader\n# unrelated comment\n\n'
        'a.zip ${'cd' * 32} $sig\n\n',
      );
      expect(entries, hasLength(1));
      expect(entries.single.assetName, 'a.zip');
      expect(entries.single.digestHex, 'cd' * 32);
    });
  });
}
