// Codecs: how to (de)serialize each setting type from JSON. We
// only need to (de)serialize to/from JSON for the file-backed
// store; the abstract interface also exposes fromPref/toPref as
// aliases for future UserDefaults-style stores.

import 'package:flutter/material.dart';

abstract class SettingCodec<T> {
  const SettingCodec();
  T fromJson(Object? json);
  Object? toJson(T value);
}

class BoolCodec extends SettingCodec<bool> {
  const BoolCodec();
  @override
  bool fromJson(Object? json) {
    if (json is bool) return json;
    if (json is String) {
      final s = json.toLowerCase();
      if (s == 'true' || s == '1' || s == 'yes') return true;
      if (s == 'false' || s == '0' || s == 'no') return false;
    }
    if (json is num) return json != 0;
    throw FormatException('Expected bool, got ${json.runtimeType}: $json');
  }
  @override
  Object? toJson(bool v) => v;
}

class IntCodec extends SettingCodec<int> {
  final int? min;
  final int? max;
  const IntCodec({this.min, this.max});
  @override
  int fromJson(Object? json) {
    int n;
    if (json is int) {
      n = json;
    } else if (json is num) {
      n = json.toInt();
    } else if (json is String) {
      n = int.tryParse(json) ??
          (double.tryParse(json)?.toInt() ??
              (throw FormatException('Expected int, got: $json')));
    } else {
      throw FormatException('Expected int, got ${json.runtimeType}: $json');
    }
    if (min != null && n < min!) n = min!;
    if (max != null && n > max!) n = max!;
    return n;
  }
  @override
  Object? toJson(int v) => v;
}

class DoubleCodec extends SettingCodec<double> {
  final double? min;
  final double? max;
  const DoubleCodec({this.min, this.max});
  @override
  double fromJson(Object? json) {
    double n;
    if (json is double) {
      n = json;
    } else if (json is int) {
      n = json.toDouble();
    } else if (json is num) {
      n = json.toDouble();
    } else if (json is String) {
      n = double.tryParse(json) ??
          (throw FormatException('Expected number, got: $json'));
    } else {
      throw FormatException(
          'Expected number, got ${json.runtimeType}: $json');
    }
    if (min != null && n < min!) n = min!;
    if (max != null && n > max!) n = max!;
    return n;
  }
  @override
  Object? toJson(double v) => v;
}

class StringCodec extends SettingCodec<String> {
  const StringCodec();
  @override
  String fromJson(Object? json) {
    if (json == null) return '';
    if (json is String) return json;
    return json.toString();
  }
  @override
  Object? toJson(String v) => v;
}

class EnumCodec<T extends Enum> extends SettingCodec<T> {
  final List<T> values;
  final String Function(T) name;
  const EnumCodec({required this.values, required this.name});
  @override
  T fromJson(Object? json) {
    final s = json?.toString() ?? '';
    for (final v in values) {
      if (name(v) == s) return v;
    }
    throw FormatException(
        'Unknown ${T.toString()} value: $s. Valid: ${values.map(name).toList()}');
  }
  @override
  Object? toJson(T v) => name(v);
}

class ColorCodec extends SettingCodec<Color> {
  const ColorCodec();
  @override
  Color fromJson(Object? json) {
    if (json is int) return Color(json);
    if (json is String) {
      var s = json.trim();
      if (s.startsWith('#')) s = s.substring(1);
      if (s.length == 6) s = 'FF$s'; // assume opaque
      return Color(int.parse(s, radix: 16));
    }
    throw FormatException(
        'Expected int or hex-string Color, got ${json.runtimeType}: $json');
  }
  @override
  Object? toJson(Color v) {
    final r = (v.r * 255.0).round() & 0xFF;
    final g = (v.g * 255.0).round() & 0xFF;
    final b = (v.b * 255.0).round() & 0xFF;
    final a = (v.a * 255.0).round() & 0xFF;
    return '#${a.toRadixString(16).padLeft(2, '0').toUpperCase()}'
        '${r.toRadixString(16).padLeft(2, '0').toUpperCase()}'
        '${g.toRadixString(16).padLeft(2, '0').toUpperCase()}'
        '${b.toRadixString(16).padLeft(2, '0').toUpperCase()}';
  }
}
