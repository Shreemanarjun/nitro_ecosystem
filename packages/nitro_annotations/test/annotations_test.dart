// Tests for the published nitro_annotations package (issue #28): the
// NativeImpl sealed hierarchy + fromTypeName mapping, and every annotation's
// const constructor / default values / const shorthand instance.
import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:test/test.dart';

void main() {
  group('NativeImpl constants map to the right impl class', () {
    test('top-level constants', () {
      expect(NativeImpl.swift, isA<SwiftImpl>());
      expect(NativeImpl.kotlin, isA<KotlinImpl>());
      expect(NativeImpl.cpp, isA<CppImpl>());
      expect(NativeImpl.wasm, isA<WasmImpl>());
    });

    test('per-platform sealed markers', () {
      expect(AppleNativeImpl.swift, isA<SwiftImpl>());
      expect(AppleNativeImpl.cpp, isA<CppImpl>());
      expect(AndroidNativeImpl.kotlin, isA<KotlinImpl>());
      expect(AndroidNativeImpl.cpp, isA<CppImpl>());
      expect(WindowsNativeImpl.cpp, isA<CppImpl>());
      expect(LinuxNativeImpl.cpp, isA<CppImpl>());
      expect(WebNativeImpl.wasm, isA<WasmImpl>());
    });

    test('CppImpl satisfies every native platform marker', () {
      const cpp = NativeImpl.cpp;
      expect(cpp, isA<AppleNativeImpl>());
      expect(cpp, isA<AndroidNativeImpl>());
      expect(cpp, isA<WindowsNativeImpl>());
      expect(cpp, isA<LinuxNativeImpl>());
    });
  });

  group('NativeImpl.fromTypeName', () {
    test('concrete impl class names', () {
      expect(NativeImpl.fromTypeName('SwiftImpl'), isA<SwiftImpl>());
      expect(NativeImpl.fromTypeName('KotlinImpl'), isA<KotlinImpl>());
      expect(NativeImpl.fromTypeName('CppImpl'), isA<CppImpl>());
      expect(NativeImpl.fromTypeName('WasmImpl'), isA<WasmImpl>());
    });

    test('single-impl sealed markers resolve unambiguously', () {
      expect(NativeImpl.fromTypeName('WindowsNativeImpl'), isA<CppImpl>());
      expect(NativeImpl.fromTypeName('LinuxNativeImpl'), isA<CppImpl>());
      expect(NativeImpl.fromTypeName('WebNativeImpl'), isA<WasmImpl>());
    });

    test('ambiguous markers and unknowns return null', () {
      // Apple/Android accept both a language impl and CppImpl → not resolvable here.
      expect(NativeImpl.fromTypeName('AppleNativeImpl'), isNull);
      expect(NativeImpl.fromTypeName('AndroidNativeImpl'), isNull);
      expect(NativeImpl.fromTypeName('NopeImpl'), isNull);
      expect(NativeImpl.fromTypeName(null), isNull);
      expect(NativeImpl.fromTypeName(''), isNull);
    });
  });

  group('annotation constructors and defaults', () {
    test('NitroModule — all fields optional, default null', () {
      const m = NitroModule();
      expect(m.ios, isNull);
      expect(m.android, isNull);
      expect(m.macos, isNull);
      expect(m.windows, isNull);
      expect(m.linux, isNull);
      expect(m.web, isNull);
      expect(m.cSymbolPrefix, isNull);
      expect(m.lib, isNull);

      const set = NitroModule(ios: AppleNativeImpl.swift, android: AndroidNativeImpl.kotlin, lib: 'math');
      expect(set.ios, isA<SwiftImpl>());
      expect(set.android, isA<KotlinImpl>());
      expect(set.lib, 'math');
    });

    test('HybridStruct defaults: empty zeroCopy, not packed', () {
      const s = HybridStruct();
      expect(s.zeroCopy, isEmpty);
      expect(s.packed, isFalse);
      const packed = HybridStruct(zeroCopy: ['data'], packed: true);
      expect(packed.zeroCopy, ['data']);
      expect(packed.packed, isTrue);
    });

    test('HybridEnum defaults: startValue 0, null nativeValues', () {
      const e = HybridEnum();
      expect(e.startValue, 0);
      expect(e.nativeValues, isNull);
      expect(const HybridEnum(startValue: 5, nativeValues: [1, 2, 4]).nativeValues, [1, 2, 4]);
    });

    test('NitroAsync timeout is optional', () {
      expect(const NitroAsync().timeout, isNull);
      expect(const NitroAsync(timeout: 5000).timeout, 5000);
    });

    test('NitroStream defaults: dropLatest, batchMaxSize 64', () {
      const st = NitroStream();
      expect(st.backpressure, Backpressure.dropLatest);
      expect(st.batchMaxSize, 64);
      expect(const NitroStream(backpressure: Backpressure.block, batchMaxSize: 16).backpressure, Backpressure.block);
    });

    test('NitroStreamBatch default maxSize 64', () {
      expect(const NitroStreamBatch().maxSize, 64);
      expect(const NitroStreamBatch(maxSize: 8).maxSize, 8);
    });

    test('NitroOwned release symbol is optional', () {
      expect(const NitroOwned().release, isNull);
      expect(const NitroOwned(release: 'wgpuBufferRelease').release, 'wgpuBufferRelease');
    });

    test('NitroCustomType requires codec + encodedSize', () {
      const c = NitroCustomType(codec: int, encodedSize: 5);
      expect(c.codec, int);
      expect(c.encodedSize, 5);
    });
  });

  group('const shorthand instances', () {
    test('are the right annotation types', () {
      expect(nitroAsync, isA<NitroAsync>());
      expect(nitroNativeAsync, isA<NitroNativeAsync>());
      expect(mainThread, isA<MainThread>());
      expect(zeroCopy, isA<ZeroCopy>());
      expect(hybridRecord, isA<HybridRecord>());
      expect(nitroOwned, isA<NitroOwned>());
      expect(nitroVariant, isA<NitroVariant>());
      expect(nitroResult, isA<NitroResult>());
    });

    test('canonical const identity (same instance)', () {
      expect(identical(nitroAsync, const NitroAsync()), isTrue);
      expect(identical(zeroCopy, const ZeroCopy()), isTrue);
      expect(identical(hybridRecord, const HybridRecord()), isTrue);
    });
  });

  group('Backpressure enum', () {
    test('exposes the documented modes and a default', () {
      expect(Backpressure.values, isNotEmpty);
      expect(Backpressure.values, contains(Backpressure.dropLatest));
      expect(Backpressure.values, contains(Backpressure.block));
      expect(Backpressure.values, contains(Backpressure.batch));
    });
  });
}
