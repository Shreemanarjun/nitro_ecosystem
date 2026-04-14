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

  // ── Per-platform sealed class constants ────────────────────────────────────

  group('AppleNativeImpl sealed constants', () {
    test('AppleNativeImpl.swift is SwiftImpl', () {
      expect(AppleNativeImpl.swift, isA<SwiftImpl>());
    });

    test('AppleNativeImpl.cpp is CppImpl', () {
      expect(AppleNativeImpl.cpp, isA<CppImpl>());
    });

    test('AppleNativeImpl.swift is identical to NativeImpl.swift', () {
      expect(identical(AppleNativeImpl.swift, NativeImpl.swift), isTrue);
    });

    test('AppleNativeImpl.cpp is identical to NativeImpl.cpp', () {
      expect(identical(AppleNativeImpl.cpp, NativeImpl.cpp), isTrue);
    });

    test('AppleNativeImpl.swift is not AppleNativeImpl.cpp', () {
      expect(identical(AppleNativeImpl.swift, AppleNativeImpl.cpp), isFalse);
    });

    test('AppleNativeImpl.swift is AppleNativeImpl', () {
      expect(AppleNativeImpl.swift, isA<AppleNativeImpl>());
    });

    test('AppleNativeImpl.cpp is AppleNativeImpl', () {
      expect(AppleNativeImpl.cpp, isA<AppleNativeImpl>());
    });
  });

  group('AndroidNativeImpl sealed constants', () {
    test('AndroidNativeImpl.kotlin is KotlinImpl', () {
      expect(AndroidNativeImpl.kotlin, isA<KotlinImpl>());
    });

    test('AndroidNativeImpl.cpp is CppImpl', () {
      expect(AndroidNativeImpl.cpp, isA<CppImpl>());
    });

    test('AndroidNativeImpl.kotlin is identical to NativeImpl.kotlin', () {
      expect(identical(AndroidNativeImpl.kotlin, NativeImpl.kotlin), isTrue);
    });

    test('AndroidNativeImpl.cpp is identical to NativeImpl.cpp', () {
      expect(identical(AndroidNativeImpl.cpp, NativeImpl.cpp), isTrue);
    });

    test('AndroidNativeImpl.kotlin is not AndroidNativeImpl.cpp', () {
      expect(identical(AndroidNativeImpl.kotlin, AndroidNativeImpl.cpp), isFalse);
    });

    test('AndroidNativeImpl.kotlin is AndroidNativeImpl', () {
      expect(AndroidNativeImpl.kotlin, isA<AndroidNativeImpl>());
    });

    test('AndroidNativeImpl.cpp is AndroidNativeImpl', () {
      expect(AndroidNativeImpl.cpp, isA<AndroidNativeImpl>());
    });
  });

  group('WindowsNativeImpl sealed constants', () {
    test('WindowsNativeImpl.cpp is CppImpl', () {
      expect(WindowsNativeImpl.cpp, isA<CppImpl>());
    });

    test('WindowsNativeImpl.cpp is identical to NativeImpl.cpp', () {
      expect(identical(WindowsNativeImpl.cpp, NativeImpl.cpp), isTrue);
    });

    test('WindowsNativeImpl.cpp is WindowsNativeImpl', () {
      expect(WindowsNativeImpl.cpp, isA<WindowsNativeImpl>());
    });
  });

  group('LinuxNativeImpl sealed constants', () {
    test('LinuxNativeImpl.cpp is CppImpl', () {
      expect(LinuxNativeImpl.cpp, isA<CppImpl>());
    });

    test('LinuxNativeImpl.cpp is identical to NativeImpl.cpp', () {
      expect(identical(LinuxNativeImpl.cpp, NativeImpl.cpp), isTrue);
    });

    test('LinuxNativeImpl.cpp is LinuxNativeImpl', () {
      expect(LinuxNativeImpl.cpp, isA<LinuxNativeImpl>());
    });
  });

  group('WebNativeImpl sealed constants', () {
    test('WebNativeImpl.wasm is WasmImpl', () {
      expect(WebNativeImpl.wasm, isA<WasmImpl>());
    });

    test('WebNativeImpl.wasm is identical to NativeImpl.wasm', () {
      expect(identical(WebNativeImpl.wasm, NativeImpl.wasm), isTrue);
    });

    test('WebNativeImpl.wasm is WebNativeImpl', () {
      expect(WebNativeImpl.wasm, isA<WebNativeImpl>());
    });
  });

  group('Cross-platform const canonicalization', () {
    test('all cpp constants are the same object', () {
      expect(identical(AppleNativeImpl.cpp, AndroidNativeImpl.cpp), isTrue);
      expect(identical(AppleNativeImpl.cpp, WindowsNativeImpl.cpp), isTrue);
      expect(identical(AppleNativeImpl.cpp, LinuxNativeImpl.cpp), isTrue);
      expect(identical(AppleNativeImpl.cpp, NativeImpl.cpp), isTrue);
    });

    test('AppleNativeImpl.swift is NOT AndroidNativeImpl', () {
      expect(AppleNativeImpl.swift, isNot(isA<AndroidNativeImpl>()));
    });

    test('AndroidNativeImpl.kotlin is NOT AppleNativeImpl', () {
      expect(AndroidNativeImpl.kotlin, isNot(isA<AppleNativeImpl>()));
    });

    test('WebNativeImpl.wasm is NOT any native platform impl', () {
      expect(WebNativeImpl.wasm, isNot(isA<AppleNativeImpl>()));
      expect(WebNativeImpl.wasm, isNot(isA<AndroidNativeImpl>()));
      expect(WebNativeImpl.wasm, isNot(isA<WindowsNativeImpl>()));
      expect(WebNativeImpl.wasm, isNot(isA<LinuxNativeImpl>()));
    });
  });

  group('NitroModule field type acceptance (compile-time safety in runtime form)', () {
    // These tests verify the type hierarchy: that per-platform constants
    // satisfy the field type constraints of NitroModule at runtime.
    test('AppleNativeImpl.swift satisfies ios field type', () {
      final mod = NitroModule(ios: AppleNativeImpl.swift);
      expect(mod.ios, isA<SwiftImpl>());
    });

    test('AppleNativeImpl.cpp satisfies macos field type', () {
      final mod = NitroModule(macos: AppleNativeImpl.cpp);
      expect(mod.macos, isA<CppImpl>());
    });

    test('AndroidNativeImpl.kotlin satisfies android field type', () {
      final mod = NitroModule(android: AndroidNativeImpl.kotlin);
      expect(mod.android, isA<KotlinImpl>());
    });

    test('AndroidNativeImpl.cpp satisfies android field type', () {
      final mod = NitroModule(android: AndroidNativeImpl.cpp);
      expect(mod.android, isA<CppImpl>());
    });

    test('WindowsNativeImpl.cpp satisfies windows field type', () {
      final mod = NitroModule(windows: WindowsNativeImpl.cpp);
      expect(mod.windows, isA<CppImpl>());
    });

    test('LinuxNativeImpl.cpp satisfies linux field type', () {
      final mod = NitroModule(linux: LinuxNativeImpl.cpp);
      expect(mod.linux, isA<CppImpl>());
    });

    test('WebNativeImpl.wasm satisfies web field type', () {
      final mod = NitroModule(web: WebNativeImpl.wasm);
      expect(mod.web, isA<WasmImpl>());
    });

    test('NativeImpl.* shorthand still satisfies field types (backward compat)', () {
      final mod = NitroModule(
        ios: NativeImpl.swift,
        android: NativeImpl.kotlin,
        macos: NativeImpl.cpp,
        windows: NativeImpl.cpp,
        linux: NativeImpl.cpp,
        web: NativeImpl.wasm,
      );
      expect(mod.ios, isA<SwiftImpl>());
      expect(mod.android, isA<KotlinImpl>());
      expect(mod.macos, isA<CppImpl>());
      expect(mod.windows, isA<CppImpl>());
      expect(mod.linux, isA<CppImpl>());
      expect(mod.web, isA<WasmImpl>());
    });

    test('ios + android with different impls: mixed-platform module is valid', () {
      final mod = NitroModule(
        ios: AppleNativeImpl.cpp,
        android: AndroidNativeImpl.kotlin,
      );
      expect(mod.ios, isA<CppImpl>());
      expect(mod.android, isA<KotlinImpl>());
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
