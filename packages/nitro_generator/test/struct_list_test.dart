// Tests for List<@HybridStruct T> as a method return type.
//
// Covers:
//   1. Dart FFI: sync method generates LazyRecordList.decode with ${T}RecordExt.fromReader
//   2. Dart FFI: async method generates correct Dart code (LazyRecordList.decode)
//   3. RecordGenerator generates ${T}RecordExt for struct used as List<T> return
//   4. Swift generator produces NitroRecordWriter.encodeIndexedList with e.writeFields(w)
//   5. Kotlin generator produces ByteArray return + result.forEach { it.writeFieldsTo(out, buf) }
//   6. Property getter returning List<@HybridStruct T> is handled correctly (Dart + RecordExt)

import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/record_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// ── Shared spec builders ──────────────────────────────────────────────────────

/// Spec: module with `List<Printer> getPrinters()` where `Printer` is a struct.
BridgeSpec _structListReturnSpec() => BridgeSpec(
  dartClassName: 'PrintModule',
  lib: 'print_module',
  namespace: 'print_module',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'print_module.native.dart',
  structs: [
    BridgeStruct(
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
    ),
  ],
  functions: [
    BridgeFunction(
      dartName: 'getPrinters',
      cSymbol: 'print_module_get_printers',
      isAsync: false,
      returnType: BridgeType(
        name: 'List<Printer>',
        isRecord: true,
        recordListItemType: 'Printer',
      ),
      params: [],
    ),
  ],
);

/// Spec: async variant of the struct list return.
BridgeSpec _asyncStructListReturnSpec() => BridgeSpec(
  dartClassName: 'PrintModule',
  lib: 'print_module',
  namespace: 'print_module',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'print_module.native.dart',
  structs: [
    BridgeStruct(
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
      ],
    ),
  ],
  functions: [
    BridgeFunction(
      dartName: 'fetchPrinters',
      cSymbol: 'print_module_fetch_printers',
      isAsync: true,
      returnType: BridgeType(
        name: 'List<Printer>',
        isRecord: true,
        isFuture: true,
        recordListItemType: 'Printer',
      ),
      params: [],
    ),
  ],
);

/// Spec: property getter returning List<@HybridStruct T>.
BridgeSpec _structListPropertySpec() => BridgeSpec(
  dartClassName: 'PrintModule',
  lib: 'print_module',
  namespace: 'print_module',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'print_module.native.dart',
  structs: [
    BridgeStruct(
      name: 'Printer',
      packed: false,
      fields: [
        BridgeField(
          name: 'id',
          type: BridgeType(name: 'String'),
        ),
        BridgeField(
          name: 'copies',
          type: BridgeType(name: 'int'),
        ),
      ],
    ),
  ],
  properties: [
    BridgeProperty(
      dartName: 'availablePrinters',
      type: BridgeType(
        name: 'List<Printer>',
        isRecord: true,
        recordListItemType: 'Printer',
      ),
      getSymbol: 'print_module_get_available_printers',
      hasGetter: true,
      hasSetter: false,
    ),
  ],
);

/// Spec combining a struct list return AND a @HybridRecord (to verify no interference).
BridgeSpec _mixedStructListAndRecordSpec() => BridgeSpec(
  dartClassName: 'PrintModule',
  lib: 'print_module',
  namespace: 'print_module',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'print_module.native.dart',
  structs: [
    BridgeStruct(
      name: 'Printer',
      packed: false,
      fields: [
        BridgeField(
          name: 'id',
          type: BridgeType(name: 'String'),
        ),
      ],
    ),
  ],
  recordTypes: [
    BridgeRecordType(
      name: 'PrintJob',
      fields: [
        BridgeRecordField(
          name: 'jobId',
          dartType: 'String',
          kind: RecordFieldKind.primitive,
        ),
      ],
    ),
  ],
  functions: [
    BridgeFunction(
      dartName: 'getPrinters',
      cSymbol: 'print_module_get_printers',
      isAsync: false,
      returnType: BridgeType(
        name: 'List<Printer>',
        isRecord: true,
        recordListItemType: 'Printer',
      ),
      params: [],
    ),
    BridgeFunction(
      dartName: 'getJob',
      cSymbol: 'print_module_get_job',
      isAsync: false,
      returnType: BridgeType(
        name: 'PrintJob',
        isRecord: true,
      ),
      params: [],
    ),
  ],
);

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  // ── Section 1: Dart FFI sync method return ────────────────────────────────

  group('DartFfiGenerator — List<@HybridStruct T> sync method return', () {
    test('FFI function pointer uses Pointer<Uint8> type for the list return', () {
      final out = DartFfiGenerator.generate(_structListReturnSpec());
      // Should use Pointer<Uint8> (record path) for the getPrinters function pointer
      expect(out, contains('Pointer<Uint8> Function(Pointer<NitroErrorFfi>)'));
      // Should NOT use Pointer<Void> in the function pointer lookup for getPrinters
      expect(out, isNot(contains("lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>('print_module_get_printers')")));
    });

    test('sync return decodes via LazyRecordList.decode with PrinterRecordExt.fromReader', () {
      final out = DartFfiGenerator.generate(_structListReturnSpec());
      expect(out, contains('LazyRecordList.decode'));
      expect(out, contains('PrinterRecordExt.fromReader'));
    });

    test('return type annotation is List<Printer> (not void or Pointer)', () {
      final out = DartFfiGenerator.generate(_structListReturnSpec());
      expect(out, contains('List<Printer> getPrinters()'));
    });

    test('does NOT emit structPtr / toDart / freeFields (struct path) for list return', () {
      final out = DartFfiGenerator.generate(_structListReturnSpec());
      // The struct-single-return path uses structPtr.ref.toDart()
      expect(out, isNot(contains('structPtr.ref.toDart()')));
    });
  });

  // ── Section 2: Dart FFI async method return ───────────────────────────────

  group('DartFfiGenerator — List<@HybridStruct T> async method return', () {
    test('async return decodes via LazyRecordList.decode', () {
      final out = DartFfiGenerator.generate(_asyncStructListReturnSpec());
      expect(out, contains('LazyRecordList.decode'));
      expect(out, contains('PrinterRecordExt.fromReader'));
    });

    test('async method uses callAsync<Pointer<Uint8>>', () {
      final out = DartFfiGenerator.generate(_asyncStructListReturnSpec());
      expect(out, contains('callAsync<Pointer<Uint8>>'));
    });

    test('return type annotation is Future<List<Printer>>', () {
      final out = DartFfiGenerator.generate(_asyncStructListReturnSpec());
      expect(out, contains('Future<List<Printer>> fetchPrinters()'));
    });
  });

  // ── Section 3: RecordGenerator generates ${T}RecordExt for struct ────────

  group('RecordGenerator — TRecordExt generated for struct in List<T> return', () {
    // Pure struct-list spec (NO @HybridRecord) — tests the early-return fix.
    // Before the fix, generateDartExtensions would return '' because
    // localRecords.isEmpty; the ${T}RecordExt was never emitted.
    test('generates PrinterRecordExt even when there are NO @HybridRecord types', () {
      final out = RecordGenerator.generateDartExtensions(_structListReturnSpec());
      expect(out, contains('PrinterRecordExt'));
    });

    test('generated PrinterRecordExt has fromReader static method (no @HybridRecord)', () {
      final out = RecordGenerator.generateDartExtensions(_structListReturnSpec());
      expect(out, contains('static Printer fromReader(RecordReader r)'));
    });

    test('generated PrinterRecordExt has writeFields method (no @HybridRecord)', () {
      final out = RecordGenerator.generateDartExtensions(_structListReturnSpec());
      expect(out, contains('void writeFields(RecordWriter writer)'));
    });

    test('mixed spec: PrinterRecordExt AND PrintJobRecordExt both generated', () {
      final out = RecordGenerator.generateDartExtensions(_mixedStructListAndRecordSpec());
      expect(out, contains('PrinterRecordExt'));
      expect(out, contains('PrintJobRecordExt'));
    });

    test('property returning List<@HybridStruct T> triggers RecordExt (no @HybridRecord)', () {
      final out = RecordGenerator.generateDartExtensions(_structListPropertySpec());
      expect(out, contains('PrinterRecordExt'));
      expect(out, contains('static Printer fromReader(RecordReader r)'));
    });
  });

  // ── Section 3b: Swift extensions for pure struct-list (no @HybridRecord) ──

  group('RecordGenerator.generateSwift — struct writeFields when no @HybridRecord', () {
    test('generates writeFields Swift extension for struct-list return (no @HybridRecord)', () {
      // _structListReturnSpec has no @HybridRecord — before the fix, generateSwift
      // returned '' because localRecords.isEmpty; e.writeFields(w) would fail to compile.
      final out = RecordGenerator.generateSwift(_structListReturnSpec());
      expect(out, contains('func writeFields'));
    });

    test('generates fromReader Swift extension for struct-list return (no @HybridRecord)', () {
      final out = RecordGenerator.generateSwift(_structListReturnSpec());
      expect(out, contains('static func fromReader'));
    });

    test('Swift extension is for the correct struct type (Printer)', () {
      final out = RecordGenerator.generateSwift(_structListReturnSpec());
      expect(out, contains('extension Printer {'));
    });

    test('property getter also triggers Swift writeFields (no @HybridRecord)', () {
      final out = RecordGenerator.generateSwift(_structListPropertySpec());
      expect(out, contains('extension Printer {'));
      expect(out, contains('func writeFields'));
    });
  });

  // ── Section 4: Swift generator ────────────────────────────────────────────

  group('SwiftGenerator — List<@HybridStruct T> sync method return', () {
    test('sync return emits NitroRecordWriter.encodeIndexedList', () {
      final out = SwiftGenerator.generate(_structListReturnSpec());
      expect(out, contains('NitroRecordWriter.encodeIndexedList'));
    });

    test('sync return calls e.writeFields(w) — not a primitive write call', () {
      final out = SwiftGenerator.generate(_structListReturnSpec());
      expect(out, contains('e.writeFields(w)'));
    });

    test('sync method return type is UnsafeMutablePointer<UInt8>?', () {
      final out = SwiftGenerator.generate(_structListReturnSpec());
      expect(out, contains('UnsafeMutablePointer<UInt8>?'));
    });

    test('async return emits NitroRecordWriter.encodeIndexedList with e.writeFields(w)', () {
      final out = SwiftGenerator.generate(_asyncStructListReturnSpec());
      expect(out, contains('NitroRecordWriter.encodeIndexedList'));
      expect(out, contains('e.writeFields(w)'));
    });
  });

  // ── Section 5: Kotlin generator ───────────────────────────────────────────

  group('KotlinGenerator — List<@HybridStruct T> sync method return', () {
    test('sync _call method returns ByteArray', () {
      final out = KotlinGenerator.generate(_structListReturnSpec());
      expect(out, contains('fun getPrinters_call(): ByteArray'));
    });

    test('sync _call uses result.forEach { it.writeFieldsTo(out, buf) }', () {
      final out = KotlinGenerator.generate(_structListReturnSpec());
      expect(out, contains('result.forEach { it.writeFieldsTo(out, buf) }'));
    });

    test('sync _call encodes list with 4-byte count prefix', () {
      final out = KotlinGenerator.generate(_structListReturnSpec());
      expect(out, contains('countBuf.putInt(result.size)'));
    });

    test('interface declares fun getPrinters(): List<Printer>', () {
      final out = KotlinGenerator.generate(_structListReturnSpec());
      expect(out, contains('fun getPrinters(): List<Printer>'));
    });

    test('async _call returns ByteArray for List<@HybridStruct T>', () {
      final out = KotlinGenerator.generate(_asyncStructListReturnSpec());
      expect(out, contains('ByteArray'));
      expect(out, contains('writeFieldsTo'));
    });
  });

  // ── Section 6: Property getter returning List<@HybridStruct T> ───────────

  group('DartFfiGenerator — List<@HybridStruct T> property getter', () {
    test('property getter uses Pointer<Uint8> FFI type', () {
      final out = DartFfiGenerator.generate(_structListPropertySpec());
      expect(out, contains('Pointer<Uint8>'));
    });

    test('property getter decodes via LazyRecordList.decode', () {
      final out = DartFfiGenerator.generate(_structListPropertySpec());
      expect(out, contains('LazyRecordList.decode'));
      expect(out, contains('PrinterRecordExt.fromReader'));
    });
  });

  // ── Section 7: No interference with plain struct single returns ───────────

  group('No regression — plain @HybridStruct single return still works', () {
    test('single struct return still uses structPtr path not LazyRecordList', () {
      // Use the richSpec which has fetchReading returning a struct
      final out = DartFfiGenerator.generate(richSpec());
      expect(out, contains('structPtr.ref.toDart()'));
      expect(out, isNot(contains('LazyRecordList.decode')));
    });
  });

  // ── Section 8: Nested struct support ─────────────────────────────────────

  group('Nested @HybridStruct in List<T> — fromReader/writeFields chain', () {
    // PrinterWithSettings has a nested SettingsStruct field.
    BridgeSpec nestedStructSpec() => BridgeSpec(
      dartClassName: 'PrintModule',
      lib: 'print_module',
      namespace: 'print_module',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'print_module.native.dart',
      structs: [
        BridgeStruct(
          name: 'PrintSettings',
          packed: false,
          fields: [
            BridgeField(
              name: 'copies',
              type: BridgeType(name: 'int'),
            ),
            BridgeField(
              name: 'quality',
              type: BridgeType(name: 'String'),
            ),
          ],
        ),
        BridgeStruct(
          name: 'Printer',
          packed: false,
          fields: [
            BridgeField(
              name: 'id',
              type: BridgeType(name: 'String'),
            ),
            BridgeField(
              name: 'settings',
              type: BridgeType(name: 'PrintSettings'),
            ),
          ],
        ),
      ],
      functions: [
        BridgeFunction(
          dartName: 'getPrinters',
          cSymbol: 'print_module_get_printers',
          isAsync: false,
          returnType: BridgeType(
            name: 'List<Printer>',
            isRecord: true,
            recordListItemType: 'Printer',
          ),
          params: [],
        ),
      ],
    );

    test('Dart: PrinterRecordExt.fromReader reads nested PrintSettings', () {
      final out = RecordGenerator.generateDartExtensions(nestedStructSpec());
      expect(out, contains('PrinterRecordExt'));
      expect(out, contains('PrintSettingsRecordExt'));
    });

    test('Dart: nested struct also gets its own fromReader', () {
      final out = RecordGenerator.generateDartExtensions(nestedStructSpec());
      expect(out, contains('static PrintSettings fromReader(RecordReader r)'));
    });

    test('Dart: writeFields calls nested struct writeFields', () {
      final out = RecordGenerator.generateDartExtensions(nestedStructSpec());
      // Nested struct field serialization uses PrintSettingsRecordExt.writeFields
      expect(out, contains('PrintSettingsRecordExt'));
    });

    test('Swift: both Printer and PrintSettings get writeFields extensions', () {
      final out = RecordGenerator.generateSwift(nestedStructSpec());
      expect(out, contains('extension Printer {'));
      expect(out, contains('extension PrintSettings {'));
    });

    test('Dart FFI: sync method uses LazyRecordList.decode with PrinterRecordExt', () {
      final out = DartFfiGenerator.generate(nestedStructSpec());
      expect(out, contains('LazyRecordList.decode'));
      expect(out, contains('PrinterRecordExt.fromReader'));
    });

    test('Kotlin: generates writeFieldsTo for both Printer and PrintSettings', () {
      final out = KotlinGenerator.generate(nestedStructSpec());
      // Kotlin struct writeFieldsTo is generated by StructGenerator — verify both are present
      expect(out, contains('fun getPrinters_call(): ByteArray'));
    });
  });
}
