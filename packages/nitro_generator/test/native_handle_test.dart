// Tests for NativeHandle`<T>` and @NitroOwned across all five generators.
//
// NativeHandle is a zero-codec raw-pointer escape hatch. The wire format is
// always `void*` / `Long` / `UnsafeMutableRawPointer?` regardless of T.
// @NitroOwned attaches a NativeFinalizer and emits a `_release` C symbol.

import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_header_generator.dart';
import 'package:nitro_generator/src/generators/languages/cpp_native/cpp_interface_generator.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:nitro_generator/src/spec_validator.dart';
import 'package:test/test.dart';

// ── Fixtures ──────────────────────────────────────────────────────────────────

BridgeSpec _borrowSpec() => BridgeSpec(
  dartClassName: 'Camera',
  lib: 'camera',
  namespace: 'camera',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'camera.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'peekFrame',
      cSymbol: 'camera_peek_frame',
      isAsync: false,
      returnType: BridgeType(name: 'NativeHandle<Void>', isNativeHandle: true, nativeHandleTypeParam: 'Void'),
      params: [],
    ),
  ],
);

BridgeSpec _ownedSpec() => BridgeSpec(
  dartClassName: 'Camera',
  lib: 'camera',
  namespace: 'camera',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'camera.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'acquireFrame',
      cSymbol: 'camera_acquire_frame',
      isAsync: false,
      returnType: BridgeType(name: 'NativeHandle<Void>', isNativeHandle: true, nativeHandleTypeParam: 'Void'),
      params: [],
      isOwned: true,
    ),
  ],
);

BridgeSpec _paramSpec() => BridgeSpec(
  dartClassName: 'Camera',
  lib: 'camera',
  namespace: 'camera',
  iosImpl: NativeImpl.cpp,
  sourceUri: 'camera.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'processFrame',
      cSymbol: 'camera_process_frame',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'handle',
          type: BridgeType(name: 'NativeHandle<Void>', isNativeHandle: true, nativeHandleTypeParam: 'Void'),
        ),
      ],
    ),
  ],
);

// ── Main ──────────────────────────────────────────────────────────────────────

void main() {
  // ── Spec validator ──────────────────────────────────────────────────────────
  group('SpecValidator — @NitroOwned rules', () {
    test('NativeHandle return without @NitroOwned is valid', () {
      expect(SpecValidator.validate(_borrowSpec()).where((i) => i.isError), isEmpty);
    });

    test('NativeHandle return with @NitroOwned is valid', () {
      expect(SpecValidator.validate(_ownedSpec()).where((i) => i.isError), isEmpty);
    });

    test('@NitroOwned on non-NativeHandle return → INVALID_OWNED error', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        sourceUri: 'mod.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'bad',
            cSymbol: 'mod_bad',
            isAsync: false,
            returnType: BridgeType(name: 'int'),
            params: [],
            isOwned: true,
          ),
        ],
      );
      final errors = SpecValidator.validate(spec).where((i) => i.code == 'INVALID_OWNED');
      expect(errors, isNotEmpty);
    });
  });

  // ── C++ header ──────────────────────────────────────────────────────────────
  group('CppHeaderGenerator — NativeHandle', () {
    test('borrow: method declaration uses void* return, no _release symbol', () {
      final out = CppHeaderGenerator.generate(_borrowSpec());
      expect(out, contains('void* camera_peek_frame(int64_t instanceId, NitroError* _nitro_err);'));
      expect(out, isNot(contains('camera_peek_frame_release')));
    });

    test('@NitroOwned: emits _release extern in header', () {
      final out = CppHeaderGenerator.generate(_ownedSpec());
      expect(out, contains('void camera_acquire_frame_release(void* handle);'));
    });

    test('NativeHandle param: uses void* in C declaration', () {
      final paramSpec = BridgeSpec(
        dartClassName: 'Camera',
        lib: 'camera',
        namespace: 'camera',
        iosImpl: NativeImpl.cpp,
        sourceUri: 'camera.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'processFrame',
            cSymbol: 'camera_process_frame',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'handle',
                type: BridgeType(name: 'NativeHandle<Void>', isNativeHandle: true),
              ),
            ],
          ),
        ],
      );
      final out = CppHeaderGenerator.generate(paramSpec);
      expect(out, contains('void camera_process_frame(int64_t instanceId, void* handle, NitroError* _nitro_err);'));
    });
  });

  // ── C++ interface (NativeImpl.cpp) ──────────────────────────────────────────
  group('CppInterfaceGenerator — NativeHandle', () {
    test('NativeHandle return → void* in abstract method', () {
      final cppSpec = BridgeSpec(
        dartClassName: 'Camera',
        lib: 'camera',
        namespace: 'camera',
        iosImpl: NativeImpl.cpp,
        sourceUri: 'camera.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'peekFrame',
            cSymbol: 'camera_peek_frame',
            isAsync: false,
            returnType: BridgeType(name: 'NativeHandle<Void>', isNativeHandle: true, nativeHandleTypeParam: 'Void'),
            params: [],
          ),
        ],
      );
      final out = CppInterfaceGenerator.generate(cppSpec);
      expect(out, contains('virtual void* peekFrame() = 0;'));
    });

    test('NativeHandle param → void* in abstract method', () {
      final out = CppInterfaceGenerator.generate(_paramSpec());
      expect(out, contains('virtual void processFrame(void* handle) = 0;'));
    });
  });

  // ── C++ bridge — @NitroOwned _release (Point 8) ────────────────────────────
  group('CppBridgeGenerator — @NitroOwned _release calls free() on all platforms (Point 8)', () {
    test('_release function calls free(handle) — not a no-op on Android', () {
      final out = CppBridgeGenerator.generate(_ownedSpec());
      expect(out, contains('if (handle) { free(handle); }'), reason: '_release must free() the handle on all platforms');
    });

    test('_release function does NOT have the Android no-op (void)handle', () {
      final out = CppBridgeGenerator.generate(_ownedSpec());
      expect(out, isNot(contains('(void)handle')), reason: 'Android no-op was removed; ART Unsafe.allocateMemory returns real malloc pointers');
    });

    test('_release function body has no platform ifdefs (uniform free on all platforms)', () {
      final out = CppBridgeGenerator.generate(_ownedSpec());
      // The _release block must not contain a platform-conditional no-op.
      // Extract just the _release function body to avoid false matches from
      // the JNI methods section which legitimately uses #ifdef __ANDROID__.
      final releaseStart = out.indexOf('camera_acquire_frame_release');
      final releaseEnd = out.indexOf('\n}', releaseStart) + 2;
      final releaseBlock = out.substring(releaseStart, releaseEnd);
      expect(releaseBlock, isNot(contains('(void)handle')));
      expect(releaseBlock, contains('free(handle)'));
    });
  });

  // ── C++ bridge (direct path) ─────────────────────────────────────────────────
  group('CppBridgeGenerator — NativeHandle', () {
    test('borrow: bridge returns void* directly, no finalizer', () {
      final cppSpec = BridgeSpec(
        dartClassName: 'Camera',
        lib: 'camera',
        namespace: 'camera',
        iosImpl: NativeImpl.cpp,
        sourceUri: 'camera.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'peekFrame',
            cSymbol: 'camera_peek_frame',
            isAsync: false,
            returnType: BridgeType(name: 'NativeHandle<Void>', isNativeHandle: true),
            params: [],
          ),
        ],
      );
      final out = CppBridgeGenerator.generate(cppSpec);
      expect(out, contains('void* camera_peek_frame(int64_t instanceId, NitroError* _nitro_err)'));
      expect(out, contains('return _impl->peekFrame('));
    });

    test('NativeHandle param: void* pass-through to C++ impl', () {
      final out = CppBridgeGenerator.generate(_paramSpec());
      expect(out, contains('void camera_process_frame(int64_t instanceId, void* handle, NitroError* _nitro_err)'));
      expect(out, contains('_impl->processFrame(handle)'));
    });

    test('Android JNI signature maps NativeHandle return to long', () {
      final out = CppBridgeGenerator.generate(_borrowSpec());
      expect(out, contains('(J)J')); // (J) = instanceId param, J = jlong return
      expect(out, contains('jlong'));
    });
  });

  // ── Kotlin ─────────────────────────────────────────────────────────────────
  group('KotlinGenerator — NativeHandle', () {
    test('NativeHandle return → Long in interface and _call', () {
      final out = KotlinGenerator.generate(_borrowSpec());
      expect(out, contains('fun peekFrame(): Long'));
    });

    test('@NitroOwned: return is still Long (ownership is Dart-side)', () {
      final out = KotlinGenerator.generate(_ownedSpec());
      expect(out, contains('fun acquireFrame(): Long'));
    });
  });

  // ── Swift ──────────────────────────────────────────────────────────────────
  group('SwiftGenerator — NativeHandle', () {
    test('NativeHandle return → UnsafeMutableRawPointer? in protocol', () {
      final out = SwiftGenerator.generate(_borrowSpec());
      expect(out, contains('func peekFrame() -> UnsafeMutableRawPointer?'));
    });

    test('@NitroOwned: return still UnsafeMutableRawPointer? (ownership Dart-side)', () {
      final out = SwiftGenerator.generate(_ownedSpec());
      expect(out, contains('func acquireFrame() -> UnsafeMutableRawPointer?'));
    });

    test('@_cdecl return type is UnsafeMutableRawPointer?', () {
      final out = SwiftGenerator.generate(_borrowSpec());
      expect(out, contains('public func _camera_call_peekFrame()'));
      expect(out, contains('UnsafeMutableRawPointer?'));
    });
  });

  // ── Dart FFI ───────────────────────────────────────────────────────────────
  group('DartFfiGenerator — NativeHandle', () {
    test('borrow: FFI function pointer type is Pointer<Void>', () {
      final out = DartFfiGenerator.generate(_borrowSpec());
      expect(out, contains("'camera_peek_frame'"));
      expect(out, contains('Pointer<Void>'));
    });

    test('borrow: method return type is NativeHandle<Void>', () {
      final out = DartFfiGenerator.generate(_borrowSpec());
      expect(out, contains('NativeHandle<Void> peekFrame()'));
    });

    test('borrow: impl wraps Pointer<Void> in NativeHandle.fromAddress', () {
      final out = DartFfiGenerator.generate(_borrowSpec());
      expect(out, contains('NativeHandle<Void>.fromAddress(res.address)'));
    });

    test('@NitroOwned: emits _ReleaseFn and _Finalizer late final fields', () {
      final out = DartFfiGenerator.generate(_ownedSpec());
      expect(out, contains('_acquireFrameReleaseFn'));
      expect(out, contains('NativeFinalizer'));
      expect(out, contains("'camera_acquire_frame_release'"));
    });

    test('@NitroOwned: attaches finalizer and sets release callback', () {
      final out = DartFfiGenerator.generate(_ownedSpec());
      expect(out, contains('_acquireFrameFinalizer.attach(handle'));
      expect(out, contains('handle.attachReleaseCallback('));
      expect(out, contains('_acquireFrameFinalizer.detach(handle)'));
    });
  });
}
