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
}
