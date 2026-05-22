// Stream item type tests for SwiftGenerator and KotlinGenerator.
//
// Verifies that every Stream<T> item type maps to the correct native type in:
//   - Swift protocol:    AnyPublisher<T, Never>
//   - Swift @_cdecl:    correct C-ABI callback param type
//   - Kotlin interface: Flow<T>
//
//   Item types covered: bool, int, double, String, Uint8List, @HybridEnum, @HybridStruct

import 'package:nitro_generator/src/generators/swift_generator.dart';
import 'package:nitro_generator/src/generators/kotlin_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

BridgeSpec _streamSpec({
  required String itemType,
  List<BridgeEnum> enums = const [],
  List<BridgeStruct> structs = const [],
}) => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'mod.native.dart',
  enums: enums,
  structs: structs,
  streams: [
    BridgeStream(
      dartName: 'events',
      itemType: BridgeType(name: itemType),
      registerSymbol: 'mod_register_events',
      releaseSymbol: 'mod_release_events',
      backpressure: Backpressure.dropLatest,
    ),
  ],
);

BridgeSpec _enumStreamSpec(String enumName) => _streamSpec(
  itemType: enumName,
  enums: [BridgeEnum(name: enumName, startValue: 0, values: ['a', 'b'])],
);

BridgeSpec _structStreamSpec(String structName) => _streamSpec(
  itemType: structName,
  structs: [
    BridgeStruct(name: structName, packed: false, fields: [
      BridgeField(name: 'x', type: BridgeType(name: 'double')),
    ]),
  ],
);

// ── Swift: protocol AnyPublisher<T, Never> ────────────────────────────────────

void main() {
  group('SwiftGenerator — Stream<T> emits AnyPublisher<T, Never> in protocol', () {
    test('Stream<bool> → AnyPublisher<Bool, Never>', () {
      final out = SwiftGenerator.generate(_streamSpec(itemType: 'bool'));
      expect(out, contains('AnyPublisher<Bool, Never>'));
    });

    test('Stream<int> → AnyPublisher<Int64, Never>', () {
      final out = SwiftGenerator.generate(_streamSpec(itemType: 'int'));
      expect(out, contains('AnyPublisher<Int64, Never>'));
    });

    test('Stream<double> → AnyPublisher<Double, Never>', () {
      final out = SwiftGenerator.generate(_streamSpec(itemType: 'double'));
      expect(out, contains('AnyPublisher<Double, Never>'));
    });

    test('Stream<String> → AnyPublisher<String, Never>', () {
      final out = SwiftGenerator.generate(_streamSpec(itemType: 'String'));
      expect(out, contains('AnyPublisher<String, Never>'));
    });

    test('Stream<Uint8List> → AnyPublisher<Data, Never>', () {
      final out = SwiftGenerator.generate(_streamSpec(itemType: 'Uint8List'));
      expect(out, contains('AnyPublisher<Data, Never>'));
    });

    test('Stream<@HybridEnum> → AnyPublisher<EnumName, Never>', () {
      final out = SwiftGenerator.generate(_enumStreamSpec('Quality'));
      expect(out, contains('AnyPublisher<Quality, Never>'));
    });

    test('Stream<@HybridStruct> → AnyPublisher<StructName, Never>', () {
      final out = SwiftGenerator.generate(_structStreamSpec('Frame'));
      expect(out, contains('AnyPublisher<Frame, Never>'));
    });
  });

  // ── Swift: @_cdecl register stub C callback param type ───────────────────

  group('SwiftGenerator — Stream @_cdecl register stub callback param type', () {
    test('Stream<bool> callback param is Int8', () {
      final out = SwiftGenerator.generate(_streamSpec(itemType: 'bool'));
      expect(out, contains('emitCb: @convention(c) (Int64, Int8) -> Void'));
    });

    test('Stream<int> callback param is Int64', () {
      final out = SwiftGenerator.generate(_streamSpec(itemType: 'int'));
      expect(out, contains('emitCb: @convention(c) (Int64, Int64) -> Void'));
    });

    test('Stream<String> callback param is UnsafeMutablePointer<Int8>?', () {
      final out = SwiftGenerator.generate(_streamSpec(itemType: 'String'));
      expect(out, contains('emitCb: @convention(c) (Int64, UnsafeMutablePointer<Int8>?) -> Void'));
    });

    test('Stream<Uint8List> callback param is UnsafeMutablePointer<UInt8>?', () {
      final out = SwiftGenerator.generate(_streamSpec(itemType: 'Uint8List'));
      expect(out, contains('emitCb: @convention(c) (Int64, UnsafeMutablePointer<UInt8>?) -> Void'));
    });

    test('Stream<@HybridEnum> callback param is Int64', () {
      final out = SwiftGenerator.generate(_enumStreamSpec('Status'));
      expect(out, contains('emitCb: @convention(c) (Int64, Int64) -> Void'));
    });

    test('Stream<@HybridStruct> callback param is UnsafeMutableRawPointer?', () {
      final out = SwiftGenerator.generate(_structStreamSpec('Point'));
      expect(out, contains('emitCb: @convention(c) (Int64, UnsafeMutableRawPointer?) -> Void'));
    });
  });

  // ── Swift: enum stream emits .rawValue, struct stream allocates C shadow ──

  group('SwiftGenerator — Stream<@HybridEnum> sink emits .rawValue', () {
    test('enum stream sink calls emitCb with item.rawValue', () {
      final out = SwiftGenerator.generate(_enumStreamSpec('Status'));
      expect(out, contains('emitCb(dartPort, item.rawValue)'));
    });
  });

  group('SwiftGenerator — Stream<@HybridStruct> sink allocates C shadow struct', () {
    test('struct stream sink allocates UnsafeMutablePointer<_PointC>', () {
      final out = SwiftGenerator.generate(_structStreamSpec('Point'));
      expect(out, contains('UnsafeMutablePointer<_PointC>.allocate(capacity: 1)'));
    });

    test('struct stream sink initializes shadow with fromSwift()', () {
      final out = SwiftGenerator.generate(_structStreamSpec('Point'));
      expect(out, contains('_PointC.fromSwift(item)'));
    });
  });

  // ── Swift: register and release stubs are emitted ─────────────────────────

  group('SwiftGenerator — Stream register and release @_cdecl stubs', () {
    test('register stub is emitted', () {
      final out = SwiftGenerator.generate(_streamSpec(itemType: 'int'));
      expect(out, contains('@_cdecl("_mod_register_events_stream")'));
    });

    test('release stub is emitted', () {
      final out = SwiftGenerator.generate(_streamSpec(itemType: 'int'));
      expect(out, contains('@_cdecl("_mod_release_events_stream")'));
    });
  });

  // ── Kotlin: interface Flow<T> ─────────────────────────────────────────────

  group('KotlinGenerator — Stream<T> emits Flow<T> in interface', () {
    test('Stream<bool> → Flow<Boolean>', () {
      final out = KotlinGenerator.generate(_streamSpec(itemType: 'bool'));
      expect(out, contains('Flow<Boolean>'));
    });

    test('Stream<int> → Flow<Long>', () {
      final out = KotlinGenerator.generate(_streamSpec(itemType: 'int'));
      expect(out, contains('Flow<Long>'));
    });

    test('Stream<double> → Flow<Double>', () {
      final out = KotlinGenerator.generate(_streamSpec(itemType: 'double'));
      expect(out, contains('Flow<Double>'));
    });

    test('Stream<String> → Flow<String>', () {
      final out = KotlinGenerator.generate(_streamSpec(itemType: 'String'));
      expect(out, contains('Flow<String>'));
    });

    test('Stream<Uint8List> → Flow<ByteArray>', () {
      final out = KotlinGenerator.generate(_streamSpec(itemType: 'Uint8List'));
      expect(out, contains('Flow<ByteArray>'));
    });

    test('Stream<@HybridEnum> → Flow<EnumName>', () {
      final out = KotlinGenerator.generate(_enumStreamSpec('Quality'));
      expect(out, contains('Flow<Quality>'));
    });

    test('Stream<@HybridStruct> → Flow<StructName>', () {
      final out = KotlinGenerator.generate(_structStreamSpec('Frame'));
      expect(out, contains('Flow<Frame>'));
    });
  });

  // ── Kotlin: register/release stubs emitted ───────────────────────────────

  group('KotlinGenerator — Stream register and release _call stubs', () {
    test('register _call stub emitted', () {
      final out = KotlinGenerator.generate(_streamSpec(itemType: 'int'));
      expect(out, contains('fun mod_register_events_call(dartPort: Long)'));
    });

    test('release _call stub emitted', () {
      final out = KotlinGenerator.generate(_streamSpec(itemType: 'int'));
      expect(out, contains('fun mod_release_events_call(dartPort: Long)'));
    });
  });
}
