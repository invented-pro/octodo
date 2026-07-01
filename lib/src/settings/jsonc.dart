// JSON-with-comments parser. Strips // line comments, /* */ block
// comments, and trailing commas, then defers to dart:convert.
//
// State machine walks the input character by character so we don't
// strip comments that appear inside string literals.

import 'dart:convert';

class JsoncParseException implements Exception {
  final String message;
  final int offset;
  JsoncParseException(this.message, this.offset);
  @override
  String toString() => 'JsoncParseException(offset=$offset): $message';
}

const _whitespace = {' ', '\t', '\n', '\r'};

/// Parse a JSONC string. Throws [JsoncParseException] on syntax
/// errors and [FormatException] from dart:convert on bad JSON.
Object? jsoncDecode(String input) {
  final stripped = _stripJsonc(input);
  return jsonDecode(stripped);
}

/// Encode a value to JSONC (just pretty-printed JSON; we don't
/// currently emit comments).
String jsoncEncode(Object? value) {
  const encoder = JsonEncoder.withIndent('  ');
  return encoder.convert(value);
}

String _stripJsonc(String input) {
  final out = StringBuffer();
  var i = 0;
  // States:
  // 0 = normal
  // 1 = in double-quoted string
  // 2 = in single-quoted string (non-standard but tolerate)
  // 3 = in line comment
  // 4 = in block comment
  var state = 0;
  while (i < input.length) {
    final c = input[i];
    switch (state) {
      case 0:
        if (c == '"') {
          out.write(c);
          state = 1;
        } else if (c == "'") {
          out.write(c);
          state = 2;
        } else if (c == '/' && i + 1 < input.length) {
          final next = input[i + 1];
          if (next == '/') {
            state = 3;
            i++; // consume the second '/'
          } else if (next == '*') {
            state = 4;
            i++; // consume the '*'
          } else {
            out.write(c);
          }
        } else {
          out.write(c);
        }
        i++;
        break;
      case 1:
        out.write(c);
        if (c == r'\') {
          // Escape: write the next char too.
          if (i + 1 < input.length) {
            out.write(input[i + 1]);
            i++;
          }
        } else if (c == '"') {
          state = 0;
        }
        i++;
        break;
      case 2:
        out.write(c);
        if (c == r'\') {
          if (i + 1 < input.length) {
            out.write(input[i + 1]);
            i++;
          }
        } else if (c == "'") {
          state = 0;
        }
        i++;
        break;
      case 3:
        // Line comment: skip until \n (write the \n so line numbers
        // are preserved in any error messages from jsonDecode).
        if (c == '\n') {
          out.write(c);
          state = 0;
        }
        i++;
        break;
      case 4:
        // Block comment: skip until */.
        if (c == '*' && i + 1 < input.length && input[i + 1] == '/') {
          state = 0;
          i++; // consume the '/'
        }
        i++;
        break;
    }
  }
  if (state == 3) {
    // Trailing line comment without newline — that's fine, just EOF.
    state = 0;
  }
  if (state == 4) {
    throw JsoncParseException('Unterminated block comment', i);
  }
  if (state == 1 || state == 2) {
    throw JsoncParseException('Unterminated string literal', i);
  }
  return _stripTrailingCommas(out.toString());
}

/// Replace `,` immediately followed by `}` or `]` (with optional
/// whitespace/newline in between) with empty. Handles the case
/// where the comma sits on the next line.
String _stripTrailingCommas(String input) {
  final out = StringBuffer();
  var i = 0;
  while (i < input.length) {
    final c = input[i];
    if (c == ',') {
      // Look ahead through whitespace for `}` or `]`.
      var j = i + 1;
      while (j < input.length && _whitespace.contains(input[j])) {
        j++;
      }
      if (j < input.length && (input[j] == '}' || input[j] == ']')) {
        // Drop the comma.
        i++;
        continue;
      }
    }
    out.write(c);
    i++;
  }
  return out.toString();
}
