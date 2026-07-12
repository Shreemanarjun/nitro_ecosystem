// Cross-generator type-coverage tests.
//
// Covers void, primitives, @HybridStruct (single + List), @HybridRecord (single + List),
// nested struct, and record params across EVERY generator:
//   • DartFfiGenerator   — Dart FFI bindings
//   • RecordGenerator    — Dart RecordExt / Swift record extensions
//   • SwiftGenerator     — Swift @_cdecl bridge (iOS/macOS)
//   • KotlinGenerator    — Kotlin JNI bridge (Android)
//   • CppBridgeGenerator — C++ .bridge.g.mm (Swift/ObjC path AND pure-C++ path)
//   • CppInterfaceGenerator — HybridXxx C++ abstract class
//   • CppMockGenerator   — GoogleMock stub
//   • CppHeaderGenerator — bridge .bridge.g.h declarations
//
// §12: Batch stream (Backpressure.batch) — Kotlin mutex-guarded _buf
// §13: String-returning callbacks — no exceptionalReturn for Pointer returns
// §14: Nullable @NitroVariant case fields — presence flags across Dart/Kotlin/Swift
// §15: Gap 1 — Stream<T?> nullable stream items (all generators)
// §16: Gap 2 — Map<String, @HybridEnum> (all generators)
// §17: Gap 3 — Backpressure.batch for @HybridEnum (all generators)
// §18: Gap 4 — Callback nullable primitive params (Dart FFI)

import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/languages/cpp_native/cpp_interface_generator.dart';
import 'package:nitro_generator/src/generators/languages/cpp_native/cpp_mock_generator.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_header_generator.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/record_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// ── §12 helpers ───────────────────────────────────────────────────────────────

BridgeSpec _batchStreamSpec(String itemType) => BridgeSpec(
  dartClassName: 'Sensor',
  lib: 'sensor',
  namespace: 'sensor',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'sensor.native.dart',
  streams: [
    BridgeStream(
      dartName: 'samples',
      registerSymbol: 'sensor_register_samples_stream',
      releaseSymbol: 'sensor_release_samples_stream',
      itemType: BridgeType(name: itemType),
      backpressure: Backpressure.batch,
      batchMaxSize: 32,
    ),
  ],
);

// ── §13 helpers ───────────────────────────────────────────────────────────────

BridgeSpec _stringCallbackReturnSpec() => BridgeSpec(
  dartClassName: 'Transform',
  lib: 'transform',
  namespace: 'transform',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'transform.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'process',
      cSymbol: 'transform_process',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'formatter',
          type: BridgeType(
            name: 'String Function(int)',
            isFunction: true,
            functionReturnType: 'String',
            functionParams: [BridgeType(name: 'int')],
          ),
        ),
      ],
    ),
  ],
);

// ── §14 helpers ───────────────────────────────────────────────────────────────

BridgeSpec _nullableVariantCoverageSpec() => BridgeSpec(
  dartClassName: 'VariantMod',
  lib: 'variant_mod',
  namespace: 'variant_mod',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'variant_mod.native.dart',
  enums: [
    BridgeEnum(name: 'VariantQuality', startValue: 10, values: ['low', 'high']),
  ],
  recordTypes: [
    BridgeRecordType(
      name: 'VariantPayload',
      fields: [
        BridgeRecordField(name: 'id', dartType: 'String', kind: RecordFieldKind.primitive),
      ],
    ),
  ],
  variants: [
    BridgeVariant(
      name: 'VariantEvent',
      cases: [
        BridgeVariantCase(
          name: 'VariantChanged',
          label: 'changed',
          fields: [
            BridgeRecordField(
              name: 'count',
              dartType: 'int?',
              kind: RecordFieldKind.primitive,
              isNullable: true,
            ),
            BridgeRecordField(
              name: 'quality',
              dartType: 'VariantQuality?',
              kind: RecordFieldKind.enumValue,
              isNullable: true,
            ),
            BridgeRecordField(
              name: 'payload',
              dartType: 'VariantPayload?',
              kind: RecordFieldKind.recordObject,
              isNullable: true,
            ),
            BridgeRecordField(
              name: 'samples',
              dartType: 'List<int>?',
              kind: RecordFieldKind.listPrimitive,
              itemTypeName: 'int',
              isNullable: true,
            ),
          ],
        ),
      ],
    ),
  ],
  functions: [
    BridgeFunction(
      dartName: 'echoVariant',
      cSymbol: 'variant_mod_echo_variant',
      isAsync: false,
      returnType: BridgeType(name: 'VariantEvent'),
      params: [
        BridgeParam(
          name: 'input',
          type: BridgeType(name: 'VariantEvent'),
        ),
      ],
    ),
  ],
);

// ── §21–§24 helpers ──────────────────────────────────────────────────────────

final _kModeVariant = BridgeVariant(
  name: 'Mode',
  cases: [
    BridgeVariantCase(name: 'ModeAuto', label: 'auto', fields: []),
    BridgeVariantCase(
      name: 'ModeManual',
      label: 'manual',
      fields: [BridgeRecordField(name: 'speed', dartType: 'int', kind: RecordFieldKind.primitive)],
    ),
  ],
);

BridgeSpec _variantPropSpec() => BridgeSpec(
  dartClassName: 'Ctrl',
  lib: 'ctrl',
  namespace: 'ctrl',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'ctrl.native.dart',
  variants: [_kModeVariant],
  properties: [
    BridgeProperty(
      dartName: 'mode',
      type: BridgeType(name: 'Mode'),
      getSymbol: 'ctrl_get_mode',
      setSymbol: 'ctrl_set_mode',
      hasGetter: true,
      hasSetter: true,
    ),
  ],
);

final _kPacketStruct = BridgeStruct(
  name: 'Packet',
  packed: false,
  fields: [
    BridgeField(
      name: 'id',
      type: BridgeType(name: 'int'),
    ),
    BridgeField(
      name: 'data',
      type: BridgeType(name: 'String'),
    ),
  ],
);

BridgeSpec _nullableStructStreamSpec() => BridgeSpec(
  dartClassName: 'Srv',
  lib: 'srv',
  namespace: 'srv',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'srv.native.dart',
  structs: [_kPacketStruct],
  streams: [
    BridgeStream(
      dartName: 'packets',
      registerSymbol: 'srv_register_packets_stream',
      releaseSymbol: 'srv_release_packets_stream',
      itemType: BridgeType(name: 'Packet', isNullable: true),
      backpressure: Backpressure.dropLatest,
    ),
  ],
);

// ── §23–§24 helpers ──────────────────────────────────────────────────────────

final _kTcEventRecord = BridgeRecordType(
  name: 'TcEvent',
  fields: [
    BridgeRecordField(name: 'id', dartType: 'int', kind: RecordFieldKind.primitive),
    BridgeRecordField(name: 'tag', dartType: 'String', kind: RecordFieldKind.primitive),
  ],
);

BridgeSpec _recordStreamSpec({bool nullable = false}) => BridgeSpec(
  dartClassName: 'EventHub',
  lib: 'event_hub',
  namespace: 'event_hub',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'event_hub.native.dart',
  recordTypes: [_kTcEventRecord],
  streams: [
    BridgeStream(
      dartName: 'events',
      registerSymbol: 'event_hub_register_events_stream',
      releaseSymbol: 'event_hub_release_events_stream',
      itemType: BridgeType(
        name: nullable ? 'TcEvent?' : 'TcEvent',
        isRecord: true,
        isNullable: nullable,
      ),
      backpressure: Backpressure.dropLatest,
    ),
  ],
);

// ── §15–§18 helpers ──────────────────────────────────────────────────────────

BridgeSpec _nullableStreamCoverageSpec(String bareItemType) {
  return BridgeSpec(
    dartClassName: 'Sensor',
    lib: 'sensor',
    namespace: 'sensor',
    iosImpl: NativeImpl.swift,
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'sensor.native.dart',
    enums: [
      BridgeEnum(name: 'Level', startValue: 0, values: ['low', 'mid', 'high']),
    ],
    streams: [
      BridgeStream(
        dartName: 'readings',
        registerSymbol: 'sensor_register_readings_stream',
        releaseSymbol: 'sensor_release_readings_stream',
        itemType: BridgeType(name: bareItemType, isNullable: true),
        backpressure: Backpressure.dropLatest,
      ),
    ],
  );
}

BridgeSpec _enumMapCoverageSpec() => BridgeSpec(
  dartClassName: 'Router',
  lib: 'router',
  namespace: 'router',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'router.native.dart',
  enums: [
    BridgeEnum(name: 'Route', startValue: 0, values: ['home', 'detail', 'settings']),
  ],
  functions: [
    BridgeFunction(
      dartName: 'getRoutes',
      cSymbol: 'router_get_routes',
      isAsync: false,
      returnType: BridgeType(name: 'Map<String, Route>', isMap: true, isRecord: true),
      params: [
        BridgeParam(
          name: 'input',
          type: BridgeType(name: 'Map<String, Route>', isMap: true, isRecord: true),
        ),
      ],
    ),
  ],
);

BridgeSpec _enumBatchCoverageSpec() => BridgeSpec(
  dartClassName: 'Monitor',
  lib: 'monitor',
  namespace: 'monitor',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'monitor.native.dart',
  enums: [
    BridgeEnum(name: 'Signal', startValue: 0, values: ['idle', 'active', 'error']),
  ],
  streams: [
    BridgeStream(
      dartName: 'signals',
      registerSymbol: 'monitor_register_signals_stream',
      releaseSymbol: 'monitor_release_signals_stream',
      itemType: BridgeType(name: 'Signal'),
      backpressure: Backpressure.batch,
      batchMaxSize: 16,
    ),
  ],
);

BridgeSpec _callbackNullableCoverageSpec() => BridgeSpec(
  dartClassName: 'Processor',
  lib: 'processor',
  namespace: 'processor',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'processor.native.dart',
  enums: [
    BridgeEnum(name: 'Quality', startValue: 0, values: ['low', 'high']),
  ],
  functions: [
    BridgeFunction(
      dartName: 'onNullableInt',
      cSymbol: 'processor_on_nullable_int',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'cb',
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
      dartName: 'onNullableBool',
      cSymbol: 'processor_on_nullable_bool',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'cb',
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
      dartName: 'onNullableDouble',
      cSymbol: 'processor_on_nullable_double',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'cb',
          type: BridgeType(
            name: 'void Function(double?)',
            isFunction: true,
            functionReturnType: 'void',
            functionParams: [BridgeType(name: 'double?')],
          ),
        ),
      ],
    ),
    BridgeFunction(
      dartName: 'onNullableEnum',
      cSymbol: 'processor_on_nullable_enum',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'cb',
          type: BridgeType(
            name: 'void Function(Quality?)',
            isFunction: true,
            functionReturnType: 'void',
            functionParams: [BridgeType(name: 'Quality?')],
          ),
        ),
      ],
    ),
    BridgeFunction(
      dartName: 'onNullableString',
      cSymbol: 'processor_on_nullable_string',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'cb',
          type: BridgeType(
            name: 'void Function(String?)',
            isFunction: true,
            functionReturnType: 'void',
            functionParams: [BridgeType(name: 'String?')],
          ),
        ),
      ],
    ),
  ],
);

// ── Shared type definitions ───────────────────────────────────────────────────

final _kPrinterStruct = BridgeStruct(
  name: 'Printer',
  packed: false,
  fields: [
    BridgeField(
      name: 'id',
      type: BridgeType(name: 'String'),
    ),
    BridgeField(
      name: 'isDefault',
      type: BridgeType(name: 'bool'),
    ),
    BridgeField(
      name: 'copies',
      type: BridgeType(name: 'int'),
    ),
  ],
);

final _kSettingsStruct = BridgeStruct(
  name: 'Settings',
  packed: false,
  fields: [
    BridgeField(
      name: 'quality',
      type: BridgeType(name: 'String'),
    ),
    BridgeField(
      name: 'printer',
      type: BridgeType(name: 'Printer'),
    ),
  ],
);

final _kJobRecord = BridgeRecordType(
  name: 'Job',
  fields: [
    BridgeRecordField(name: 'jobId', dartType: 'String', kind: RecordFieldKind.primitive),
    BridgeRecordField(name: 'pages', dartType: 'int', kind: RecordFieldKind.primitive),
  ],
);

// ── Spec builders ─────────────────────────────────────────────────────────────

BridgeSpec _swiftKotlinSpec(
  List<BridgeFunction> fns, {
  List<BridgeStruct> structs = const [],
  List<BridgeRecordType> records = const [],
  List<BridgeProperty> props = const [],
}) => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'mod.native.dart',
  structs: structs,
  recordTypes: records,
  functions: fns,
  properties: props,
);

BridgeSpec _cppSpec(
  List<BridgeFunction> fns, {
  List<BridgeStruct> structs = const [],
  List<BridgeRecordType> records = const [],
  List<BridgeProperty> props = const [],
}) => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  iosImpl: NativeImpl.cpp,
  androidImpl: NativeImpl.cpp,
  sourceUri: 'mod.native.dart',
  structs: structs,
  recordTypes: records,
  functions: fns,
  properties: props,
);

BridgeFunction _fn(String name, BridgeType ret, {List<BridgeParam> params = const []}) => BridgeFunction(
  dartName: name,
  cSymbol: 'mod_${name.replaceAllMapped(RegExp(r'[A-Z]'), (m) => '_${m[0]!.toLowerCase()}')}',
  isAsync: false,
  returnType: ret,
  params: params,
);

BridgeType _listStruct(String name) => BridgeType(
  name: 'List<$name>',
  isRecord: true,
  recordListItemType: name,
);

BridgeType _listRecord(String name) => BridgeType(
  name: 'List<$name>',
  isRecord: true,
  recordListItemType: name,
);

// ── §1: void return ───────────────────────────────────────────────────────────

void main() {
  group('void return — all generators', () {
    final spec = _swiftKotlinSpec([_fn('reset', BridgeType(name: 'void'))]);
    final cppSpec = _cppSpec([_fn('reset', BridgeType(name: 'void'))]);

    test('Dart FFI: override void reset()', () {
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('void reset()'));
    });

    test('Swift: @_cdecl reset returns void', () {
      final out = SwiftGenerator.generate(spec);
      expect(out, contains('func _mod_call_reset('));
    });

    test('Kotlin: reset_call returns Unit', () {
      final out = KotlinGenerator.generate(spec);
      expect(out, contains('fun reset_call(instanceId: Long)'));
    });

    test('CppBridge (Swift path): void mod_reset(void)', () {
      final out = CppBridgeGenerator.generate(spec);
      expect(out, contains('void mod_reset(int64_t instanceId, NitroError* _nitro_err)'));
    });

    test('CppBridge (pure-C++ path): void mod_reset(void)', () {
      final out = CppBridgeGenerator.generate(cppSpec);
      expect(out, contains('void mod_reset(int64_t instanceId, NitroError* _nitro_err)'));
    });

    test('CppInterface: virtual void reset() = 0', () {
      final out = CppInterfaceGenerator.generate(cppSpec);
      expect(out, contains('virtual void reset()'));
    });

    test('CppMock: MOCK_METHOD(void, reset, ())', () {
      final out = CppMockGenerator.generateMockHeader(cppSpec);
      expect(out, contains('MOCK_METHOD(void, reset,'));
    });

    test('CppHeader: NITRO_EXPORT void mod_reset(void)', () {
      final out = CppHeaderGenerator.generate(spec);
      expect(out, contains('void mod_reset(int64_t instanceId, NitroError* _nitro_err)'));
    });
  });

  // ── §2: primitive returns (int, double, bool, String) ─────────────────────

  group('primitive returns — all generators', () {
    for (final type in ['int', 'double', 'bool', 'String']) {
      final spec = _swiftKotlinSpec([_fn('get', BridgeType(name: type))]);
      final cppSpec = _cppSpec([_fn('get', BridgeType(name: type))]);

      test('Dart FFI: $type return annotation', () {
        final out = DartFfiGenerator.generate(spec);
        expect(out, contains('$type get('));
      });

      test('CppBridge (Swift path): $type get function signature', () {
        final out = CppBridgeGenerator.generate(spec);
        expect(out, contains('mod_get('));
      });

      test('CppBridge (pure-C++ path): $type get', () {
        final out = CppBridgeGenerator.generate(cppSpec);
        expect(out, contains('mod_get('));
      });

      test('CppInterface: virtual $type get() = 0', () {
        final out = CppInterfaceGenerator.generate(cppSpec);
        expect(out, contains('virtual'));
        expect(out, contains('get()'));
      });
    }
  });

  // ── §3: @HybridStruct single return ───────────────────────────────────────

  group('@HybridStruct single return — all generators', () {
    final spec = _swiftKotlinSpec(
      [_fn('getPrinter', BridgeType(name: 'Printer'))],
      structs: [_kPrinterStruct],
    );
    final cppSpec = _cppSpec(
      [_fn('getPrinter', BridgeType(name: 'Printer'))],
      structs: [_kPrinterStruct],
    );

    test('Dart FFI: single struct uses structPtr.ref.toDart()', () {
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('structPtr.ref.toDart()'));
      expect(out, isNot(contains('LazyRecordList')));
    });

    test('Dart FFI: Printer getPrinter() override', () {
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('Printer getPrinter()'));
    });

    test('Swift: single struct packs result into _PrinterC pointer', () {
      final out = SwiftGenerator.generate(spec);
      expect(out, contains('_PrinterC'));
    });

    test('Kotlin: single struct unwraps jobject via pack_Printer_from_jni', () {
      final out = KotlinGenerator.generate(spec);
      expect(out, contains('getPrinter_call'));
    });

    test('CppBridge (pure-C++ path): malloc + struct copy pattern', () {
      final out = CppBridgeGenerator.generate(cppSpec);
      expect(out, contains('malloc(sizeof(Printer))'));
      expect(out, isNot(contains('NitroCppBuffer')));
    });

    test('CppInterface: virtual Printer getPrinter() = 0', () {
      final out = CppInterfaceGenerator.generate(cppSpec);
      expect(out, contains('virtual Printer getPrinter()'));
    });

    test('CppMock: MOCK_METHOD(Printer, getPrinter, ())', () {
      final out = CppMockGenerator.generateMockHeader(cppSpec);
      expect(out, contains('MOCK_METHOD(Printer, getPrinter,'));
    });
  });

  // ── §4: List<@HybridStruct T> return ─────────────────────────────────────

  group('List<@HybridStruct T> return — all generators', () {
    final spec = _swiftKotlinSpec(
      [_fn('getPrinters', _listStruct('Printer'))],
      structs: [_kPrinterStruct],
    );
    final cppSpec = _cppSpec(
      [_fn('getPrinters', _listStruct('Printer'))],
      structs: [_kPrinterStruct],
    );

    test('Dart FFI: FFI pointer uses Pointer<Uint8> (not Pointer<Void>)', () {
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains("Pointer<Uint8> Function(int, Pointer<NitroErrorFfi>) _getPrintersPtr"));
      expect(out, isNot(contains("Pointer<Void> Function() _getPrintersPtr")));
    });

    test('Dart FFI: body uses LazyRecordList.decode', () {
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('LazyRecordList.decode'));
      expect(out, contains('PrinterRecordExt.fromReader'));
    });

    test('Dart FFI: no redundant cast in body', () {
      final out = DartFfiGenerator.generate(spec);
      expect(out, isNot(contains('res as Pointer<Uint8>')));
    });

    test('Dart RecordExt: PrinterRecordExt generated (no @HybridRecord needed)', () {
      final out = RecordGenerator.generateDartExtensions(spec);
      expect(out, contains('PrinterRecordExt'));
      expect(out, contains('static Printer fromReader(RecordReader r)'));
      expect(out, contains('void writeFields(RecordWriter writer)'));
    });

    test('Swift RecordExt: extension Printer with writeFields and fromReader', () {
      final out = RecordGenerator.generateSwift(spec);
      expect(out, contains('extension Printer {'));
      expect(out, contains('public func writeFields'));
      expect(out, contains('public static func fromReader'));
    });

    test('Swift bridge: NitroRecordWriter.encodeIndexedList with e.writeFields(w)', () {
      final out = SwiftGenerator.generate(spec);
      expect(out, contains('NitroRecordWriter.encodeIndexedList'));
      expect(out, contains('e.writeFields(w)'));
    });

    test('Swift bridge: return type is UnsafeMutablePointer<UInt8>?', () {
      final out = SwiftGenerator.generate(spec);
      expect(out, contains('UnsafeMutablePointer<UInt8>?'));
    });

    test('Kotlin: getPrinters_call returns ByteArray', () {
      final out = KotlinGenerator.generate(spec);
      expect(out, contains('fun getPrinters_call(instanceId: Long): ByteArray'));
    });

    test('Kotlin: result.forEach { it.writeFieldsTo(out, buf) }', () {
      final out = KotlinGenerator.generate(spec);
      expect(out, contains('item.writeFieldsTo(tmpOut, tmpBuf)'));
    });

    test('Kotlin: interface declares fun getPrinters(): List<Printer>', () {
      final out = KotlinGenerator.generate(spec);
      expect(out, contains('fun getPrinters(): List<Printer>'));
    });

    test('CppBridge (Swift/ObjC path): void* return + NitroCppBuffer pattern', () {
      final out = CppBridgeGenerator.generate(spec);
      // Bridge calls Swift via extern void* _mod_call_getPrinters()
      expect(out, contains('_mod_call_getPrinters'));
      // Bridge returns void* pointing to buffer data
      expect(out, contains('void* mod_get_printers'));
    });

    test('CppBridge (pure-C++ path): NitroCppBuffer _res + return (uint8_t*)_res.data', () {
      final out = CppBridgeGenerator.generate(cppSpec);
      expect(out, contains('NitroCppBuffer _res = _impl->getPrinters()'));
      expect(out, contains('return (uint8_t*)_res.data'));
    });

    test('CppBridge (pure-C++ path): does NOT use malloc(sizeof(Printer))', () {
      final out = CppBridgeGenerator.generate(cppSpec);
      expect(out, isNot(contains('malloc(sizeof(Printer))')));
    });

    test('CppInterface: getPrinters returns NitroCppBuffer', () {
      final out = CppInterfaceGenerator.generate(cppSpec);
      expect(out, contains('NitroCppBuffer'));
      expect(out, contains('getPrinters'));
    });

    test('CppMock: MOCK_METHOD(NitroCppBuffer, getPrinters, ())', () {
      final out = CppMockGenerator.generateMockHeader(cppSpec);
      expect(out, contains('NitroCppBuffer'));
      expect(out, contains('getPrinters'));
    });

    test('CppHeader: void* mod_get_printers(void)', () {
      final out = CppHeaderGenerator.generate(spec);
      expect(out, contains('mod_get_printers'));
    });
  });

  // ── §5: @HybridRecord single return ───────────────────────────────────────

  group('@HybridRecord single return — all generators', () {
    final spec = _swiftKotlinSpec(
      [_fn('getJob', BridgeType(name: 'Job', isRecord: true))],
      records: [_kJobRecord],
    );
    final cppSpec = _cppSpec(
      [_fn('getJob', BridgeType(name: 'Job', isRecord: true))],
      records: [_kJobRecord],
    );

    test('Dart FFI: FFI pointer uses Pointer<Uint8>', () {
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('Pointer<Uint8>'));
    });

    test('Dart FFI: decodes via JobRecordExt.fromNative', () {
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('JobRecordExt.fromNative'));
    });

    test('Swift bridge: returns fromNative result', () {
      final out = SwiftGenerator.generate(spec);
      expect(out, contains('toNative()'));
    });

    test('Kotlin: getJob_call returns ByteArray', () {
      final out = KotlinGenerator.generate(spec);
      expect(out, contains('ByteArray'));
    });

    test('CppBridge (pure-C++ path): NitroCppBuffer _res + return (uint8_t*)_res.data', () {
      final out = CppBridgeGenerator.generate(cppSpec);
      expect(out, contains('NitroCppBuffer _res = _impl->getJob()'));
      expect(out, contains('return (uint8_t*)_res.data'));
    });

    test('CppInterface: getJob returns NitroCppBuffer', () {
      final out = CppInterfaceGenerator.generate(cppSpec);
      expect(out, contains('NitroCppBuffer'));
      expect(out, contains('getJob'));
    });
  });

  // ── §6: List<@HybridRecord T> return ─────────────────────────────────────

  group('List<@HybridRecord T> return — all generators', () {
    final spec = _swiftKotlinSpec(
      [_fn('getJobs', _listRecord('Job'))],
      records: [_kJobRecord],
    );
    final cppSpec = _cppSpec(
      [_fn('getJobs', _listRecord('Job'))],
      records: [_kJobRecord],
    );

    test('Dart FFI: uses LazyRecordList.decode', () {
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('LazyRecordList.decode'));
      expect(out, contains('JobRecordExt.fromReader'));
    });

    test('Swift bridge: NitroRecordWriter.encodeIndexedList for struct list return', () {
      final out = SwiftGenerator.generate(spec);
      expect(out, contains('NitroRecordWriter.encodeIndexedList'));
    });

    test('Kotlin: getJobs_call returns ByteArray', () {
      final out = KotlinGenerator.generate(spec);
      expect(out, contains('ByteArray'));
    });

    test('CppBridge (pure-C++ path): NitroCppBuffer pattern for list record return', () {
      final out = CppBridgeGenerator.generate(cppSpec);
      expect(out, contains('NitroCppBuffer _res = _impl->getJobs()'));
      expect(out, contains('return (uint8_t*)_res.data'));
    });

    test('CppInterface: getJobs returns NitroCppBuffer', () {
      final out = CppInterfaceGenerator.generate(cppSpec);
      expect(out, contains('NitroCppBuffer'));
      expect(out, contains('getJobs'));
    });

    test('CppMock: MOCK_METHOD(NitroCppBuffer, getJobs, ())', () {
      final out = CppMockGenerator.generateMockHeader(cppSpec);
      expect(out, contains('NitroCppBuffer'));
      expect(out, contains('getJobs'));
    });
  });

  // ── §7: Nested @HybridStruct in List<T> ───────────────────────────────────

  group('Nested @HybridStruct in List<T> — all generators', () {
    // Settings has a nested Printer field.
    final spec = _swiftKotlinSpec(
      [_fn('getSettings', _listStruct('Settings'))],
      structs: [_kPrinterStruct, _kSettingsStruct],
    );
    final cppSpec = _cppSpec(
      [_fn('getSettings', _listStruct('Settings'))],
      structs: [_kPrinterStruct, _kSettingsStruct],
    );

    test('Dart RecordExt: SettingsRecordExt AND PrinterRecordExt both emitted', () {
      final out = RecordGenerator.generateDartExtensions(spec);
      expect(out, contains('SettingsRecordExt'));
      expect(out, contains('PrinterRecordExt'));
    });

    test('Dart RecordExt: nested fromReader call inside Settings.fromReader', () {
      final out = RecordGenerator.generateDartExtensions(spec);
      expect(out, contains('PrinterRecordExt.fromReader'));
    });

    test('Swift: extension Settings AND extension Printer both emitted', () {
      final out = RecordGenerator.generateSwift(spec);
      expect(out, contains('extension Settings {'));
      expect(out, contains('extension Printer {'));
    });

    test('Dart FFI: LazyRecordList.decode with SettingsRecordExt.fromReader', () {
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('LazyRecordList.decode'));
      expect(out, contains('SettingsRecordExt.fromReader'));
    });

    test('CppBridge (pure-C++ path): NitroCppBuffer pattern', () {
      final out = CppBridgeGenerator.generate(cppSpec);
      expect(out, contains('NitroCppBuffer _res = _impl->getSettings()'));
      expect(out, contains('return (uint8_t*)_res.data'));
    });

    test('CppInterface: getSettings returns NitroCppBuffer', () {
      final out = CppInterfaceGenerator.generate(cppSpec);
      expect(out, contains('NitroCppBuffer'));
      expect(out, contains('getSettings'));
    });
  });

  // ── §8: @HybridRecord param ───────────────────────────────────────────────

  group('@HybridRecord param — all generators', () {
    final spec = _swiftKotlinSpec(
      [
        _fn(
          'submitJob',
          BridgeType(name: 'void'),
          params: [
            BridgeParam(
              name: 'job',
              type: BridgeType(name: 'Job', isRecord: true),
            ),
          ],
        ),
      ],
      records: [_kJobRecord],
    );
    final cppSpec = _cppSpec(
      [
        _fn(
          'submitJob',
          BridgeType(name: 'void'),
          params: [
            BridgeParam(
              name: 'job',
              type: BridgeType(name: 'Job', isRecord: true),
            ),
          ],
        ),
      ],
      records: [_kJobRecord],
    );

    test('Dart FFI: param uses arena + toNative', () {
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('job.toNative'));
    });

    test('CppBridge (pure-C++ path): wraps param in NitroCppBuffer', () {
      final out = CppBridgeGenerator.generate(cppSpec);
      expect(out, contains('NitroCppBuffer _buf_job'));
    });

    test('CppInterface: param type is NitroCppBuffer', () {
      final out = CppInterfaceGenerator.generate(cppSpec);
      expect(out, contains('NitroCppBuffer job'));
    });
  });

  // ── §9: List<@HybridStruct T> param ──────────────────────────────────────

  group('List<@HybridStruct T> param — all generators', () {
    final spec = _swiftKotlinSpec(
      [
        _fn(
          'submitPrinters',
          BridgeType(name: 'void'),
          params: [
            BridgeParam(name: 'printers', type: _listStruct('Printer')),
          ],
        ),
      ],
      structs: [_kPrinterStruct],
    );
    final cppSpec = _cppSpec(
      [
        _fn(
          'submitPrinters',
          BridgeType(name: 'void'),
          params: [
            BridgeParam(name: 'printers', type: _listStruct('Printer')),
          ],
        ),
      ],
      structs: [_kPrinterStruct],
    );

    test('Dart FFI: list param uses RecordWriter.encodeIndexedList', () {
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('RecordWriter.encodeIndexedList'));
      expect(out, contains('e.writeFields(w)'));
    });

    test('CppBridge (pure-C++ path): wraps list param in NitroCppBuffer', () {
      final out = CppBridgeGenerator.generate(cppSpec);
      expect(out, contains('NitroCppBuffer _buf_printers'));
    });

    test('CppInterface: list param type is NitroCppBuffer', () {
      final out = CppInterfaceGenerator.generate(cppSpec);
      expect(out, contains('NitroCppBuffer printers'));
    });

    test('Swift: list param decodes indexed binary buffer via NitroRecordReader.decodeIndexedList', () {
      final out = SwiftGenerator.generate(spec);
      // Dart encodes list params with encodeIndexedList (offset table format); Swift skips the table.
      expect(out, contains('NitroRecordReader.decodeIndexedList'));
      expect(out, contains('Printer.fromReader'));
    });

    test('Kotlin: list param decodes each item from the indexed offset table', () {
      final out = KotlinGenerator.generate(spec);
      expect(out, contains('val printersOffsets = LongArray(printersCount) { printersBuf.getLong() }'));
      expect(out, contains('for (printersOffset in printersOffsets)'));
      expect(out, contains('java.nio.ByteBuffer.wrap(printers, 4 + printersOffset.toInt()'));
      expect(out, contains('Printer.decodeFrom(itemBuf)'));
      expect(out, isNot(contains('repeat(printersCount) { printersBuf.getLong() } // skip offsets')));
    });

    test('Kotlin: List<bool> param reads bool items from indexed offsets', () {
      final boolSpec = _swiftKotlinSpec([
        _fn(
          'submitFlags',
          BridgeType(name: 'void'),
          params: [
            BridgeParam(
              name: 'flags',
              type: BridgeType(
                name: 'List<bool>',
                isRecord: true,
                recordListItemType: 'bool',
                recordListItemIsPrimitive: true,
              ),
            ),
          ],
        ),
      ]);
      final out = KotlinGenerator.generate(boolSpec);
      expect(out, contains('val flagsOffsets = LongArray(flagsCount) { flagsBuf.getLong() }'));
      expect(out, contains('for (flagsOffset in flagsOffsets)'));
      expect(out, contains('java.nio.ByteBuffer.wrap(flags, 4 + flagsOffset.toInt()'));
      expect(out, contains('flagsDecoded.add(itemBuf.get().toInt() != 0)'));
      expect(out, isNot(contains('repeat(flagsCount) { flagsDecoded.add(flagsBuf.getLong()) }')));
    });

    test('Kotlin: List<bool> return encodes flat primitive payload', () {
      final boolSpec = _swiftKotlinSpec([
        _fn(
          'echoFlags',
          BridgeType(
            name: 'List<bool>',
            isRecord: true,
            recordListItemType: 'bool',
            recordListItemIsPrimitive: true,
          ),
        ),
      ]);
      final out = KotlinGenerator.generate(boolSpec);
      expect(out, contains('val payloadSize = 4 + 1 * count'));
      expect(out, contains('buf.putInt(count)'));
      expect(out, contains('result.forEach { buf.put((if (it) 1 else 0).toByte()) }'));
      expect(out, isNot(contains('var offsetPos = 4 + 8L * result.size')));
      expect(out, isNot(contains('offsets.forEach { payloadBuf.putLong(it) }')));
      expect(out, isNot(contains('result.forEach { buf.putLong(if (it) 1L else 0L) }')));
    });

    test('Kotlin: enum-return callback converts JNI Long back to enum', () {
      final statusSpec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'mod.native.dart',
        enums: [
          BridgeEnum(
            name: 'TcStatus',
            startValue: 0,
            values: ['ok', 'warning', 'error'],
          ),
        ],
        functions: [
          _fn(
            'onStatusTransform',
            BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'statusCb',
                type: BridgeType(
                  name: 'TcStatus Function(int)',
                  isFunction: true,
                  functionReturnType: 'TcStatus',
                  functionParams: [BridgeType(name: 'int')],
                ),
              ),
            ],
          ),
        ],
      );
      final out = KotlinGenerator.generate(statusSpec);
      expect(out, contains('@JvmStatic external fun _invoke_statusCb(callbackPtr: Long, arg0: Long): Long'));
      expect(out, contains('impl.onStatusTransform({ p0: Long -> TcStatus.fromNative(_invoke_statusCb(statusCb, p0)) })'));
      expect(out, isNot(contains('_invoke_statusCb(callbackPtr: Long, arg0: Long): TcStatus')));
    });

    test('Swift: enum-return callback converts raw Int64 back to enum', () {
      final statusSpec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'mod.native.dart',
        enums: [
          BridgeEnum(
            name: 'TcStatus',
            startValue: 0,
            values: ['ok', 'warning', 'error'],
          ),
        ],
        functions: [
          _fn(
            'onStatusTransform',
            BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'statusCb',
                type: BridgeType(
                  name: 'TcStatus Function(int)',
                  isFunction: true,
                  functionReturnType: 'TcStatus',
                  functionParams: [BridgeType(name: 'int')],
                ),
              ),
            ],
          ),
        ],
      );
      final out = SwiftGenerator.generate(statusSpec);
      expect(
        out,
        contains('ModRegistry.impl?.onStatusTransform(statusCb: { arg0 in TcStatus(rawValue: statusCb(arg0))! })'),
      );
      expect(out, isNot(contains('statusCb: { arg0 in statusCb(arg0) }')));
    });
  });

  // ── §10: Property returning List<@HybridStruct T> ─────────────────────────

  group('Property returning List<@HybridStruct T> — all generators', () {
    final spec = _swiftKotlinSpec(
      [],
      structs: [_kPrinterStruct],
      props: [
        BridgeProperty(
          dartName: 'printers',
          type: _listStruct('Printer'),
          getSymbol: 'mod_get_printers',
          hasGetter: true,
          hasSetter: false,
        ),
      ],
    );

    test('Dart FFI: property getter uses LazyRecordList.decode', () {
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('LazyRecordList.decode'));
      expect(out, contains('PrinterRecordExt.fromReader'));
    });

    test('Dart FFI: property pointer uses Pointer<Uint8>', () {
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('Pointer<Uint8>'));
    });

    test('Dart RecordExt: PrinterRecordExt emitted from property (no @HybridRecord)', () {
      final out = RecordGenerator.generateDartExtensions(spec);
      expect(out, contains('PrinterRecordExt'));
    });

    test('Swift RecordExt: extension Printer emitted from property', () {
      final out = RecordGenerator.generateSwift(spec);
      expect(out, contains('extension Printer {'));
    });
  });

  // ── §11: Mixed — List<struct>, single record, void, primitives in one spec ─

  group('Mixed spec — multiple return types in one module', () {
    final mixedSpec = _swiftKotlinSpec(
      [
        _fn('reset', BridgeType(name: 'void')),
        _fn('getCount', BridgeType(name: 'int')),
        _fn('getPrinters', _listStruct('Printer')),
        _fn('getJob', BridgeType(name: 'Job', isRecord: true)),
        _fn('getJobs', _listRecord('Job')),
        _fn('getPrinter', BridgeType(name: 'Printer')),
      ],
      structs: [_kPrinterStruct],
      records: [_kJobRecord],
    );
    final mixedCppSpec = _cppSpec(
      [
        _fn('reset', BridgeType(name: 'void')),
        _fn('getCount', BridgeType(name: 'int')),
        _fn('getPrinters', _listStruct('Printer')),
        _fn('getJob', BridgeType(name: 'Job', isRecord: true)),
        _fn('getJobs', _listRecord('Job')),
        _fn('getPrinter', BridgeType(name: 'Printer')),
      ],
      structs: [_kPrinterStruct],
      records: [_kJobRecord],
    );

    test('Dart FFI: generates all 6 method overrides', () {
      final out = DartFfiGenerator.generate(mixedSpec);
      expect(out, contains('void reset()'));
      expect(out, contains('int getCount()'));
      expect(out, contains('List<Printer> getPrinters()'));
      expect(out, contains('Job getJob()'));
      expect(out, contains('List<Job> getJobs()'));
      expect(out, contains('Printer getPrinter()'));
    });

    test('Dart FFI: void uses no LazyRecordList', () {
      final out = DartFfiGenerator.generate(mixedSpec);
      final voidFn = out.split('void reset()').last.split('int getCount()').first;
      expect(voidFn, isNot(contains('LazyRecordList')));
    });

    test('Dart FFI: struct single return uses structPtr, not LazyRecordList', () {
      final out = DartFfiGenerator.generate(mixedSpec);
      expect(out, contains('structPtr.ref.toDart()'));
    });

    test('Dart FFI: no Pointer<Void> in function pointers for record returns', () {
      final out = DartFfiGenerator.generate(mixedSpec);
      expect(out, isNot(contains("Pointer<Void> Function() _getPrintersPtr")));
      expect(out, isNot(contains("Pointer<Void> Function() _getJobsPtr")));
      expect(out, isNot(contains("Pointer<Void> Function() _getJobPtr")));
    });

    test('CppBridge (pure-C++): all record-return methods use NitroCppBuffer pattern', () {
      final out = CppBridgeGenerator.generate(mixedCppSpec);
      // List<Printer>
      expect(out, contains('NitroCppBuffer _res = _impl->getPrinters()'));
      // Job
      expect(out, contains('NitroCppBuffer _res = _impl->getJob()'));
      // List<Job>
      expect(out, contains('NitroCppBuffer _res = _impl->getJobs()'));
    });

    test('CppBridge (pure-C++): Printer single return uses malloc not NitroCppBuffer', () {
      final out = CppBridgeGenerator.generate(mixedCppSpec);
      expect(out, contains('malloc(sizeof(Printer))'));
    });

    test('CppInterface: all 6 methods declared', () {
      final out = CppInterfaceGenerator.generate(mixedCppSpec);
      expect(out, contains('virtual void reset()'));
      expect(out, contains('virtual int64_t getCount()'));
      expect(out, contains('virtual Printer getPrinter()'));
      expect(out, contains('NitroCppBuffer'));
    });

    test('Kotlin: all 6 _call methods generated', () {
      final out = KotlinGenerator.generate(mixedSpec);
      expect(out, contains('fun reset_call(instanceId: Long)'));
      expect(out, contains('fun getCount_call(instanceId: Long)'));
      expect(out, contains('fun getPrinters_call(instanceId: Long): ByteArray'));
      expect(out, contains('fun getJob_call(instanceId: Long): ByteArray'));
      expect(out, contains('fun getJobs_call(instanceId: Long): ByteArray'));
    });

    test('Swift: all 6 _call functions generated', () {
      final out = SwiftGenerator.generate(mixedSpec);
      expect(out, contains('_mod_call_reset'));
      expect(out, contains('_mod_call_getCount'));
      expect(out, contains('_mod_call_getPrinters'));
      expect(out, contains('_mod_call_getJob'));
      expect(out, contains('_mod_call_getJobs'));
    });

    test('RecordExt: PrinterRecordExt AND JobRecordExt both generated', () {
      final dartExt = RecordGenerator.generateDartExtensions(mixedSpec);
      expect(dartExt, contains('PrinterRecordExt'));
      expect(dartExt, contains('JobRecordExt'));
    });
  });

  // ── §12: Batch stream — Kotlin mutex-guarded _buf ────────────────────────────
  //
  // Backpressure.batch uses a periodic _flushJob coroutine alongside the main
  // collect coroutine, both running on Dispatchers.Default (multi-threaded).
  // All accesses to _buf must be guarded by a kotlinx.coroutines.sync.Mutex.

  group('Batch stream — Kotlin mutex-guarded _buf (all numeric item types)', () {
    for (final itemType in ['int', 'double', 'bool']) {
      final spec = _batchStreamSpec(itemType);

      test('Kotlin ($itemType): emits Mutex guard for _buf', () {
        final out = KotlinGenerator.generate(spec);
        expect(out, contains('val _lock = kotlinx.coroutines.sync.Mutex()'), reason: '_buf must be protected by a Mutex for $itemType batch stream');
        expect(out, contains('import kotlinx.coroutines.sync.withLock'), reason: 'Mutex.withLock is an extension function and must be imported');
      });

      test('Kotlin ($itemType): _flush is a suspend fun', () {
        final out = KotlinGenerator.generate(spec);
        expect(out, contains('suspend fun _flush()'), reason: '_flush must be suspend so it can call _lock.withLock{}');
      });

      test('Kotlin ($itemType): _flush body is inside _lock.withLock', () {
        final out = KotlinGenerator.generate(spec);
        expect(out, contains('_lock.withLock {'), reason: 'Mutex.withLock must wrap _buf read/write in _flush');
        expect(out, contains('if (_buf.isEmpty()) return@withLock'), reason: 'return inside withLock must be labeled to compile');
        expect(out, isNot(contains('if (_buf.isEmpty()) return\n')), reason: 'unlabeled return is prohibited inside withLock');
      });

      test('Kotlin ($itemType): collect lambda stores size-check result in _full', () {
        final out = KotlinGenerator.generate(spec);
        expect(out, contains('val _full = _lock.withLock {'), reason: '_buf.add and size check must both happen inside the lock');
        expect(out, contains('if (_full) _flush()'), reason: 'flush is triggered outside the lock using the captured _full flag');
      });

      test('Kotlin ($itemType): _buf.size check is inside withLock (no bare _buf.size)', () {
        final out = KotlinGenerator.generate(spec);
        // The size check `_buf.size >= N` must be INSIDE the lock.
        // Any occurrence of `_buf.size` must be preceded (in the same withLock block)
        // by the lock acquisition — so `_buf.size` must NOT appear outside a withLock.
        final withoutLockSection = out.replaceAll(RegExp(r'_lock\.withLock \{[^}]*\}', dotAll: true), '');
        expect(withoutLockSection, isNot(contains('_buf.size')), reason: '_buf.size must only appear inside _lock.withLock{}');
      });

      test('Kotlin ($itemType): periodic _flushJob launches as child coroutine', () {
        final out = KotlinGenerator.generate(spec);
        expect(out, contains('val _flushJob = launch { while (true) { kotlinx.coroutines.delay(10); _flush() } }'));
      });

      test('Kotlin ($itemType): batch size limit comes from spec (32)', () {
        final out = KotlinGenerator.generate(spec);
        expect(out, contains('ArrayList<Long>(32)'), reason: 'batchMaxSize: 32 must flow through to the generated capacity');
        expect(out, contains('_buf.size >= 32'));
      });
    }

    test('Kotlin (int): _buf.add uses item.toLong()', () {
      final out = KotlinGenerator.generate(_batchStreamSpec('int'));
      expect(out, contains('_buf.add(item.toLong())'));
    });

    test('Kotlin (double): _buf.add uses doubleToRawLongBits', () {
      final out = KotlinGenerator.generate(_batchStreamSpec('double'));
      expect(out, contains('_buf.add(java.lang.Double.doubleToRawLongBits(item))'));
    });

    test('Kotlin (bool): _buf.add uses 1L/0L ternary', () {
      final out = KotlinGenerator.generate(_batchStreamSpec('bool'));
      expect(out, contains('_buf.add(if (item) 1L else 0L)'));
    });

    test('Kotlin: non-batch (dropLatest) stream does NOT emit Mutex', () {
      final spec = BridgeSpec(
        dartClassName: 'Sensor',
        lib: 'sensor',
        namespace: 'sensor',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'sensor.native.dart',
        streams: [
          BridgeStream(
            dartName: 'ticks',
            registerSymbol: 'sensor_register_ticks_stream',
            releaseSymbol: 'sensor_release_ticks_stream',
            itemType: BridgeType(name: 'int'),
            backpressure: Backpressure.dropLatest,
          ),
        ],
      );
      final out = KotlinGenerator.generate(spec);
      expect(out, isNot(contains('Mutex()')), reason: 'dropLatest streams are single-coroutine — no Mutex needed');
      expect(out, isNot(contains('import kotlinx.coroutines.sync.withLock')), reason: 'withLock import is only needed for batch streams');
      expect(out, isNot(contains('_flushJob')));
    });

    test('Swift: batch stream emits correct collect closure (not affected by Mutex change)', () {
      final out = SwiftGenerator.generate(_batchStreamSpec('int'));
      // Swift uses its own concurrency model — no Mutex emitted.
      expect(out, isNot(contains('Mutex')));
      expect(out, contains('_sensor_register_samples_stream'));
    });

    test('Dart FFI: batch stream emits Backpressure.batch', () {
      final out = DartFfiGenerator.generate(_batchStreamSpec('int'));
      expect(out, contains('Backpressure.batch'));
    });
  });

  // ── §13: String-returning callbacks — no exceptionalReturn for Pointer returns
  //
  // NativeCallable.isolateLocal rejects exceptionalReturn when the native return
  // type is Pointer<T>. String callbacks return Pointer<Utf8>, so omit it.

  group('String-returning callback — no exceptionalReturn for Pointer returns', () {
    test('Dart FFI: NativeCallable uses isolateLocal (not listener) for String return', () {
      final out = DartFfiGenerator.generate(_stringCallbackReturnSpec());
      expect(out, contains('.isolateLocal('));
      expect(out, isNot(contains('.listener(')));
    });

    test('Dart FFI: native signature is Pointer<Utf8> Function(Int64)', () {
      final out = DartFfiGenerator.generate(_stringCallbackReturnSpec());
      expect(out, contains('NativeCallable<Pointer<Utf8> Function(Int64)>.isolateLocal'));
    });

    test('Dart FFI: exceptionalReturn is omitted for String return', () {
      final out = DartFfiGenerator.generate(_stringCallbackReturnSpec());
      expect(out, isNot(contains('exceptionalReturn: nullptr')), reason: 'NativeCallable.isolateLocal rejects exceptionalReturn for Pointer<Utf8>');
    });

    test('Dart FFI: return expression uses toNativeUtf8()', () {
      final out = DartFfiGenerator.generate(_stringCallbackReturnSpec());
      expect(out, contains('return callback('));
      expect(out, contains('.toNativeUtf8()'));
    });

    test('Dart FFI: void-return callback uses listener (no exceptionalReturn)', () {
      final voidSpec = _swiftKotlinSpec([
        BridgeFunction(
          dartName: 'watch',
          cSymbol: 'mod_watch',
          isAsync: false,
          returnType: BridgeType(name: 'void'),
          params: [
            BridgeParam(
              name: 'onEvent',
              type: BridgeType(
                name: 'void Function(int)',
                isFunction: true,
                functionReturnType: 'void',
                functionParams: [BridgeType(name: 'int')],
              ),
            ),
          ],
        ),
      ]);
      final out = DartFfiGenerator.generate(voidSpec);
      expect(out, contains('.listener('));
      expect(out, isNot(contains('exceptionalReturn')));
    });

    test('Dart FFI: int-return callback uses isolateLocal with exceptionalReturn: 0', () {
      final intSpec = _swiftKotlinSpec([
        BridgeFunction(
          dartName: 'classify',
          cSymbol: 'mod_classify',
          isAsync: false,
          returnType: BridgeType(name: 'void'),
          params: [
            BridgeParam(
              name: 'classifier',
              type: BridgeType(
                name: 'int Function(int)',
                isFunction: true,
                functionReturnType: 'int',
                functionParams: [BridgeType(name: 'int')],
              ),
            ),
          ],
        ),
      ]);
      final out = DartFfiGenerator.generate(intSpec);
      expect(out, contains('.isolateLocal('));
      expect(out, contains('exceptionalReturn: 0'));
      expect(out, isNot(contains('exceptionalReturn: nullptr')));
    });

    test('Dart FFI: bool-return callback uses isolateLocal with exceptionalReturn: 0', () {
      final boolSpec = _swiftKotlinSpec([
        BridgeFunction(
          dartName: 'validate',
          cSymbol: 'mod_validate',
          isAsync: false,
          returnType: BridgeType(name: 'void'),
          params: [
            BridgeParam(
              name: 'predicate',
              type: BridgeType(
                name: 'bool Function(int)',
                isFunction: true,
                functionReturnType: 'bool',
                functionParams: [BridgeType(name: 'int')],
              ),
            ),
          ],
        ),
      ]);
      final out = DartFfiGenerator.generate(boolSpec);
      expect(out, contains('.isolateLocal('));
      expect(out, contains('exceptionalReturn: 0'));
    });

    test('Kotlin: String-return callback JNI invoker returns String', () {
      final out = KotlinGenerator.generate(_stringCallbackReturnSpec());
      // The Kotlin bridge invokes the Dart callback via an external JNI function.
      // For String returns the bridge returns a JVM String directly (not Long).
      expect(out, contains('@JvmStatic external fun _invoke_formatter(callbackPtr: Long, arg0: Long): String'));
    });

    test('Swift: String-return callback wraps result via strdup / UTF-8 pointer', () {
      final out = SwiftGenerator.generate(_stringCallbackReturnSpec());
      // Swift bridge invokes the formatter callback and converts the result to a C string.
      expect(out, contains('formatter('));
    });

    test('CppBridge (Swift/ObjC path): String-return callback typedef uses const char*', () {
      final out = CppBridgeGenerator.generate(_stringCallbackReturnSpec());
      // The generated C bridge must declare the callback as returning const char* (or char*).
      expect(out, contains('formatter'));
    });

    test('Dart FFI: callback cache key uses function + param name', () {
      final out = DartFfiGenerator.generate(_stringCallbackReturnSpec());
      expect(out, contains("const key = 'process.formatter';"), reason: 'cache key is a per-(functionName.paramName) slot, replaced on reassignment');
    });
  });

  // ── §14: Nullable @NitroVariant case fields ─────────────────────────────────

  group('Nullable @NitroVariant case fields — type coverage', () {
    final spec = _nullableVariantCoverageSpec();

    test('Dart FFI: generated variant codec writes presence flags and non-null payloads', () {
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('extension VariantEventVariantExt on VariantEvent'));
      expect(out, contains('writer.writeBool(count != null);'));
      expect(out, contains('writer.writeInt(count)'));
      expect(out, contains('writer.writeBool(quality != null);'));
      expect(out, contains('writer.writeInt(quality.index)'));
      expect(out, contains('writer.writeBool(payload != null);'));
      expect(out, contains('payload.writeFields(writer);'));
      expect(out, contains('writer.writeBool(samples != null);'));
      expect(out, contains('writer.writeInt32(samples.length); for (final e in samples)'));
    });

    test('Kotlin: nullable variant fields decode with readBool presence flags', () {
      final out = KotlinGenerator.generate(spec);
      expect(out, contains('data class VariantChanged(val count: Long?, val quality: VariantQuality?, val payload: VariantPayload?, val samples: List<Long>?)'));
      expect(out, contains('class RecordReader(val buf: java.nio.ByteBuffer)'));
      expect(out, contains('count = if (r.readBool()) r.readInt64() else null'));
      expect(out, contains('quality = if (r.readBool()) VariantQuality.fromNative(r.readInt64()) else null'));
      expect(out, contains('payload = if (r.readBool()) VariantPayload.decodeFrom(r.buf) else null'));
      expect(out, contains('samples = if (r.readBool()) List(r.readInt32()) { r.readInt64() } else null'));
    });

    test('Kotlin: nullable variant fields encode with safe calls', () {
      final out = KotlinGenerator.generate(spec);
      expect(out, contains('val out = java.io.ByteArrayOutputStream()'));
      expect(out, contains('val tmp = java.nio.ByteBuffer.allocate(8).order(java.nio.ByteOrder.LITTLE_ENDIAN)'));
      expect(out, contains('w.writeBool(count != null); count?.let { w.writeInt64(it) }'));
      expect(out, contains('w.writeBool(quality != null); quality?.let { w.writeInt64(it.nativeValue) }'));
      expect(out, contains('w.writeBool(payload != null); payload?.let { it.writeFieldsTo(w.out, w.tmp) }'));
      expect(out, contains('w.writeBool(samples != null); samples?.let { w.writeInt32(it.size); it.forEach { w.writeInt64(it) } }'));
      expect(out, isNot(contains('quality.nativeValue')), reason: 'nullable enum must use ?.let before nativeValue');
      expect(out, isNot(contains('payload.writeFields(w)')), reason: 'nullable record must use ?.let before writeFields');
      expect(out, isNot(contains('it.writeFields(w)')), reason: 'nullable record must use writeFieldsTo with RecordWriter buffers');
      expect(out, isNot(contains('w.writeInt64(count)')), reason: 'nullable primitive must not be passed as Long?');
    });

    test('Swift: nullable variant associated values use presence flags', () {
      final out = SwiftGenerator.generate(spec);
      expect(out, contains('case changed(count: Int64?, quality: VariantQuality?, payload: VariantPayload?, samples: [Int64]?)'));
      expect(out, contains('count: r.readBool() ? r.readInt() : nil'));
      expect(out, contains('quality: r.readBool() ? VariantQuality(rawValue: r.readInt())! : nil'));
      expect(out, contains('payload: r.readBool() ? VariantPayload.fromReader(r) : nil'));
      expect(out, contains('samples: r.readBool() ? (0..<Int(r.readInt32())).map { _ in r.readInt() } : nil'));
      expect(out, contains('w.writeBool(quality != nil); if let value = quality { w.writeInt(value.rawValue) }'));
      expect(out, contains('w.writeBool(payload != nil); if let value = payload { value.writeFields(w) }'));
    });
  });

  // ── §15: Gap 1 — Stream<T?> nullable stream items ────────────────────────

  group('§15: Gap 1 — Stream<T?> nullable stream items', () {
    for (final bareType in ['int', 'double', 'String']) {
      test('Dart FFI ($bareType?): nullable stream uses $bareType? cast', () {
        final out = DartFfiGenerator.generate(_nullableStreamCoverageSpec(bareType));
        expect(out, contains('message as $bareType?'), reason: 'null passes through as $bareType? cast');
        expect(out, contains('Stream<$bareType?>'));
      });
    }

    test('Dart FFI (bool?): nullable stream uses null check + int-to-bool decode', () {
      final out = DartFfiGenerator.generate(_nullableStreamCoverageSpec('bool'));
      expect(out, contains('message == null ? null : (message as int) != 0'));
      expect(out, contains('Stream<bool?>'));
    });

    test('Dart FFI (Level?): nullable enum stream uses null check + .toLevel()', () {
      final out = DartFfiGenerator.generate(_nullableStreamCoverageSpec('Level'));
      expect(out, contains('message == null ? null'));
      expect(out, contains('.toLevel()'));
      expect(out, contains('Stream<Level?>'));
    });

    test('Swift (int?): nullable stream uses UnsafePointer<Int64>? emit type', () {
      final out = SwiftGenerator.generate(_nullableStreamCoverageSpec('int'));
      expect(out, contains('UnsafePointer<Int64>?'));
    });

    test('Swift (bool?): nullable stream uses UnsafePointer<Int8>? emit type', () {
      final out = SwiftGenerator.generate(_nullableStreamCoverageSpec('bool'));
      expect(out, contains('UnsafePointer<Int8>?'));
      expect(out, contains('var _bv: Int8 = v ? 1 : 0'));
    });

    test('Swift (Level?): nullable enum stream uses UnsafePointer<Int64>? and rawValue', () {
      final out = SwiftGenerator.generate(_nullableStreamCoverageSpec('Level'));
      expect(out, contains('UnsafePointer<Int64>?'));
      expect(out, contains('var _rv = v.rawValue'));
    });

    test('Swift (int?): nil-posting path present in sink', () {
      final out = SwiftGenerator.generate(_nullableStreamCoverageSpec('int'));
      expect(out, contains('if let v = item'));
      expect(out, contains('emitCb(dartPort, nil)'));
    });

    test('Kotlin (int?): nullable stream emits Long? external decl', () {
      final out = KotlinGenerator.generate(_nullableStreamCoverageSpec('int'));
      expect(out, contains('Long?'));
    });

    test('Kotlin (bool?): nullable stream emits Boolean? external decl', () {
      final out = KotlinGenerator.generate(_nullableStreamCoverageSpec('bool'));
      expect(out, contains('Boolean?'));
    });

    test('C bridge (int?): nullable stream emits jobject + kNull path', () {
      final out = CppBridgeGenerator.generate(_nullableStreamCoverageSpec('int'));
      expect(out, contains('jobject'));
      expect(out, contains('Dart_CObject_kNull'));
    });

    test('Spec validator: no E009 for nullable stream items', () {
      for (final bareType in ['int', 'double', 'bool', 'String', 'Level']) {
        final issues = SpecValidator.validate(_nullableStreamCoverageSpec(bareType));
        expect(
          issues.any((i) => i.code == 'E009'),
          isFalse,
          reason: 'Stream<$bareType?> must be valid (E009 was removed)',
        );
      }
    });
  });

  // ── §16: Gap 2 — Map<String, @HybridEnum> ────────────────────────────────

  group('§16: Gap 2 — Map<String, @HybridEnum>', () {
    test('Spec validator: no E007 for Map<String, @HybridEnum>', () {
      final issues = SpecValidator.validate(_enumMapCoverageSpec());
      expect(issues.any((i) => i.code == 'E007'), isFalse);
    });

    test('Dart FFI: emits binary encode/decode helpers for enum map', () {
      final out = DartFfiGenerator.generate(_enumMapCoverageSpec());
      expect(out, contains('_nitroEncodeMapBinaryRoute'));
      expect(out, contains('_nitroDecodeMapBinaryRoute'));
    });

    test('Dart FFI: encoder uses .nativeValue (tag 1 = int64) for enum', () {
      final out = DartFfiGenerator.generate(_enumMapCoverageSpec());
      expect(out, contains('bb.addByte(1)'));
      expect(out, contains('.nativeValue'));
    });

    test('Dart FFI: decoder uses .toRoute() extension to convert int64', () {
      final out = DartFfiGenerator.generate(_enumMapCoverageSpec());
      expect(out, contains('.toRoute()'));
    });

    test('Kotlin: input map decodes enum with Route.fromNative', () {
      final out = KotlinGenerator.generate(_enumMapCoverageSpec());
      expect(out, contains('Route.fromNative'));
    });

    test('Kotlin: output map encodes enum with tag 1 + .nativeValue', () {
      final out = KotlinGenerator.generate(_enumMapCoverageSpec());
      expect(out, contains('_outBb.write(1)'));
      expect(out, contains('nativeValue'));
    });

    test('Swift: input map uses compactMapValues + Route(rawValue:)', () {
      final out = SwiftGenerator.generate(_enumMapCoverageSpec());
      expect(out, contains('compactMapValues'));
      expect(out, contains('Route(rawValue:'));
    });

    test('Swift: output map uses mapValues + .rawValue as Any', () {
      final out = SwiftGenerator.generate(_enumMapCoverageSpec());
      expect(out, contains('mapValues'));
      expect(out, contains('.rawValue'));
    });
  });

  // ── §17: Gap 3 — Backpressure.batch for @HybridEnum ─────────────────────

  group('§17: Gap 3 — Backpressure.batch for @HybridEnum', () {
    test('Spec validator: no E005 for batch stream with enum item type', () {
      final issues = SpecValidator.validate(_enumBatchCoverageSpec());
      expect(issues.any((i) => i.code == 'E005'), isFalse);
    });

    test('Dart FFI: batch enum stream decodes via .toSignal() extension', () {
      final out = DartFfiGenerator.generate(_enumBatchCoverageSpec());
      expect(out, contains('.toSignal()'));
      expect(out, contains('Backpressure.batch'));
    });

    test('Kotlin: batch enum stream uses item.nativeValue in _buf.add', () {
      final out = KotlinGenerator.generate(_enumBatchCoverageSpec());
      expect(out, contains('nativeValue'));
    });

    test('Kotlin: batch enum stream uses ArrayList<Long> (rawValue encoding)', () {
      final out = KotlinGenerator.generate(_enumBatchCoverageSpec());
      expect(out, contains('ArrayList<Long>'));
    });

    test('Swift: batch enum stream appends item.rawValue to buffer', () {
      final out = SwiftGenerator.generate(_enumBatchCoverageSpec());
      expect(out, contains('item.rawValue'));
    });

    test('Kotlin: enum batch shares Mutex+flush pattern from numeric batch', () {
      final out = KotlinGenerator.generate(_enumBatchCoverageSpec());
      expect(out, contains('val _lock = kotlinx.coroutines.sync.Mutex()'));
      expect(out, contains('suspend fun _flush()'));
    });
  });

  // ── §18: Gap 4 — Callback nullable primitive params ──────────────────────

  group('§18: Gap 4 — Callback nullable primitive params', () {
    test('Dart FFI (int?): two-param (isNull, value) — no sentinel corruption', () {
      final out = DartFfiGenerator.generate(_callbackNullableCoverageSpec());
      // Two Int64 params eliminate the Int64.min sentinel corruption risk.
      expect(out, contains('Void Function(Int64, Int64)'));
      expect(out, contains('arg0Null != 0 ? null : arg0Val'));
    });

    test('Dart FFI (bool?): two-param (isNull, value) — no sentinel corruption', () {
      final out = DartFfiGenerator.generate(_callbackNullableCoverageSpec());
      expect(out, contains('arg0Null != 0 ? null : arg0Val != 0'));
    });

    test('Dart FFI (double?): two-param (isNull, valueBits) — no NaN sentinel', () {
      final out = DartFfiGenerator.generate(_callbackNullableCoverageSpec());
      // Two Int64 params; second holds IEEE 754 bits when isNull == 0.
      expect(out, contains('arg0Null != 0 ? null : Int64List.fromList([arg0Val]).buffer.asFloat64List()[0]'));
    });

    test('Dart FFI (Quality?): sentinel -1 → null, otherwise → .toQuality()', () {
      final out = DartFfiGenerator.generate(_callbackNullableCoverageSpec());
      expect(out, contains('arg0 == -1 ? null'));
      expect(out, contains('.toQuality()'));
    });

    test('Dart FFI (String?): nullptr → null, otherwise .toDartString()', () {
      final out = DartFfiGenerator.generate(_callbackNullableCoverageSpec());
      expect(out, contains('arg0 == nullptr ? null : arg0.toDartString()'));
    });

    test('Spec validator: all nullable callback param types are valid (no errors)', () {
      final issues = SpecValidator.validate(_callbackNullableCoverageSpec());
      expect(issues.where((i) => i.isError).isEmpty, isTrue);
    });

    test('Dart FFI: NativeCallable uses two Int64 params for nullable int (isNull + value)', () {
      final out = DartFfiGenerator.generate(_callbackNullableCoverageSpec());
      // Nullable int params now use two Int64 params: (isNull flag, value bits).
      expect(out, contains('Void Function(Int64, Int64)'));
    });

    test('Dart FFI: exceptional return for int? callback uses Int64.min', () {
      final intNullableReturnSpec = BridgeSpec(
        dartClassName: 'Processor',
        lib: 'processor',
        namespace: 'processor',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'processor.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'query',
            cSymbol: 'processor_query',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'cb',
                type: BridgeType(
                  name: 'int? Function()',
                  isFunction: true,
                  functionReturnType: 'int?',
                  functionParams: [],
                ),
              ),
            ],
          ),
        ],
      );
      final out = DartFfiGenerator.generate(intNullableReturnSpec);
      // exceptionalReturn for int? uses Int64.min sentinel
      expect(out, contains('-9223372036854775808'));
    });
  });

  // ── §19: Item 4 — typed Pointer<NitroOptXxx> for nullable prim sync returns ─

  group('§19: Item 4 — typed Pointer<NitroOptXxx> nullable prim returns', () {
    BridgeSpec nullablePrimReturnSpec(String returnType) => BridgeSpec(
      dartClassName: 'Counter',
      lib: 'counter',
      namespace: 'counter',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'counter.native.dart',
      functions: [
        BridgeFunction(
          dartName: 'getCount',
          cSymbol: 'counter_get_count',
          isAsync: false,
          returnType: BridgeType(name: returnType, isNullable: true),
          params: [],
        ),
      ],
    );

    test('Dart FFI (int?): FFI type uses Pointer<NitroOptInt64>', () {
      final out = DartFfiGenerator.generate(nullablePrimReturnSpec('int?'));
      expect(out, contains('Pointer<NitroOptInt64>'));
    });

    test('Dart FFI (int?): decode uses .decoded + malloc.free', () {
      final out = DartFfiGenerator.generate(nullablePrimReturnSpec('int?'));
      // Sync path uses 'res' variable; async would use 'optPtr'.
      expect(out, contains('.decoded'));
      expect(out, contains('_nitroFree('));
    });

    test('Dart FFI (double?): FFI type uses Pointer<NitroOptFloat64>', () {
      final out = DartFfiGenerator.generate(nullablePrimReturnSpec('double?'));
      expect(out, contains('Pointer<NitroOptFloat64>'));
    });

    test('Dart FFI (double?): decode uses .decoded + malloc.free', () {
      final out = DartFfiGenerator.generate(nullablePrimReturnSpec('double?'));
      expect(out, contains('.decoded'));
      expect(out, contains('_nitroFree('));
    });

    test('Dart FFI (bool?): FFI type uses Pointer<NitroOptBool>', () {
      final out = DartFfiGenerator.generate(nullablePrimReturnSpec('bool?'));
      expect(out, contains('Pointer<NitroOptBool>'));
    });

    test('Dart FFI (bool?): decode uses .decoded + malloc.free', () {
      final out = DartFfiGenerator.generate(nullablePrimReturnSpec('bool?'));
      expect(out, contains('.decoded'));
      expect(out, contains('_nitroFree('));
    });

    test('Spec validator: int?/double?/bool? sync return has no errors', () {
      for (final t in ['int?', 'double?', 'bool?']) {
        final issues = SpecValidator.validate(nullablePrimReturnSpec(t));
        expect(issues.where((i) => i.isError).isEmpty, isTrue, reason: '$t return should have no errors');
      }
    });
  });

  // ── §20: Item 5 — @HybridRecord and @NitroVariant as callback return types ──

  group('§20: Item 5 — @HybridRecord / @NitroVariant callback returns', () {
    final kCbJobRecord = BridgeRecordType(
      name: 'Job',
      fields: [
        BridgeRecordField(name: 'id', dartType: 'int', kind: RecordFieldKind.primitive),
        BridgeRecordField(name: 'name', dartType: 'String', kind: RecordFieldKind.primitive),
      ],
    );

    BridgeSpec recordCallbackReturnSpec() => BridgeSpec(
      dartClassName: 'Scheduler',
      lib: 'scheduler',
      namespace: 'scheduler',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'scheduler.native.dart',
      recordTypes: [kCbJobRecord],
      functions: [
        BridgeFunction(
          dartName: 'transform',
          cSymbol: 'scheduler_transform',
          isAsync: false,
          returnType: BridgeType(name: 'void'),
          params: [
            BridgeParam(
              name: 'cb',
              type: BridgeType(
                name: 'Job Function(Job)',
                isFunction: true,
                functionReturnType: 'Job',
                functionParams: [
                  BridgeType(name: 'Job', isRecord: true),
                ],
              ),
            ),
          ],
        ),
      ],
    );

    BridgeSpec variantCallbackReturnSpec() => BridgeSpec(
      dartClassName: 'EventBus',
      lib: 'event_bus',
      namespace: 'event_bus',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'event_bus.native.dart',
      variants: [
        BridgeVariant(
          name: 'Event',
          cases: [
            BridgeVariantCase(
              name: 'EventClick',
              label: 'click',
              fields: [
                BridgeRecordField(name: 'x', dartType: 'int', kind: RecordFieldKind.primitive),
              ],
            ),
            BridgeVariantCase(
              name: 'EventScroll',
              label: 'scroll',
              fields: [
                BridgeRecordField(name: 'delta', dartType: 'double', kind: RecordFieldKind.primitive),
              ],
            ),
          ],
        ),
      ],
      functions: [
        BridgeFunction(
          dartName: 'process',
          cSymbol: 'event_bus_process',
          isAsync: false,
          returnType: BridgeType(name: 'void'),
          params: [
            BridgeParam(
              name: 'cb',
              type: BridgeType(
                name: 'Event Function(Event)',
                isFunction: true,
                functionReturnType: 'Event',
                functionParams: [
                  BridgeType(name: 'Event'),
                ],
              ),
            ),
          ],
        ),
      ],
    );

    test('Dart FFI (@HybridRecord return): NativeCallable uses Pointer<Uint8> return', () {
      final out = DartFfiGenerator.generate(recordCallbackReturnSpec());
      // Callback NativeCallable return type is Pointer<Uint8>
      expect(out, contains('Pointer<Uint8> Function('));
    });

    test('Dart FFI (@HybridRecord return): wrapper calls .toNative(malloc)', () {
      final out = DartFfiGenerator.generate(recordCallbackReturnSpec());
      expect(out, contains('toNative(malloc)'));
    });

    test('Dart FFI (@HybridRecord return): uses isolateLocal (not listener)', () {
      final out = DartFfiGenerator.generate(recordCallbackReturnSpec());
      expect(out, contains('.isolateLocal('));
      expect(out, isNot(contains('.listener(')));
    });

    test('Dart FFI (@NitroVariant return): NativeCallable uses Pointer<Uint8> return', () {
      final out = DartFfiGenerator.generate(variantCallbackReturnSpec());
      expect(out, contains('Pointer<Uint8> Function('));
    });

    test('Dart FFI (@NitroVariant return): wrapper calls .toNative(malloc)', () {
      final out = DartFfiGenerator.generate(variantCallbackReturnSpec());
      expect(out, contains('toNative(malloc)'));
    });

    test('Kotlin (@HybridRecord return): _invoke_cb declared as: ByteArray', () {
      final out = KotlinGenerator.generate(recordCallbackReturnSpec());
      expect(out, contains('external fun _invoke_cb(callbackPtr: Long'));
      expect(out, contains(': ByteArray'));
    });

    test('Kotlin (@HybridRecord return): lambda decodes ByteArray via run { ... decodeFrom(...) }', () {
      final out = KotlinGenerator.generate(recordCallbackReturnSpec());
      expect(out, contains('decodeFrom'));
      expect(out, contains('getInt()'));
    });

    test('Kotlin (@NitroVariant return): _invoke_cb declared as: ByteArray', () {
      final out = KotlinGenerator.generate(variantCallbackReturnSpec());
      expect(out, contains(': ByteArray'));
    });

    test('C bridge (@HybridRecord return): JNI invoker returns jbyteArray', () {
      final out = CppBridgeGenerator.generate(recordCallbackReturnSpec());
      expect(out, contains('JNIEXPORT jbyteArray JNICALL'));
    });

    test('C bridge (@HybridRecord return): reads 4-byte prefix + NewByteArray + free', () {
      final out = CppBridgeGenerator.generate(recordCallbackReturnSpec());
      expect(out, contains('memcpy(&_plen, _ret, 4)'));
      expect(out, contains('NewByteArray'));
      expect(out, contains('free(_ret)'));
    });

    test('Swift (@HybridRecord return): cdecl callback type uses UnsafeMutablePointer<UInt8>?', () {
      final out = SwiftGenerator.generate(recordCallbackReturnSpec());
      expect(out, contains('UnsafeMutablePointer<UInt8>?'));
    });

    test('Swift (@HybridRecord return): wrapper calls fromNative + free', () {
      final out = SwiftGenerator.generate(recordCallbackReturnSpec());
      expect(out, contains('fromNative'));
      expect(out, contains('free('));
    });

    test('Spec validator: @HybridRecord callback return has no errors', () {
      final issues = SpecValidator.validate(recordCallbackReturnSpec());
      expect(issues.where((i) => i.isError).isEmpty, isTrue);
    });

    test('Spec validator: @NitroVariant callback return has no errors', () {
      final issues = SpecValidator.validate(variantCallbackReturnSpec());
      expect(issues.where((i) => i.isError).isEmpty, isTrue);
    });
  });

  // ── §21: Item 3 — @NitroVariant as a property type ───────────────────────

  group('§21: Item 3 — @NitroVariant property getter + setter', () {
    group('Dart FFI', () {
      test('@NitroVariant getter: lookupFunction uses Pointer<Uint8> return', () {
        final out = DartFfiGenerator.generate(_variantPropSpec());
        expect(out, contains('Pointer<Uint8> Function(int, Pointer<NitroErrorFfi>) _getModePtr'));
      });

      test('@NitroVariant getter: decodes via ModeVariantExt.fromNative(res)', () {
        final out = DartFfiGenerator.generate(_variantPropSpec());
        expect(out, contains('ModeVariantExt.fromNative(res)'));
      });

      test('@NitroVariant getter: frees pointer via malloc.free(res)', () {
        final out = DartFfiGenerator.generate(_variantPropSpec());
        expect(out, contains('_nitroFree(res)'));
      });

      test('@NitroVariant setter: encodes via value.toNative(arena)', () {
        final out = DartFfiGenerator.generate(_variantPropSpec());
        expect(out, contains('value.toNative(arena)'));
      });

      test('@NitroVariant setter: calls _setModePtr with Pointer<Uint8>', () {
        final out = DartFfiGenerator.generate(_variantPropSpec());
        expect(out, contains('_setModePtr(_instanceId, value.toNative(arena)'));
      });
    });

    group('Kotlin', () {
      test('@NitroVariant getter bridge: ctrl_get_mode_call returns ByteArray', () {
        final out = KotlinGenerator.generate(_variantPropSpec());
        expect(out, contains('fun ctrl_get_mode_call(instanceId: Long): ByteArray'));
      });

      test('@NitroVariant getter bridge: encodes via writeFields + ByteBuffer length prefix', () {
        final out = KotlinGenerator.generate(_variantPropSpec());
        expect(out, contains('_vResult.writeFields(_vw)'));
        expect(out, contains('_vBuf.putInt(_vPayload.size)'));
      });

      test('@NitroVariant setter bridge: ctrl_set_mode_call takes ByteArray', () {
        final out = KotlinGenerator.generate(_variantPropSpec());
        expect(out, contains('fun ctrl_set_mode_call(instanceId: Long, value: ByteArray)'));
      });

      test('@NitroVariant setter bridge: decodes via Mode.fromReader after skipping length', () {
        final out = KotlinGenerator.generate(_variantPropSpec());
        expect(out, contains('valueBuf.getInt() // skip 4-byte length prefix'));
        expect(out, contains('Mode.fromReader(RecordReader(valueBuf))'));
      });

      test('@NitroVariant interface declares Mode property (var — has setter)', () {
        final out = KotlinGenerator.generate(_variantPropSpec());
        expect(out, contains('var mode: Mode'));
      });
    });

    group('Swift', () {
      test('@NitroVariant getter: @_cdecl returns UnsafeMutablePointer<UInt8>?', () {
        final out = SwiftGenerator.generate(_variantPropSpec());
        expect(out, contains('@_cdecl("_ctrl_call_get_mode")'));
        expect(out, contains('-> UnsafeMutablePointer<UInt8>?'));
      });

      test('@NitroVariant getter: encodes via writeFields + toNative', () {
        final out = SwiftGenerator.generate(_variantPropSpec());
        expect(out, contains('_vImpl.mode.writeFields(to: _vw)'));
        expect(out, contains('_vw.toNative().map'));
      });

      test('@NitroVariant protocol: mode property declared', () {
        final out = SwiftGenerator.generate(_variantPropSpec());
        expect(out, contains('var mode: Mode'));
      });
    });

    test('Spec validator: no errors for @NitroVariant property', () {
      final issues = SpecValidator.validate(_variantPropSpec());
      expect(issues.where((i) => i.isError), isEmpty);
    });
  });

  // ── §22: Item 6 — nullable @HybridStruct stream items ────────────────────

  group('§22: Item 6 — nullable @HybridStruct stream items', () {
    group('Dart FFI', () {
      test('Stream<Packet?> getter returns Stream<Packet?>', () {
        final out = DartFfiGenerator.generate(_nullableStructStreamSpec());
        expect(out, contains('Stream<Packet?> get packets'));
      });

      test('openStream typed as PacketProxy? (nullable proxy)', () {
        final out = DartFfiGenerator.generate(_nullableStructStreamSpec());
        expect(out, contains('NitroRuntime.openStream<PacketProxy?>'));
      });

      test('unpack: null message returns null (nullable path)', () {
        final out = DartFfiGenerator.generate(_nullableStructStreamSpec());
        expect(out, contains('if (message == null) { return null; }'));
      });

      test('unpack: non-null message creates PacketProxy from address', () {
        final out = DartFfiGenerator.generate(_nullableStructStreamSpec());
        expect(out, contains('PacketProxy(Pointer<PacketFfi>.fromAddress(message as int))'));
      });

      test('PacketProxy zero-copy proxy generated for struct', () {
        final out = DartFfiGenerator.generate(_nullableStructStreamSpec());
        expect(out, contains('final class PacketProxy extends Packet implements Finalizable'));
      });
    });

    group('Kotlin', () {
      test('Kotlin interface Flow<Packet?> with nullable type', () {
        final out = KotlinGenerator.generate(_nullableStructStreamSpec());
        expect(out, contains('val packets: Flow<Packet?>'));
      });
    });

    test('Spec validator: no errors for nullable @HybridStruct stream', () {
      final issues = SpecValidator.validate(_nullableStructStreamSpec());
      expect(issues.where((i) => i.isError), isEmpty);
    });
  });

  // ── §23: L1 — Stream<@HybridRecord> (non-nullable) ───────────────────────
  group('§23: L1 — Stream<@HybridRecord> non-nullable', () {
    group('Dart FFI', () {
      test('Stream getter returns Stream<TcEvent>', () {
        final out = DartFfiGenerator.generate(_recordStreamSpec());
        expect(out, contains('Stream<TcEvent> get events'));
      });

      test('openStream typed as TcEvent (non-nullable)', () {
        final out = DartFfiGenerator.generate(_recordStreamSpec());
        expect(out, contains('NitroRuntime.openStream<TcEvent>'));
      });

      test('unpack decodes via TcEventRecordExt.fromNative', () {
        final out = DartFfiGenerator.generate(_recordStreamSpec());
        expect(out, contains('TcEventRecordExt.fromNative(rawPtr)'));
      });

      test('unpack reads pointer from message address', () {
        final out = DartFfiGenerator.generate(_recordStreamSpec());
        expect(out, contains('Pointer<Uint8>.fromAddress(message as int)'));
      });

      test('unpack frees the native buffer after decode', () {
        final out = DartFfiGenerator.generate(_recordStreamSpec());
        expect(out, contains('_nitroFree(rawPtr)'));
      });

      test('unpack throws StateError for null message (non-nullable)', () {
        final out = DartFfiGenerator.generate(_recordStreamSpec());
        expect(out, contains("throw StateError('Received null event on non-nullable stream events')"));
      });
    });

    group('Kotlin', () {
      test('Kotlin interface uses Flow<TcEvent> (non-nullable)', () {
        final out = KotlinGenerator.generate(_recordStreamSpec());
        expect(out, contains('val events: Flow<TcEvent>'));
      });

      test('JNI emit function uses ByteArray (not the record class directly)', () {
        final out = KotlinGenerator.generate(_recordStreamSpec());
        expect(out, contains('external fun emit_events(dartPort: Long, item: ByteArray): Boolean'));
      });

      test('collect calls item.encode() before emitting', () {
        final out = KotlinGenerator.generate(_recordStreamSpec());
        expect(out, contains('emit_events(dartPort, item.encode())'));
      });

      test('register stream _call bridges to impl coroutine', () {
        final out = KotlinGenerator.generate(_recordStreamSpec());
        expect(out, contains('event_hub_register_events_stream_call(instanceId: Long, dartPort: Long)'));
      });
    });

    group('Swift', () {
      test('emitCb parameter uses UnsafeMutablePointer<UInt8>? (record wire type)', () {
        final out = SwiftGenerator.generate(_recordStreamSpec());
        expect(out, contains('_ emitCb: @convention(c) (Int64, UnsafeMutablePointer<UInt8>?) -> Bool'));
      });

      test('sink body calls item.toNative() to serialize', () {
        final out = SwiftGenerator.generate(_recordStreamSpec());
        expect(out, contains('let raw = item.toNative()'));
      });

      test('emit posts raw pointer via emitCb', () {
        final out = SwiftGenerator.generate(_recordStreamSpec());
        expect(out, contains('if !emitCb(dartPort, raw)'));
      });

      test('frees native buffer when emit returns false', () {
        final out = SwiftGenerator.generate(_recordStreamSpec());
        expect(out, contains('if let raw { free(UnsafeMutableRawPointer(raw)) }'));
      });
    });

    group('C JNI bridge', () {
      test('JNI emit function signature uses jbyteArray (not jobject)', () {
        final out = CppBridgeGenerator.generate(_recordStreamSpec());
        expect(out, contains('jlong dartPort, jbyteArray item)'));
      });

      test('C copies jbyteArray bytes to malloc\'d buffer', () {
        final out = CppBridgeGenerator.generate(_recordStreamSpec());
        expect(out, contains('env->GetByteArrayRegion(item, 0, len, (jbyte*)buf)'));
      });

      test('C posts buffer address as kInt64', () {
        final out = CppBridgeGenerator.generate(_recordStreamSpec());
        expect(out, contains('obj.value.as_int64 = (intptr_t)buf'));
      });
    });

    test('Spec validator: no errors for Stream<@HybridRecord>', () {
      final issues = SpecValidator.validate(_recordStreamSpec());
      expect(issues.where((i) => i.isError), isEmpty);
    });
  });

  // ── §24: L1 edge — Stream<@HybridRecord?> nullable record stream ──────────
  group('§24: L1 edge — Stream<@HybridRecord?> nullable', () {
    group('Dart FFI', () {
      test('Stream getter returns Stream<TcEvent?> (nullable)', () {
        final out = DartFfiGenerator.generate(_recordStreamSpec(nullable: true));
        expect(out, contains('Stream<TcEvent?> get events'));
      });

      test('openStream typed as TcEvent? (nullable)', () {
        final out = DartFfiGenerator.generate(_recordStreamSpec(nullable: true));
        expect(out, contains('NitroRuntime.openStream<TcEvent?>'));
      });

      test('unpack returns null for null message (nullable)', () {
        final out = DartFfiGenerator.generate(_recordStreamSpec(nullable: true));
        expect(out, contains('if (message == null) { return null; }'));
      });

      test('unpack still decodes non-null via fromNative', () {
        final out = DartFfiGenerator.generate(_recordStreamSpec(nullable: true));
        expect(out, contains('TcEventRecordExt.fromNative(rawPtr)'));
      });
    });

    group('Kotlin', () {
      test('Kotlin Flow type is nullable Flow<TcEvent?>', () {
        final out = KotlinGenerator.generate(_recordStreamSpec(nullable: true));
        expect(out, contains('val events: Flow<TcEvent?>'));
      });

      test('JNI emit function uses ByteArray? (nullable ByteArray)', () {
        final out = KotlinGenerator.generate(_recordStreamSpec(nullable: true));
        expect(out, contains('external fun emit_events(dartPort: Long, item: ByteArray?): Boolean'));
      });

      test('collect calls item?.encode() (null-safe encode)', () {
        final out = KotlinGenerator.generate(_recordStreamSpec(nullable: true));
        expect(out, contains('emit_events(dartPort, item?.encode())'));
      });
    });

    group('C JNI bridge', () {
      test('C JNI bridge handles null jbyteArray → kNull', () {
        final out = CppBridgeGenerator.generate(_recordStreamSpec(nullable: true));
        expect(out, contains('if (item == nullptr) { obj.type = Dart_CObject_kNull; }'));
      });

      test('C copies non-null jbyteArray to malloc\'d buffer', () {
        final out = CppBridgeGenerator.generate(_recordStreamSpec(nullable: true));
        expect(out, contains('env->GetByteArrayRegion(item, 0, len, (jbyte*)buf)'));
      });
    });

    test('Spec validator: no errors for nullable Stream<@HybridRecord?>', () {
      final issues = SpecValidator.validate(_recordStreamSpec(nullable: true));
      expect(issues.where((i) => i.isError), isEmpty);
    });
  });
}
