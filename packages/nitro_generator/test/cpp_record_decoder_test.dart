// Tests for RecordGenerator.generateCpp and the CppInterfaceGenerator
// integration of @HybridRecord C++ decoders with null bounds checking (§3.3).
import 'package:nitro_generator/src/generators/languages/cpp_native/cpp_interface_generator.dart';
import 'package:nitro_generator/src/generators/record_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// ── Spec helpers ──────────────────────────────────────────────────────────────

BridgeSpec _primitiveRecordSpec() => BridgeSpec(
  dartClassName: 'Camera',
  lib: 'camera',
  namespace: 'camera',
  iosImpl: NativeImpl.cpp,
  androidImpl: NativeImpl.cpp,
  sourceUri: 'camera.native.dart',
  recordTypes: [
    BridgeRecordType(
      name: 'CameraDevice',
      fields: [
        BridgeRecordField(name: 'id', dartType: 'String', kind: RecordFieldKind.primitive),
        BridgeRecordField(name: 'index', dartType: 'int', kind: RecordFieldKind.primitive),
        BridgeRecordField(name: 'score', dartType: 'double', kind: RecordFieldKind.primitive),
        BridgeRecordField(name: 'front', dartType: 'bool', kind: RecordFieldKind.primitive),
      ],
    ),
  ],
);

BridgeSpec _nullableRecordSpec() => BridgeSpec(
  dartClassName: 'Sensor',
  lib: 'sensor',
  namespace: 'sensor',
  iosImpl: NativeImpl.cpp,
  androidImpl: NativeImpl.cpp,
  sourceUri: 'sensor.native.dart',
  recordTypes: [
    BridgeRecordType(
      name: 'SensorReading',
      fields: [
        BridgeRecordField(name: 'value', dartType: 'double', kind: RecordFieldKind.primitive),
        BridgeRecordField(name: 'label', dartType: 'String?', kind: RecordFieldKind.primitive, isNullable: true),
        BridgeRecordField(name: 'count', dartType: 'int?', kind: RecordFieldKind.primitive, isNullable: true),
        BridgeRecordField(name: 'valid', dartType: 'bool?', kind: RecordFieldKind.primitive, isNullable: true),
      ],
    ),
  ],
);

BridgeSpec _nestedRecordSpec() => BridgeSpec(
  dartClassName: 'Map',
  lib: 'map_module',
  namespace: 'map_module',
  iosImpl: NativeImpl.cpp,
  androidImpl: NativeImpl.cpp,
  sourceUri: 'map_module.native.dart',
  recordTypes: [
    BridgeRecordType(
      name: 'Point',
      fields: [
        BridgeRecordField(name: 'x', dartType: 'double', kind: RecordFieldKind.primitive),
        BridgeRecordField(name: 'y', dartType: 'double', kind: RecordFieldKind.primitive),
      ],
    ),
    BridgeRecordType(
      name: 'Region',
      fields: [
        BridgeRecordField(name: 'center', dartType: 'Point', kind: RecordFieldKind.recordObject),
        BridgeRecordField(name: 'optPt', dartType: 'Point?', kind: RecordFieldKind.recordObject, isNullable: true),
        BridgeRecordField(name: 'radius', dartType: 'double', kind: RecordFieldKind.primitive),
      ],
    ),
  ],
);

BridgeSpec _listRecordSpec() => BridgeSpec(
  dartClassName: 'Batch',
  lib: 'batch',
  namespace: 'batch',
  iosImpl: NativeImpl.cpp,
  androidImpl: NativeImpl.cpp,
  sourceUri: 'batch.native.dart',
  recordTypes: [
    BridgeRecordType(
      name: 'Item',
      fields: [
        BridgeRecordField(name: 'name', dartType: 'String', kind: RecordFieldKind.primitive),
        BridgeRecordField(name: 'counts', dartType: 'List<int>', kind: RecordFieldKind.listPrimitive, itemTypeName: 'int'),
        BridgeRecordField(name: 'tags', dartType: 'List<String>', kind: RecordFieldKind.listPrimitive, itemTypeName: 'String'),
      ],
    ),
    BridgeRecordType(
      name: 'Batch',
      fields: [
        BridgeRecordField(name: 'items', dartType: 'List<Item>', kind: RecordFieldKind.listRecordObject, itemTypeName: 'Item'),
      ],
    ),
  ],
);

BridgeSpec _noRecordSpec() => BridgeSpec(
  dartClassName: 'Simple',
  lib: 'simple',
  namespace: 'simple',
  iosImpl: NativeImpl.cpp,
  androidImpl: NativeImpl.cpp,
  sourceUri: 'simple.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'add',
      cSymbol: 'simple_add',
      isAsync: false,
      returnType: BridgeType(name: 'int'),
      params: [
        BridgeParam(
          name: 'a',
          type: BridgeType(name: 'int'),
        ),
      ],
    ),
  ],
);

// ── RecordGenerator.generateCpp ───────────────────────────────────────────────

void main() {
  group('RecordGenerator.generateCpp — empty output', () {
    test('returns empty string when spec has no record types', () {
      final out = RecordGenerator.generateCpp(_noRecordSpec());
      expect(out, isEmpty);
    });
  });

  group('RecordGenerator.generateCpp — NitroRecordReader', () {
    test('emits NitroRecordReader struct', () {
      final out = RecordGenerator.generateCpp(_primitiveRecordSpec());
      expect(out, contains('struct NitroRecordReader'));
    });

    test('readNullTag has explicit bounds check before byte access', () {
      final out = RecordGenerator.generateCpp(_primitiveRecordSpec());
      // Search for the method definition (not the comment that also mentions readNullTag)
      final methodDecl = 'bool readNullTag()';
      final methodIdx = out.indexOf(methodDecl);
      expect(methodIdx, isNot(-1), reason: 'readNullTag method must be defined');
      final methodBody = out.substring(methodIdx, out.indexOf('\n    }', methodIdx) + 6);
      expect(methodBody, contains('_offset + 1 > _size'), reason: 'bounds check must compare offset+1 against size');
      expect(methodBody, contains('throw std::runtime_error'));
    });

    test('readNullTag throws a std::runtime_error on out-of-bounds', () {
      final out = RecordGenerator.generateCpp(_primitiveRecordSpec());
      expect(out, contains('throw std::runtime_error("NitroRecordReader: null tag read past end of buffer")'));
    });

    test('other read methods use _require() helper (not open-coded check)', () {
      final out = RecordGenerator.generateCpp(_primitiveRecordSpec());
      // readInt / readDouble / readBool / readString use _require(n)
      expect(out, contains('_require(8)')); // readInt + readDouble
      expect(out, contains('_require(1)')); // readBool
      // _require itself throws runtime_error for general underflow
      expect(out, contains('throw std::runtime_error("NitroRecordReader: buffer underflow")'));
    });

    test('reader is constructible from NitroCppBuffer', () {
      final out = RecordGenerator.generateCpp(_primitiveRecordSpec());
      expect(out, contains('explicit NitroRecordReader(NitroCppBuffer buf)'));
    });
  });

  group('RecordGenerator.generateCpp — forward declarations', () {
    test('emits a forward declaration for every record type', () {
      final out = RecordGenerator.generateCpp(_nestedRecordSpec());
      expect(out, contains('struct Point;'));
      expect(out, contains('struct Region;'));
    });

    test('forward declaration appears before the NitroRecordReader definition', () {
      final out = RecordGenerator.generateCpp(_nestedRecordSpec());
      final fwdIdx = out.indexOf('struct Point;');
      final readerIdx = out.indexOf('struct NitroRecordReader');
      expect(fwdIdx, lessThan(readerIdx));
    });
  });

  group('RecordGenerator.generateCpp — primitive fields', () {
    test('String field maps to std::string', () {
      final out = RecordGenerator.generateCpp(_primitiveRecordSpec());
      expect(out, contains('std::string id'));
    });

    test('int field maps to int64_t', () {
      final out = RecordGenerator.generateCpp(_primitiveRecordSpec());
      expect(out, contains('int64_t index'));
    });

    test('double field maps to double', () {
      final out = RecordGenerator.generateCpp(_primitiveRecordSpec());
      expect(out, contains('double score'));
    });

    test('bool field maps to bool', () {
      final out = RecordGenerator.generateCpp(_primitiveRecordSpec());
      expect(out, contains('bool front'));
    });

    test('fromReader reads String via readString()', () {
      final out = RecordGenerator.generateCpp(_primitiveRecordSpec());
      expect(out, contains('_obj.id = _r.readString()'));
    });

    test('fromReader reads int via readInt()', () {
      final out = RecordGenerator.generateCpp(_primitiveRecordSpec());
      expect(out, contains('_obj.index = _r.readInt()'));
    });

    test('fromReader reads double via readDouble()', () {
      final out = RecordGenerator.generateCpp(_primitiveRecordSpec());
      expect(out, contains('_obj.score = _r.readDouble()'));
    });

    test('fromReader reads bool via readBool()', () {
      final out = RecordGenerator.generateCpp(_primitiveRecordSpec());
      expect(out, contains('_obj.front = _r.readBool()'));
    });
  });

  group('RecordGenerator.generateCpp — nullable fields', () {
    test('nullable String field maps to std::optional<std::string>', () {
      final out = RecordGenerator.generateCpp(_nullableRecordSpec());
      expect(out, contains('std::optional<std::string> label'));
    });

    test('nullable int field maps to std::optional<int64_t>', () {
      final out = RecordGenerator.generateCpp(_nullableRecordSpec());
      expect(out, contains('std::optional<int64_t> count'));
    });

    test('nullable bool field maps to std::optional<bool>', () {
      final out = RecordGenerator.generateCpp(_nullableRecordSpec());
      expect(out, contains('std::optional<bool> valid'));
    });

    test('nullable field read calls readNullTag() before the value read', () {
      final out = RecordGenerator.generateCpp(_nullableRecordSpec());
      // Pattern: bool _null = _r.readNullTag(); _obj.X = _null ? std::nullopt : ...
      expect(out, contains('bool _null = _r.readNullTag()'));
      expect(out, contains('std::nullopt'));
    });

    test('nullable String: readNullTag() gates readString()', () {
      final out = RecordGenerator.generateCpp(_nullableRecordSpec());
      expect(out, contains('std::optional<std::string>(_r.readString())'));
    });

    test('nullable int: readNullTag() gates readInt()', () {
      final out = RecordGenerator.generateCpp(_nullableRecordSpec());
      expect(out, contains('std::optional<int64_t>(_r.readInt())'));
    });

    test('nullable bool: readNullTag() gates readBool()', () {
      final out = RecordGenerator.generateCpp(_nullableRecordSpec());
      expect(out, contains('std::optional<bool>(_r.readBool())'));
    });

    test('non-nullable field does NOT call readNullTag()', () {
      final out = RecordGenerator.generateCpp(_nullableRecordSpec());
      // 'value' is non-nullable — its read line must not contain readNullTag
      final valueReadLine = out
          .split('\n')
          .firstWhere(
            (l) => l.contains('_obj.value'),
            orElse: () => '',
          );
      expect(valueReadLine, isNot(contains('readNullTag')));
    });
  });

  group('RecordGenerator.generateCpp — nested records', () {
    test('nested record field uses RecordType::fromReader(_r)', () {
      final out = RecordGenerator.generateCpp(_nestedRecordSpec());
      expect(out, contains('Point::fromReader(_r)'));
    });

    test('nullable nested record calls readNullTag() before fromReader', () {
      final out = RecordGenerator.generateCpp(_nestedRecordSpec());
      expect(out, contains('std::optional<Point>(Point::fromReader(_r))'));
    });

    test('nullable nested record field maps to std::optional<NestedType>', () {
      final out = RecordGenerator.generateCpp(_nestedRecordSpec());
      expect(out, contains('std::optional<Point> optPt'));
    });
  });

  group('RecordGenerator.generateCpp — list fields', () {
    test('List<int> field maps to std::vector<int64_t>', () {
      final out = RecordGenerator.generateCpp(_listRecordSpec());
      expect(out, contains('std::vector<int64_t> counts'));
    });

    test('List<String> field maps to std::vector<std::string>', () {
      final out = RecordGenerator.generateCpp(_listRecordSpec());
      expect(out, contains('std::vector<std::string> tags'));
    });

    test('List<Item> field maps to std::vector<Item>', () {
      final out = RecordGenerator.generateCpp(_listRecordSpec());
      expect(out, contains('std::vector<Item> items'));
    });

    test('list read uses readInt32() for count and push_back in loop', () {
      final out = RecordGenerator.generateCpp(_listRecordSpec());
      expect(out, contains('int32_t _n = _r.readInt32()'));
      expect(out, contains('push_back(_r.readInt())'));
    });

    test('list of record objects uses push_back(Item::fromReader(_r))', () {
      final out = RecordGenerator.generateCpp(_listRecordSpec());
      expect(out, contains('push_back(Item::fromReader(_r))'));
    });

    test('list read uses reserve() before pushing items', () {
      final out = RecordGenerator.generateCpp(_listRecordSpec());
      expect(out, contains('.reserve((size_t)_n)'));
    });
  });

  group('RecordGenerator.generateCpp — struct skeleton', () {
    test('emits fromNative(NitroCppBuffer) static method', () {
      final out = RecordGenerator.generateCpp(_primitiveRecordSpec());
      expect(out, contains('static CameraDevice fromNative(NitroCppBuffer buf)'));
    });

    test('fromNative constructs a NitroRecordReader and calls fromReader', () {
      final out = RecordGenerator.generateCpp(_primitiveRecordSpec());
      expect(out, contains('NitroRecordReader _r(buf)'));
      expect(out, contains('return fromReader(_r)'));
    });

    test('emits fromReader(NitroRecordReader&) static method', () {
      final out = RecordGenerator.generateCpp(_primitiveRecordSpec());
      expect(out, contains('static CameraDevice fromReader(NitroRecordReader& _r)'));
    });

    test('fromReader returns the populated struct by value', () {
      final out = RecordGenerator.generateCpp(_primitiveRecordSpec());
      expect(out, contains('return _obj'));
    });
  });

  // ── CppInterfaceGenerator integration ────────────────────────────────────────

  group('CppInterfaceGenerator — record decoder integration', () {
    test('includes <cstring>, <optional>, <vector> when spec has records', () {
      final out = CppInterfaceGenerator.generate(_primitiveRecordSpec());
      expect(out, contains('#include <cstring>'));
      expect(out, contains('#include <optional>'));
      expect(out, contains('#include <vector>'));
    });

    test('always includes <cstring>/<optional>/<vector> (RN Nitro parity — unconditional stdlib headers)', () {
      // Always-included mirrors RN Nitro's HybridXxxSpec.hpp pattern:
      // all stdlib headers present even when no records/variants exist,
      // so user implementations can use std::optional<T> and std::vector<T> freely.
      final out = CppInterfaceGenerator.generate(_noRecordSpec());
      expect(out, contains('#include <cstring>'));
      expect(out, contains('#include <optional>'));
      expect(out, contains('#include <vector>'));
    });

    test('record decoder appears before the Hybrid class definition', () {
      final out = CppInterfaceGenerator.generate(_primitiveRecordSpec());
      final decoderIdx = out.indexOf('struct NitroRecordReader');
      // Use 'class HybridCamera {' to skip the earlier comment line
      // '// Subclass HybridCamera and register...'
      final classIdx = out.indexOf('class HybridCamera {');
      expect(decoderIdx, isNot(-1));
      expect(classIdx, isNot(-1));
      expect(decoderIdx, lessThan(classIdx));
    });

    test('NitroCppBuffer is still emitted (used by bridge params)', () {
      final out = CppInterfaceGenerator.generate(_primitiveRecordSpec());
      expect(out, contains('struct NitroCppBuffer'));
    });

    test('null-tag bounds check is present in the header output', () {
      final out = CppInterfaceGenerator.generate(_nullableRecordSpec());
      expect(out, contains('_offset + 1 > _size'));
      expect(out, contains('null tag read past end of buffer'));
    });
  });
}
