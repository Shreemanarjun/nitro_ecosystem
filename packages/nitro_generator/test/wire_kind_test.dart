// WireKind closes the "what kind of type is this?" question that every backend
// used to answer with its own if/else ladder. The ladders encoded a precedence
// (map before record, because isRecord is ALSO true for maps) that could drift
// apart. These tests pin that precedence and prove the enum stays exhaustive.
import 'package:nitro_generator/src/wire_kind.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

BridgeType _t(
  String name, {
  bool isRecord = false,
  bool isMap = false,
  bool isAnyMap = false,
  bool isTuple = false,
  bool isFunction = false,
  bool isPointer = false,
  bool isNativeHandle = false,
  bool isEnumList = false,
  String? recordListItemType,
}) => BridgeType(
  name: name,
  isRecord: isRecord,
  isMap: isMap,
  isAnyMap: isAnyMap,
  isTuple: isTuple,
  isFunction: isFunction,
  isPointer: isPointer,
  isNativeHandle: isNativeHandle,
  isEnumList: isEnumList,
  recordListItemType: recordListItemType,
);

WireKind _k(BridgeType t) => wireKindOf(
  t,
  isEnum: (n) => n == 'MyEnum',
  isStruct: (n) => n == 'MyStruct',
  isVariant: (n) => n == 'MyVariant',
);

void main() {
  test('scalars', () {
    expect(_k(_t('int')), WireKind.integer);
    expect(_k(_t('uint64')), WireKind.integer);
    expect(_k(_t('DateTime')), WireKind.integer);
    expect(_k(_t('double')), WireKind.float);
    expect(_k(_t('bool')), WireKind.bool_);
    expect(_k(_t('String')), WireKind.string);
    expect(_k(_t('void')), WireKind.none);
  });

  test('nullability does not change the kind', () {
    for (final n in ['int?', 'double?', 'bool?', 'String?', 'MyEnum?']) {
      expect(_k(_t(n)), _k(_t(n.substring(0, n.length - 1))), reason: n);
    }
  });

  test('a map is a map, NOT a record — isRecord is true for both', () {
    // The precedence that every backend ladder had to get right.
    expect(_k(_t('Map<String, int>', isRecord: true, isMap: true)), WireKind.map);
    expect(_k(_t('NitroAnyMap', isRecord: true, isMap: true, isAnyMap: true)), WireKind.anyMap);
  });

  test('a list is a list whatever its item flavour', () {
    expect(_k(_t('List<int>', isRecord: true, recordListItemType: 'int')), WireKind.list);
    expect(_k(_t('List<MyEnum>', isRecord: true, isEnumList: true, recordListItemType: 'MyEnum')), WireKind.list);
  });

  test('a tuple shares the record wire', () {
    expect(_k(_t('MyTuple', isRecord: true, isTuple: true)), WireKind.record);
  });

  test('declared types outrank the primitive fallback', () {
    expect(_k(_t('MyStruct')), WireKind.struct);
    expect(_k(_t('MyVariant')), WireKind.variant);
    expect(_k(_t('MyEnum')), WireKind.enumeration);
    expect(_k(_t('MyRecord', isRecord: true)), WireKind.record);
  });

  test('typed data, pointers, callbacks and handles', () {
    expect(_k(_t('Uint8List')), WireKind.typedData);
    expect(_k(_t('Float64List')), WireKind.typedData);
    expect(_k(_t('Pointer<Void>', isPointer: true)), WireKind.pointer);
    expect(_k(_t('void Function(int)', isFunction: true)), WireKind.function);
    expect(_k(_t('NativeHandle', isNativeHandle: true)), WireKind.handle);
  });

  test('anything unrecognised is opaque, never silently a scalar', () {
    expect(_k(_t('SomeCustomType')), WireKind.opaque);
  });

  test('every WireKind is reachable — none is dead', () {
    final reached = {
      for (final t in [
        _t('void'), _t('int'), _t('double'), _t('bool'), _t('String'), _t('MyEnum'),
        _t('Uint8List'), _t('Pointer<Void>', isPointer: true), _t('MyStruct'),
        _t('MyRecord', isRecord: true), _t('MyVariant'),
        _t('List<int>', isRecord: true, recordListItemType: 'int'),
        _t('Map<String, int>', isRecord: true, isMap: true),
        _t('NitroAnyMap', isRecord: true, isMap: true, isAnyMap: true),
        _t('void Function()', isFunction: true), _t('NativeHandle', isNativeHandle: true),
        _t('SomeCustomType'),
      ])
        _k(t),
    };
    expect(reached, WireKind.values.toSet(), reason: 'a WireKind no real type produces is dead code');
  });
}
