// Validates that native → Dart UTF-8 string decoding preserves a leading BOM
// (U+FEFF). Bridge strings are raw data, not text streams, so every byte must
// survive. The decode uses the fast native Utf8Decoder (perf-audit "C"); this
// test guards the BOM-preservation behavior that the previous per-byte decoder
// existed to provide.
import 'dart:convert';
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:nitro/src/ffi_utils.dart';
import 'package:test/test.dart';

/// Allocates a NUL-terminated native UTF-8 buffer for [s], decodes it back via
/// the real bridge path (which frees the buffer), and returns the result.
String roundTrip(String s) {
  final bytes = utf8.encode(s);
  final ptr = calloc<Uint8>(bytes.length + 1); // +1 NUL, calloc zero-fills
  ptr.asTypedList(bytes.length).setAll(0, bytes);
  return ptr.cast<Utf8>().toDartStringFreedBy(calloc.free);
}

void main() {
  group('native → Dart string decode (perf-audit C)', () {
    test('plain ASCII round-trips', () {
      expect(roundTrip('Hello, 42!'), 'Hello, 42!');
    });

    test('empty string', () {
      expect(roundTrip(''), '');
    });

    test('multi-byte UTF-8 (emoji, CJK, RTL) round-trips', () {
      expect(roundTrip('café — 日本語 — 🚀 — مرحبا'), 'café — 日本語 — 🚀 — مرحبا');
    });

    test('leading BOM (U+FEFF) is PRESERVED, not stripped', () {
      const bom = '﻿';
      expect(roundTrip('${bom}hello'), '${bom}hello');
      // The BOM must actually be present.
      expect(roundTrip('${bom}hello').codeUnitAt(0), 0xFEFF);
    });

    test('a BOM alone survives', () {
      expect(roundTrip('﻿'), '﻿');
      expect(roundTrip('﻿').length, 1);
    });

    test('multiple leading BOMs are all preserved', () {
      const b = '﻿';
      expect(roundTrip('$b$b$b tail'), '$b$b$b tail');
    });

    test('a non-leading BOM is preserved', () {
      expect(roundTrip('a﻿b'), 'a﻿b');
    });

    test('a longer string with BOM prefix round-trips', () {
      final body = 'x' * 500;
      expect(roundTrip('﻿$body'), '﻿$body');
    });
  });
}
