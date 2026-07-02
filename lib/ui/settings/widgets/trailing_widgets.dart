// Trailing widgets used by settings rows. Each is a small,
// self-contained control that reads/writes a [Setting] via the
// provided [SettingsStore].

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../src/settings/setting.dart';
import '../../../src/settings/setting_codec.dart';
import '../../../src/settings/settings_store.dart';
import '../../../src/theme/palette_context.dart';
import '../../../src/theme/palettes.dart';

// ── Bool toggle ─────────────────────────────────────────────────────

class BoolToggleTrailing extends StatefulWidget {
  final BoolSetting setting;
  final SettingsStore store;
  const BoolToggleTrailing({super.key, required this.setting, required this.store});

  @override
  State<BoolToggleTrailing> createState() => _BoolToggleTrailingState();
}

class _BoolToggleTrailingState extends State<BoolToggleTrailing> {
  late bool _value = widget.store.get(widget.setting);
  late final StreamSubscription<bool> _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.store.watch(widget.setting).listen((v) {
      if (mounted && v != _value) setState(() => _value = v);
    });
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: widget.setting.title,
      child: Switch(
        value: _value,
        onChanged: (v) {
          setState(() => _value = v);
          widget.store.set(widget.setting, v);
        },
      ),
    );
  }
}

// ── Enum dropdown ───────────────────────────────────────────────────

class EnumDropdownTrailing<T extends Enum> extends StatefulWidget {
  final EnumSetting<T> setting;
  final SettingsStore store;
  const EnumDropdownTrailing({super.key, required this.setting, required this.store});

  @override
  State<EnumDropdownTrailing<T>> createState() => _EnumDropdownTrailingState<T>();
}

class _EnumDropdownTrailingState<T extends Enum> extends State<EnumDropdownTrailing<T>> {
  late T _value = widget.store.get(widget.setting);
  late final StreamSubscription<T> _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.store.watch(widget.setting).listen((v) {
      if (mounted && v != _value) setState(() => _value = v);
    });
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }

  String _pretty(String raw) {
    if (raw.isEmpty) return raw;
    return raw[0].toUpperCase() + raw.substring(1);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      label: widget.setting.title,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: palette.dialogSurface,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: palette.outline, width: 1),
        ),
        child: DropdownButton<T>(
          value: _value,
          isDense: true,
          underline: const SizedBox.shrink(),
          dropdownColor: palette.popupSurface,
          style: TextStyle(color: palette.textPrimary, fontSize: 12),
          items: [
            for (final v in widget.setting.values)
              DropdownMenuItem<T>(
                value: v,
                child: Text(_pretty(widget.setting.label(v))),
              ),
          ],
          onChanged: (v) {
            if (v == null) return;
            setState(() => _value = v);
            widget.store.set(widget.setting, v);
          },
        ),
      ),
    );
  }
}

// ── Int input ───────────────────────────────────────────────────────

class IntInputTrailing extends StatefulWidget {
  final IntSetting setting;
  final SettingsStore store;
  const IntInputTrailing({super.key, required this.setting, required this.store});

  @override
  State<IntInputTrailing> createState() => _IntInputTrailingState();
}

class _IntInputTrailingState extends State<IntInputTrailing> {
  late int _value;
  late final TextEditingController _controller;
  String? _errorText;
  StreamSubscription<int>? _sub;

  @override
  void initState() {
    super.initState();
    _value = widget.store.get(widget.setting);
    _controller = TextEditingController(text: _value.toString());
    _sub = widget.store.watch(widget.setting).listen((v) {
      if (!mounted) return;
      if (v != _value) {
        setState(() {
          _value = v;
          _controller.text = v.toString();
          _errorText = null;
        });
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _controller.dispose();
    super.dispose();
  }

  int _step() {
    final raw = (_value * 0.10).round();
    return raw < 1 ? 1 : raw;
  }

  void _bump(int sign) {
    final step = _step();
    final next = (_value + sign * step).clamp(
      widget.setting.min ?? -0x7FFFFFFF,
      widget.setting.max ?? 0x7FFFFFFF,
    );
    setState(() {
      _value = next;
      _controller.text = next.toString();
      _errorText = null;
    });
    widget.store.set(widget.setting, next);
  }

  /// Apply the textfield's contents to the store. Validates against
  /// the setting's [IntSetting.min]/[IntSetting.max] window. On
  /// success, the textfield is normalised to the canonical form
  /// (e.g. "  10000 " → "10000"). On failure the [errorText] is set
  /// so the row can show what's wrong without applying a bad value.
  void _submit() {
    final raw = _controller.text.trim();
    final parsed = int.tryParse(raw);
    final min = widget.setting.min;
    final max = widget.setting.max;
    if (parsed == null) {
      setState(() => _errorText = 'Enter an integer');
      return;
    }
    if ((min != null && parsed < min) || (max != null && parsed > max)) {
      final lo = min == null ? '−∞' : min.toString();
      final hi = max == null ? '∞' : max.toString();
      setState(() => _errorText = 'Must be between $lo and $hi');
      return;
    }
    setState(() {
      _value = parsed;
      _controller.text = parsed.toString();
      _errorText = null;
    });
    widget.store.set(widget.setting, parsed);
  }

  /// On focus loss: commit valid pending edits silently, revert
  /// invalid ones. Avoids the situation where the user tabbed out
  /// with a valid value they expect to apply, but doesn't yank a
  /// bad value into the store.
  void _handleFocusLoss() {
    final raw = _controller.text.trim();
    final parsed = int.tryParse(raw);
    final min = widget.setting.min;
    final max = widget.setting.max;
    if (parsed == null || parsed == _value ||
        (min != null && parsed < min) ||
        (max != null && parsed > max)) {
      if (mounted) {
        setState(() {
          _controller.text = _value.toString();
          _errorText = null;
        });
      }
      return;
    }
    setState(() {
      _value = parsed;
      _controller.text = parsed.toString();
      _errorText = null;
    });
    widget.store.set(widget.setting, parsed);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      label: widget.setting.title,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.remove, size: 14),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 26, height: 26),
            tooltip: 'Decrement by 10%',
            onPressed: () => _bump(-1),
          ),
          SizedBox(
            width: 80,
            child: TextField(
              controller: _controller,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _errorText != null
                    ? palette.accentPink
                    : palette.textPrimary,
                fontSize: 12,
              ),
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9]')),
              ],
              cursorColor: palette.accentBlue,
              decoration: InputDecoration(
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                filled: true,
                fillColor: palette.dialogSurface,
                errorText: _errorText,
                errorStyle: const TextStyle(fontSize: 10, height: 1.2),
                errorMaxLines: 2,
                border: _border(palette: palette, focused: false, hasError: false),
                enabledBorder: _border(palette: palette, focused: false, hasError: false),
                focusedBorder:
                    _border(palette: palette, focused: true, hasError: _errorText != null),
              ),
              onSubmitted: (_) => _submit(),
              onTapOutside: (_) => _handleFocusLoss(),
              onEditingComplete: _submit,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add, size: 14),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 26, height: 26),
            tooltip: 'Increment by 10%',
            onPressed: () => _bump(1),
          ),
        ],
      ),
    );
  }

  OutlineInputBorder _border({
    required ThemePalette palette,
    required bool focused,
    required bool hasError,
  }) {
    final color = hasError
        ? palette.accentPink
        : focused
            ? palette.accentBlue
            : palette.outline;
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(4),
      borderSide: BorderSide(color: color, width: 1),
    );
  }
}

// ── Double input ────────────────────────────────────────────────────

class DoubleInputTrailing extends StatefulWidget {
  final DoubleSetting setting;
  final SettingsStore store;
  const DoubleInputTrailing({super.key, required this.setting, required this.store});

  @override
  State<DoubleInputTrailing> createState() => _DoubleInputTrailingState();
}

class _DoubleInputTrailingState extends State<DoubleInputTrailing> {
  late double _value;
  late final TextEditingController _controller;
  String? _errorText;
  StreamSubscription<double>? _sub;

  @override
  void initState() {
    super.initState();
    _value = widget.store.get(widget.setting);
    _controller = TextEditingController(text: _formatValue(_value));
    _sub = widget.store.watch(widget.setting).listen((v) {
      if (!mounted) return;
      if (v != _value) {
        setState(() {
          _value = v;
          _controller.text = _formatValue(v);
          _errorText = null;
        });
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _controller.dispose();
    super.dispose();
  }

  String _formatValue(double v) {
    return v.truncateToDouble() == v
        ? v.toStringAsFixed(0)
        : v.toStringAsFixed(1);
  }

  void _submit() {
    final raw = _controller.text.trim();
    final parsed = double.tryParse(raw);
    final min = widget.setting.min;
    final max = widget.setting.max;
    if (parsed == null) {
      setState(() => _errorText = 'Enter a number');
      return;
    }
    if ((min != null && parsed < min) || (max != null && parsed > max)) {
      final lo = min == null ? '−∞' : min.toString();
      final hi = max == null ? '∞' : max.toString();
      setState(() => _errorText = 'Must be between $lo and $hi');
      return;
    }
    setState(() {
      _value = parsed;
      _controller.text = _formatValue(parsed);
      _errorText = null;
    });
    widget.store.set(widget.setting, parsed);
  }

  void _handleFocusLoss() {
    final raw = _controller.text.trim();
    final parsed = double.tryParse(raw);
    final min = widget.setting.min;
    final max = widget.setting.max;
    if (parsed == null || parsed == _value ||
        (min != null && parsed < min) ||
        (max != null && parsed > max)) {
      if (mounted) {
        setState(() {
          _controller.text = _formatValue(_value);
          _errorText = null;
        });
      }
      return;
    }
    setState(() {
      _value = parsed;
      _controller.text = _formatValue(parsed);
      _errorText = null;
    });
    widget.store.set(widget.setting, parsed);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      label: widget.setting.title,
      child: SizedBox(
        width: 96,
        child: TextField(
          controller: _controller,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: _errorText != null
                ? palette.accentPink
                : palette.textPrimary,
            fontSize: 12,
          ),
          keyboardType:
              const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(
              RegExp(r'[0-9.]'),
            ),
          ],
          cursorColor: palette.accentBlue,
          decoration: InputDecoration(
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            filled: true,
            fillColor: palette.dialogSurface,
            errorText: _errorText,
            errorStyle: const TextStyle(fontSize: 10, height: 1.2),
            errorMaxLines: 2,
            border: _border(palette: palette, focused: false, hasError: false),
            enabledBorder: _border(palette: palette, focused: false, hasError: false),
            focusedBorder:
                _border(palette: palette, focused: true, hasError: _errorText != null),
          ),
          onSubmitted: (_) => _submit(),
          onTapOutside: (_) => _handleFocusLoss(),
          onEditingComplete: _submit,
        ),
      ),
    );
  }

  OutlineInputBorder _border({
    required ThemePalette palette,
    required bool focused,
    required bool hasError,
  }) {
    final color = hasError
        ? palette.accentPink
        : focused
            ? palette.accentBlue
            : palette.outline;
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(4),
      borderSide: BorderSide(color: color, width: 1),
    );
  }
}

// ── String text field ───────────────────────────────────────────────

class StringTextFieldTrailing extends StatefulWidget {
  final StringSetting setting;
  final SettingsStore store;
  const StringTextFieldTrailing({super.key, required this.setting, required this.store});

  @override
  State<StringTextFieldTrailing> createState() => _StringTextFieldTrailingState();
}

class _StringTextFieldTrailingState extends State<StringTextFieldTrailing> {
  late final TextEditingController _controller;
  late final StreamSubscription<String> _sub;

  @override
  void initState() {
    super.initState();
    _controller =
        TextEditingController(text: widget.store.get(widget.setting));
    _sub = widget.store.watch(widget.setting).listen((v) {
      if (mounted && v != _controller.text) {
        _controller.text = v;
      }
    });
  }

  @override
  void dispose() {
    _sub.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      label: widget.setting.title,
      child: SizedBox(
        width: 160,
        child: TextField(
          controller: _controller,
          style: TextStyle(color: palette.textPrimary, fontSize: 12),
          cursorColor: palette.accentBlue,
          decoration: InputDecoration(
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            filled: true,
            fillColor: palette.dialogSurface,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: BorderSide(color: palette.outline, width: 1),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: BorderSide(color: palette.outline, width: 1),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: BorderSide(color: palette.accentBlue, width: 1),
            ),
          ),
          onSubmitted: (v) => widget.store.set(widget.setting, v),
          onEditingComplete: () => widget.store.set(widget.setting, _controller.text),
        ),
      ),
    );
  }
}

// ── Font family dropdown ────────────────────────────────────────────

/// Monospace fonts commonly installed on Windows 10/11 plus the CJK
/// families our terminal relies on as fallback glyphs. Listed in
/// priority order — the user's current value is always shown even if
/// not in this list (e.g. a custom installed font).
const _kKnownMonospaceFonts = <String>[
  // Western monospace (the typical primary choice)
  'Cascadia Code',
  'Cascadia Mono',
  'Cascadia Code PL',
  'Consolas',
  'Lucida Console',
  'Courier New',
  // East Asian (CJK fallback chain matches TerminalView's hardcoded list)
  'Microsoft YaHei',
  'Microsoft YaHei UI',
  'SimSun',
  'NSimSun',
  'MS Gothic',
  'MS Mincho',
  // Last-resort (always available)
  'monospace',
];

/// Dropdown that lists the monospace fonts typically installed on
/// Windows plus the user's currently-selected font (in case it's a
/// custom face not in the known list). Replaces the free-text field
/// for `terminal.fontFamily` so the user can't enter typos that would
/// silently fall back to `monospace`.
class FontFamilyDropdownTrailing extends StatefulWidget {
  final StringSetting setting;
  final SettingsStore store;
  const FontFamilyDropdownTrailing({
    super.key,
    required this.setting,
    required this.store,
  });

  @override
  State<FontFamilyDropdownTrailing> createState() =>
      _FontFamilyDropdownTrailingState();
}

class _FontFamilyDropdownTrailingState
    extends State<FontFamilyDropdownTrailing> {
  late String _value = widget.store.get(widget.setting);
  late final StreamSubscription<String> _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.store.watch(widget.setting).listen((v) {
      if (mounted && v != _value) setState(() => _value = v);
    });
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }

  /// Build the option list: known fonts in priority order, with the
  /// user's current value pinned to the top if it isn't in the list
  /// (handles custom-installed fonts the user has previously picked).
  List<String> _options() {
    final seen = <String>{};
    final out = <String>[];
    if (_value.isNotEmpty && !_kKnownMonospaceFonts.contains(_value)) {
      out.add(_value);
      seen.add(_value);
    }
    for (final f in _kKnownMonospaceFonts) {
      if (seen.add(f)) out.add(f);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      label: widget.setting.title,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: palette.dialogSurface,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: palette.outline, width: 1),
        ),
        child: DropdownButton<String>(
          value: _value,
          isDense: true,
          underline: const SizedBox.shrink(),
          isExpanded: false,
          dropdownColor: palette.popupSurface,
          style: TextStyle(color: palette.textPrimary, fontSize: 12),
          items: [
            for (final f in _options())
              DropdownMenuItem<String>(
                value: f,
                // Render the dropdown entry in the actual font face so the
                // user can visually compare; if the font is missing
                // Flutter falls back gracefully to the default sans-serif.
                child: Text(
                  f,
                  style: TextStyle(
                    color: palette.textPrimary,
                    fontSize: 12,
                    fontFamily: f,
                  ),
                ),
              ),
          ],
          onChanged: (v) {
            if (v == null) return;
            setState(() => _value = v);
            widget.store.set(widget.setting, v);
          },
        ),
      ),
    );
  }
}

// ── Color hex field ─────────────────────────────────────────────────

class ColorHexFieldTrailing extends StatefulWidget {
  final ColorSetting setting;
  final SettingsStore store;
  const ColorHexFieldTrailing({super.key, required this.setting, required this.store});

  @override
  State<ColorHexFieldTrailing> createState() => _ColorHexFieldTrailingState();
}

class _ColorHexFieldTrailingState extends State<ColorHexFieldTrailing> {
  static final _hexPattern =
      RegExp(r'^#?[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$');

  late final Color _initialValue = widget.store.get(widget.setting);
  late final TextEditingController _controller;
  late Color _value = _initialValue;
  String? _errorText;
  late final StreamSubscription<Color> _sub;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _format(_initialValue));
    _sub = widget.store.watch(widget.setting).listen((v) {
      if (mounted && v != _value) {
        setState(() {
          _value = v;
          _errorText = null;
          _controller.text = _format(v);
        });
      }
    });
  }

  @override
  void dispose() {
    _sub.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// Format a [Color] as a hex string suitable for editing.
  /// Drops the alpha prefix when it's `FF` (opaque). Length-based
  /// (not string-search) so we never corrupt a user-typed alpha
  /// byte that happens to be `FF`.
  String _format(Color c) {
    final r = (c.r * 255).round() & 0xFF;
    final g = (c.g * 255).round() & 0xFF;
    final b = (c.b * 255).round() & 0xFF;
    final hex = '#'
        '${r.toRadixString(16).padLeft(2, '0').toUpperCase()}'
        '${g.toRadixString(16).padLeft(2, '0').toUpperCase()}'
        '${b.toRadixString(16).padLeft(2, '0').toUpperCase()}';
    final a = (c.a * 255).round() & 0xFF;
    if (a == 0xFF) return hex;
    return '#${a.toRadixString(16).padLeft(2, '0').toUpperCase()}${hex.substring(1)}';
  }

  void _apply(String text) {
    final normalized = text.trim();
    if (!_hexPattern.hasMatch(normalized)) {
      setState(() => _errorText = 'Expected #RRGGBB or #AARRGGBB');
      return;
    }
    try {
      final c = const ColorCodec().fromJson(normalized);
      setState(() {
        _value = c;
        _errorText = null;
        _controller.text = _format(c);
      });
      widget.store.set(widget.setting, c);
    } catch (e) {
      setState(() => _errorText = 'Invalid color: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      label: widget.setting.title,
      child: SizedBox(
        width: 140,
        child: Row(
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: _value,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: palette.accentBlue, width: 1),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _controller,
                style: TextStyle(
                  color: palette.textPrimary,
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
                cursorColor: palette.accentBlue,
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  filled: true,
                  fillColor: palette.dialogSurface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide:
                        BorderSide(color: palette.outline, width: 1),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide:
                        BorderSide(color: palette.outline, width: 1),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide:
                        BorderSide(color: palette.accentBlue, width: 1),
                  ),
                  errorText: _errorText,
                ),
                onSubmitted: _apply,
                onEditingComplete: () => _apply(_controller.text),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Theme picker ────────────────────────────────────────────────────

/// Dropdown that lists every built-in [ThemePalette] by display name,
/// grouped by brightness (Dark themes first, then Light) with
/// section headers in between. Editing this widget retints the whole
/// chrome immediately (the top-level MaterialApp rebuilds via its
/// `appearance.themeName` subscription).
///
/// Implementation note: Flutter's stock [DropdownButton] has no
/// native section-header support, so the headers are injected as
/// disabled [DropdownMenuItem]s whose text is rendered in the
/// "muted" tier — they read as labels but cannot be selected, and
/// Material's hover/click feedback still suppresses any focus ring
/// because they're `enabled: false`.
class ThemeDropdownTrailing extends StatefulWidget {
  final StringSetting setting;
  final SettingsStore store;
  const ThemeDropdownTrailing({
    super.key,
    required this.setting,
    required this.store,
  });

  @override
  State<ThemeDropdownTrailing> createState() =>
      _ThemeDropdownTrailingState();
}

class _ThemeDropdownTrailingState extends State<ThemeDropdownTrailing> {
  late String _value = widget.store.get(widget.setting);
  late final StreamSubscription<String> _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.store.watch(widget.setting).listen((v) {
      if (mounted && v != _value) setState(() => _value = v);
    });
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }

  /// Sentinel ids for the synthetic section headers we splice into
  /// the dropdown item list. We pick ids the registry will never
  /// produce (`__` prefix + lowercase hex) so they can't collide
  /// with a real palette even by accident.
  static const String _darkHeaderId = '__theme_section_dark';
  static const String _lightHeaderId = '__theme_section_light';

  /// Build the dropdown item list. Section headers come first (dark),
  /// then the dark palettes in registry order; then the light header,
  /// then the light palettes. Each section header is a disabled item
  /// so it shows up in the popup but can't be picked.
  List<DropdownMenuItem<String>> _items(BuildContext context) {
    final palette = context.palette;
    final dark = AppPalettes.all
        .where((p) => p.brightness == Brightness.dark)
        .toList(growable: false);
    final light = AppPalettes.all
        .where((p) => p.brightness == Brightness.light)
        .toList(growable: false);
    Widget header(String text) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                text == 'Dark' ? Icons.dark_mode : Icons.light_mode,
                size: 11,
                color: palette.textMuted,
              ),
              const SizedBox(width: 6),
              Text(
                text.toUpperCase(),
                style: TextStyle(
                  color: palette.textMuted,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6,
                ),
              ),
            ],
          ),
        );
    Widget item(ThemePalette p) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              p.brightness == Brightness.dark
                  ? Icons.dark_mode
                  : Icons.light_mode,
              size: 13,
              color: palette.textMuted,
            ),
            const SizedBox(width: 8),
            Text(p.displayName),
          ],
        );
    return [
      DropdownMenuItem<String>(
        value: _darkHeaderId,
        enabled: false,
        child: header('Dark'),
      ),
      for (final p in dark)
        DropdownMenuItem<String>(value: p.id, child: item(p)),
      DropdownMenuItem<String>(
        value: _lightHeaderId,
        enabled: false,
        child: header('Light'),
      ),
      for (final p in light)
        DropdownMenuItem<String>(value: p.id, child: item(p)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      label: widget.setting.title,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: palette.dialogSurface,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: palette.outline, width: 1),
        ),
        child: DropdownButton<String>(
          value: _value,
          isDense: true,
          underline: const SizedBox.shrink(),
          isExpanded: false,
          dropdownColor: palette.popupSurface,
          style: TextStyle(color: palette.textPrimary, fontSize: 12),
          items: _items(context),
          // Section-header ids must be filtered out of the
          // `onChanged` callback: `DropdownButton` still emits a
          // selection event for disabled items when their row is
          // hovered (so the highlight ripple works), but here we
          // must not commit a sentinel id to the store. The
          // `enabled: false` flag already prevents the user from
          // confirming a click on a header — this is belt-and-
          // suspenders for keyboard activation (Enter on a focused
          // header row still fires `onChanged` in some Flutter
          // versions).
          onChanged: (v) {
            if (v == null ||
                v == _darkHeaderId ||
                v == _lightHeaderId) {
              return;
            }
            setState(() => _value = v);
            widget.store.set(widget.setting, v);
          },
        ),
      ),
    );
  }
}

// ── Generic "Reset to default" button ───────────────────────────────

class ResetButtonTrailing extends StatelessWidget {
  final Setting<dynamic> setting;
  final SettingsStore store;
  final bool isAtDefault;
  const ResetButtonTrailing({
    super.key,
    required this.setting,
    required this.store,
    required this.isAtDefault,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      label: '${setting.title}, reset to default',
      child: IconButton(
        icon: Icon(Icons.refresh,
            size: 15,
            color: isAtDefault
                ? palette.outline
                : palette.textSecondary),
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 28, height: 28),
        tooltip: isAtDefault ? 'Already at default' : 'Reset to default',
        onPressed: isAtDefault ? null : () => store.reset(setting),
      ),
    );
  }
}
