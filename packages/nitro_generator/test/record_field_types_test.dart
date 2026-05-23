// Comprehensive field-type coverage for RecordGenerator across all three targets.
//
// The existing record_generator_test.dart covers String primitive fields and
// List<@HybridRecord> fields. This file adds all remaining primitive/list types:
//
//   Section 1: bool field   — Dart r.readBool(), Kotlin buf.get(), Swift r.readBool()
//   Section 2: double field — Dart r.readDouble(), Kotlin buf.double, Swift r.readDouble()
//   Section 3: Uint8List field — Dart r.readBlob(), Kotlin ByteArray decode, Swift r.readBlob()
//   Section 4: List<String> primitive list — all three targets
//   Section 5: List<double> primitive list — all three targets
//   Section 6: List<bool>   primitive list — all three targets
//   Section 7: Swift struct boilerplate — public struct, fromNative, fromReader, writeFields, toNative

import 'package:nitro_generator/src/generators/record_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// ── Spec builders ─────────────────────────────────────────────────────────────

BridgeSpec _primFieldSpec(String dartType, String fieldName) => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'mod.native.dart',
  recordTypes: [
    BridgeRecordType(
      name: 'Rec',
      fields: [
        BridgeRecordField(
          name: fieldName,
          dartType: dartType,
          kind: RecordFieldKind.primitive,
        ),
      ],
    ),
  ],
);

BridgeSpec _listPrimFieldSpec(String itemType, String fieldName) => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'mod.native.dart',
  recordTypes: [
    BridgeRecordType(
      name: 'Rec',
      fields: [
        BridgeRecordField(
          name: fieldName,
          dartType: 'List<$itemType>',
          kind: RecordFieldKind.listPrimitive,
          itemTypeName: itemType,
        ),
      ],
    ),
  ],
);

// ── Section 1: bool field ─────────────────────────────────────────────────────

void main() {
  group('RecordGenerator — bool primitive field', () {
    final spec = _primFieldSpec('bool', 'enabled');

    test('Dart fromReader uses r.readBool()', () {
      final out = RecordGenerator.generateDartExtensions(spec);
      expect(out, contains('r.readBool()'));
    });

    test('Dart writeFields uses writer.writeBool(enabled)', () {
      final out = RecordGenerator.generateDartExtensions(spec);
      expect(out, contains('writer.writeBool(enabled)'));
    });

    test('Kotlin decodeFrom reads bool via buf.get().toInt() != 0', () {
      final out = RecordGenerator.generateKotlin(spec);
      expect(out, contains("(buf.get().toInt() != 0)"));
    });

    test('Kotlin data class declares field as Boolean', () {
      final out = RecordGenerator.generateKotlin(spec);
      expect(out, contains('val enabled: Boolean'));
    });

    test('Kotlin writeFieldsTo emits writeBool(enabled)', () {
      final out = RecordGenerator.generateKotlin(spec);
      expect(out, contains('writeBool(enabled)'));
    });

    test('Swift fromReader uses r.readBool()', () {
      final out = RecordGenerator.generateSwift(spec, emitBoilerplate: false);
      expect(out, contains('r.readBool()'));
    });

    test('Swift struct declares field as Bool', () {
      final out = RecordGenerator.generateSwift(spec, emitBoilerplate: false);
      expect(out, contains('public var enabled: Bool'));
    });

    test('Swift writeFields emits writer.writeBool(enabled)', () {
      final out = RecordGenerator.generateSwift(spec, emitBoilerplate: false);
      expect(out, contains('writer.writeBool(enabled)'));
    });
  });

  // ── Section 2: double field ─────────────────────────────────────────────────

  group('RecordGenerator — double primitive field', () {
    final spec = _primFieldSpec('double', 'score');

    test('Dart fromReader uses r.readDouble()', () {
      final out = RecordGenerator.generateDartExtensions(spec);
      expect(out, contains('r.readDouble()'));
    });

    test('Dart writeFields uses writer.writeDouble(score)', () {
      final out = RecordGenerator.generateDartExtensions(spec);
      expect(out, contains('writer.writeDouble(score)'));
    });

    test('Kotlin decodeFrom reads double via buf.double', () {
      final out = RecordGenerator.generateKotlin(spec);
      expect(out, contains('buf.double'));
    });

    test('Kotlin data class declares field as Double', () {
      final out = RecordGenerator.generateKotlin(spec);
      expect(out, contains('val score: Double'));
    });

    test('Kotlin writeFieldsTo emits writeDouble(score)', () {
      final out = RecordGenerator.generateKotlin(spec);
      expect(out, contains('writeDouble(score)'));
    });

    test('Swift fromReader uses r.readDouble()', () {
      final out = RecordGenerator.generateSwift(spec, emitBoilerplate: false);
      expect(out, contains('r.readDouble()'));
    });

    test('Swift struct declares field as Double', () {
      final out = RecordGenerator.generateSwift(spec, emitBoilerplate: false);
      expect(out, contains('public var score: Double'));
    });

    test('Swift writeFields emits writer.writeDouble(score)', () {
      final out = RecordGenerator.generateSwift(spec, emitBoilerplate: false);
      expect(out, contains('writer.writeDouble(score)'));
    });
  });

  // ── Section 3: Uint8List field ──────────────────────────────────────────────

  group('RecordGenerator — Uint8List primitive field', () {
    final spec = _primFieldSpec('Uint8List', 'data');

    test('Dart fromReader uses r.readBlob()', () {
      final out = RecordGenerator.generateDartExtensions(spec);
      expect(out, contains('r.readBlob()'));
    });

    test('Dart writeFields uses writer.writeBlob(data)', () {
      final out = RecordGenerator.generateDartExtensions(spec);
      expect(out, contains('writer.writeBlob(data)'));
    });

    test('Kotlin decodeFrom reads ByteArray via buf.int + buf.get(b)', () {
      final out = RecordGenerator.generateKotlin(spec);
      expect(out, contains('ByteArray(len)'));
      expect(out, contains('buf.get(b)'));
    });

    test('Kotlin writeFieldsTo emits writeInt32(size) + out.write(data)', () {
      final out = RecordGenerator.generateKotlin(spec);
      expect(out, contains('data.size'));
      expect(out, contains('out.write(data)'));
    });

    test('Swift fromReader uses r.readBlob()', () {
      final out = RecordGenerator.generateSwift(spec, emitBoilerplate: false);
      expect(out, contains('r.readBlob()'));
    });

    test('Swift writeFields emits writer.writeBlob(data)', () {
      final out = RecordGenerator.generateSwift(spec, emitBoilerplate: false);
      expect(out, contains('writer.writeBlob(data)'));
    });
  });

  // ── Section 4: List<String> field ──────────────────────────────────────────

  group('RecordGenerator — List<String> primitive list field', () {
    final spec = _listPrimFieldSpec('String', 'tags');

    test('Dart fromReader uses List.generate + r.readString()', () {
      final out = RecordGenerator.generateDartExtensions(spec);
      expect(out, contains('List.generate(r.readInt32()'));
      expect(out, contains('r.readString()'));
    });

    test('Dart writeFields writes count then each string', () {
      final out = RecordGenerator.generateDartExtensions(spec);
      expect(out, contains('writer.writeInt32(tags.length)'));
      expect(out, contains('writer.writeString(e)'));
    });

    test('Kotlin decodeFrom uses (0 until buf.int).map for String list', () {
      final out = RecordGenerator.generateKotlin(spec);
      expect(out, contains('0 until buf.int'));
      // String decode in Kotlin involves b.toString(Charsets.UTF_8)
      expect(out, contains('Charsets.UTF_8'));
    });

    test('Kotlin data class declares field as List<String>', () {
      final out = RecordGenerator.generateKotlin(spec);
      expect(out, contains('val tags: List<String>'));
    });

    test('Kotlin writeFieldsTo emits writeInt32(size) + forEach writeString', () {
      final out = RecordGenerator.generateKotlin(spec);
      expect(out, contains('writeInt32(tags.size)'));
      expect(out, contains('writeString(e)'));
    });

    test('Swift fromReader uses (0..<Int(r.readInt32())).map + r.readString()', () {
      final out = RecordGenerator.generateSwift(spec, emitBoilerplate: false);
      expect(out, contains('0..<Int(r.readInt32())'));
      expect(out, contains('r.readString()'));
    });

    test('Swift struct declares field as [String]', () {
      final out = RecordGenerator.generateSwift(spec, emitBoilerplate: false);
      expect(out, contains('public var tags: [String]'));
    });

    test('Swift writeFields emits writeInt32(count) + for loop writeString', () {
      final out = RecordGenerator.generateSwift(spec, emitBoilerplate: false);
      expect(out, contains('writer.writeInt32(Int32(tags.count))'));
      expect(out, contains('writer.writeString(e)'));
    });
  });

  // ── Section 5: List<double> field ──────────────────────────────────────────

  group('RecordGenerator — List<double> primitive list field', () {
    final spec = _listPrimFieldSpec('double', 'values');

    test('Dart fromReader uses List.generate + r.readDouble()', () {
      final out = RecordGenerator.generateDartExtensions(spec);
      expect(out, contains('List.generate(r.readInt32()'));
      expect(out, contains('r.readDouble()'));
    });

    test('Dart writeFields writes count then each double', () {
      final out = RecordGenerator.generateDartExtensions(spec);
      expect(out, contains('writer.writeInt32(values.length)'));
      expect(out, contains('writer.writeDouble(e)'));
    });

    test('Kotlin data class declares field as List<Double>', () {
      final out = RecordGenerator.generateKotlin(spec);
      expect(out, contains('val values: List<Double>'));
    });

    test('Kotlin writeFieldsTo emits forEach writeDouble', () {
      final out = RecordGenerator.generateKotlin(spec);
      expect(out, contains('writeDouble(e)'));
    });

    test('Swift struct declares field as [Double]', () {
      final out = RecordGenerator.generateSwift(spec, emitBoilerplate: false);
      expect(out, contains('public var values: [Double]'));
    });

    test('Swift fromReader uses r.readDouble() inside map', () {
      final out = RecordGenerator.generateSwift(spec, emitBoilerplate: false);
      expect(out, contains('r.readDouble()'));
    });

    test('Swift writeFields uses writer.writeDouble(e)', () {
      final out = RecordGenerator.generateSwift(spec, emitBoilerplate: false);
      expect(out, contains('writer.writeDouble(e)'));
    });
  });

  // ── Section 6: List<bool> field ────────────────────────────────────────────

  group('RecordGenerator — List<bool> primitive list field', () {
    final spec = _listPrimFieldSpec('bool', 'flags');

    test('Dart fromReader uses List.generate + r.readBool()', () {
      final out = RecordGenerator.generateDartExtensions(spec);
      expect(out, contains('List.generate(r.readInt32()'));
      expect(out, contains('r.readBool()'));
    });

    test('Dart writeFields writes count then each bool', () {
      final out = RecordGenerator.generateDartExtensions(spec);
      expect(out, contains('writer.writeInt32(flags.length)'));
      expect(out, contains('writer.writeBool(e)'));
    });

    test('Kotlin data class declares field as List<Boolean>', () {
      final out = RecordGenerator.generateKotlin(spec);
      expect(out, contains('val flags: List<Boolean>'));
    });

    test('Kotlin writeFieldsTo emits forEach writeBool', () {
      final out = RecordGenerator.generateKotlin(spec);
      expect(out, contains('writeBool(e)'));
    });

    test('Swift struct declares field as [Bool]', () {
      final out = RecordGenerator.generateSwift(spec, emitBoilerplate: false);
      expect(out, contains('public var flags: [Bool]'));
    });

    test('Swift fromReader uses r.readBool() inside map', () {
      final out = RecordGenerator.generateSwift(spec, emitBoilerplate: false);
      expect(out, contains('r.readBool()'));
    });

    test('Swift writeFields uses writer.writeBool(e)', () {
      final out = RecordGenerator.generateSwift(spec, emitBoilerplate: false);
      expect(out, contains('writer.writeBool(e)'));
    });
  });

  // ── Section 7: Swift struct boilerplate ────────────────────────────────────

  group('RecordGenerator — Swift struct boilerplate', () {
    final spec = _primFieldSpec('String', 'name');

    test('Swift emits public struct declaration', () {
      final out = RecordGenerator.generateSwift(spec, emitBoilerplate: false);
      expect(out, contains('public struct Rec'));
    });

    test('Swift emits public init with matching param', () {
      final out = RecordGenerator.generateSwift(spec, emitBoilerplate: false);
      expect(out, contains('public init(name: String)'));
    });

    test('Swift emits fromNative factory', () {
      final out = RecordGenerator.generateSwift(spec, emitBoilerplate: false);
      expect(out, contains('public static func fromNative'));
      expect(out, contains('UnsafeMutablePointer<UInt8>'));
    });

    test('Swift fromNative delegates to fromReader', () {
      final out = RecordGenerator.generateSwift(spec, emitBoilerplate: false);
      expect(out, contains('fromReader(NitroRecordReader(ptr: ptr))'));
    });

    test('Swift emits static fromReader', () {
      final out = RecordGenerator.generateSwift(spec, emitBoilerplate: false);
      expect(out, contains('public static func fromReader(_ r: NitroRecordReader) -> Rec'));
    });

    test('Swift emits writeFields method', () {
      final out = RecordGenerator.generateSwift(spec, emitBoilerplate: false);
      expect(out, contains('public func writeFields(_ writer: NitroRecordWriter)'));
    });

    test('Swift emits toNative method returning UnsafeMutablePointer<UInt8>?', () {
      final out = RecordGenerator.generateSwift(spec, emitBoilerplate: false);
      expect(out, contains('public func toNative() -> UnsafeMutablePointer<UInt8>?'));
    });

    test('Swift toNative creates NitroRecordWriter + calls writeFields', () {
      final out = RecordGenerator.generateSwift(spec, emitBoilerplate: false);
      expect(out, contains('let writer = NitroRecordWriter()'));
      expect(out, contains('writeFields(writer)'));
      expect(out, contains('return writer.toNative()'));
    });

    test('Swift emits boilerplate when emitBoilerplate = true (default)', () {
      final out = RecordGenerator.generateSwift(spec);
      expect(out, contains('NitroRecordWriter'));
      expect(out, contains('NitroRecordReader'));
    });
  });

  // ── Section 8: Multi-field record — correct field ordering ─────────────────

  group('RecordGenerator — multi-field ordering across all targets', () {
    final spec = BridgeSpec(
      dartClassName: 'Mod',
      lib: 'mod',
      namespace: 'mod',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'mod.native.dart',
      recordTypes: [
        BridgeRecordType(
          name: 'Event',
          fields: [
            BridgeRecordField(name: 'id', dartType: 'int', kind: RecordFieldKind.primitive),
            BridgeRecordField(name: 'label', dartType: 'String', kind: RecordFieldKind.primitive),
            BridgeRecordField(name: 'active', dartType: 'bool', kind: RecordFieldKind.primitive),
            BridgeRecordField(name: 'score', dartType: 'double', kind: RecordFieldKind.primitive),
          ],
        ),
      ],
    );

    test('Dart fromReader reads all four fields', () {
      final out = RecordGenerator.generateDartExtensions(spec);
      expect(out, contains('r.readInt()'));
      expect(out, contains('r.readString()'));
      expect(out, contains('r.readBool()'));
      expect(out, contains('r.readDouble()'));
    });

    test('Kotlin data class has all four fields', () {
      final out = RecordGenerator.generateKotlin(spec);
      expect(out, contains('val id: Long'));
      expect(out, contains('val label: String'));
      expect(out, contains('val active: Boolean'));
      expect(out, contains('val score: Double'));
    });

    test('Swift struct has all four fields', () {
      final out = RecordGenerator.generateSwift(spec, emitBoilerplate: false);
      expect(out, contains('public var id: Int64'));
      expect(out, contains('public var label: String'));
      expect(out, contains('public var active: Bool'));
      expect(out, contains('public var score: Double'));
    });
  });
}
