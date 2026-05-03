// Tests for the shared NativeImpl.fromTypeName helper in nitro_annotations.
// The helper is the single source of truth for mapping an analyzer-reported
// Dart type name back to the corresponding NativeImpl constant. SpecExtractor
// in nitro_generator delegates to this helper for the unambiguous cases and
// handles the two ambiguous sealed markers (AppleNativeImpl, AndroidNativeImpl)
// itself via analyzer supertype inspection.
import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:test/test.dart';

void main() {
  group('NativeImpl.fromTypeName — concrete impl names', () {
    test('SwiftImpl → NativeImpl.swift', () {
      expect(NativeImpl.fromTypeName('SwiftImpl'), same(NativeImpl.swift));
    });

    test('KotlinImpl → NativeImpl.kotlin', () {
      expect(NativeImpl.fromTypeName('KotlinImpl'), same(NativeImpl.kotlin));
    });

    test('CppImpl → NativeImpl.cpp', () {
      expect(NativeImpl.fromTypeName('CppImpl'), same(NativeImpl.cpp));
    });

    test('WasmImpl → NativeImpl.wasm', () {
      expect(NativeImpl.fromTypeName('WasmImpl'), same(NativeImpl.wasm));
    });
  });

  group('NativeImpl.fromTypeName — unambiguous sealed markers', () {
    test('WindowsNativeImpl → NativeImpl.cpp (only valid impl)', () {
      expect(NativeImpl.fromTypeName('WindowsNativeImpl'), same(NativeImpl.cpp));
    });

    test('LinuxNativeImpl → NativeImpl.cpp (only valid impl)', () {
      expect(NativeImpl.fromTypeName('LinuxNativeImpl'), same(NativeImpl.cpp));
    });

    test('WebNativeImpl → NativeImpl.wasm (only valid impl)', () {
      expect(NativeImpl.fromTypeName('WebNativeImpl'), same(NativeImpl.wasm));
    });
  });

  group('NativeImpl.fromTypeName — ambiguous markers return null', () {
    // AppleNativeImpl and AndroidNativeImpl each accept two concrete impls
    // (SwiftImpl/CppImpl, KotlinImpl/CppImpl respectively), so the helper
    // cannot disambiguate them without analyzer-level supertype inspection.
    // Callers must resolve these themselves.
    test('AppleNativeImpl → null (caller must disambiguate)', () {
      expect(NativeImpl.fromTypeName('AppleNativeImpl'), isNull);
    });

    test('AndroidNativeImpl → null (caller must disambiguate)', () {
      expect(NativeImpl.fromTypeName('AndroidNativeImpl'), isNull);
    });
  });

  group('NativeImpl.fromTypeName — unknown inputs', () {
    test('null → null', () {
      expect(NativeImpl.fromTypeName(null), isNull);
    });

    test('empty string → null', () {
      expect(NativeImpl.fromTypeName(''), isNull);
    });

    test('unknown type name → null', () {
      expect(NativeImpl.fromTypeName('FutureImpl'), isNull);
    });

    test('lowercased concrete name → null (case-sensitive)', () {
      // Defensive: analyzer always returns the exact class name. If a caller
      // passes a lowercased variant, we prefer a null (caller handles) over
      // a silent false match.
      expect(NativeImpl.fromTypeName('swiftimpl'), isNull);
    });
  });

  group('NativeImpl.fromTypeName — result is the canonical constant', () {
    // The helper must return the same instance as the static constant so
    // `identical()` / `same()` checks pass in generator code.
    test('SwiftImpl result is identical to NativeImpl.swift', () {
      final a = NativeImpl.fromTypeName('SwiftImpl');
      expect(identical(a, NativeImpl.swift), isTrue);
    });

    test('CppImpl result is identical to NativeImpl.cpp', () {
      final a = NativeImpl.fromTypeName('CppImpl');
      expect(identical(a, NativeImpl.cpp), isTrue);
    });

    test('WindowsNativeImpl and LinuxNativeImpl both resolve to the same cpp instance', () {
      final w = NativeImpl.fromTypeName('WindowsNativeImpl');
      final l = NativeImpl.fromTypeName('LinuxNativeImpl');
      expect(identical(w, l), isTrue);
      expect(identical(w, NativeImpl.cpp), isTrue);
    });
  });
}
