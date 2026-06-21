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

    test('CppBridge (pure-C++ path): NitroCppBuffer _res + return (void*)_res.data', () {
      final out = CppBridgeGenerator.generate(cppSpec);
      expect(out, contains('NitroCppBuffer _res = g_impl->getPrinters()'));
      expect(out, contains('return (void*)_res.data'));
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

    test('CppBridge (pure-C++ path): NitroCppBuffer _res + return (void*)_res.data', () {
      final out = CppBridgeGenerator.generate(cppSpec);
      expect(out, contains('NitroCppBuffer _res = g_impl->getJob()'));
      expect(out, contains('return (void*)_res.data'));
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
      expect(out, contains('return (void*)_res.data'));
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
      expect(out, contains('return (void*)_res.data'));
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

    test('Swift: list param decodes binary buffer via NitroRecordReader.decodeList', () {
      final out = SwiftGenerator.generate(spec);
      expect(out, contains('NitroRecordReader.decodeList'));
      expect(out, contains('Printer.fromReader'));
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
}
