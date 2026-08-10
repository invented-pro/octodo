import 'package:flex_color_picker/flex_color_picker.dart';
import 'package:flutter/material.dart';

/// Opens the [flex_color_picker] HSV wheel dialog and returns the chosen color,
/// or `null` if the user cancels (Cancel, Esc, or barrier dismiss).
///
/// `onColorChanged` captures the live value because `showPickerDialog` returns
/// a `bool` (OK/Cancel), not the final [Color]. Wheel-only keeps the dialog
/// self-contained (no curated swatches to source), which is enough for a
/// single-user-chosen tint like the terminal cursor color.
Future<Color?> showColorPickerDialog(BuildContext context, Color current) async {
  Color working = current;
  final ok = await ColorPicker(
    color: current,
    onColorChanged: (c) => working = c,
    enableOpacity: false,
    showColorCode: true,
    showColorName: false,
    showMaterialName: false,
    pickersEnabled: const <ColorPickerType, bool>{
      ColorPickerType.wheel: true,
    },
    width: 36,
    height: 36,
    borderRadius: 4,
    copyPasteBehavior: const ColorPickerCopyPasteBehavior(
      copyButton: false,
      pasteButton: false,
      longPressMenu: false,
    ),
  ).showPickerDialog(
    context,
    constraints: const BoxConstraints(
      minHeight: 420,
      minWidth: 320,
      maxWidth: 320,
    ),
  );
  return ok ? working : null;
}
