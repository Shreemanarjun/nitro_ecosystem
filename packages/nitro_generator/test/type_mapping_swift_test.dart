// Comprehensive type-mapping tests for SwiftGenerator.
//
// Covers every Dart type → Swift type translation that the generator must
// produce correctly, verified against the actual _toSwiftType() logic:
//
//   Section 1: Scalar primitives (bool, int, double, String) as params + returns
//   Section 2: All 10 TypedData variants as params (Data / [Int16] / [Int32] / …)
//   Section 3: Nullable scalars as params and protocol return types
//   Section 4: Enum as param, return, and property
//   Section 5: Struct as param, return, and property
//   Section 6: Properties — all scalar types, read-only and read-write
//   Section 7: Async (async throws) for every return type
//   Section 8: macOS Swift — identical protocol output when iosImpl is absent

import 'package:nitro_generator/src/generators/swift_generator.dart';
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

BridgeParam _p(String type, String name) =>
    BridgeParam(name: name, type: BridgeType(name: type));

BridgeSpec _typedDataParamSpec(String typeName) =>
    _fnSpec('void', [_p(typeName, 'data')]);

BridgeSpec _propSpec(String dartType, {bool readOnly = false}) => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  iosImpl: NativeImpl.swift,
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

BridgeSpec _macosSpec() => BridgeSpec(
  dartClassName: 'MacMod',
  lib: 'mac_mod',
  namespace: 'mac_mod',
  macosImpl: NativeImpl.swift,
  sourceUri: 'mac_mod.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'greet',
      cSymbol: 'mac_mod_greet',
      isAsync: false,
      returnType: BridgeType(name: 'String'),
      params: [_p('String', 'name')],
    ),
  ],
);

BridgeSpec _enumSpec(String enumName) => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  iosImpl: NativeImpl.swift,
  sourceUri: 'mod.native.dart',
  enums: [BridgeEnum(name: enumName, startValue: 0, values: ['a', 'b'])],
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

BridgeSpec _structParamReturnSpec(String structName) => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  iosImpl: NativeImpl.swift,
  sourceUri: 'mod.native.dart',
  structs: [
    BridgeStruct(name: structName, packed: false, fields: [
      BridgeField(name: 'x', type: BridgeType(name: 'double')),
    ]),
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

// ── Section 1: Scalar primitives ─────────────────────────────────────────────

void main() {
  group('SwiftGenerator — scalar primitive params', () {
    test('bool param in protocol uses Bool', () {
      final out = SwiftGenerator.generate(_fnSpec('void', [_p('bool', 'flag')]));
      expect(out, contains('func fn(flag: Bool)'));
    });

    test('int param in protocol uses Int64', () {
      final out = SwiftGenerator.generate(_fnSpec('void', [_p('int', 'count')]));
      expect(out, contains('func fn(count: Int64)'));
    });

    test('double param in protocol uses Double', () {
      final out = SwiftGenerator.generate(_fnSpec('void', [_p('double', 'value')]));
      expect(out, contains('func fn(value: Double)'));
    });

    test('String param in protocol uses String', () {
      final out = SwiftGenerator.generate(_fnSpec('void', [_p('String', 'text')]));
      expect(out, contains('func fn(text: String)'));
    });

    test('bool return in protocol uses Bool', () {
      final out = SwiftGenerator.generate(_fnSpec('bool', []));
      expect(out, contains('func fn() -> Bool'));
    });

    test('int return in protocol uses Int64', () {
      final out = SwiftGenerator.generate(_fnSpec('int', []));
      expect(out, contains('func fn() -> Int64'));
    });

    test('double return in protocol uses Double', () {
      final out = SwiftGenerator.generate(_fnSpec('double', []));
      expect(out, contains('func fn() -> Double'));
    });

    test('String return in protocol uses String', () {
      final out = SwiftGenerator.generate(_fnSpec('String', []));
      expect(out, contains('func fn() -> String'));
    });

    test('void return in protocol uses -> Void', () {
      final out = SwiftGenerator.generate(_fnSpec('void', []));
      expect(out, contains('func fn() -> Void'));
    });
  });

  // ── Section 2: TypedData variants ─────────────────────────────────────────

  group('SwiftGenerator — TypedData param type mapping', () {
    test('Uint8List param → Data', () {
      final out = SwiftGenerator.generate(_typedDataParamSpec('Uint8List'));
      expect(out, contains('data: Data'));
    });

    test('Int8List param → Data', () {
      final out = SwiftGenerator.generate(_typedDataParamSpec('Int8List'));
      expect(out, contains('data: Data'));
    });

    test('Int16List param → [Int16]', () {
      final out = SwiftGenerator.generate(_typedDataParamSpec('Int16List'));
      expect(out, contains('data: [Int16]'));
    });

    test('Uint16List param → [Int16]', () {
      final out = SwiftGenerator.generate(_typedDataParamSpec('Uint16List'));
      expect(out, contains('data: [Int16]'));
    });

    test('Int32List param → [Int32]', () {
      final out = SwiftGenerator.generate(_typedDataParamSpec('Int32List'));
      expect(out, contains('data: [Int32]'));
    });

    test('Uint32List param → [Int32]', () {
      final out = SwiftGenerator.generate(_typedDataParamSpec('Uint32List'));
      expect(out, contains('data: [Int32]'));
    });

    test('Float32List param → [Float]', () {
      final out = SwiftGenerator.generate(_typedDataParamSpec('Float32List'));
      expect(out, contains('data: [Float]'));
    });

    test('Float64List param → [Double]', () {
      final out = SwiftGenerator.generate(_typedDataParamSpec('Float64List'));
      expect(out, contains('data: [Double]'));
    });

    test('Int64List param → [Int64]', () {
      final out = SwiftGenerator.generate(_typedDataParamSpec('Int64List'));
      expect(out, contains('data: [Int64]'));
    });

    test('Uint64List param → [Int64]', () {
      final out = SwiftGenerator.generate(_typedDataParamSpec('Uint64List'));
      expect(out, contains('data: [Int64]'));
    });
  });

  group('SwiftGenerator — TypedData @_cdecl stub params include _length', () {
    for (final typeName in [
      'Uint8List',
      'Int8List',
      'Int16List',
      'Uint16List',
      'Int32List',
      'Uint32List',
      'Float32List',
      'Float64List',
      'Int64List',
      'Uint64List',
    ]) {
      test('$typeName param gets extra _length: Int64 in @_cdecl stub', () {
        final out = SwiftGenerator.generate(_typedDataParamSpec(typeName));
        expect(out, contains('_ data_length: Int64'));
      });
    }
  });

  // ── Section 3: Nullable scalars ───────────────────────────────────────────

  group('SwiftGenerator — nullable scalar params in protocol', () {
    test('bool? param → Bool?', () {
      final out = SwiftGenerator.generate(_fnSpec('void', [_p('bool?', 'flag')]));
      expect(out, contains('flag: Bool?'));
    });

    test('int? param → Int64?', () {
      final out = SwiftGenerator.generate(_fnSpec('void', [_p('int?', 'n')]));
      expect(out, contains('n: Int64?'));
    });

    test('double? param → Double?', () {
      final out = SwiftGenerator.generate(_fnSpec('void', [_p('double?', 'd')]));
      expect(out, contains('d: Double?'));
    });

    test('String? param → String?', () {
      final out = SwiftGenerator.generate(_fnSpec('void', [_p('String?', 's')]));
      expect(out, contains('s: String?'));
    });
  });

  group('SwiftGenerator — nullable scalar returns in protocol', () {
    test('bool? return → Bool?', () {
      final out = SwiftGenerator.generate(_fnSpec('bool?', []));
      expect(out, contains('-> Bool?'));
    });

    test('int? return → Int64?', () {
      final out = SwiftGenerator.generate(_fnSpec('int?', []));
      expect(out, contains('-> Int64?'));
    });

    test('double? return → Double?', () {
      final out = SwiftGenerator.generate(_fnSpec('double?', []));
      expect(out, contains('-> Double?'));
    });

    test('String? return → String?', () {
      final out = SwiftGenerator.generate(_fnSpec('String?', []));
      expect(out, contains('-> String?'));
    });
  });

  // ── Section 4: Enum ───────────────────────────────────────────────────────

  group('SwiftGenerator — enum type mapping', () {
    test('enum param uses enum type name in protocol', () {
      final out = SwiftGenerator.generate(_enumSpec('Status'));
      expect(out, contains('func fn(mode: Status)'));
    });

    test('enum return uses enum type name in protocol', () {
      final out = SwiftGenerator.generate(_enumSpec('Status'));
      expect(out, contains('-> Status'));
    });

    test('nullable enum param uses optional type name', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        sourceUri: 'mod.native.dart',
        enums: [BridgeEnum(name: 'Mode', startValue: 0, values: ['off', 'on'])],
        functions: [
          BridgeFunction(
            dartName: 'fn',
            cSymbol: 'mod_fn',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [_p('Mode?', 'm')],
          ),
        ],
      );
      final out = SwiftGenerator.generate(spec);
      expect(out, contains('m: Mode?'));
    });

    test('enum read-write property uses get set syntax', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        sourceUri: 'mod.native.dart',
        enums: [BridgeEnum(name: 'Mode', startValue: 0, values: ['off', 'on'])],
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
      final out = SwiftGenerator.generate(spec);
      expect(out, contains('var mode: Mode { get set }'));
    });

    test('enum read-only property uses get syntax', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        sourceUri: 'mod.native.dart',
        enums: [BridgeEnum(name: 'Mode', startValue: 0, values: ['off', 'on'])],
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
      final out = SwiftGenerator.generate(spec);
      expect(out, contains('var mode: Mode { get }'));
    });
  });

  // ── Section 5: Struct ─────────────────────────────────────────────────────

  group('SwiftGenerator — struct type mapping', () {
    test('struct param uses struct name in protocol', () {
      final out = SwiftGenerator.generate(_structParamReturnSpec('Point'));
      expect(out, contains('src: Point'));
    });

    test('struct return uses struct name in protocol', () {
      final out = SwiftGenerator.generate(_structParamReturnSpec('Point'));
      expect(out, contains('-> Point'));
    });

    test('nullable struct param uses optional type', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        sourceUri: 'mod.native.dart',
        structs: [
          BridgeStruct(name: 'Frame', packed: false, fields: [
            BridgeField(name: 'w', type: BridgeType(name: 'int')),
          ]),
        ],
        functions: [
          BridgeFunction(
            dartName: 'push',
            cSymbol: 'mod_push',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [_p('Frame?', 'f')],
          ),
        ],
      );
      final out = SwiftGenerator.generate(spec);
      expect(out, contains('f: Frame?'));
    });

    test('struct read-only property uses get syntax', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        sourceUri: 'mod.native.dart',
        structs: [
          BridgeStruct(name: 'Config', packed: false, fields: [
            BridgeField(name: 'x', type: BridgeType(name: 'double')),
          ]),
        ],
        properties: [
          BridgeProperty(
            dartName: 'config',
            type: BridgeType(name: 'Config'),
            getSymbol: 'mod_get_config',
            setSymbol: 'mod_set_config',
            hasGetter: true,
            hasSetter: false,
          ),
        ],
      );
      final out = SwiftGenerator.generate(spec);
      expect(out, contains('var config: Config { get }'));
    });
  });

  // ── Section 6: Properties — all scalar types ──────────────────────────────

  group('SwiftGenerator — property type mapping (read-write)', () {
    test('bool property uses Bool', () {
      final out = SwiftGenerator.generate(_propSpec('bool'));
      expect(out, contains('var value: Bool { get set }'));
    });

    test('int property uses Int64', () {
      final out = SwiftGenerator.generate(_propSpec('int'));
      expect(out, contains('var value: Int64 { get set }'));
    });

    test('double property uses Double', () {
      final out = SwiftGenerator.generate(_propSpec('double'));
      expect(out, contains('var value: Double { get set }'));
    });

    test('String property uses String', () {
      final out = SwiftGenerator.generate(_propSpec('String'));
      expect(out, contains('var value: String { get set }'));
    });
  });

  group('SwiftGenerator — property type mapping (read-only)', () {
    test('bool read-only property uses get only', () {
      final out = SwiftGenerator.generate(_propSpec('bool', readOnly: true));
      expect(out, contains('var value: Bool { get }'));
      expect(out, isNot(contains('{ get set }')));
    });

    test('int read-only property uses get only', () {
      final out = SwiftGenerator.generate(_propSpec('int', readOnly: true));
      expect(out, contains('var value: Int64 { get }'));
    });

    test('String read-only property uses get only', () {
      final out = SwiftGenerator.generate(_propSpec('String', readOnly: true));
      expect(out, contains('var value: String { get }'));
    });
  });

  // ── Section 7: Async returns ──────────────────────────────────────────────

  group('SwiftGenerator — async throws return types in protocol', () {
    test('Future<void> → async throws (no return arrow)', () {
      final out = SwiftGenerator.generate(_asyncReturnSpec('void'));
      expect(out, contains('async throws'));
    });

    test('Future<bool> → async throws -> Bool', () {
      final out = SwiftGenerator.generate(_asyncReturnSpec('bool'));
      expect(out, contains('async throws -> Bool'));
    });

    test('Future<int> → async throws -> Int64', () {
      final out = SwiftGenerator.generate(_asyncReturnSpec('int'));
      expect(out, contains('async throws -> Int64'));
    });

    test('Future<double> → async throws -> Double', () {
      final out = SwiftGenerator.generate(_asyncReturnSpec('double'));
      expect(out, contains('async throws -> Double'));
    });

    test('Future<String> → async throws -> String', () {
      final out = SwiftGenerator.generate(_asyncReturnSpec('String'));
      expect(out, contains('async throws -> String'));
    });

    test('Future<@HybridEnum> → async throws -> EnumName', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        sourceUri: 'mod.native.dart',
        enums: [BridgeEnum(name: 'Quality', startValue: 0, values: ['low', 'high'])],
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
      final out = SwiftGenerator.generate(spec);
      expect(out, contains('async throws -> Quality'));
    });

    test('Future<@HybridStruct> → async throws -> StructName', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        sourceUri: 'mod.native.dart',
        structs: [
          BridgeStruct(name: 'Reading', packed: false, fields: [
            BridgeField(name: 'val', type: BridgeType(name: 'double')),
          ]),
        ],
        functions: [
          BridgeFunction(
            dartName: 'read',
            cSymbol: 'mod_read',
            isAsync: true,
            returnType: BridgeType(name: 'Reading'),
            params: [],
          ),
        ],
      );
      final out = SwiftGenerator.generate(spec);
      expect(out, contains('async throws -> Reading'));
    });
  });

  // ── Section 8: macOS Swift ────────────────────────────────────────────────
  //
  // SwiftGenerator.generate() checks spec.iosImpl only. A macOS-only spec
  // (no iosImpl) returns an "iOS not targeted" comment rather than emitting
  // a protocol. To generate Swift for macOS, the spec must include iosImpl.

  group('SwiftGenerator — macOS-only spec returns no-target comment', () {
    test('macOS-only spec (no iosImpl) returns iOS-not-targeted comment', () {
      final out = SwiftGenerator.generate(_macosSpec());
      expect(out, contains('iOS not targeted'));
    });

    test('macOS-only spec does not emit a protocol', () {
      final out = SwiftGenerator.generate(_macosSpec());
      expect(out, isNot(contains('public protocol')));
    });
  });

  group('SwiftGenerator — spec with both iosImpl and macosImpl emits full protocol', () {
    BridgeSpec iosMacSpec() => BridgeSpec(
      dartClassName: 'MacMod',
      lib: 'mac_mod',
      namespace: 'mac_mod',
      iosImpl: NativeImpl.swift,
      macosImpl: NativeImpl.swift,
      sourceUri: 'mac_mod.native.dart',
      functions: [
        BridgeFunction(
          dartName: 'greet',
          cSymbol: 'mac_mod_greet',
          isAsync: false,
          returnType: BridgeType(name: 'String'),
          params: [_p('String', 'name')],
        ),
      ],
    );

    test('emits HybridMacModProtocol', () {
      final out = SwiftGenerator.generate(iosMacSpec());
      expect(out, contains('public protocol HybridMacModProtocol'));
    });

    test('protocol contains correct function signature', () {
      final out = SwiftGenerator.generate(iosMacSpec());
      expect(out, contains('func greet(name: String) -> String'));
    });
  });
}
