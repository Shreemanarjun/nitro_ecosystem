// Tests for TypedData (Uint8List, Int8List, Int16List, Int32List, Int64List,
// Float32List, Float64List) support as @HybridRecord field types.
//
// The new `RecordFieldKind.typedData` path serialises every TypedData as:
//   [4B int32 element_count][element_bytes * count]
// via RecordWriter.writeBlob / RecordReader.readBlob (Uint8List) or
// buffer-view conversion for other types.
//
// Dart  : writeBlob / readBlob (Uint8List), buffer.asUint8List() + view for others
// Kotlin: ByteArray (Uint8List/Int8List), ShortArray, IntArray, LongArray, FloatArray, DoubleArray
// Swift : Data (Uint8List/Int8List), [Int16], [Int32], [Int64], [Float], [Double]
// C++   : std::vector<uint8_t>

import 'package:nitro_generator/src/generators/record_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// ── Spec helpers ──────────────────────────────────────────────────────────────

BridgeSpec _typedDataRecordSpec() => BridgeSpec(
  dartClassName: 'DataModule',
  lib: 'data_module',
  namespace: 'data_module',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'data_module.native.dart',
  recordTypes: [
    BridgeRecordType(
      name: 'DataRecord',
      fields: [
        BridgeRecordField(
          name: 'bytes',
          dartType: 'Uint8List',
          kind: RecordFieldKind.typedData,
        ),
        BridgeRecordField(
          name: 'values',
          dartType: 'Int32List',
          kind: RecordFieldKind.typedData,
        ),
        BridgeRecordField(
          name: 'scores',
          dartType: 'Float64List',
          kind: RecordFieldKind.typedData,
        ),
        BridgeRecordField(
          name: 'label',
          dartType: 'String',
          kind: RecordFieldKind.primitive,
        ),
      ],
    ),
  ],
);

BridgeSpec _nullableTypedDataSpec() => BridgeSpec(
  dartClassName: 'NullableModule',
  lib: 'nullable_module',
  namespace: 'nullable_module',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'nullable_module.native.dart',
  recordTypes: [
    BridgeRecordType(
      name: 'NullableData',
      fields: [
        BridgeRecordField(
          name: 'optBytes',
          dartType: 'Uint8List?',
          kind: RecordFieldKind.typedData,
          isNullable: true,
        ),
        BridgeRecordField(
          name: 'optInts',
          dartType: 'Int16List?',
          kind: RecordFieldKind.typedData,
          isNullable: true,
        ),
      ],
    ),
  ],
);

BridgeSpec _allTypedDataSpec() => BridgeSpec(
  dartClassName: 'AllTyped',
  lib: 'all_typed',
  namespace: 'all_typed',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'all_typed.native.dart',
  recordTypes: [
    BridgeRecordType(
      name: 'AllTyped',
      fields: [
        BridgeRecordField(name: 'u8', dartType: 'Uint8List', kind: RecordFieldKind.typedData),
        BridgeRecordField(name: 'i8', dartType: 'Int8List', kind: RecordFieldKind.typedData),
        BridgeRecordField(name: 'i16', dartType: 'Int16List', kind: RecordFieldKind.typedData),
        BridgeRecordField(name: 'i32', dartType: 'Int32List', kind: RecordFieldKind.typedData),
        BridgeRecordField(name: 'i64', dartType: 'Int64List', kind: RecordFieldKind.typedData),
        BridgeRecordField(name: 'f32', dartType: 'Float32List', kind: RecordFieldKind.typedData),
        BridgeRecordField(name: 'f64', dartType: 'Float64List', kind: RecordFieldKind.typedData),
      ],
    ),
  ],
);

void main() {
  // ── Dart codec ─────────────────────────────────────────────────────────────
  group('RecordGenerator TypedData — Dart codec', () {
    late String dart;
    setUpAll(() => dart = RecordGenerator.generateDartExtensions(_typedDataRecordSpec()));

    test('extension is emitted for DataRecord', () {
      expect(dart, contains('extension DataRecordRecordExt on DataRecord'));
    });

    test('Uint8List field uses r.readBlob()', () {
      expect(dart, contains('bytes: r.readBlob()'));
    });

    test('Int32List field uses Int32List.view(r.readBlob().buffer)', () {
      expect(dart, contains('values: Int32List.view(r.readBlob().buffer)'));
    });

    test('Float64List field uses Float64List.view(r.readBlob().buffer)', () {
      expect(dart, contains('scores: Float64List.view(r.readBlob().buffer)'));
    });

    test('Uint8List field write uses writeBlob(bytes)', () {
      expect(dart, contains('writer.writeBlob(bytes)'));
    });

    test('Int32List field write uses writeBlob(values.buffer.asUint8List())', () {
      expect(dart, contains('writer.writeBlob(values.buffer.asUint8List())'));
    });

    test('Float64List field write uses writeBlob(scores.buffer.asUint8List())', () {
      expect(dart, contains('writer.writeBlob(scores.buffer.asUint8List())'));
    });

    test('String field still uses r.readString()', () {
      expect(dart, contains('label: r.readString()'));
    });
  });

  group('RecordGenerator TypedData — Dart codec all types', () {
    late String dart;
    setUpAll(() => dart = RecordGenerator.generateDartExtensions(_allTypedDataSpec()));

    test('Uint8List uses readBlob() directly', () {
      expect(dart, contains('u8: r.readBlob()'));
    });

    test('Int8List uses Int8List.view(r.readBlob().buffer)', () {
      expect(dart, contains('i8: Int8List.view(r.readBlob().buffer)'));
    });

    test('Int16List uses Int16List.view(r.readBlob().buffer)', () {
      expect(dart, contains('i16: Int16List.view(r.readBlob().buffer)'));
    });

    test('Int64List uses Int64List.view(r.readBlob().buffer)', () {
      expect(dart, contains('i64: Int64List.view(r.readBlob().buffer)'));
    });

    test('Float32List uses Float32List.view(r.readBlob().buffer)', () {
      expect(dart, contains('f32: Float32List.view(r.readBlob().buffer)'));
    });

    test('Uint8List write uses writeBlob(u8)', () {
      expect(dart, contains('writer.writeBlob(u8)'));
    });

    test('Int8List write uses buffer.asUint8List()', () {
      expect(dart, contains('writer.writeBlob(i8.buffer.asUint8List())'));
    });

    test('Float32List write uses buffer.asUint8List()', () {
      expect(dart, contains('writer.writeBlob(f32.buffer.asUint8List())'));
    });
  });

  group('RecordGenerator TypedData — Dart nullable', () {
    late String dart;
    setUpAll(() => dart = RecordGenerator.generateDartExtensions(_nullableTypedDataSpec()));

    test('nullable Uint8List uses readNullTag guard', () {
      expect(dart, contains('optBytes: r.readNullTag() ? null : r.readBlob()'));
    });

    test('nullable Int16List uses readNullTag guard', () {
      expect(dart, contains('optInts: r.readNullTag() ? null : Int16List.view(r.readBlob().buffer)'));
    });

    test('nullable Uint8List write emits writeNullTag', () {
      expect(dart, contains('writer.writeNullTag(optBytes == null)'));
    });

    test('nullable Int16List write emits writeNullTag', () {
      expect(dart, contains('writer.writeNullTag(optInts == null)'));
    });
  });

  // ── Kotlin codec ───────────────────────────────────────────────────────────
  group('RecordGenerator TypedData — Kotlin codec', () {
    late String kotlin;
    setUpAll(() => kotlin = RecordGenerator.generateKotlin(_typedDataRecordSpec()));

    test('Uint8List field maps to ByteArray in Kotlin', () {
      expect(kotlin, contains('val bytes: ByteArray'));
    });

    test('Int32List field maps to IntArray in Kotlin', () {
      expect(kotlin, contains('val values: IntArray'));
    });

    test('Float64List field maps to DoubleArray in Kotlin', () {
      expect(kotlin, contains('val scores: DoubleArray'));
    });

    test('Uint8List read uses buf.get(b) into ByteArray', () {
      expect(kotlin, contains('val bytes = { val _len = buf.int; val _b = ByteArray(_len); buf.get(_b); _b }()'));
    });

    test('Int32List read uses IntArray { buf.int }', () {
      expect(kotlin, contains('val values = { val _len = buf.int; IntArray(_len / 4) { buf.int } }()'));
    });

    test('Float64List read uses DoubleArray { buf.double }', () {
      expect(kotlin, contains('val scores = { val _len = buf.int; DoubleArray(_len / 8) { buf.double } }()'));
    });

    test('Uint8List write uses writeInt32 + out.write', () {
      expect(kotlin, contains('run { writeInt32(bytes.size); out.write(bytes) }'));
    });
  });

  group('RecordGenerator TypedData — Kotlin all types', () {
    late String kotlin;
    setUpAll(() => kotlin = RecordGenerator.generateKotlin(_allTypedDataSpec()));

    test('Uint8List → ByteArray', () {
      expect(kotlin, contains('val u8: ByteArray'));
    });

    test('Int8List → ByteArray', () {
      expect(kotlin, contains('val i8: ByteArray'));
    });

    test('Int16List → ShortArray', () {
      expect(kotlin, contains('val i16: ShortArray'));
    });

    test('Int32List → IntArray', () {
      expect(kotlin, contains('val i32: IntArray'));
    });

    test('Int64List → LongArray', () {
      expect(kotlin, contains('val i64: LongArray'));
    });

    test('Float32List → FloatArray', () {
      expect(kotlin, contains('val f32: FloatArray'));
    });

    test('Float64List → DoubleArray', () {
      expect(kotlin, contains('val f64: DoubleArray'));
    });

    test('Int16List read uses ShortArray { buf.short }', () {
      expect(kotlin, contains('ShortArray(_len / 2) { buf.short }'));
    });

    test('Int64List read uses LongArray { buf.long }', () {
      expect(kotlin, contains('LongArray(_len / 8) { buf.long }'));
    });

    test('Float32List read uses FloatArray { buf.float }', () {
      expect(kotlin, contains('FloatArray(_len / 4) { buf.float }'));
    });
  });

  group('RecordGenerator TypedData — Kotlin nullable', () {
    late String kotlin;
    setUpAll(() => kotlin = RecordGenerator.generateKotlin(_nullableTypedDataSpec()));

    test('nullable Uint8List → ByteArray? in Kotlin', () {
      expect(kotlin, contains('val optBytes: ByteArray?'));
    });

    test('nullable Int16List → ShortArray? in Kotlin', () {
      expect(kotlin, contains('val optInts: ShortArray?'));
    });

    test('nullable Uint8List write uses null check', () {
      expect(kotlin, contains('out.write(if (optBytes == null) 0 else 1)'));
    });
  });

  // ── Swift codec ────────────────────────────────────────────────────────────
  group('RecordGenerator TypedData — Swift codec', () {
    late String swift;
    setUpAll(() => swift = RecordGenerator.generateSwift(_typedDataRecordSpec(), emitBoilerplate: false));

    test('Uint8List field maps to Data in Swift', () {
      expect(swift, contains('public var bytes: Data'));
    });

    test('Int32List field maps to [Int32] in Swift', () {
      expect(swift, contains('public var values: [Int32]'));
    });

    test('Float64List field maps to [Double] in Swift', () {
      expect(swift, contains('public var scores: [Double]'));
    });

    test('Uint8List read uses r.readBlob()', () {
      expect(swift, contains('bytes: r.readBlob()'));
    });

    test('Int32List read uses bindMemory(to: Int32.self)', () {
      expect(swift, contains('bindMemory(to: Int32.self)'));
    });

    test('Float64List read uses bindMemory(to: Double.self)', () {
      expect(swift, contains('bindMemory(to: Double.self)'));
    });

    test('Uint8List write uses writer.writeBlob(bytes)', () {
      expect(swift, contains('writer.writeBlob(bytes)'));
    });

    test('Int32List write uses withUnsafeBufferPointer + writeBlob', () {
      expect(swift, contains('values.withUnsafeBufferPointer'));
      expect(swift, contains('writeBlob(Data(buffer:'));
    });
  });

  group('RecordGenerator TypedData — Swift all types', () {
    late String swift;
    setUpAll(() => swift = RecordGenerator.generateSwift(_allTypedDataSpec(), emitBoilerplate: false));

    test('Uint8List → Data', () {
      expect(swift, contains('public var u8: Data'));
    });

    test('Int8List → Data', () {
      expect(swift, contains('public var i8: Data'));
    });

    test('Int16List → [Int16]', () {
      expect(swift, contains('public var i16: [Int16]'));
    });

    test('Int32List → [Int32]', () {
      expect(swift, contains('public var i32: [Int32]'));
    });

    test('Int64List → [Int64]', () {
      expect(swift, contains('public var i64: [Int64]'));
    });

    test('Float32List → [Float]', () {
      expect(swift, contains('public var f32: [Float]'));
    });

    test('Float64List → [Double]', () {
      expect(swift, contains('public var f64: [Double]'));
    });

    test('Int16List read uses bindMemory(to: Int16.self)', () {
      expect(swift, contains('bindMemory(to: Int16.self)'));
    });

    test('Int64List read uses bindMemory(to: Int64.self)', () {
      expect(swift, contains('bindMemory(to: Int64.self)'));
    });

    test('Float32List read uses bindMemory(to: Float.self)', () {
      expect(swift, contains('bindMemory(to: Float.self)'));
    });
  });

  group('RecordGenerator TypedData — Swift nullable', () {
    late String swift;
    setUpAll(() => swift = RecordGenerator.generateSwift(_nullableTypedDataSpec(), emitBoilerplate: false));

    test('nullable Uint8List → Data? in Swift', () {
      expect(swift, contains('public var optBytes: Data?'));
    });

    test('nullable Int16List → [Int16]? in Swift', () {
      expect(swift, contains('public var optInts: [Int16]?'));
    });

    test('nullable Uint8List uses readNullTag in Swift', () {
      expect(swift, contains('r.readNullTag() ? nil : r.readBlob()'));
    });

    test('nullable Uint8List write uses writeNullTag in Swift', () {
      expect(swift, contains('writer.writeNullTag(optBytes == nil)'));
    });
  });

  // ── C++ codec ──────────────────────────────────────────────────────────────
  group('RecordGenerator TypedData — C++ codec', () {
    late String cpp;
    setUpAll(() => cpp = RecordGenerator.generateCpp(_typedDataRecordSpec()));

    test('Uint8List field maps to std::vector<uint8_t>', () {
      expect(cpp, contains('std::vector<uint8_t> bytes'));
    });

    test('Int32List field maps to std::vector<uint8_t> (raw bytes)', () {
      expect(cpp, contains('std::vector<uint8_t> values'));
    });

    test('Float64List field maps to std::vector<uint8_t> (raw bytes)', () {
      expect(cpp, contains('std::vector<uint8_t> scores'));
    });

    test('C++ reader has readBytes method', () {
      expect(cpp, contains('void readBytes(uint8_t* dst, size_t n)'));
    });

    test('bytes field read uses readBytes', () {
      expect(cpp, contains('_r.readBytes(_obj.bytes.data()'));
    });
  });

  group('RecordGenerator TypedData — C++ nullable', () {
    late String cpp;
    setUpAll(() => cpp = RecordGenerator.generateCpp(_nullableTypedDataSpec()));

    test('nullable Uint8List → std::optional<std::vector<uint8_t>>', () {
      expect(cpp, contains('std::optional<std::vector<uint8_t>> optBytes'));
    });

    test('nullable field read uses readNullTag', () {
      expect(cpp, contains('_r.readNullTag()'));
    });
  });
}
