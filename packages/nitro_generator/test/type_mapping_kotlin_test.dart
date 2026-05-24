// Comprehensive type-mapping tests for KotlinGenerator.
//
// Covers every Dart type → Kotlin type translation that the generator must
// produce correctly, verified against the actual _toKotlinType() logic:
//
//   Section 1: Scalar primitives (bool, int, double, String) as params + returns
//   Section 2: All 10 TypedData variants as params (ByteArray / ShortArray / …)
//   Section 3: Nullable params — int?→Long?, bool?→Boolean?, etc.
//   Section 4: Enum as param, return, and property
//   Section 5: Struct as param and return
//   Section 6: Properties — all scalar types, var (read-write) vs val (read-only)
//   Section 7: Streams — Flow<T> for all item types
//   Section 8: Async — suspend fun for every return type
//   Section 9: Android-not-targeted spec returns no-target comment

import 'package:nitro_generator/src/generators/kotlin_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

BridgeSpec _fnSpec(String returnType, List<BridgeParam> params, {bool async = false}) => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'mod.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'fn',
      cSymbol: 'mod_fn',
      isAsync: async,
      returnType: BridgeType(name: returnType),
      params: params,
    ),
  ],
);

BridgeParam _p(String type, String name) => BridgeParam(
  name: name,
  type: BridgeType(name: type),
);

BridgeSpec _typedDataParamSpec(String typeName) => _fnSpec('void', [_p(typeName, 'data')]);

BridgeSpec _propSpec(String dartType, {bool readOnly = false}) => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'mod.native.dart',
  properties: [
    BridgeProperty(
      dartName: 'value',
      type: BridgeType(name: dartType),
      getSymbol: 'mod_get_value',
      setSymbol: 'mod_set_value',
      hasGetter: true,
      hasSetter: !readOnly,
    ),
  ],
);

BridgeSpec _asyncReturnSpec(String returnType) => _fnSpec(returnType, [], async: true);

BridgeSpec _enumFnSpec(String enumName) => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'mod.native.dart',
  enums: [
    BridgeEnum(name: enumName, startValue: 0, values: ['a', 'b']),
  ],
  functions: [
    BridgeFunction(
      dartName: 'fn',
      cSymbol: 'mod_fn',
      isAsync: false,
      returnType: BridgeType(name: enumName),
      params: [_p(enumName, 'mode')],
    ),
  ],
);

BridgeSpec _structFnSpec(String structName) => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'mod.native.dart',
  structs: [
    BridgeStruct(
      name: structName,
      packed: false,
      fields: [
        BridgeField(
          name: 'x',
          type: BridgeType(name: 'double'),
        ),
      ],
    ),
  ],
  functions: [
    BridgeFunction(
      dartName: 'make',
      cSymbol: 'mod_make',
      isAsync: false,
      returnType: BridgeType(name: structName),
      params: [_p(structName, 'src')],
    ),
  ],
);

BridgeSpec _streamSpec(String itemType) => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'mod.native.dart',
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

// ── Section 1: Scalar primitives ─────────────────────────────────────────────

void main() {
  group('KotlinGenerator — scalar primitive params in interface', () {
    test('bool param uses Boolean', () {
      final out = KotlinGenerator.generate(_fnSpec('void', [_p('bool', 'flag')]));
      expect(out, contains('flag: Boolean'));
    });

    test('int param uses Long', () {
      final out = KotlinGenerator.generate(_fnSpec('void', [_p('int', 'count')]));
      expect(out, contains('count: Long'));
    });

    test('double param uses Double', () {
      final out = KotlinGenerator.generate(_fnSpec('void', [_p('double', 'value')]));
      expect(out, contains('value: Double'));
    });

    test('String param uses String', () {
      final out = KotlinGenerator.generate(_fnSpec('void', [_p('String', 'text')]));
      expect(out, contains('text: String'));
    });
  });

  group('KotlinGenerator — scalar primitive returns in interface', () {
    test('bool return uses Boolean', () {
      final out = KotlinGenerator.generate(_fnSpec('bool', []));
      expect(out, contains('fun fn(): Boolean'));
    });

    test('int return uses Long', () {
      final out = KotlinGenerator.generate(_fnSpec('int', []));
      expect(out, contains('fun fn(): Long'));
    });

    test('double return uses Double', () {
      final out = KotlinGenerator.generate(_fnSpec('double', []));
      expect(out, contains('fun fn(): Double'));
    });

    test('String return uses String', () {
      final out = KotlinGenerator.generate(_fnSpec('String', []));
      expect(out, contains('fun fn(): String'));
    });

    test('void return uses Unit', () {
      final out = KotlinGenerator.generate(_fnSpec('void', []));
      expect(out, contains('fun fn(): Unit'));
    });
  });

  // ── Section 2: TypedData variants ─────────────────────────────────────────

  group('KotlinGenerator — TypedData param type mapping in interface', () {
    test('Uint8List param → ByteArray', () {
      final out = KotlinGenerator.generate(_typedDataParamSpec('Uint8List'));
      expect(out, contains('data: ByteArray'));
    });

    test('Int8List param → ByteArray', () {
      final out = KotlinGenerator.generate(_typedDataParamSpec('Int8List'));
      expect(out, contains('data: ByteArray'));
    });

    test('Int16List param → ShortArray', () {
      final out = KotlinGenerator.generate(_typedDataParamSpec('Int16List'));
      expect(out, contains('data: ShortArray'));
    });

    test('Uint16List param → ShortArray', () {
      final out = KotlinGenerator.generate(_typedDataParamSpec('Uint16List'));
      expect(out, contains('data: ShortArray'));
    });

    test('Int32List param → IntArray', () {
      final out = KotlinGenerator.generate(_typedDataParamSpec('Int32List'));
      expect(out, contains('data: IntArray'));
    });

    test('Uint32List param → IntArray', () {
      final out = KotlinGenerator.generate(_typedDataParamSpec('Uint32List'));
      expect(out, contains('data: IntArray'));
    });

    test('Float32List param → FloatArray', () {
      final out = KotlinGenerator.generate(_typedDataParamSpec('Float32List'));
      expect(out, contains('data: FloatArray'));
    });

    test('Float64List param → DoubleArray', () {
      final out = KotlinGenerator.generate(_typedDataParamSpec('Float64List'));
      expect(out, contains('data: DoubleArray'));
    });

    test('Int64List param → LongArray', () {
      final out = KotlinGenerator.generate(_typedDataParamSpec('Int64List'));
      expect(out, contains('data: LongArray'));
    });

    test('Uint64List param → LongArray', () {
      final out = KotlinGenerator.generate(_typedDataParamSpec('Uint64List'));
      expect(out, contains('data: LongArray'));
    });
  });

  // ── Section 3: Nullable params ────────────────────────────────────────────

  group('KotlinGenerator — nullable scalar params in interface', () {
    test('bool? param → Boolean?', () {
      final out = KotlinGenerator.generate(_fnSpec('void', [_p('bool?', 'flag')]));
      expect(out, contains('flag: Boolean?'));
    });

    test('int? param → Long?', () {
      final out = KotlinGenerator.generate(_fnSpec('void', [_p('int?', 'n')]));
      expect(out, contains('n: Long?'));
    });

    test('double? param → Double?', () {
      final out = KotlinGenerator.generate(_fnSpec('void', [_p('double?', 'd')]));
      expect(out, contains('d: Double?'));
    });

    test('String? param → String?', () {
      final out = KotlinGenerator.generate(_fnSpec('void', [_p('String?', 's')]));
      expect(out, contains('s: String?'));
    });
  });

  // ── Section 4: Enum ───────────────────────────────────────────────────────

  group('KotlinGenerator — enum type mapping', () {
    test('enum param uses enum name in interface', () {
      final out = KotlinGenerator.generate(_enumFnSpec('Status'));
      expect(out, contains('mode: Status'));
    });

    test('enum return uses enum name in interface', () {
      final out = KotlinGenerator.generate(_enumFnSpec('Status'));
      expect(out, contains('fun fn(mode: Status): Status'));
    });

    test('enum JniBridge _call returns Long (bridge primitive), param stays enum type', () {
      final out = KotlinGenerator.generate(_enumFnSpec('Status'));
      // Enum params in _call keep the enum type; only the return type is bridged to Long.
      expect(out, contains('fun fn_call(mode: Status): Long'));
    });

    test('enum read-write property uses var', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'mod.native.dart',
        enums: [
          BridgeEnum(name: 'Mode', startValue: 0, values: ['off', 'on']),
        ],
        properties: [
          BridgeProperty(
            dartName: 'mode',
            type: BridgeType(name: 'Mode'),
            getSymbol: 'mod_get_mode',
            setSymbol: 'mod_set_mode',
            hasGetter: true,
            hasSetter: true,
          ),
        ],
      );
      final out = KotlinGenerator.generate(spec);
      expect(out, contains('var mode: Mode'));
    });

    test('enum read-only property uses val', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'mod.native.dart',
        enums: [
          BridgeEnum(name: 'Mode', startValue: 0, values: ['off', 'on']),
        ],
        properties: [
          BridgeProperty(
            dartName: 'mode',
            type: BridgeType(name: 'Mode'),
            getSymbol: 'mod_get_mode',
            setSymbol: 'mod_set_mode',
            hasGetter: true,
            hasSetter: false,
          ),
        ],
      );
      final out = KotlinGenerator.generate(spec);
      expect(out, contains('val mode: Mode'));
    });
  });

  // ── Section 5: Struct ─────────────────────────────────────────────────────

  group('KotlinGenerator — struct type mapping', () {
    test('struct param uses struct name in interface', () {
      final out = KotlinGenerator.generate(_structFnSpec('Point'));
      expect(out, contains('src: Point'));
    });

    test('struct return uses struct name in interface', () {
      final out = KotlinGenerator.generate(_structFnSpec('Point'));
      expect(out, contains('fun make(src: Point): Point'));
    });
  });

  // ── Section 6: Properties ─────────────────────────────────────────────────

  group('KotlinGenerator — property type mapping (read-write → var)', () {
    test('bool property uses Boolean', () {
      final out = KotlinGenerator.generate(_propSpec('bool'));
      expect(out, contains('var value: Boolean'));
    });

    test('int property uses Long', () {
      final out = KotlinGenerator.generate(_propSpec('int'));
      expect(out, contains('var value: Long'));
    });

    test('double property uses Double', () {
      final out = KotlinGenerator.generate(_propSpec('double'));
      expect(out, contains('var value: Double'));
    });

    test('String property uses String', () {
      final out = KotlinGenerator.generate(_propSpec('String'));
      expect(out, contains('var value: String'));
    });
  });

  group('KotlinGenerator — property type mapping (read-only → val)', () {
    test('bool read-only uses val', () {
      final out = KotlinGenerator.generate(_propSpec('bool', readOnly: true));
      expect(out, contains('val value: Boolean'));
      expect(out, isNot(contains('var value: Boolean')));
    });

    test('int read-only uses val', () {
      final out = KotlinGenerator.generate(_propSpec('int', readOnly: true));
      expect(out, contains('val value: Long'));
    });

    test('String read-only uses val', () {
      final out = KotlinGenerator.generate(_propSpec('String', readOnly: true));
      expect(out, contains('val value: String'));
    });
  });

  // ── Section 7: Streams ────────────────────────────────────────────────────

  group('KotlinGenerator — Stream<T> uses Flow<T> in interface', () {
    test('Stream<bool> → Flow<Boolean>', () {
      final out = KotlinGenerator.generate(_streamSpec('bool'));
      expect(out, contains('Flow<Boolean>'));
    });

    test('Stream<int> → Flow<Long>', () {
      final out = KotlinGenerator.generate(_streamSpec('int'));
      expect(out, contains('Flow<Long>'));
    });

    test('Stream<double> → Flow<Double>', () {
      final out = KotlinGenerator.generate(_streamSpec('double'));
      expect(out, contains('Flow<Double>'));
    });

    test('Stream<String> → Flow<String>', () {
      final out = KotlinGenerator.generate(_streamSpec('String'));
      expect(out, contains('Flow<String>'));
    });

    test('Stream<Uint8List> → Flow<ByteArray>', () {
      final out = KotlinGenerator.generate(_streamSpec('Uint8List'));
      expect(out, contains('Flow<ByteArray>'));
    });
  });

  // ── Section 8: Async ──────────────────────────────────────────────────────

  group('KotlinGenerator — async functions use suspend fun in interface', () {
    test('Future<void> → suspend fun fn(): Unit', () {
      final out = KotlinGenerator.generate(_asyncReturnSpec('void'));
      expect(out, contains('suspend fun fn(): Unit'));
    });

    test('Future<bool> → suspend fun fn(): Boolean', () {
      final out = KotlinGenerator.generate(_asyncReturnSpec('bool'));
      expect(out, contains('suspend fun fn(): Boolean'));
    });

    test('Future<int> → suspend fun fn(): Long', () {
      final out = KotlinGenerator.generate(_asyncReturnSpec('int'));
      expect(out, contains('suspend fun fn(): Long'));
    });

    test('Future<double> → suspend fun fn(): Double', () {
      final out = KotlinGenerator.generate(_asyncReturnSpec('double'));
      expect(out, contains('suspend fun fn(): Double'));
    });

    test('Future<String> → suspend fun fn(): String', () {
      final out = KotlinGenerator.generate(_asyncReturnSpec('String'));
      expect(out, contains('suspend fun fn(): String'));
    });

    test('Future<@HybridEnum> → suspend fun fn(): EnumName', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'mod.native.dart',
        enums: [
          BridgeEnum(name: 'Quality', startValue: 0, values: ['low', 'high']),
        ],
        functions: [
          BridgeFunction(
            dartName: 'getQuality',
            cSymbol: 'mod_get_quality',
            isAsync: true,
            returnType: BridgeType(name: 'Quality'),
            params: [],
          ),
        ],
      );
      final out = KotlinGenerator.generate(spec);
      expect(out, contains('suspend fun getQuality(): Quality'));
    });
  });

  // ── Section 9: Android-not-targeted ──────────────────────────────────────

  group('KotlinGenerator — iOS-only spec returns no-target comment', () {
    test('spec without androidImpl returns Android-not-targeted comment', () {
      final spec = BridgeSpec(
        dartClassName: 'IosMod',
        lib: 'ios_mod',
        namespace: 'ios_mod',
        iosImpl: NativeImpl.swift,
        sourceUri: 'ios_mod.native.dart',
        functions: [],
      );
      final out = KotlinGenerator.generate(spec);
      expect(out, contains('Android not targeted'));
    });

    test('spec without androidImpl does not emit an interface', () {
      final spec = BridgeSpec(
        dartClassName: 'IosMod',
        lib: 'ios_mod',
        namespace: 'ios_mod',
        iosImpl: NativeImpl.swift,
        sourceUri: 'ios_mod.native.dart',
        functions: [],
      );
      final out = KotlinGenerator.generate(spec);
      expect(out, isNot(contains('interface Hybrid')));
    });
  });
}
