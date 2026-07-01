// Unit tests for the six SettingCodec implementations. Each codec
// is a pure (de)serializer — fully hermetic.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/settings/setting_codec.dart';

/// Local enum used by the EnumCodec tests (avoids depending on the
/// project's real enums so this file stays self-contained).
enum _Pet { cat, dog, fish }

void main() {
  group('BoolCodec', () {
    const codec = BoolCodec();

    test('roundtrips bool ↔ bool', () {
      expect(codec.fromJson(codec.toJson(true)), isTrue);
      expect(codec.fromJson(codec.toJson(false)), isFalse);
    });

    test('accepts bool', () {
      expect(codec.fromJson(true), isTrue);
      expect(codec.fromJson(false), isFalse);
    });

    test('accepts truthy strings', () {
      expect(codec.fromJson('true'), isTrue);
      expect(codec.fromJson('TRUE'), isTrue);
      expect(codec.fromJson('1'), isTrue);
      expect(codec.fromJson('yes'), isTrue);
    });

    test('accepts falsy strings', () {
      expect(codec.fromJson('false'), isFalse);
      expect(codec.fromJson('False'), isFalse);
      expect(codec.fromJson('0'), isFalse);
      expect(codec.fromJson('no'), isFalse);
    });

    test('accepts numeric truthy/falsy', () {
      expect(codec.fromJson(1), isTrue);
      expect(codec.fromJson(0), isFalse);
      expect(codec.fromJson(42), isTrue);
    });

    test('rejects unknown types', () {
      expect(() => codec.fromJson([1]), throwsFormatException);
      expect(() => codec.fromJson(<String, String>{}), throwsFormatException);
      expect(() => codec.fromJson('maybe'), throwsFormatException);
    });
  });

  group('IntCodec', () {
    const codec = IntCodec();

    test('roundtrips int ↔ int', () {
      expect(codec.fromJson(codec.toJson(42)), 42);
      expect(codec.fromJson(codec.toJson(-7)), -7);
    });

    test('accepts int, double, and numeric strings', () {
      expect(codec.fromJson(42), 42);
      expect(codec.fromJson(42.7), 42); // truncated
      expect(codec.fromJson('42'), 42);
      expect(codec.fromJson('42.7'), 42); // parsed as double, then truncated
      expect(codec.fromJson('-3'), -3);
    });

    test('rejects unparseable strings', () {
      expect(() => codec.fromJson('not a number'), throwsFormatException);
      expect(() => codec.fromJson(<String, String>{}), throwsFormatException);
    });

    test('clamps to min/max range', () {
      const clamped = IntCodec(min: 0, max: 100);
      expect(clamped.fromJson(50), 50);
      expect(clamped.fromJson(-5), 0);
      expect(clamped.fromJson(150), 100);
    });
  });

  group('DoubleCodec', () {
    const codec = DoubleCodec();

    test('roundtrips double ↔ double', () {
      expect(codec.fromJson(codec.toJson(3.14)), 3.14);
      expect(codec.fromJson(codec.toJson(-0.5)), -0.5);
    });

    test('accepts double, int, and numeric strings', () {
      expect(codec.fromJson(3.14), 3.14);
      expect(codec.fromJson(2), 2.0);
      expect(codec.fromJson('3.14'), 3.14);
      expect(codec.fromJson('-0.5'), -0.5);
    });

    test('rejects unparseable strings', () {
      expect(() => codec.fromJson('not a number'), throwsFormatException);
      expect(() => codec.fromJson(null), throwsFormatException);
    });

    test('clamps to min/max range', () {
      const clamped = DoubleCodec(min: 0.0, max: 1.0);
      expect(clamped.fromJson(0.5), 0.5);
      expect(clamped.fromJson(-0.1), 0.0);
      expect(clamped.fromJson(1.5), 1.0);
    });
  });

  group('StringCodec', () {
    const codec = StringCodec();

    test('roundtrips string ↔ string', () {
      expect(codec.fromJson(codec.toJson('hello')), 'hello');
      expect(codec.fromJson(codec.toJson('')), '');
    });

    test('null becomes empty string', () {
      expect(codec.fromJson(null), '');
    });

    test('string passes through', () {
      expect(codec.fromJson('hello'), 'hello');
      expect(codec.fromJson(''), '');
    });

    test('non-string scalar is coerced via toString', () {
      expect(codec.fromJson(42), '42');
      expect(codec.fromJson(true), 'true');
    });
  });

  group('EnumCodec', () {
    final codec = EnumCodec<_Pet>(
      values: _Pet.values,
      name: (v) => v.name,
    );

    test('roundtrips enum value ↔ name', () {
      expect(codec.fromJson(codec.toJson(_Pet.cat)), _Pet.cat);
      expect(codec.fromJson(codec.toJson(_Pet.fish)), _Pet.fish);
    });

    test('accepts a known name', () {
      expect(codec.fromJson('cat'), _Pet.cat);
      expect(codec.fromJson('dog'), _Pet.dog);
    });

    test('rejects an unknown name with a helpful message', () {
      expect(
        () => codec.fromJson('zebra'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('zebra'), contains('cat'), contains('dog'),
                contains('fish')),
          ),
        ),
      );
    });

    test('rejects null', () {
      expect(() => codec.fromJson(null), throwsFormatException);
    });
  });

  group('ColorCodec', () {
    const codec = ColorCodec();

    test('roundtrips Color ↔ AARRGGBB hex string', () {
      final c = Color(0xFF89B4FA);
      expect(codec.fromJson(codec.toJson(c)), c);
    });

    test('roundtrips opaque + transparent colors', () {
      final opaque = Color(0xFF181818);
      final transparent = Color(0x00000000);
      expect(codec.fromJson(codec.toJson(opaque)), opaque);
      expect(codec.fromJson(codec.toJson(transparent)), transparent);
    });

    test('accepts int (raw ARGB)', () {
      expect(codec.fromJson(0xFF89B4FA), const Color(0xFF89B4FA));
      expect(codec.fromJson(0x00000000), const Color(0x00000000));
    });

    test('accepts 6-digit hex (assumes opaque alpha FF)', () {
      expect(codec.fromJson('89B4FA'), const Color(0xFF89B4FA));
      expect(codec.fromJson('#89B4FA'), const Color(0xFF89B4FA));
    });

    test('accepts 8-digit hex (explicit alpha)', () {
      expect(codec.fromJson('80CDD6F4'), const Color(0x80CDD6F4));
    });

    test('rejects unknown shape', () {
      expect(() => codec.fromJson([255, 0, 0]), throwsFormatException);
      expect(() => codec.fromJson(null), throwsFormatException);
      expect(() => codec.fromJson('not-hex'), throwsFormatException);
    });
  });
}