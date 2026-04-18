// Tests for @HybridStruct types used as fields inside @HybridRecord types.
//
// Covers:
//   1. Dart RecordExt generated for @HybridStruct items in record list fields
//   2. Kotlin struct codec (decodeFrom / writeFieldsTo / encode) on struct class
//   3. Kotlin record correctly uses struct.decodeFrom / struct.writeFieldsTo
//   4. Transitive closure: nested structs inside referenced structs get RecordExt
//   5. recordObject (non-list) struct field in record
//   6. Wire format consistency: Kotlin list write/read uses count-then-items (no indexed offsets)
//   7. Struct codec handles all primitive types (int, double, bool, String, enum, nested struct)

import 'package:nitro_generator/src/generators/record_generator.dart';
import 'package:nitro_generator/src/generators/struct_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// ── Shared spec builders ──────────────────────────────────────────────────────

/// Spec for `PackageBoxes { List<BoundingBox> boxes }` where
/// `BoundingBox` is a @HybridStruct with four double fields.
BridgeSpec _boxesSpec() => BridgeSpec(
  dartClassName: 'ArModule',
  lib: 'ar_module',
  namespace: 'ar_module',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'ar_module.native.dart',
  structs: [
    BridgeStruct(
      name: 'BoundingBox',
      packed: false,
      fields: [
        BridgeField(name: 'x', type: BridgeType(name: 'double')),
        BridgeField(name: 'y', type: BridgeType(name: 'double')),
        BridgeField(name: 'w', type: BridgeType(name: 'double')),
        BridgeField(name: 'h', type: BridgeType(name: 'double')),
      ],
    ),
  ],
  recordTypes: [
    BridgeRecordType(
      name: 'PackageBoxes',
      fields: [
        BridgeRecordField(
          name: 'boxes',
          dartType: 'List<BoundingBox>',
          kind: RecordFieldKind.listRecordObject,
          itemTypeName: 'BoundingBox',
        ),
      ],
    ),
  ],
  functions: [],
);

/// Spec where a record holds a single (non-list) struct field.
BridgeSpec _singleStructFieldSpec() => BridgeSpec(
  dartClassName: 'GeoModule',
  lib: 'geo_module',
  namespace: 'geo_module',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'geo_module.native.dart',
  structs: [
    BridgeStruct(
      name: 'Point3D',
      packed: false,
      fields: [
        BridgeField(name: 'x', type: BridgeType(name: 'double')),
        BridgeField(name: 'y', type: BridgeType(name: 'double')),
        BridgeField(name: 'z', type: BridgeType(name: 'double')),
      ],
    ),
  ],
  recordTypes: [
    BridgeRecordType(
      name: 'GeoResult',
      fields: [
        BridgeRecordField(
          name: 'origin',
          dartType: 'Point3D',
          kind: RecordFieldKind.recordObject,
          itemTypeName: 'Point3D',
        ),
        BridgeRecordField(
          name: 'confidence',
          dartType: 'double',
          kind: RecordFieldKind.primitive,
        ),
      ],
    ),
  ],
  functions: [],
);

/// Spec with a deep nesting: `Segment` record has `List<Line>` field,
/// `Line` struct has two `Vec2` struct fields (transitive closure test).
BridgeSpec _transitiveNestedSpec() => BridgeSpec(
  dartClassName: 'ShapeModule',
  lib: 'shape_module',
  namespace: 'shape_module',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'shape_module.native.dart',
  structs: [
    BridgeStruct(
      name: 'Vec2',
      packed: false,
      fields: [
        BridgeField(name: 'x', type: BridgeType(name: 'double')),
        BridgeField(name: 'y', type: BridgeType(name: 'double')),
      ],
    ),
    BridgeStruct(
      name: 'Line',
      packed: false,
      fields: [
        BridgeField(name: 'start', type: BridgeType(name: 'Vec2')),
        BridgeField(name: 'end',   type: BridgeType(name: 'Vec2')),
      ],
    ),
  ],
  recordTypes: [
    BridgeRecordType(
      name: 'Segment',
      fields: [
        BridgeRecordField(
          name: 'lines',
          dartType: 'List<Line>',
          kind: RecordFieldKind.listRecordObject,
          itemTypeName: 'Line',
        ),
      ],
    ),
  ],
  functions: [],
);

/// Spec where the struct has all primitive field types.
BridgeSpec _allPrimitiveFieldsSpec() => BridgeSpec(
  dartClassName: 'AllTypesModule',
  lib: 'all_types',
  namespace: 'all_types',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'all_types.native.dart',
  structs: [
    BridgeStruct(
      name: 'AllTypes',
      packed: false,
      fields: [
        BridgeField(name: 'n',  type: BridgeType(name: 'int')),
        BridgeField(name: 'd',  type: BridgeType(name: 'double')),
        BridgeField(name: 'ok', type: BridgeType(name: 'bool')),
        BridgeField(name: 's',  type: BridgeType(name: 'String')),
      ],
    ),
  ],
  recordTypes: [
    BridgeRecordType(
      name: 'Wrapper',
      fields: [
        BridgeRecordField(
          name: 'item',
          dartType: 'AllTypes',
          kind: RecordFieldKind.recordObject,
          itemTypeName: 'AllTypes',
        ),
      ],
    ),
  ],
  functions: [],
);

// ─────────────────────────────────────────────────────────────────────────────

void main() {
  // ── 1. Dart RecordExt for @HybridStruct list items ───────────────────────────

  group('Dart RecordExt generated for struct referenced in record list field', () {
    late String dart;

    setUp(() {
      dart = RecordGenerator.generateDartExtensions(_boxesSpec());
    });

    test('BoundingBoxRecordExt extension is emitted', () {
      expect(dart, contains('extension BoundingBoxRecordExt on BoundingBox'));
    });

    test('fromNative delegates to fromReader', () {
      expect(dart, contains('static BoundingBox fromNative(Pointer<Uint8> ptr)'));
      expect(dart, contains('fromReader(RecordReader.fromNative(ptr))'));
    });

    test('fromReader constructs BoundingBox from r.readDouble() for each field', () {
      expect(dart, contains('static BoundingBox fromReader(RecordReader r)'));
      expect(dart, contains('BoundingBox('));
      final fromReaderIdx = dart.indexOf('static BoundingBox fromReader');
      final block = dart.substring(fromReaderIdx, dart.indexOf('}', fromReaderIdx + 1) + 1);
      expect(block, contains('r.readDouble()'));
    });

    test('writeFields emits writer.writeDouble for each double field', () {
      expect(dart, contains('void writeFields(RecordWriter writer)'));
      final writeIdx = dart.indexOf('void writeFields(RecordWriter writer)');
      final block = dart.substring(writeIdx, dart.indexOf('}', writeIdx + 1) + 1);
      expect(block, contains('writer.writeDouble(x)'));
      expect(block, contains('writer.writeDouble(y)'));
      expect(block, contains('writer.writeDouble(w)'));
      expect(block, contains('writer.writeDouble(h)'));
    });

    test('toNative allocates via RecordWriter', () {
      expect(dart, contains('Pointer<Uint8> toNative(Allocator alloc)'));
      expect(dart, contains('final writer = RecordWriter()'));
      expect(dart, contains('writeFields(writer)'));
      expect(dart, contains('return writer.toNative(alloc)'));
    });

    test('PackageBoxesRecordExt is also emitted (for the record type)', () {
      expect(dart, contains('extension PackageBoxesRecordExt on PackageBoxes'));
    });

    test('PackageBoxes.fromReader calls BoundingBoxRecordExt.fromReader for each item', () {
      expect(dart, contains('BoundingBoxRecordExt.fromReader(r)'));
    });

    test('PackageBoxes.writeFields calls e.writeFields(writer) for each item in list', () {
      expect(dart, contains('e.writeFields(writer)'));
    });

    test('PackageBoxes.writeFields writes list count via writeInt32', () {
      final writeIdx = dart.lastIndexOf('void writeFields(RecordWriter writer)');
      final block = dart.substring(writeIdx, dart.indexOf('}', writeIdx + 1) + 1);
      expect(block, contains('writer.writeInt32(boxes.length)'));
    });
  });

  // ── 2. Kotlin struct codec methods ───────────────────────────────────────────

  group('Kotlin struct data class has decodeFrom / writeFieldsTo / encode', () {
    late String kotlin;

    setUp(() {
      kotlin = StructGenerator.generateKotlin(_boxesSpec());
    });

    test('@androidx.annotation.Keep annotation is present', () {
      expect(kotlin, contains('@androidx.annotation.Keep'));
    });

    test('data class constructor params are preserved', () {
      expect(kotlin, contains('val x: Double'));
      expect(kotlin, contains('val y: Double'));
      expect(kotlin, contains('val w: Double'));
      expect(kotlin, contains('val h: Double'));
    });

    test('companion object with decodeFrom is generated', () {
      expect(kotlin, contains('companion object {'));
      expect(kotlin, contains('@JvmStatic fun decodeFrom(buf: java.nio.ByteBuffer): BoundingBox'));
    });

    test('decodeFrom reads each double field from buf.double', () {
      final decodeIdx = kotlin.indexOf('fun decodeFrom(buf: java.nio.ByteBuffer): BoundingBox');
      final block = kotlin.substring(decodeIdx, kotlin.indexOf('}', decodeIdx + 1) + 1);
      expect(block, contains('val x = buf.double'));
      expect(block, contains('val y = buf.double'));
      expect(block, contains('val w = buf.double'));
      expect(block, contains('val h = buf.double'));
    });

    test('decodeFrom returns BoundingBox with all fields', () {
      expect(kotlin, contains('return BoundingBox(x, y, w, h)'));
    });

    test('companion object with decode(bytes) is generated', () {
      expect(kotlin, contains('@JvmStatic fun decode(bytes: ByteArray): BoundingBox'));
      expect(kotlin, contains('java.nio.ByteBuffer.wrap(bytes)'));
    });

    test('writeFieldsTo method is generated', () {
      expect(kotlin, contains('fun writeFieldsTo(out: java.io.ByteArrayOutputStream, buf: java.nio.ByteBuffer)'));
    });

    test('writeFieldsTo defines writeDouble local helper', () {
      final writeIdx = kotlin.indexOf('fun writeFieldsTo(out: java.io.ByteArrayOutputStream');
      final block = kotlin.substring(writeIdx, kotlin.indexOf('\n    }', writeIdx) + 6);
      expect(block, contains('fun writeDouble(v: Double)'));
    });

    test('writeFieldsTo writes each double field', () {
      final writeIdx = kotlin.indexOf('fun writeFieldsTo(out: java.io.ByteArrayOutputStream');
      final block = kotlin.substring(writeIdx, kotlin.indexOf('\n    }', writeIdx) + 6);
      expect(block, contains('writeDouble(x)'));
      expect(block, contains('writeDouble(y)'));
      expect(block, contains('writeDouble(w)'));
      expect(block, contains('writeDouble(h)'));
    });

    test('encode() method is generated', () {
      expect(kotlin, contains('fun encode(): ByteArray'));
      expect(kotlin, contains('writeFieldsTo(out, buf)'));
      expect(kotlin, contains('return out.toByteArray()'));
    });
  });

  // ── 3. Kotlin record uses struct codec in list field ─────────────────────────

  group('Kotlin record uses struct.decodeFrom and struct.writeFieldsTo for list', () {
    late String kotlin;

    setUp(() {
      kotlin = RecordGenerator.generateKotlin(_boxesSpec());
    });

    test('PackageBoxes data class is generated', () {
      expect(kotlin, contains('data class PackageBoxes('));
      expect(kotlin, contains('val boxes: List<BoundingBox>'));
    });

    test('decodeFrom reads list via (0 until buf.int).map { BoundingBox.decodeFrom(buf) }', () {
      expect(kotlin, contains('BoundingBox.decodeFrom(buf)'));
      // Non-indexed read: count-then-items, no offset skip
      expect(kotlin, contains('(0 until buf.int).map { BoundingBox.decodeFrom(buf) }'));
    });

    test('writeFieldsTo writes list count then iterates items with e.writeFieldsTo', () {
      expect(kotlin, contains('writeInt32(boxes.size)'));
      expect(kotlin, contains('boxes.forEach { e -> e.writeFieldsTo(out, buf) }'));
    });

    test('Kotlin list write does NOT use the broken writeIndexedList helper', () {
      expect(kotlin, isNot(contains('writeIndexedList')));
    });

    test('Kotlin list read does NOT skip longs as offset table', () {
      // The broken pattern was: { val _cnt = buf.int; repeat(_cnt) { buf.long }; ... }
      expect(kotlin, isNot(contains('repeat(_cnt) { buf.long }')));
    });
  });

  // ── 4. Transitive nested structs ─────────────────────────────────────────────

  group('Transitive closure: nested structs inside referenced structs get RecordExt', () {
    late String dart;

    setUp(() {
      dart = RecordGenerator.generateDartExtensions(_transitiveNestedSpec());
    });

    test('LineRecordExt is emitted (directly referenced in record)', () {
      expect(dart, contains('extension LineRecordExt on Line'));
    });

    test('Vec2RecordExt is emitted (transitively referenced via Line)', () {
      expect(dart, contains('extension Vec2RecordExt on Vec2'));
    });

    test('Vec2RecordExt.fromReader reads x and y as doubles', () {
      final idx = dart.indexOf('extension Vec2RecordExt');
      final fromReaderIdx = dart.indexOf('static Vec2 fromReader', idx);
      final block = dart.substring(fromReaderIdx, dart.indexOf('}', fromReaderIdx + 1) + 1);
      expect(block, contains('r.readDouble()'));
    });

    test('LineRecordExt.fromReader calls Vec2RecordExt.fromReader for nested fields', () {
      final idx = dart.indexOf('extension LineRecordExt');
      final fromReaderIdx = dart.indexOf('static Line fromReader', idx);
      final block = dart.substring(fromReaderIdx, dart.indexOf('}', fromReaderIdx + 1) + 1);
      expect(block, contains('Vec2RecordExt.fromReader(r)'));
    });

    test('LineRecordExt.writeFields calls start.writeFields and end.writeFields', () {
      final idx = dart.indexOf('extension LineRecordExt');
      final writeIdx = dart.indexOf('void writeFields(RecordWriter writer)', idx);
      final block = dart.substring(writeIdx, dart.indexOf('}', writeIdx + 1) + 1);
      expect(block, contains('start.writeFields(writer)'));
      expect(block, contains('end.writeFields(writer)'));
    });
  });

  // ── 5. recordObject (non-list) struct field in record ────────────────────────

  group('recordObject struct field in record', () {
    late String dart;
    late String kotlin;

    setUp(() {
      dart   = RecordGenerator.generateDartExtensions(_singleStructFieldSpec());
      kotlin = RecordGenerator.generateKotlin(_singleStructFieldSpec());
    });

    test('Point3DRecordExt is emitted', () {
      expect(dart, contains('extension Point3DRecordExt on Point3D'));
    });

    test('GeoResultRecordExt.fromReader calls Point3DRecordExt.fromReader for origin', () {
      expect(dart, contains('origin: Point3DRecordExt.fromReader(r)'));
    });

    test('GeoResultRecordExt.writeFields calls origin.writeFields', () {
      final writeIdx = dart.lastIndexOf('void writeFields(RecordWriter writer)');
      final block = dart.substring(writeIdx, dart.indexOf('}', writeIdx + 1) + 1);
      expect(block, contains('origin.writeFields(writer)'));
    });

    test('Kotlin GeoResult uses Point3D.decodeFrom(buf) for origin', () {
      expect(kotlin, contains('Point3D.decodeFrom(buf)'));
    });

    test('Kotlin GeoResult.writeFieldsTo calls origin.writeFieldsTo', () {
      expect(kotlin, contains('origin.writeFieldsTo(out, buf)'));
    });
  });

  // ── 6. Kotlin struct codec: all primitive field types ────────────────────────

  group('Kotlin struct codec for all primitive field types', () {
    late String kotlin;

    setUp(() {
      kotlin = StructGenerator.generateKotlin(_allPrimitiveFieldsSpec());
    });

    test('int field: decodeFrom reads buf.long', () {
      expect(kotlin, contains('val n = buf.long'));
    });

    test('double field: decodeFrom reads buf.double', () {
      expect(kotlin, contains('val d = buf.double'));
    });

    test('bool field: decodeFrom reads buf.get().toInt() != 0', () {
      expect(kotlin, contains('val ok = (buf.get().toInt() != 0)'));
    });

    test('String field: decodeFrom reads length then bytes', () {
      expect(kotlin, contains('val s = { val len = buf.int'));
      expect(kotlin, contains('b.toString(Charsets.UTF_8)'));
    });

    test('int field: writeFieldsTo calls writeInt(n)', () {
      final writeIdx = kotlin.indexOf('fun writeFieldsTo(out: java.io.ByteArrayOutputStream');
      final block = kotlin.substring(writeIdx, kotlin.indexOf('\n    }', writeIdx) + 6);
      expect(block, contains('writeInt(n)'));
    });

    test('double field: writeFieldsTo calls writeDouble(d)', () {
      final writeIdx = kotlin.indexOf('fun writeFieldsTo(out: java.io.ByteArrayOutputStream');
      final block = kotlin.substring(writeIdx, kotlin.indexOf('\n    }', writeIdx) + 6);
      expect(block, contains('writeDouble(d)'));
    });

    test('bool field: writeFieldsTo calls writeBool(ok)', () {
      final writeIdx = kotlin.indexOf('fun writeFieldsTo(out: java.io.ByteArrayOutputStream');
      final block = kotlin.substring(writeIdx, kotlin.indexOf('\n    }', writeIdx) + 6);
      expect(block, contains('writeBool(ok)'));
    });

    test('String field: writeFieldsTo calls writeString(s)', () {
      final writeIdx = kotlin.indexOf('fun writeFieldsTo(out: java.io.ByteArrayOutputStream');
      final block = kotlin.substring(writeIdx, kotlin.indexOf('\n    }', writeIdx) + 6);
      expect(block, contains('writeString(s)'));
    });
  });

  // ── 7. Kotlin record list field wire format (no broken offset table) ─────────

  group('Kotlin record list field wire format consistency', () {
    late String kotlin;

    setUp(() {
      kotlin = RecordGenerator.generateKotlin(recordListSpec());
    });

    test('listRecordObject write uses writeInt32(size) + forEach', () {
      expect(kotlin, contains('writeInt32(resolutions.size)'));
      expect(kotlin, contains('resolutions.forEach { e -> e.writeFieldsTo(out, buf) }'));
    });

    test('listRecordObject read uses (0 until buf.int).map', () {
      expect(kotlin, contains('(0 until buf.int).map { Resolution.decodeFrom(buf) }'));
    });

    test('no writeIndexedList in generated Kotlin (format is count-then-items)', () {
      expect(kotlin, isNot(contains('writeIndexedList')));
    });
  });

  // ── 8. Kotlin struct codec handles nested struct fields ──────────────────────

  group('Kotlin struct codec handles nested @HybridStruct fields', () {
    late String kotlin;

    setUp(() {
      // Use transitiveNestedSpec: Line has Vec2 start/end fields
      kotlin = StructGenerator.generateKotlin(_transitiveNestedSpec());
    });

    test('Vec2 struct gets its own companion object with decodeFrom', () {
      expect(kotlin, contains('fun decodeFrom(buf: java.nio.ByteBuffer): Vec2'));
    });

    test('Line struct decodeFrom reads Vec2 fields via Vec2.decodeFrom(buf)', () {
      final decodeIdx = kotlin.indexOf('fun decodeFrom(buf: java.nio.ByteBuffer): Line');
      final block = kotlin.substring(decodeIdx, kotlin.indexOf('}', decodeIdx + 1) + 1);
      expect(block, contains('Vec2.decodeFrom(buf)'));
    });

    test('Line struct writeFieldsTo calls start.writeFieldsTo and end.writeFieldsTo', () {
      // There are two writeFieldsTo methods (one per struct). Find Line's.
      final lineIdx = kotlin.indexOf('data class Line(');
      final writeIdx = kotlin.indexOf('fun writeFieldsTo(out:', lineIdx);
      final block = kotlin.substring(writeIdx, kotlin.indexOf('\n    }', writeIdx) + 6);
      expect(block, contains('start.writeFieldsTo(out, buf)'));
      expect(block, contains('end.writeFieldsTo(out, buf)'));
    });
  });

  // ── 9. No RecordExt for structs NOT referenced in records ────────────────────

  group('Structs not referenced in records do NOT get RecordExt', () {
    test('spec with structs but no records emits empty string', () {
      final out = RecordGenerator.generateDartExtensions(nestedStructSpec());
      expect(out, isEmpty);
    });

    test('spec with records but struct not referenced emits no RecordExt for it', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        sourceUri: 'mod.native.dart',
        structs: [
          BridgeStruct(
            name: 'UnusedStruct',
            packed: false,
            fields: [BridgeField(name: 'v', type: BridgeType(name: 'double'))],
          ),
        ],
        recordTypes: [
          BridgeRecordType(
            name: 'SimpleRecord',
            fields: [
              BridgeRecordField(name: 'x', dartType: 'double', kind: RecordFieldKind.primitive),
            ],
          ),
        ],
        functions: [],
      );
      final out = RecordGenerator.generateDartExtensions(spec);
      expect(out, isNot(contains('UnusedStructRecordExt')));
      expect(out, contains('SimpleRecordRecordExt'));
    });
  });
}
