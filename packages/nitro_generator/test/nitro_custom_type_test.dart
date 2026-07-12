// Tests for @NitroCustomType (L16) across all five generators.
//
// @NitroCustomType is the equivalent of JSIConverter<T> specialization in RN
// Nitro. Users annotate a Dart class with @NitroCustomType(codec: ...) and the
// generator emits `const CodecClass().encode(value, arena)` for params and
// `const CodecClass().decode(ptr)` for returns. Wire: Pointer<Uint8> /
// ByteArray — identical to @HybridRecord.

import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_header_generator.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:test/test.dart';

// ── Fixtures ──────────────────────────────────────────────────────────────────

const _colorCodec = BridgeCustomType(
  name: 'Color',
  codecClass: 'ColorCodec',
  encodedSize: 5,
);

BridgeSpec _returnSpec() => BridgeSpec(
  dartClassName: 'Graphics',
  lib: 'graphics',
  namespace: 'graphics',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'graphics.native.dart',
  customTypes: [_colorCodec],
  functions: [
    BridgeFunction(
      dartName: 'getColor',
      cSymbol: 'graphics_get_color',
      isAsync: false,
      returnType: BridgeType(name: 'Color'),
      params: [],
    ),
    BridgeFunction(
      dartName: 'findColor',
      cSymbol: 'graphics_find_color',
      isAsync: false,
      returnType: BridgeType(name: 'Color?', isNullable: true),
      params: [],
    ),
  ],
);

BridgeSpec _paramSpec() => BridgeSpec(
  dartClassName: 'Graphics',
  lib: 'graphics',
  namespace: 'graphics',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'graphics.native.dart',
  customTypes: [_colorCodec],
  functions: [
    BridgeFunction(
      dartName: 'setColor',
      cSymbol: 'graphics_set_color',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'color',
          type: BridgeType(name: 'Color'),
        ),
      ],
    ),
    BridgeFunction(
      dartName: 'trySetColor',
      cSymbol: 'graphics_try_set_color',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'color',
          type: BridgeType(name: 'Color?', isNullable: true),
        ),
      ],
    ),
  ],
);

// ── Main ──────────────────────────────────────────────────────────────────────

void main() {
  group('@NitroCustomType — C header', () {
    test('non-null return: uint8_t* in C declaration', () {
      final out = CppHeaderGenerator.generate(_returnSpec());
      expect(out, contains('uint8_t* graphics_get_color(int64_t instanceId, NitroError* _nitro_err);'));
    });

    test('nullable return: uint8_t* in C declaration', () {
      final out = CppHeaderGenerator.generate(_returnSpec());
      expect(out, contains('uint8_t* graphics_find_color(int64_t instanceId, NitroError* _nitro_err);'));
    });

    test('non-null param: const uint8_t* in C declaration', () {
      final out = CppHeaderGenerator.generate(_paramSpec());
      expect(out, contains('void graphics_set_color(int64_t instanceId, const uint8_t* color, NitroError* _nitro_err);'));
    });

    test('nullable param: const uint8_t* in C declaration', () {
      final out = CppHeaderGenerator.generate(_paramSpec());
      expect(out, contains('void graphics_try_set_color(int64_t instanceId, const uint8_t* color, NitroError* _nitro_err);'));
    });
  });

  group('@NitroCustomType — Dart FFI', () {
    test('non-null param: const ColorCodec().encode(color, arena)', () {
      final out = DartFfiGenerator.generate(_paramSpec());
      expect(out, contains('const ColorCodec().encode(color, arena)'));
    });

    test('nullable param: const ColorCodec().encode(color, arena)', () {
      final out = DartFfiGenerator.generate(_paramSpec());
      expect(out, contains('const ColorCodec().encode(color, arena)'));
    });

    test('non-null return: codec decode with null-assert', () {
      final out = DartFfiGenerator.generate(_returnSpec());
      expect(out, contains('const ColorCodec().decode(res)!'));
    });

    test('nullable return: codec decode without null-assert', () {
      final out = DartFfiGenerator.generate(_returnSpec());
      expect(out, contains('const ColorCodec().decode(res)'));
    });

    test('non-null return: frees native pointer after decode', () {
      final out = DartFfiGenerator.generate(_returnSpec());
      expect(out, contains('malloc.free(res)'));
    });
  });

  group('@NitroCustomType — Kotlin', () {
    test('param type: ByteArray', () {
      final out = KotlinGenerator.generate(_paramSpec());
      expect(out, contains('fun setColor(color: ByteArray)'));
    });

    test('nullable param type: ByteArray?', () {
      final out = KotlinGenerator.generate(_paramSpec());
      expect(out, contains('fun trySetColor(color: ByteArray?)'));
    });

    test('non-null return type: ByteArray', () {
      final out = KotlinGenerator.generate(_returnSpec());
      expect(out, contains('fun getColor(): ByteArray'));
    });

    test('nullable return type: ByteArray?', () {
      final out = KotlinGenerator.generate(_returnSpec());
      expect(out, contains('fun findColor(): ByteArray?'));
    });
  });

  group('@NitroCustomType — Swift', () {
    test('non-null return: UnsafeMutablePointer<UInt8>? in @_cdecl', () {
      final out = SwiftGenerator.generate(_returnSpec());
      expect(out, contains('-> UnsafeMutablePointer<UInt8>?'));
    });

    test('non-null param: UnsafeMutablePointer<UInt8>? in @_cdecl', () {
      final out = SwiftGenerator.generate(_paramSpec());
      expect(out, contains('color: UnsafeMutablePointer<UInt8>?'));
    });

    test('protocol method returns [UInt8] for custom type', () {
      final out = SwiftGenerator.generate(_returnSpec());
      expect(out, contains('[UInt8]'));
    });
  });

  group('@NitroCustomType — C bridge JNI', () {
    test('non-null param: copies bytes to ByteArray with fixed encodedSize', () {
      final out = CppBridgeGenerator.generate(_paramSpec());
      expect(out, contains('NewByteArray((jsize)5)'));
      expect(out, contains('SetByteArrayRegion'));
    });

    test('non-null return: copies ByteArray bytes to malloc\'d buffer', () {
      final out = CppBridgeGenerator.generate(_returnSpec());
      expect(out, contains('GetByteArrayRegion'));
      expect(out, contains('malloc((size_t)ct_len)'));
    });
  });

  // ── @NitroCustomType — C++ desktop dispatch param declaration consistency ──
  //
  // Found via an audit (not a real CI failure) prompted by the earlier
  // List/Map/callback native-async param bug: cpp_header_generator.dart
  // declares a @NitroCustomType param as `const uint8_t*`, but neither
  // cpp_bridge_generator.dart's sync/native-async desktop dispatch nor
  // cpp_direct_emitter.dart's pure-C++ dispatch special-cased CustomType at
  // all — both fell through to the generic branch, which defaults to
  // `void*`. Declaring the SAME extern "C" symbol with two different
  // parameter types is a hard MSVC/Clang "conflicting types" compile error
  // (the exact same failure class as GitHub #9 bug 1 and the callback bug),
  // for BOTH sync and native-async, on BOTH desktop dispatch paths — never
  // caught because no existing test exercised @NitroCustomType together
  // with windows/linux NativeImpl.cpp.
  group('@NitroCustomType — desktop dispatch declares the SAME type as the .h file', () {
    String firstDeclLine(String text, String needle) => text.split('\n').firstWhere((l) => l.contains(needle));

    test('mixed platform (android:kotlin, windows/linux:cpp), sync: .h and .cpp both use const uint8_t*', () {
      final h = CppHeaderGenerator.generate(_mixedPlatformSpec());
      final cpp = CppBridgeGenerator.generate(_mixedPlatformSpec());
      final hLine = firstDeclLine(h, 'graphics_set_color_sync(');
      final winLinuxSection = cpp.substring(cpp.indexOf('Windows/Linux: NativeImpl.cpp'));
      final cppLine = firstDeclLine(winLinuxSection, 'void graphics_set_color_sync(');
      expect(hLine, contains('const uint8_t* color'));
      expect(cppLine, contains('const uint8_t* color'));
      expect(cppLine, isNot(contains('void* color')));
    });

    test('mixed platform, native-async: .h and .cpp both use const uint8_t*', () {
      final h = CppHeaderGenerator.generate(_mixedPlatformSpec());
      final cpp = CppBridgeGenerator.generate(_mixedPlatformSpec());
      final hLine = firstDeclLine(h, 'graphics_set_color(');
      final winLinuxSection = cpp.substring(cpp.indexOf('Windows/Linux: NativeImpl.cpp'));
      final cppLine = firstDeclLine(winLinuxSection, 'void graphics_set_color(');
      expect(hLine, contains('const uint8_t* color'));
      expect(cppLine, contains('const uint8_t* color'));
      expect(cppLine, isNot(contains('void* color')));
    });

    test('pure C++ everywhere (android+ios both cpp), sync: .h and .cpp both use const uint8_t*', () {
      final h = CppHeaderGenerator.generate(_cppOnlySpec());
      final cpp = CppBridgeGenerator.generate(_cppOnlySpec());
      final hLine = firstDeclLine(h, 'graphics_set_color_sync(');
      final cppLine = cpp.split('\n').firstWhere((l) => l.trim().startsWith('void graphics_set_color_sync('));
      expect(hLine, contains('const uint8_t* color'));
      expect(cppLine, contains('const uint8_t* color'));
      expect(cppLine, isNot(contains('void* color')));
    });

    test('pure C++ everywhere, native-async: .h and .cpp both use const uint8_t*', () {
      final h = CppHeaderGenerator.generate(_cppOnlySpec());
      final cpp = CppBridgeGenerator.generate(_cppOnlySpec());
      final hLine = firstDeclLine(h, 'graphics_set_color(');
      final cppLine = cpp.split('\n').firstWhere((l) => l.trim().startsWith('void graphics_set_color('));
      expect(hLine, contains('const uint8_t* color'));
      expect(cppLine, contains('const uint8_t* color'));
      expect(cppLine, isNot(contains('void* color')));
    });
  });
}

BridgeSpec _mixedPlatformSpec() => BridgeSpec(
  dartClassName: 'Graphics',
  lib: 'graphics',
  namespace: 'graphics',
  androidImpl: NativeImpl.kotlin,
  iosImpl: NativeImpl.swift,
  windowsImpl: NativeImpl.cpp,
  linuxImpl: NativeImpl.cpp,
  sourceUri: 'graphics.native.dart',
  customTypes: [_colorCodec],
  functions: [
    BridgeFunction(
      dartName: 'setColor',
      cSymbol: 'graphics_set_color',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'void'),
      params: [BridgeParam(name: 'color', type: BridgeType(name: 'Color'))],
    ),
    BridgeFunction(
      dartName: 'setColorSync',
      cSymbol: 'graphics_set_color_sync',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [BridgeParam(name: 'color', type: BridgeType(name: 'Color'))],
    ),
  ],
);

BridgeSpec _cppOnlySpec() => BridgeSpec(
  dartClassName: 'Graphics',
  lib: 'graphics',
  namespace: 'graphics',
  androidImpl: NativeImpl.cpp,
  iosImpl: NativeImpl.cpp,
  sourceUri: 'graphics.native.dart',
  customTypes: [_colorCodec],
  functions: [
    BridgeFunction(
      dartName: 'setColor',
      cSymbol: 'graphics_set_color',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'void'),
      params: [BridgeParam(name: 'color', type: BridgeType(name: 'Color'))],
    ),
    BridgeFunction(
      dartName: 'setColorSync',
      cSymbol: 'graphics_set_color_sync',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [BridgeParam(name: 'color', type: BridgeType(name: 'Color'))],
    ),
  ],
);
