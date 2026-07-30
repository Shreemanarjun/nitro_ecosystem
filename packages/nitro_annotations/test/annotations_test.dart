import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:test/test.dart';

void main() {
  // ─── NativeImpl sealed hierarchy ──────────────────────────────────────────

  group('NativeImpl sealed hierarchy', () {
    group('NativeImpl.swift (SwiftImpl)', () {
      test('is a SwiftImpl', () {
        expect(NativeImpl.swift, isA<SwiftImpl>());
      });

      test('is an AppleNativeImpl', () {
        expect(NativeImpl.swift, isA<AppleNativeImpl>());
      });

      test('is a NativeImpl', () {
        expect(NativeImpl.swift, isA<NativeImpl>());
      });

      test('is NOT an AndroidNativeImpl', () {
        expect(NativeImpl.swift, isNot(isA<AndroidNativeImpl>()));
      });

      test('is NOT a WindowsNativeImpl', () {
        expect(NativeImpl.swift, isNot(isA<WindowsNativeImpl>()));
      });

      test('is NOT a LinuxNativeImpl', () {
        expect(NativeImpl.swift, isNot(isA<LinuxNativeImpl>()));
      });

      test('is NOT a WebNativeImpl', () {
        expect(NativeImpl.swift, isNot(isA<WebNativeImpl>()));
      });
    });

    group('NativeImpl.kotlin (KotlinImpl)', () {
      test('is a KotlinImpl', () {
        expect(NativeImpl.kotlin, isA<KotlinImpl>());
      });

      test('is an AndroidNativeImpl', () {
        expect(NativeImpl.kotlin, isA<AndroidNativeImpl>());
      });

      test('is a NativeImpl', () {
        expect(NativeImpl.kotlin, isA<NativeImpl>());
      });

      test('is NOT an AppleNativeImpl', () {
        expect(NativeImpl.kotlin, isNot(isA<AppleNativeImpl>()));
      });

      test('is NOT a WindowsNativeImpl', () {
        expect(NativeImpl.kotlin, isNot(isA<WindowsNativeImpl>()));
      });

      test('is NOT a WebNativeImpl', () {
        expect(NativeImpl.kotlin, isNot(isA<WebNativeImpl>()));
      });
    });

    group('NativeImpl.cpp (CppImpl)', () {
      test('is a CppImpl', () {
        expect(NativeImpl.cpp, isA<CppImpl>());
      });

      test('is an AppleNativeImpl', () {
        expect(NativeImpl.cpp, isA<AppleNativeImpl>());
      });

      test('is an AndroidNativeImpl', () {
        expect(NativeImpl.cpp, isA<AndroidNativeImpl>());
      });

      test('is a WindowsNativeImpl', () {
        expect(NativeImpl.cpp, isA<WindowsNativeImpl>());
      });

      test('is a LinuxNativeImpl', () {
        expect(NativeImpl.cpp, isA<LinuxNativeImpl>());
      });

      test('is NOT a WebNativeImpl', () {
        expect(NativeImpl.cpp, isNot(isA<WebNativeImpl>()));
      });

      test('is a NativeImpl', () {
        expect(NativeImpl.cpp, isA<NativeImpl>());
      });
    });

    group('NativeImpl.wasm (WasmImpl)', () {
      test('is a WasmImpl', () {
        expect(NativeImpl.wasm, isA<WasmImpl>());
      });

      test('is a WebNativeImpl', () {
        expect(NativeImpl.wasm, isA<WebNativeImpl>());
      });

      test('is a NativeImpl', () {
        expect(NativeImpl.wasm, isA<NativeImpl>());
      });

      test('is NOT an AppleNativeImpl', () {
        expect(NativeImpl.wasm, isNot(isA<AppleNativeImpl>()));
      });

      test('is NOT an AndroidNativeImpl', () {
        expect(NativeImpl.wasm, isNot(isA<AndroidNativeImpl>()));
      });

      test('is NOT a WindowsNativeImpl', () {
        expect(NativeImpl.wasm, isNot(isA<WindowsNativeImpl>()));
      });

      test('is NOT a LinuxNativeImpl', () {
        expect(NativeImpl.wasm, isNot(isA<LinuxNativeImpl>()));
      });
    });
  });

  // ─── Platform-specific sealed class constants ─────────────────────────────

  group('Platform-specific sealed class constants', () {
    test('AppleNativeImpl.swift is same object as NativeImpl.swift', () {
      expect(identical(AppleNativeImpl.swift, NativeImpl.swift), isTrue);
    });

    test('AppleNativeImpl.cpp is same object as NativeImpl.cpp', () {
      expect(identical(AppleNativeImpl.cpp, NativeImpl.cpp), isTrue);
    });

    test('AndroidNativeImpl.kotlin is same object as NativeImpl.kotlin', () {
      expect(identical(AndroidNativeImpl.kotlin, NativeImpl.kotlin), isTrue);
    });

    test('AndroidNativeImpl.cpp is same object as NativeImpl.cpp', () {
      expect(identical(AndroidNativeImpl.cpp, NativeImpl.cpp), isTrue);
    });

    test('WindowsNativeImpl.cpp is same object as NativeImpl.cpp', () {
      expect(identical(WindowsNativeImpl.cpp, NativeImpl.cpp), isTrue);
    });

    test('LinuxNativeImpl.cpp is same object as NativeImpl.cpp', () {
      expect(identical(LinuxNativeImpl.cpp, NativeImpl.cpp), isTrue);
    });

    test('WebNativeImpl.wasm is same object as NativeImpl.wasm', () {
      expect(identical(WebNativeImpl.wasm, NativeImpl.wasm), isTrue);
    });

    test('All platform .cpp constants are identical to each other', () {
      expect(identical(AppleNativeImpl.cpp, AndroidNativeImpl.cpp), isTrue);
      expect(identical(AndroidNativeImpl.cpp, WindowsNativeImpl.cpp), isTrue);
      expect(identical(WindowsNativeImpl.cpp, LinuxNativeImpl.cpp), isTrue);
    });

    test('AppleNativeImpl.swift type checks', () {
      final AppleNativeImpl impl = AppleNativeImpl.swift;
      expect(impl, isA<SwiftImpl>());
    });

    test('AppleNativeImpl.cpp type checks', () {
      final AppleNativeImpl impl = AppleNativeImpl.cpp;
      expect(impl, isA<CppImpl>());
    });

    test('AndroidNativeImpl.kotlin type checks', () {
      final AndroidNativeImpl impl = AndroidNativeImpl.kotlin;
      expect(impl, isA<KotlinImpl>());
    });

    test('AndroidNativeImpl.cpp type checks', () {
      final AndroidNativeImpl impl = AndroidNativeImpl.cpp;
      expect(impl, isA<CppImpl>());
    });

    test('WindowsNativeImpl.cpp type checks', () {
      final WindowsNativeImpl impl = WindowsNativeImpl.cpp;
      expect(impl, isA<CppImpl>());
    });

    test('LinuxNativeImpl.cpp type checks', () {
      final LinuxNativeImpl impl = LinuxNativeImpl.cpp;
      expect(impl, isA<CppImpl>());
    });

    test('WebNativeImpl.wasm type checks', () {
      final WebNativeImpl impl = WebNativeImpl.wasm;
      expect(impl, isA<WasmImpl>());
    });
  });

  // ─── NativeImpl.fromTypeName ──────────────────────────────────────────────

  group('NativeImpl.fromTypeName', () {
    test('SwiftImpl maps to NativeImpl.swift', () {
      final result = NativeImpl.fromTypeName('SwiftImpl');
      expect(result, isNotNull);
      expect(identical(result, NativeImpl.swift), isTrue);
    });

    test('KotlinImpl maps to NativeImpl.kotlin', () {
      final result = NativeImpl.fromTypeName('KotlinImpl');
      expect(result, isNotNull);
      expect(identical(result, NativeImpl.kotlin), isTrue);
    });

    test('CppImpl maps to NativeImpl.cpp', () {
      final result = NativeImpl.fromTypeName('CppImpl');
      expect(result, isNotNull);
      expect(identical(result, NativeImpl.cpp), isTrue);
    });

    test('WasmImpl maps to NativeImpl.wasm', () {
      final result = NativeImpl.fromTypeName('WasmImpl');
      expect(result, isNotNull);
      expect(identical(result, NativeImpl.wasm), isTrue);
    });

    test('WindowsNativeImpl maps to NativeImpl.cpp', () {
      final result = NativeImpl.fromTypeName('WindowsNativeImpl');
      expect(result, isNotNull);
      expect(identical(result, NativeImpl.cpp), isTrue);
    });

    test('LinuxNativeImpl maps to NativeImpl.cpp', () {
      final result = NativeImpl.fromTypeName('LinuxNativeImpl');
      expect(result, isNotNull);
      expect(identical(result, NativeImpl.cpp), isTrue);
    });

    test('WebNativeImpl maps to NativeImpl.wasm', () {
      final result = NativeImpl.fromTypeName('WebNativeImpl');
      expect(result, isNotNull);
      expect(identical(result, NativeImpl.wasm), isTrue);
    });

    test('null returns null', () {
      expect(NativeImpl.fromTypeName(null), isNull);
    });

    test('Unknown returns null', () {
      expect(NativeImpl.fromTypeName('Unknown'), isNull);
    });

    test('empty string returns null', () {
      expect(NativeImpl.fromTypeName(''), isNull);
    });

    test('AppleNativeImpl returns null (ambiguous)', () {
      expect(NativeImpl.fromTypeName('AppleNativeImpl'), isNull);
    });

    test('AndroidNativeImpl returns null (ambiguous)', () {
      expect(NativeImpl.fromTypeName('AndroidNativeImpl'), isNull);
    });

    test('NativeImpl returns null (not a concrete impl)', () {
      expect(NativeImpl.fromTypeName('NativeImpl'), isNull);
    });
  });

  // ─── NitroModule annotation ───────────────────────────────────────────────

  group('NitroModule', () {
    test('can be const-constructed with all null platforms', () {
      const module = NitroModule();
      expect(module.ios, isNull);
      expect(module.android, isNull);
      expect(module.macos, isNull);
      expect(module.windows, isNull);
      expect(module.linux, isNull);
      expect(module.web, isNull);
      expect(module.cSymbolPrefix, isNull);
      expect(module.lib, isNull);
    });

    test('can be const-constructed with specific platforms', () {
      const module = NitroModule(
        ios: AppleNativeImpl.swift,
        android: AndroidNativeImpl.kotlin,
        macos: AppleNativeImpl.cpp,
        windows: WindowsNativeImpl.cpp,
        linux: LinuxNativeImpl.cpp,
        web: WebNativeImpl.wasm,
      );
      expect(module.ios, isA<SwiftImpl>());
      expect(module.android, isA<KotlinImpl>());
      expect(module.macos, isA<CppImpl>());
      expect(module.windows, isA<CppImpl>());
      expect(module.linux, isA<CppImpl>());
      expect(module.web, isA<WasmImpl>());
    });

    test('can use NativeImpl shorthand constants', () {
      const module = NitroModule(
        ios: NativeImpl.swift,
        android: NativeImpl.kotlin,
      );
      expect(identical(module.ios, AppleNativeImpl.swift), isTrue);
      expect(identical(module.android, AndroidNativeImpl.kotlin), isTrue);
    });

    test('fields are properly typed', () {
      const module = NitroModule(
        ios: AppleNativeImpl.swift,
        android: AndroidNativeImpl.cpp,
        macos: AppleNativeImpl.cpp,
        windows: WindowsNativeImpl.cpp,
        linux: LinuxNativeImpl.cpp,
        web: WebNativeImpl.wasm,
        cSymbolPrefix: 'my_prefix',
        lib: 'libmy',
      );
      // ios and macos accept AppleNativeImpl
      expect(module.ios, isA<AppleNativeImpl>());
      expect(module.macos, isA<AppleNativeImpl>());
      // android accepts AndroidNativeImpl
      expect(module.android, isA<AndroidNativeImpl>());
      // windows accepts WindowsNativeImpl
      expect(module.windows, isA<WindowsNativeImpl>());
      // linux accepts LinuxNativeImpl
      expect(module.linux, isA<LinuxNativeImpl>());
      // web accepts WebNativeImpl
      expect(module.web, isA<WebNativeImpl>());
      // string fields
      expect(module.cSymbolPrefix, 'my_prefix');
      expect(module.lib, 'libmy');
    });

    test('cSymbolPrefix and lib default to null', () {
      const module = NitroModule();
      expect(module.cSymbolPrefix, isNull);
      expect(module.lib, isNull);
    });
  });

  // ─── HybridStruct ────────────────────────────────────────────────────────

  group('HybridStruct', () {
    test('const constructor with defaults', () {
      const hs = HybridStruct();
      expect(hs.zeroCopy, isEmpty);
      expect(hs.packed, isFalse);
    });

    test('custom zeroCopy list', () {
      const hs = HybridStruct(zeroCopy: ['data', 'buffer']);
      expect(hs.zeroCopy, ['data', 'buffer']);
      expect(hs.packed, isFalse);
    });

    test('custom packed = true', () {
      const hs = HybridStruct(packed: true);
      expect(hs.packed, isTrue);
    });

    test('all custom values', () {
      const hs = HybridStruct(zeroCopy: ['pixels'], packed: true);
      expect(hs.zeroCopy, ['pixels']);
      expect(hs.packed, isTrue);
    });
  });

  // ─── HybridEnum ──────────────────────────────────────────────────────────

  group('HybridEnum', () {
    test('const constructor with defaults', () {
      const he = HybridEnum();
      expect(he.startValue, 0);
      expect(he.nativeValues, isNull);
    });

    test('custom startValue', () {
      const he = HybridEnum(startValue: 10);
      expect(he.startValue, 10);
      expect(he.nativeValues, isNull);
    });

    test('custom nativeValues', () {
      const he = HybridEnum(nativeValues: [0, 50, 100]);
      expect(he.startValue, 0);
      expect(he.nativeValues, [0, 50, 100]);
    });

    test('both custom startValue and nativeValues', () {
      const he = HybridEnum(startValue: 5, nativeValues: [5, 10, 15]);
      expect(he.startValue, 5);
      expect(he.nativeValues, [5, 10, 15]);
    });
  });

  // ─── NitroAsync ──────────────────────────────────────────────────────────

  group('NitroAsync', () {
    test('const constructor with default timeout', () {
      const na = NitroAsync();
      expect(na.timeout, isNull);
    });

    test('custom timeout', () {
      const na = NitroAsync(timeout: 5000);
      expect(na.timeout, 5000);
    });

    test('const shorthand nitroAsync has null timeout', () {
      expect(nitroAsync, isA<NitroAsync>());
      expect(nitroAsync.timeout, isNull);
    });
  });

  // ─── NitroNativeAsync ────────────────────────────────────────────────────

  group('NitroNativeAsync', () {
    test('const constructor', () {
      const nna = NitroNativeAsync();
      expect(nna, isA<NitroNativeAsync>());
    });

    test('const shorthand nitroNativeAsync', () {
      expect(nitroNativeAsync, isA<NitroNativeAsync>());
    });
  });

  // ─── MainThread ──────────────────────────────────────────────────────────

  group('MainThread', () {
    test('const constructor', () {
      const mt = MainThread();
      expect(mt, isA<MainThread>());
    });

    test('const shorthand mainThread', () {
      expect(mainThread, isA<MainThread>());
    });
  });

  // ─── NitroStream ─────────────────────────────────────────────────────────

  group('NitroStream', () {
    test('default backpressure is Backpressure.dropLatest', () {
      const ns = NitroStream();
      expect(ns.backpressure, Backpressure.dropLatest);
    });

    test('default batchMaxSize is 64', () {
      const ns = NitroStream();
      expect(ns.batchMaxSize, 64);
    });

    test('custom backpressure', () {
      const ns = NitroStream(backpressure: Backpressure.block);
      expect(ns.backpressure, Backpressure.block);
      expect(ns.batchMaxSize, 64);
    });

    test('custom batchMaxSize', () {
      const ns = NitroStream(
        backpressure: Backpressure.batch,
        batchMaxSize: 128,
      );
      expect(ns.backpressure, Backpressure.batch);
      expect(ns.batchMaxSize, 128);
    });

    test('bufferDrop backpressure', () {
      const ns = NitroStream(backpressure: Backpressure.bufferDrop);
      expect(ns.backpressure, Backpressure.bufferDrop);
    });
  });

  // ─── ZeroCopy ─────────────────────────────────────────────────────────────

  group('ZeroCopy', () {
    test('const constructor', () {
      const zc = ZeroCopy();
      expect(zc, isA<ZeroCopy>());
    });

    test('const shorthand zeroCopy', () {
      expect(zeroCopy, isA<ZeroCopy>());
    });
  });

  // ─── Backpressure enum ────────────────────────────────────────────────────

  group('Backpressure enum', () {
    test('has exactly 4 values', () {
      expect(Backpressure.values, hasLength(4));
    });

    test('contains dropLatest', () {
      expect(Backpressure.values, contains(Backpressure.dropLatest));
    });

    test('contains block', () {
      expect(Backpressure.values, contains(Backpressure.block));
    });

    test('contains bufferDrop', () {
      expect(Backpressure.values, contains(Backpressure.bufferDrop));
    });

    test('contains batch', () {
      expect(Backpressure.values, contains(Backpressure.batch));
    });

    test('index ordering', () {
      expect(Backpressure.dropLatest.index, 0);
      expect(Backpressure.block.index, 1);
      expect(Backpressure.bufferDrop.index, 2);
      expect(Backpressure.batch.index, 3);
    });
  });

  // ─── HybridRecord ────────────────────────────────────────────────────────

  group('HybridRecord', () {
    test('const constructor', () {
      const hr = HybridRecord();
      expect(hr, isA<HybridRecord>());
    });

    test('const shorthand hybridRecord', () {
      expect(hybridRecord, isA<HybridRecord>());
    });
  });

  // ─── NitroOwned ──────────────────────────────────────────────────────────

  group('NitroOwned', () {
    test('const constructor with default release', () {
      const no = NitroOwned();
      expect(no.release, isNull);
    });

    test('custom release string', () {
      const no = NitroOwned(release: 'wgpuBufferRelease');
      expect(no.release, 'wgpuBufferRelease');
    });

    test('const shorthand nitroOwned has null release', () {
      expect(nitroOwned, isA<NitroOwned>());
      expect(nitroOwned.release, isNull);
    });
  });

  // ─── NitroVariant ─────────────────────────────────────────────────────────

  group('NitroVariant', () {
    test('const constructor', () {
      const nv = NitroVariant();
      expect(nv, isA<NitroVariant>());
    });

    test('const shorthand nitroVariant', () {
      expect(nitroVariant, isA<NitroVariant>());
    });
  });

  // ─── NitroTuple ──────────────────────────────────────────────────────────

  group('NitroTuple', () {
    test('const constructor', () {
      const nt = NitroTuple();
      expect(nt, isA<NitroTuple>());
    });
  });

  // ─── NitroResult ─────────────────────────────────────────────────────────

  group('NitroResult', () {
    test('const constructor', () {
      const nr = NitroResult();
      expect(nr, isA<NitroResult>());
    });

    test('const shorthand nitroResult', () {
      expect(nitroResult, isA<NitroResult>());
    });
  });

  // ─── NitroCustomType ─────────────────────────────────────────────────────

  group('NitroCustomType', () {
    test('const constructor with required params', () {
      const nct = NitroCustomType(codec: String, encodedSize: 5);
      expect(nct.codec, String);
      expect(nct.encodedSize, 5);
    });

    test('codec stores the Type', () {
      const nct = NitroCustomType(codec: int, encodedSize: 4);
      expect(nct.codec, int);
    });

    test('encodedSize stores the value', () {
      const nct = NitroCustomType(codec: double, encodedSize: 8);
      expect(nct.encodedSize, 8);
    });
  });

  // ─── NitroStreamBatch ────────────────────────────────────────────────────

  group('NitroStreamBatch', () {
    test('default maxSize is 64', () {
      const nsb = NitroStreamBatch();
      expect(nsb.maxSize, 64);
    });

    test('custom maxSize', () {
      const nsb = NitroStreamBatch(maxSize: 256);
      expect(nsb.maxSize, 256);
    });
  });

  // ─── Const shorthand instances ────────────────────────────────────────────

  group('Const shorthand instances', () {
    test('nitroAsync is a NitroAsync', () {
      expect(nitroAsync, isA<NitroAsync>());
    });

    test('nitroNativeAsync is a NitroNativeAsync', () {
      expect(nitroNativeAsync, isA<NitroNativeAsync>());
    });

    test('mainThread is a MainThread', () {
      expect(mainThread, isA<MainThread>());
    });

    test('zeroCopy is a ZeroCopy', () {
      expect(zeroCopy, isA<ZeroCopy>());
    });

    test('hybridRecord is a HybridRecord', () {
      expect(hybridRecord, isA<HybridRecord>());
    });

    test('nitroOwned is a NitroOwned', () {
      expect(nitroOwned, isA<NitroOwned>());
    });

    test('nitroVariant is a NitroVariant', () {
      expect(nitroVariant, isA<NitroVariant>());
    });

    test('nitroResult is a NitroResult', () {
      expect(nitroResult, isA<NitroResult>());
    });
  });
}
