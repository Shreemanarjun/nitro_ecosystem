// Tests that NativeImpl sealed class hierarchy enforces correct platform
// capability markers. These are the compile-time guarantees expressed as
// runtime type checks — the actual compile-time safety is enforced by the
// @NitroModule annotation field types (AppleNativeImpl, AndroidNativeImpl, etc.).
import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:test/test.dart';

void main() {
  // ── Concrete subclass identity ──────────────────────────────────────────────

  group('NativeImpl static constants have correct runtime types', () {
    test('NativeImpl.swift is SwiftImpl', () {
      expect(NativeImpl.swift, isA<SwiftImpl>());
    });

    test('NativeImpl.kotlin is KotlinImpl', () {
      expect(NativeImpl.kotlin, isA<KotlinImpl>());
    });

    test('NativeImpl.cpp is CppImpl', () {
      expect(NativeImpl.cpp, isA<CppImpl>());
    });

    test('NativeImpl.wasm is WasmImpl', () {
      expect(NativeImpl.wasm, isA<WasmImpl>());
    });
  });

  // ── Const canonicalization ──────────────────────────────────────────────────

  group('NativeImpl constants are canonicalized (identical)', () {
    test('NativeImpl.swift == NativeImpl.swift', () {
      expect(identical(NativeImpl.swift, NativeImpl.swift), isTrue);
    });

    test('NativeImpl.cpp == NativeImpl.cpp', () {
      expect(identical(NativeImpl.cpp, NativeImpl.cpp), isTrue);
    });

    test('NativeImpl.kotlin != NativeImpl.cpp', () {
      expect(identical(NativeImpl.kotlin, NativeImpl.cpp), isFalse);
    });

    test('NativeImpl.wasm != NativeImpl.cpp', () {
      expect(identical(NativeImpl.wasm, NativeImpl.cpp), isFalse);
    });
  });

  // ── Platform capability markers for CppImpl (multi-platform) ───────────────

  group('CppImpl implements all native platform markers', () {
    test('NativeImpl.cpp is AppleNativeImpl', () {
      expect(NativeImpl.cpp, isA<AppleNativeImpl>());
    });

    test('NativeImpl.cpp is AndroidNativeImpl', () {
      expect(NativeImpl.cpp, isA<AndroidNativeImpl>());
    });

    test('NativeImpl.cpp is WindowsNativeImpl', () {
      expect(NativeImpl.cpp, isA<WindowsNativeImpl>());
    });

    test('NativeImpl.cpp is LinuxNativeImpl', () {
      expect(NativeImpl.cpp, isA<LinuxNativeImpl>());
    });

    test('NativeImpl.cpp is NOT WebNativeImpl (web is WASM only)', () {
      expect(NativeImpl.cpp, isNot(isA<WebNativeImpl>()));
    });
  });

  // ── SwiftImpl: Apple only ───────────────────────────────────────────────────

  group('SwiftImpl is valid only on Apple platforms', () {
    test('NativeImpl.swift is AppleNativeImpl', () {
      expect(NativeImpl.swift, isA<AppleNativeImpl>());
    });

    test('NativeImpl.swift is NOT AndroidNativeImpl', () {
      expect(NativeImpl.swift, isNot(isA<AndroidNativeImpl>()));
    });

    test('NativeImpl.swift is NOT WindowsNativeImpl', () {
      expect(NativeImpl.swift, isNot(isA<WindowsNativeImpl>()));
    });

    test('NativeImpl.swift is NOT LinuxNativeImpl', () {
      expect(NativeImpl.swift, isNot(isA<LinuxNativeImpl>()));
    });

    test('NativeImpl.swift is NOT WebNativeImpl', () {
      expect(NativeImpl.swift, isNot(isA<WebNativeImpl>()));
    });
  });

  // ── KotlinImpl: Android only ────────────────────────────────────────────────

  group('KotlinImpl is valid only on Android', () {
    test('NativeImpl.kotlin is AndroidNativeImpl', () {
      expect(NativeImpl.kotlin, isA<AndroidNativeImpl>());
    });

    test('NativeImpl.kotlin is NOT AppleNativeImpl', () {
      expect(NativeImpl.kotlin, isNot(isA<AppleNativeImpl>()));
    });

    test('NativeImpl.kotlin is NOT WindowsNativeImpl', () {
      expect(NativeImpl.kotlin, isNot(isA<WindowsNativeImpl>()));
    });

    test('NativeImpl.kotlin is NOT LinuxNativeImpl', () {
      expect(NativeImpl.kotlin, isNot(isA<LinuxNativeImpl>()));
    });

    test('NativeImpl.kotlin is NOT WebNativeImpl', () {
      expect(NativeImpl.kotlin, isNot(isA<WebNativeImpl>()));
    });
  });

  // ── WasmImpl: Web only ─────────────────────────────────────────────────────

  group('WasmImpl is valid only on Web', () {
    test('NativeImpl.wasm is WebNativeImpl', () {
      expect(NativeImpl.wasm, isA<WebNativeImpl>());
    });

    test('NativeImpl.wasm is NOT AppleNativeImpl', () {
      expect(NativeImpl.wasm, isNot(isA<AppleNativeImpl>()));
    });

    test('NativeImpl.wasm is NOT AndroidNativeImpl', () {
      expect(NativeImpl.wasm, isNot(isA<AndroidNativeImpl>()));
    });

    test('NativeImpl.wasm is NOT WindowsNativeImpl', () {
      expect(NativeImpl.wasm, isNot(isA<WindowsNativeImpl>()));
    });

    test('NativeImpl.wasm is NOT LinuxNativeImpl', () {
      expect(NativeImpl.wasm, isNot(isA<LinuxNativeImpl>()));
    });
  });

  // ── Exhaustive sealed switch ────────────────────────────────────────────────

  group('Exhaustive switch over NativeImpl sealed hierarchy', () {
    String describePlatforms(NativeImpl impl) {
      // This switch must be exhaustive — adding a new sealed subclass without
      // updating this switch causes a compile-time warning/error.
      return switch (impl) {
        SwiftImpl()  => 'apple-swift',
        KotlinImpl() => 'android-kotlin',
        CppImpl()    => 'native-cpp',
        WasmImpl()   => 'web-wasm',
      };
    }

    test('swift → apple-swift', () {
      expect(describePlatforms(NativeImpl.swift), equals('apple-swift'));
    });

    test('kotlin → android-kotlin', () {
      expect(describePlatforms(NativeImpl.kotlin), equals('android-kotlin'));
    });

    test('cpp → native-cpp', () {
      expect(describePlatforms(NativeImpl.cpp), equals('native-cpp'));
    });

    test('wasm → web-wasm', () {
      expect(describePlatforms(NativeImpl.wasm), equals('web-wasm'));
    });

    test('all four variants are distinguishable', () {
      final results = [
        NativeImpl.swift,
        NativeImpl.kotlin,
        NativeImpl.cpp,
        NativeImpl.wasm,
      ].map(describePlatforms).toSet();
      expect(results, hasLength(4));
    });
  });
}
