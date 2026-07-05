// narrow_scalar_types_test.dart
//
// Verifies that the 9 new narrow FFI scalar types are correctly handled across:
//   - Dart FFI: FFI native types and callable Dart types
//   - C header: correct C type names
//   - Kotlin interface: correct Kotlin types
//   - Swift generator: correct Swift types via SwiftTypeMapperExtended
//   - Async transport type for @nitroAsync functions

import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_header_generator.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_return_helpers.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// ── Spec helpers ──────────────────────────────────────────────────────────────

/// Creates a BridgeSpec with a single sync function returning [returnType].
BridgeSpec _returnSpec(String returnType) => BridgeSpec(
  dartClassName: 'Narrow',
  lib: 'narrow',
  namespace: 'narrow',
  iosImpl: NativeImpl.cpp,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'narrow.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'getValue',
      cSymbol: 'narrow_getValue',
      isAsync: false,
      returnType: BridgeType(name: returnType),
      params: [],
    ),
  ],
);

/// Creates a BridgeSpec with a single sync function taking [paramType] as a param.
BridgeSpec _paramSpec(String paramType) => BridgeSpec(
  dartClassName: 'Narrow',
  lib: 'narrow',
  namespace: 'narrow',
  iosImpl: NativeImpl.cpp,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'narrow.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'setValue',
      cSymbol: 'narrow_setValue',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'val',
          type: BridgeType(name: paramType),
        ),
      ],
    ),
  ],
);

/// Creates a BridgeSpec with a single @nitroAsync function returning [returnType].
BridgeSpec _asyncReturnSpec(String returnType) => BridgeSpec(
  dartClassName: 'Narrow',
  lib: 'narrow',
  namespace: 'narrow',
  iosImpl: NativeImpl.cpp,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'narrow.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'getAsync',
      cSymbol: 'narrow_getAsync',
      isAsync: true,
      returnType: BridgeType(name: returnType, isNullable: returnType.endsWith('?')),
      params: [],
    ),
  ],
);

/// Creates a BridgeSpec with iosImpl=swift + narrow scalar types.
BridgeSpec _swiftNarrowSpec({String returnType = 'int32', String paramType = 'int32'}) => BridgeSpec(
  dartClassName: 'NarrowSwift',
  lib: 'narrow_swift',
  namespace: 'narrow_swift',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'narrow_swift.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'getValue',
      cSymbol: 'narrow_swift_getValue',
      isAsync: false,
      returnType: BridgeType(name: returnType),
      params: [
        BridgeParam(
          name: 'val',
          type: BridgeType(name: paramType),
        ),
      ],
    ),
  ],
);

// ── int32 tests ───────────────────────────────────────────────────────────────

void main() {
  group('narrow scalars — int32', () {
    test('int32 param: Dart FFI type is Int32', () {
      final dart = DartFfiGenerator.generate(_paramSpec('int32'));
      expect(dart, contains('Int32'));
    });

    test('int32 param: C type is int32_t', () {
      final header = CppHeaderGenerator.generate(_paramSpec('int32'));
      expect(header, contains('int32_t'));
    });

    test('int32 param: Kotlin type contains Int', () {
      final kotlin = KotlinGenerator.generate(_paramSpec('int32'));
      expect(kotlin, contains('Int'));
    });

    test('int32 return: Dart callable type is int', () {
      final dart = DartFfiGenerator.generate(_returnSpec('int32'));
      expect(dart, contains('int Function('));
    });

    test('int32 return: async transport is int', () {
      final transport = callAsyncTransportType(
        BridgeType(name: 'int32'),
        _asyncReturnSpec('int32'),
      );
      expect(transport, equals('int'));
    });
  });

  // ── float tests ─────────────────────────────────────────────────────────────

  group('narrow scalars — float', () {
    test('float param: Dart FFI type is Float', () {
      final dart = DartFfiGenerator.generate(_paramSpec('float'));
      expect(dart, contains('Float'));
    });

    test('float param: C type is float', () {
      final header = CppHeaderGenerator.generate(_paramSpec('float'));
      expect(header, contains('float'));
    });

    test('float param: Kotlin type contains Float', () {
      final kotlin = KotlinGenerator.generate(_paramSpec('float'));
      expect(kotlin, contains('Float'));
    });

    test('float return: Dart callable type is double', () {
      final dart = DartFfiGenerator.generate(_returnSpec('float'));
      // Float maps to Dart double; the callable should use double Function(...)
      expect(dart, contains('double Function('));
    });

    test('float return: async transport is double', () {
      final transport = callAsyncTransportType(
        BridgeType(name: 'float'),
        _asyncReturnSpec('float'),
      );
      expect(transport, equals('double'));
    });
  });

  // ── uint8 tests ─────────────────────────────────────────────────────────────

  group('narrow scalars — uint8', () {
    test('uint8 param: Dart FFI type is Uint8', () {
      final dart = DartFfiGenerator.generate(_paramSpec('uint8'));
      expect(dart, contains('Uint8'));
    });

    test('uint8 param: C type is uint8_t', () {
      final header = CppHeaderGenerator.generate(_paramSpec('uint8'));
      expect(header, contains('uint8_t'));
    });
  });

  // ── size tests ──────────────────────────────────────────────────────────────

  group('narrow scalars — size', () {
    test('size param: Dart FFI type is Size', () {
      final dart = DartFfiGenerator.generate(_paramSpec('size'));
      expect(dart, contains('Size'));
    });

    test('size param: C type is size_t', () {
      final header = CppHeaderGenerator.generate(_paramSpec('size'));
      expect(header, contains('size_t'));
    });
  });

  // ── intptr tests ─────────────────────────────────────────────────────────────

  group('narrow scalars — intptr', () {
    test('intptr param: Dart FFI type is IntPtr', () {
      final dart = DartFfiGenerator.generate(_paramSpec('intptr'));
      expect(dart, contains('IntPtr'));
    });

    test('intptr param: C type is intptr_t', () {
      final header = CppHeaderGenerator.generate(_paramSpec('intptr'));
      expect(header, contains('intptr_t'));
    });
  });

  // ── Swift generator: narrow types via SwiftTypeMapperExtended ─────────────

  group('narrow scalars — Swift generator', () {
    test('int32 return: Swift @_cdecl return type is Int32', () {
      final swift = SwiftGenerator.generate(_swiftNarrowSpec(returnType: 'int32', paramType: 'void'));
      expect(swift, contains('Int32'));
    });

    test('int32 param: Swift @_cdecl param type is Int32', () {
      final swift = SwiftGenerator.generate(_swiftNarrowSpec(returnType: 'void', paramType: 'int32'));
      expect(swift, contains('Int32'));
    });

    test('uint8 param: Swift type is UInt8', () {
      final swift = SwiftGenerator.generate(_swiftNarrowSpec(returnType: 'void', paramType: 'uint8'));
      expect(swift, contains('UInt8'));
    });

    test('float return: Swift type is Float', () {
      final swift = SwiftGenerator.generate(_swiftNarrowSpec(returnType: 'float', paramType: 'void'));
      expect(swift, contains('Float'));
    });

    test('int16 param: Swift type is Int16', () {
      final swift = SwiftGenerator.generate(_swiftNarrowSpec(returnType: 'void', paramType: 'int16'));
      expect(swift, contains('Int16'));
    });

    test('size param: Swift type is Int', () {
      final swift = SwiftGenerator.generate(_swiftNarrowSpec(returnType: 'void', paramType: 'size'));
      // size_t maps to Swift Int (platform pointer width)
      expect(swift, contains(': Int'));
    });

    test('no E012 error for iosImpl=swift with int32', () {
      final issues = SpecValidator.validate(_swiftNarrowSpec());
      final e012Errors = issues.where((i) => i.isError && i.code == 'E012').toList();
      expect(e012Errors, isEmpty, reason: 'Swift now supports narrow types via SwiftTypeMapperExtended');
    });
  });

  // ── Additional types ─────────────────────────────────────────────────────────

  group('narrow scalars — other types', () {
    test('int8 param: Dart FFI type is Int8', () {
      final dart = DartFfiGenerator.generate(_paramSpec('int8'));
      expect(dart, contains('Int8'));
    });

    test('int8 param: C type is int8_t', () {
      final header = CppHeaderGenerator.generate(_paramSpec('int8'));
      expect(header, contains('int8_t'));
    });

    test('int16 param: Dart FFI type is Int16', () {
      final dart = DartFfiGenerator.generate(_paramSpec('int16'));
      expect(dart, contains('Int16'));
    });

    test('int16 param: C type is int16_t', () {
      final header = CppHeaderGenerator.generate(_paramSpec('int16'));
      expect(header, contains('int16_t'));
    });

    test('uint16 param: Dart FFI type is Uint16', () {
      final dart = DartFfiGenerator.generate(_paramSpec('uint16'));
      expect(dart, contains('Uint16'));
    });

    test('uint16 param: C type is uint16_t', () {
      final header = CppHeaderGenerator.generate(_paramSpec('uint16'));
      expect(header, contains('uint16_t'));
    });

    test('uint32 param: Dart FFI type is Uint32', () {
      final dart = DartFfiGenerator.generate(_paramSpec('uint32'));
      expect(dart, contains('Uint32'));
    });

    test('uint32 param: C type is uint32_t', () {
      final header = CppHeaderGenerator.generate(_paramSpec('uint32'));
      expect(header, contains('uint32_t'));
    });

    test('int32 return: async transport is int (not int32)', () {
      final transport = callAsyncTransportType(
        BridgeType(name: 'int32'),
        _asyncReturnSpec('int32'),
      );
      expect(transport, equals('int'));
      expect(transport, isNot(equals('int32')));
    });

    test('float return: async transport is double (not float)', () {
      final transport = callAsyncTransportType(
        BridgeType(name: 'float'),
        _asyncReturnSpec('float'),
      );
      expect(transport, equals('double'));
      expect(transport, isNot(equals('float')));
    });
  });
}
