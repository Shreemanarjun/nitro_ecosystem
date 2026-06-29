// Tests for the 7 limitations vs RN Nitro — gaps that have been implemented.
//
// Gap 1: Stream<T?> — nullable stream item types (E009 removed)
// Gap 2: Map<String, @HybridEnum> — enum map values (E007 removed)
// Gap 3: Backpressure.batch for @HybridEnum — E005 relaxed
// Gap 4: Callback nullable primitive params — sentinel-based full domain

import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// ── Helpers ──────────────────────────────────────────────────────────────────

BridgeSpec _nullableStreamSpec(String itemTypeName) {
  // The stream emitter expects the bare type name (no '?') in BridgeType.name,
  // with nullability carried separately in BridgeType.isNullable.
  final isNullable = itemTypeName.endsWith('?');
  final bareName = isNullable ? itemTypeName.substring(0, itemTypeName.length - 1) : itemTypeName;
  return BridgeSpec(
    dartClassName: 'Events',
    lib: 'events',
    namespace: 'events',
    iosImpl: NativeImpl.swift,
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'events.native.dart',
    enums: [BridgeEnum(name: 'Status', startValue: 0, values: ['ok', 'err'])],
    streams: [
      BridgeStream(
        dartName: 'data',
        registerSymbol: 'events_register_data_stream',
        releaseSymbol: 'events_release_data_stream',
        itemType: BridgeType(name: bareName, isNullable: isNullable),
        backpressure: Backpressure.dropLatest,
      ),
    ],
  );
}

BridgeSpec _enumMapSpec() => BridgeSpec(
  dartClassName: 'Router',
  lib: 'router',
  namespace: 'router',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'router.native.dart',
  enums: [BridgeEnum(name: 'Route', startValue: 0, values: ['home', 'detail', 'settings'])],
  functions: [
    BridgeFunction(
      dartName: 'getRoutes',
      cSymbol: 'router_get_routes',
      isAsync: false,
      returnType: BridgeType(name: 'Map<String, Route>', isMap: true, isRecord: true),
      params: [
        BridgeParam(
          name: 'value',
          type: BridgeType(name: 'Map<String, Route>', isMap: true, isRecord: true),
        ),
      ],
    ),
  ],
);

BridgeSpec _enumBatchStreamSpec() => BridgeSpec(
  dartClassName: 'Monitor',
  lib: 'monitor',
  namespace: 'monitor',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'monitor.native.dart',
  enums: [BridgeEnum(name: 'Signal', startValue: 0, values: ['idle', 'active', 'error'])],
  streams: [
    BridgeStream(
      dartName: 'signals',
      registerSymbol: 'monitor_register_signals_stream',
      releaseSymbol: 'monitor_release_signals_stream',
      itemType: BridgeType(name: 'Signal'),
      backpressure: Backpressure.batch,
      batchMaxSize: 32,
    ),
  ],
);

BridgeSpec _callbackNullableSpec() => BridgeSpec(
  dartClassName: 'Processor',
  lib: 'processor',
  namespace: 'processor',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'processor.native.dart',
  enums: [BridgeEnum(name: 'Quality', startValue: 0, values: ['low', 'high'])],
  functions: [
    BridgeFunction(
      dartName: 'process',
      cSymbol: 'processor_process',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'onNullableInt',
          type: BridgeType(
            name: 'void Function(int?)',
            isFunction: true,
            functionReturnType: 'void',
            functionParams: [BridgeType(name: 'int?')],
          ),
        ),
      ],
    ),
    BridgeFunction(
      dartName: 'query',
      cSymbol: 'processor_query',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'onNullableBool',
          type: BridgeType(
            name: 'void Function(bool?)',
            isFunction: true,
            functionReturnType: 'void',
            functionParams: [BridgeType(name: 'bool?')],
          ),
        ),
      ],
    ),
    BridgeFunction(
      dartName: 'compute',
      cSymbol: 'processor_compute',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'onNullableEnum',
          type: BridgeType(
            name: 'void Function(Quality?)',
            isFunction: true,
            functionReturnType: 'void',
            functionParams: [BridgeType(name: 'Quality?')],
          ),
        ),
      ],
    ),
  ],
);

// ── Gap 1: Stream<T?> ────────────────────────────────────────────────────────

void main() {
  group('Gap 1 — Stream<T?> nullable stream items', () {
    group('Dart FFI generator', () {
      test('Stream<int?> emits nullable message cast', () {
        final code = DartFfiGenerator.generate(_nullableStreamSpec('int?'));
        // int?/double? streams use direct nullable cast (null passes through)
        expect(code, contains('message as int?'));
      });

      test('Stream<double?> emits nullable message cast', () {
        final code = DartFfiGenerator.generate(_nullableStreamSpec('double?'));
        expect(code, contains('message as double?'));
      });

      test('Stream<bool?> emits null-safe unpack with message == null check', () {
        final code = DartFfiGenerator.generate(_nullableStreamSpec('bool?'));
        expect(code, contains('message == null ? null : (message as int) != 0'));
      });

      test('Stream<String?> emits nullable message cast', () {
        final code = DartFfiGenerator.generate(_nullableStreamSpec('String?'));
        expect(code, contains('message as String?'));
      });

      test('Stream<Status?> emits null-safe enum decode', () {
        final code = DartFfiGenerator.generate(_nullableStreamSpec('Status?'));
        expect(code, contains('message == null ? null'));
        expect(code, contains('.toStatus()'));
      });

      test('Stream<int?> return type uses nullable generic', () {
        final code = DartFfiGenerator.generate(_nullableStreamSpec('int?'));
        expect(code, contains('Stream<int?>'));
      });
    });

    group('Swift generator', () {
      test('Stream<int?> uses UnsafePointer<Int64>? emitCb type', () {
        final code = SwiftGenerator.generate(_nullableStreamSpec('int?'));
        expect(code, contains('UnsafePointer<Int64>?'));
      });

      test('Stream<bool?> uses UnsafePointer<Int8>? emitCb type', () {
        final code = SwiftGenerator.generate(_nullableStreamSpec('bool?'));
        expect(code, contains('UnsafePointer<Int8>?'));
      });

      test('Stream<int?> emits nil-posting code in sink', () {
        final code = SwiftGenerator.generate(_nullableStreamSpec('int?'));
        expect(code, contains('if let v = item'));
        expect(code, contains('emitCb(dartPort, nil)'));
      });

      test('Stream<bool?> emits nil-posting code in sink', () {
        final code = SwiftGenerator.generate(_nullableStreamSpec('bool?'));
        expect(code, contains('if let v = item'));
        expect(code, contains('var _bv: Int8 = v ? 1 : 0'));
        expect(code, contains('emitCb(dartPort, nil)'));
      });

      test('Stream<Status?> uses UnsafePointer<Int64>? for nullable enum', () {
        final code = SwiftGenerator.generate(_nullableStreamSpec('Status?'));
        expect(code, contains('UnsafePointer<Int64>?'));
        expect(code, contains('var _rv = v.rawValue'));
      });
    });

    group('Kotlin generator', () {
      test('Stream<int?> emits Long? JNI type for nullable int', () {
        final code = KotlinGenerator.generate(_nullableStreamSpec('int?'));
        expect(code, contains('Long?'));
        expect(code, contains('emit_data'));
      });

      test('Stream<bool?> emits Boolean? JNI type', () {
        final code = KotlinGenerator.generate(_nullableStreamSpec('bool?'));
        expect(code, contains('Boolean?'));
      });
    });

    group('C bridge (JNI)', () {
      test('Stream<int?> emits jobject param in C JNI emit function', () {
        final code = CppBridgeGenerator.generate(_nullableStreamSpec('int?'));
        expect(code, contains('jobject'));
        // Null check logic present
        expect(code, contains('nullptr'));
        expect(code, contains('Dart_CObject_kNull'));
      });

      test('Stream<bool?> emits jobject with nullptr check', () {
        final code = CppBridgeGenerator.generate(_nullableStreamSpec('bool?'));
        expect(code, contains('jobject'));
        expect(code, contains('Dart_CObject_kNull'));
      });
    });
  });

  // ── Gap 2: Map<String, @HybridEnum> ────────────────────────────────────────

  group('Gap 2 — Map<String, @HybridEnum>', () {
    group('Dart FFI generator', () {
      test('emits _nitroEncodeMapBinaryRoute helper', () {
        final code = DartFfiGenerator.generate(_enumMapSpec());
        expect(code, contains('_nitroEncodeMapBinaryRoute'));
        expect(code, contains('_nitroDecodeMapBinaryRoute'));
      });

      test('encoder uses .nativeValue for enum values', () {
        final code = DartFfiGenerator.generate(_enumMapSpec());
        expect(code, contains('.nativeValue'));
        // Should use tag 1 (int64) for enum encoding
        expect(code, contains('bb.addByte(1)'));
      });

      test('decoder calls .toRoute() to convert from int64', () {
        final code = DartFfiGenerator.generate(_enumMapSpec());
        expect(code, contains('.toRoute()'));
      });
    });

    group('Kotlin generator', () {
      test('emits Route.fromNative for input map decode', () {
        final code = KotlinGenerator.generate(_enumMapSpec());
        expect(code, contains('Route.fromNative'));
      });

      test('emits .nativeValue for output map encode', () {
        final code = KotlinGenerator.generate(_enumMapSpec());
        // Output encode should use nativeValue and tag 1
        expect(code, contains('nativeValue'));
        expect(code, contains('_outBb.write(1)'));
      });
    });

    group('Swift generator', () {
      test('emits compactMapValues for enum input decode', () {
        final code = SwiftGenerator.generate(_enumMapSpec());
        expect(code, contains('compactMapValues'));
        expect(code, contains('Route(rawValue:'));
      });

      test('emits mapValues with rawValue for enum output encode', () {
        final code = SwiftGenerator.generate(_enumMapSpec());
        expect(code, contains('mapValues'));
        expect(code, contains('rawValue'));
      });
    });

    group('Spec validator', () {
      test('Map<String, @HybridEnum> return type has no E007', () {
        final issues = SpecValidator.validate(_enumMapSpec());
        expect(issues.any((i) => i.code == 'E007'), isFalse);
      });
    });
  });

  // ── Gap 3: Backpressure.batch for @HybridEnum ────────────────────────────

  group('Gap 3 — Backpressure.batch for @HybridEnum', () {
    group('Spec validator', () {
      test('enum batch stream has no E005', () {
        final issues = SpecValidator.validate(_enumBatchStreamSpec());
        expect(issues.any((i) => i.code == 'E005'), isFalse);
      });
    });

    group('Dart FFI generator', () {
      test('batch enum stream decodes via .toSignal() extension', () {
        final code = DartFfiGenerator.generate(_enumBatchStreamSpec());
        expect(code, contains('.toSignal()'));
      });
    });

    group('Kotlin generator', () {
      test('batch enum stream emits item.nativeValue in collect', () {
        final code = KotlinGenerator.generate(_enumBatchStreamSpec());
        expect(code, contains('nativeValue'));
      });

      test('batch enum uses LongArray wire format', () {
        final code = KotlinGenerator.generate(_enumBatchStreamSpec());
        expect(code, contains('LongArray'));
      });
    });

    group('Swift generator', () {
      test('batch enum stream appends item.rawValue to buffer', () {
        final code = SwiftGenerator.generate(_enumBatchStreamSpec());
        expect(code, contains('item.rawValue'));
      });
    });
  });

  // ── Gap 4: Callback nullable primitive params ─────────────────────────────

  group('Gap 4 — Callback nullable primitive params', () {
    group('Dart FFI — nullable int? callback param', () {
      test('uses Int64.min sentinel for null (arg == -9223372036854775808)', () {
        final code = DartFfiGenerator.generate(_callbackNullableSpec());
        expect(code, contains('-9223372036854775808'));
        expect(code, contains('arg0 == -9223372036854775808 ? null : arg0'));
      });
    });

    group('Dart FFI — nullable bool? callback param', () {
      test('uses -1 sentinel for null (arg == -1)', () {
        final code = DartFfiGenerator.generate(_callbackNullableSpec());
        expect(code, contains('arg0 == -1 ? null : arg0 != 0'));
      });
    });

    group('Dart FFI — nullable enum callback param', () {
      test('uses -1 sentinel for null enum', () {
        final code = DartFfiGenerator.generate(_callbackNullableSpec());
        expect(code, contains('arg0 == -1 ? null'));
        expect(code, contains('.toQuality()'));
      });
    });

    group('Spec validator', () {
      test('void Function(int?) is a valid callback type', () {
        expect(
          () => SpecValidator.validate(_callbackNullableSpec()),
          returnsNormally,
        );
        final issues = SpecValidator.validate(_callbackNullableSpec());
        expect(issues.where((i) => i.isError).isEmpty, isTrue);
      });
    });
  });

  // ── Gap 7: NitroFfiCodec<T> — runtime class already exists ──────────────

  group('Gap 7 — NitroFfiCodec<T> runtime class', () {
    // These tests verify the codec class exists in the nitro package.
    // Since the file is pre-existing, we just check the generator imports
    // reference the right types.
    test('Spec with nullable int params generates code using NitroOptInt64', () {
      final spec = BridgeSpec(
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
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(name: 'x', type: BridgeType(name: 'int?')),
            ],
          ),
        ],
      );
      final code = DartFfiGenerator.generate(spec);
      // Nullable int param uses NitroOptInt64 via arena.packInt
      expect(code, contains('packInt'));
    });

    test('Spec with nullable double param uses packDouble', () {
      final spec = BridgeSpec(
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
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(name: 'x', type: BridgeType(name: 'double?')),
            ],
          ),
        ],
      );
      final code = DartFfiGenerator.generate(spec);
      expect(code, contains('packDouble'));
    });
  });
}
