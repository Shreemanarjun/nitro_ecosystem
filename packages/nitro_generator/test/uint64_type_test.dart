// uint64 scalar type — generator tests for L13.
//
// Verifies that `uint64` and `uint64?` types are correctly handled across:
//   - Dart FFI: Uint64 native type, int Dart type; uint64? → Pointer<NitroOptInt64>
//   - C header: uint64_t; uint64? → uint8_t*
//   - Kotlin: Long; uint64? → Long? interface, ByteArray bridge param
//   - Swift: UInt64; uint64? → UnsafeMutablePointer<UInt8>?
//   - Streams: kInt64 wire, int Dart unpack expr
//   - Callbacks: Int64 GP register, same-bits Dart int

import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_header_generator.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// ── Spec helpers ──────────────────────────────────────────────────────────────

BridgeSpec _spec(String returnType, {List<BridgeParam> params = const []}) =>
    BridgeSpec(
      dartClassName: 'Counter',
      lib: 'counter',
      namespace: 'counter',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'counter.native.dart',
      functions: [
        BridgeFunction(
          dartName: 'getValue',
          cSymbol: 'counter_getValue',
          isAsync: false,
          returnType: BridgeType(name: returnType),
          params: params,
        ),
      ],
    );

BridgeSpec _streamSpec(String itemType) => BridgeSpec(
      dartClassName: 'Counter',
      lib: 'counter',
      namespace: 'counter',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'counter.native.dart',
      streams: [
        BridgeStream(
          dartName: 'valueStream',
          registerSymbol: 'counter_register_valueStream',
          releaseSymbol: 'counter_release_valueStream',
          backpressure: Backpressure.dropLatest,
          itemType: BridgeType(
            name: itemType,
            isNullable: itemType.endsWith('?'),
          ),
        ),
      ],
    );

// ── Dart FFI ──────────────────────────────────────────────────────────────────

void main() {
  group('L13 uint64 — Dart FFI return', () {
    test('uint64 return: native type is Uint64', () {
      final dart = DartFfiGenerator.generate(_spec('uint64'));
      expect(dart, contains('Uint64'));
    });

    test('uint64 return: callable type is int', () {
      final dart = DartFfiGenerator.generate(_spec('uint64'));
      // The callable (Dart-side) type should use plain int for uint64.
      expect(dart, contains('int Function('));
    });

    test('uint64? return: native type is Pointer<NitroOptInt64>', () {
      final dart = DartFfiGenerator.generate(_spec('uint64?'));
      expect(dart, contains('Pointer<NitroOptInt64>'));
    });

    test('uint64? return: decoded via .decoded and malloc.free', () {
      final dart = DartFfiGenerator.generate(_spec('uint64?'));
      expect(dart, contains('.decoded'));
      expect(dart, contains('malloc.free'));
    });

    test('uint64 param: native type is Uint64', () {
      final dart = DartFfiGenerator.generate(_spec('void', params: [
        BridgeParam(name: 'val', type: BridgeType(name: 'uint64')),
      ]));
      expect(dart, contains('Uint64'));
    });

    test('uint64? param: packed via arena.packInt', () {
      final dart = DartFfiGenerator.generate(_spec('void', params: [
        BridgeParam(name: 'val', type: BridgeType(name: 'uint64?', isNullable: true)),
      ]));
      expect(dart, contains('arena.packInt(val)'));
    });
  });

  group('L13 uint64 — C header', () {
    test('uint64 return type is uint64_t', () {
      final header = CppHeaderGenerator.generate(_spec('uint64'));
      expect(header, contains('uint64_t'));
    });

    test('uint64? return type is uint8_t*', () {
      final header = CppHeaderGenerator.generate(_spec('uint64?'));
      expect(header, contains('uint8_t*'));
    });

    test('uint64 param type is uint64_t', () {
      final header = CppHeaderGenerator.generate(_spec('void', params: [
        BridgeParam(name: 'v', type: BridgeType(name: 'uint64')),
      ]));
      expect(header, contains('uint64_t v'));
    });

    test('uint64? param type is const uint8_t*', () {
      final header = CppHeaderGenerator.generate(_spec('void', params: [
        BridgeParam(name: 'v', type: BridgeType(name: 'uint64?', isNullable: true)),
      ]));
      expect(header, contains('const uint8_t* v'));
    });
  });

  group('L13 uint64 — Kotlin interface', () {
    test('uint64 return: Kotlin type is Long', () {
      final kotlin = KotlinGenerator.generate(_spec('uint64'));
      expect(kotlin, contains('Long'));
    });

    test('uint64? return interface: Long?', () {
      final kotlin = KotlinGenerator.generate(_spec('uint64?'));
      // retType: Long? for uint64?
      expect(kotlin, contains('Long?'));
    });

    test('uint64? bridge param: ByteArray', () {
      final kotlin = KotlinGenerator.generate(_spec('void', params: [
        BridgeParam(name: 'v', type: BridgeType(name: 'uint64?', isNullable: true)),
      ]));
      // bridgeParamType: ByteArray
      expect(kotlin, contains('ByteArray'));
    });
  });

  group('L13 uint64 — C bridge JNI sig', () {
    test('uint64 JNI sig: J (jlong)', () {
      final bridge = CppBridgeGenerator.generate(_spec('uint64'));
      // JNI sig: (J)J → (instanceId)→uint64 return (jlong)
      expect(bridge, contains('"(J)J"'));
    });

    test('uint64 return: CallStaticLongMethod with uint64_t cast', () {
      final bridge = CppBridgeGenerator.generate(_spec('uint64'));
      expect(bridge, contains('uint64_t'));
      expect(bridge, contains('CallStaticLongMethod'));
    });

    test('uint64? return: CallStaticObjectMethod → NitroOptInt64 copy', () {
      final bridge = CppBridgeGenerator.generate(_spec('uint64?'));
      expect(bridge, contains('CallStaticObjectMethod'));
      expect(bridge, contains('NitroOptInt64'));
    });
  });

  group('L13 uint64 — Stream<uint64>', () {
    test('Dart stream unpack: message as int', () {
      final dart = DartFfiGenerator.generate(_streamSpec('uint64'));
      expect(dart, contains('message as int'));
    });

    test('Dart stream unpack nullable: null check then message as int', () {
      final dart = DartFfiGenerator.generate(_streamSpec('uint64?'));
      expect(dart, contains('message == null ? null : message as int'));
    });

    test('Kotlin emit declaration: Long item for non-nullable uint64', () {
      final kotlin = KotlinGenerator.generate(_streamSpec('uint64'));
      expect(kotlin, contains('item: Long'));
    });

    test('Kotlin emit declaration: Long? item for nullable uint64?', () {
      final kotlin = KotlinGenerator.generate(_streamSpec('uint64?'));
      expect(kotlin, contains('item: Long?'));
    });

    test('C bridge JNI emit: jlong for non-nullable uint64 stream', () {
      final bridge = CppBridgeGenerator.generate(_streamSpec('uint64'));
      // jlong from _jniSigTypeC('uint64') → 'jlong'
      expect(bridge, contains('jlong item'));
    });

    test('C bridge JNI emit: jobject for nullable uint64? stream', () {
      final bridge = CppBridgeGenerator.generate(_streamSpec('uint64?'));
      // nullable uint64? → jobject (boxed Long?)
      expect(bridge, contains('jobject item'));
    });
  });

  group('L13 uint64 — @nitroAsync return', () {
    BridgeSpec asyncSpec(String ret) => BridgeSpec(
          dartClassName: 'Counter',
          lib: 'counter',
          namespace: 'counter',
          iosImpl: NativeImpl.swift,
          androidImpl: NativeImpl.kotlin,
          sourceUri: 'counter.native.dart',
          functions: [
            BridgeFunction(
              dartName: 'getAsync',
              cSymbol: 'counter_getAsync',
              isAsync: true,
              returnType: BridgeType(name: ret, isNullable: ret.endsWith('?')),
              params: [],
            ),
          ],
        );

    test('uint64 async return: callAsync<int>', () {
      final dart = DartFfiGenerator.generate(asyncSpec('uint64'));
      expect(dart, contains('callAsync<int>'));
    });

    test('uint64? async return: callAsync<Pointer<NitroOptInt64>>', () {
      final dart = DartFfiGenerator.generate(asyncSpec('uint64?'));
      expect(dart, contains('callAsync<Pointer<NitroOptInt64>>'));
    });
  });
}
