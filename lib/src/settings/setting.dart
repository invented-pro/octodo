// The typed settings catalog. Each setting is a value type with:
//   * a dotted JSON path (the `key`)
//   * a default value
//   * a codec (how to (de)serialize from JSON)
//   * UI hints (title, subtitle, icon, range)
//
// New settings are declared in [SettingsCatalog]; they show up
// automatically in the settings UI, the validation list, the
// search index, and the schema documentation.

import 'package:flutter/material.dart';
import 'setting_codec.dart';

abstract class Setting<T> {
  String get key;
  T get defaultValue;
  SettingCodec<T> get codec;
  String get title;
  String? get subtitle;
  IconData? get icon;

  /// When non-null, this setting is a *sub-item* of [dependsOn]: the
  /// settings UI hides the row entirely while the dependency is false
  /// (and renders it indented when visible). Used for e.g. the
  /// notification-threshold row under the notifications master toggle.
  /// The catalog stays the single source of truth — the dependency is
  /// data, not UI code.
  Setting<bool>? get dependsOn => null;
}

class BoolSetting extends Setting<bool> {
  @override
  final String key;
  @override
  final bool defaultValue;
  @override
  final String title;
  @override
  final String? subtitle;
  @override
  final IconData? icon;

  /// Hides (and indents when visible) this row while [dependsOn]
  /// evaluates false. See [Setting.dependsOn].
  @override
  final Setting<bool>? dependsOn;

  BoolSetting(
    this.key, {
    required this.defaultValue,
    required this.title,
    this.subtitle,
    this.icon,
    this.dependsOn,
  });

  @override
  SettingCodec<bool> get codec => const BoolCodec();
}

class IntSetting extends Setting<int> {
  @override
  final String key;
  @override
  final int defaultValue;
  final int? min;
  final int? max;
  @override
  final String title;
  @override
  final String? subtitle;
  @override
  final IconData? icon;

  /// Hides (and indents when visible) this row while [dependsOn]
  /// evaluates false. See [Setting.dependsOn].
  @override
  final Setting<bool>? dependsOn;

  IntSetting(
    this.key, {
    required this.defaultValue,
    this.min,
    this.max,
    required this.title,
    this.subtitle,
    this.icon,
    this.dependsOn,
  });

  @override
  SettingCodec<int> get codec => IntCodec(min: min, max: max);
}

class DoubleSetting extends Setting<double> {
  @override
  final String key;
  @override
  final double defaultValue;
  final double? min;
  final double? max;
  @override
  final String title;
  @override
  final String? subtitle;
  @override
  final IconData? icon;

  /// See [Setting.dependsOn].
  @override
  final Setting<bool>? dependsOn;

  DoubleSetting(
    this.key, {
    required this.defaultValue,
    this.min,
    this.max,
    required this.title,
    this.subtitle,
    this.icon,
    this.dependsOn,
  });

  @override
  SettingCodec<double> get codec => DoubleCodec(min: min, max: max);
}

class StringSetting extends Setting<String> {
  @override
  final String key;
  @override
  final String defaultValue;
  @override
  final String title;
  @override
  final String? subtitle;
  @override
  final IconData? icon;

  /// Optional codec override. The default [StringCodec] accepts any
  /// string; settings that need to validate (e.g. palette ids)
  /// provide a domain-specific codec here.
  final SettingCodec<String>? codecOverride;

  /// See [Setting.dependsOn].
  @override
  final Setting<bool>? dependsOn;

  StringSetting(
    this.key, {
    required this.defaultValue,
    required this.title,
    this.subtitle,
    this.icon,
    this.codecOverride,
    this.dependsOn,
  });

  @override
  SettingCodec<String> get codec => codecOverride ?? const StringCodec();
}

class EnumSetting<T extends Enum> extends Setting<T> {
  @override
  final String key;
  @override
  final T defaultValue;
  final List<T> values;
  final String Function(T) label;
  @override
  final String title;
  @override
  final String? subtitle;
  @override
  final IconData? icon;

  /// See [Setting.dependsOn].
  @override
  final Setting<bool>? dependsOn;

  EnumSetting(
    this.key, {
    required this.defaultValue,
    required this.values,
    required this.label,
    required this.title,
    this.subtitle,
    this.icon,
    this.dependsOn,
  });

  @override
  SettingCodec<T> get codec => EnumCodec<T>(values: values, name: label);
}

class ColorSetting extends Setting<Color> {
  @override
  final String key;
  @override
  final Color defaultValue;
  @override
  final String title;
  @override
  final String? subtitle;
  @override
  final IconData? icon;

  /// See [Setting.dependsOn].
  @override
  final Setting<bool>? dependsOn;

  ColorSetting(
    this.key, {
    required this.defaultValue,
    required this.title,
    this.subtitle,
    this.icon,
    this.dependsOn,
  });

  @override
  SettingCodec<Color> get codec => const ColorCodec();
}
