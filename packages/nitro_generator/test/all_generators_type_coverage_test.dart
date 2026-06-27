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
      expect(out, contains('fun reset_call()'));
    });

    test('CppBridge (Swift path): void mod_reset(void)', () {
      final out = CppBridgeGenerator.generate(spec);
      expect(out, contains('void mod_reset(NitroError* _nitro_err)'));
    });

    test('CppBridge (pure-C++ path): void mod_reset(void)', () {
      final out = CppBridgeGenerator.generate(cppSpec);
      expect(out, contains('void mod_reset(NitroError* _nitro_err)'));
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
      expect(out, contains('void mod_reset(NitroError* _nitro_err)'));
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
      expect(out, contains("Pointer<Uint8> Function(Pointer<NitroErrorFfi>) _getPrintersPtr"));
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
      expect(out, contains('fun getPrinters_call(): ByteArray'));
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
      expect(out, contains('NitroCppBuffer _res = g_impl->getPrinters()'));
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
      expect(out, contains('NitroCppBuffer _res = g_impl->getJob()'));
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
      expect(out, contains('NitroCppBuffer _res = g_impl->getJobs()'));
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
      expect(out, contains('NitroCppBuffer _res = g_impl->getSettings()'));
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
      expect(out, contains('flagsDecoded.add(if (itemBuf.get().toInt() != 0) 1L else 0L)'));
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
      expect(out, contains('NitroCppBuffer _res = g_impl->getPrinters()'));
      // Job
      expect(out, contains('NitroCppBuffer _res = g_impl->getJob()'));
      // List<Job>
      expect(out, contains('NitroCppBuffer _res = g_impl->getJobs()'));
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
      expect(out, contains('fun reset_call()'));
      expect(out, contains('fun getCount_call()'));
      expect(out, contains('fun getPrinters_call(): ByteArray'));
      expect(out, contains('fun getJob_call(): ByteArray'));
      expect(out, contains('fun getJobs_call(): ByteArray'));
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
      expect(out, contains("('process.formatter', callback)"), reason: 'cache key is (functionName.paramName, callback) for deduplication');
    });
  });
}
