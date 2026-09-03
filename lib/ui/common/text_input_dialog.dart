import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../src/theme/palette_context.dart';

/// Opens a small single-line text-input [AlertDialog] and returns the
/// submitted value **trimmed** — which may be empty (meaning "clear"),
/// matching the tab-rename contract where empty input reverts to the
/// automatic title. Returns `null` when the user cancels (Cancel
/// button, Esc, or barrier dismiss), leaving the current value alone.
///
/// There is no other text-input dialog in the app (the workspace
/// rename is an inline TextField), so this stays generic: title,
/// initial value, hint, max length and confirm label are all callers'
/// choice. Mirrors `showColorPickerDialog` as a plain top-level
/// future-returning helper.
Future<String?> showTextInputDialog(
  BuildContext context, {
  required String title,
  String initialValue = '',
  String? hintText,
  int maxLength = 64,
  String confirmLabel = 'OK',
}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => _TextInputDialog(
      title: title,
      initialValue: initialValue,
      hintText: hintText,
      maxLength: maxLength,
      confirmLabel: confirmLabel,
    ),
  );
}

class _TextInputDialog extends StatefulWidget {
  final String title;
  final String initialValue;
  final String? hintText;
  final int maxLength;
  final String confirmLabel;

  const _TextInputDialog({
    required this.title,
    required this.initialValue,
    required this.maxLength,
    required this.confirmLabel,
    this.hintText,
  });

  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
    // Select-all so the dialog opens in "type to replace" mode, while
    // End / arrows still let the user append to the initial value.
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.initialValue.length,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text.trim());

  void _cancel() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return AlertDialog(
      title: Text(widget.title),
      content: Focus(
        // Esc cancels deterministically even while the TextField owns
        // focus (the modal barrier only sees Esc when nothing inside
        // the dialog has focus). Same pattern as the workspace
        // inline rename in main.dart.
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape) {
            _cancel();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: TextField(
          controller: _controller,
          autofocus: true,
          onSubmitted: (_) => _submit(),
          maxLength: widget.maxLength,
          cursorColor: palette.accentBlue,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            hintText: widget.hintText,
            counterText: '',
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _cancel, child: const Text('Cancel')),
        TextButton(onPressed: _submit, child: Text(widget.confirmLabel)),
      ],
    );
  }
}
