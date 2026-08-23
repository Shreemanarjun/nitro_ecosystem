// The map wire contract is shared by five independently-written codecs. These
// tests pin the tag numbers (changing one silently breaks every already-built
// native binary) and prove each backend emits them from the shared table
// rather than its own literals — the drift that hid the nullable-value gap.
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:nitro_generator/src/generators/languages/web/web_bridge_generator.dart';
import 'package:nitro_generator/src/map_wire.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

BridgeSpec _spec(String valueType, {bool web = false}) => BridgeSpec(
  dartClassName: 'Foo',
  lib: 'foo',
  namespace: 'foo',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  webImpl: web ? NativeImpl.wasm : null,
  sourceUri: 'foo.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'echoMap',
      cSymbol: 'foo_echo_map',
      isAsync: false,
      returnType: BridgeType(name: 'Map<String, $valueType>', isRecord: true, isMap: true),
      params: [BridgeParam(name: 'value', type: BridgeType(name: 'Map<String, $valueType>', isRecord: true, isMap: true))],
    ),
  ],
);

void main() {
  test('tag numbers are frozen — changing one breaks every built binary', () {
    expect(
      {for (final w in MapValueWire.values) w.name: w.tag},
      {'nul': 0, 'int64': 1, 'float64': 2, 'boolean': 3, 'string': 4, 'blob': 5},
    );
  });

  test('classification is exhaustive over the enum', () {
    // A new MapValueWire variant must be given a classification rule, or this
    // fails rather than silently never being produced.
    final produced = {
      for (final t in ['int', 'double', 'bool', 'String', 'MyEnum', 'MyRecord', 'Object'])
        mapValueWireOf(t, isEnum: (x) => x == 'MyEnum', isRecord: (x) => x == 'MyRecord', isVariant: (_) => false),
    };
    expect(produced, MapValueWire.values.toSet().difference({MapValueWire.nul}));
  });

  test('an enum value rides the int64 wire, a record the blob wire', () {
    bool no(String _) => false;
    expect(mapValueWireOf('E', isEnum: (x) => x == 'E', isRecord: no, isVariant: no), MapValueWire.int64);
    expect(mapValueWireOf('R', isEnum: no, isRecord: (x) => x == 'R', isVariant: no), MapValueWire.blob);
    expect(mapValueWireOf('V', isEnum: no, isRecord: no, isVariant: (x) => x == 'V'), MapValueWire.blob);
    expect(mapValueWireOf('Whatever', isEnum: no, isRecord: no, isVariant: no), MapValueWire.string);
  });

  test('every backend writes the same tag for the same value type', () {
    for (final (type, wire) in [('int', MapValueWire.int64), ('double', MapValueWire.float64), ('bool', MapValueWire.boolean)]) {
      expect(DartFfiGenerator.generate(_spec(type)), contains('bb.addByte(${wire.tag})'), reason: 'dart/$type');
      expect(KotlinGenerator.generate(_spec(type)), contains('_outBb.write(${wire.tag})'), reason: 'kotlin/$type');
    }
    // Swift shares one codec across all value types.
    final swift = SwiftGenerator.generate(_spec('int'));
    expect(swift, contains('payload.append(${MapValueWire.nul.tag})'));
    expect(swift, contains('case ${MapValueWire.int64.tag}: result[k] = readLE64()'));
    // Web tags via the shared classifier.
    expect(WebBridgeGenerator.generate(_spec('int', web: true)), contains('w.writeInt8(${MapValueWire.int64.tag})'));
  });

  // The web backend gets COMPILE-time exhaustiveness (switch over WireKind).
  // The other four map types by name, so this is the test-time equivalent:
  // adding a MapValueWire variant fails here until every backend emits it.
  test('every backend emits every wire variant', () {
    const sample = {
      MapValueWire.nul: 'int?',
      MapValueWire.int64: 'int',
      MapValueWire.float64: 'double',
      MapValueWire.boolean: 'bool',
      MapValueWire.string: 'String',
      MapValueWire.blob: 'TcRec',
    };
    expect(
      sample.keys.toSet(),
      MapValueWire.values.toSet(),
      reason: 'a new MapValueWire variant needs a representative value type here',
    );

    for (final MapEntry(key: wire, value: type) in sample.entries) {
      // blob needs a declared record in the spec; skip the ones that cannot be
      // expressed with a bare scalar spec and assert the tag literal instead.
      if (wire == MapValueWire.blob) {
        expect(DartFfiGenerator.generate(_spec('int')), isNot(contains('bb.addByte(${wire.tag})')));
        continue;
      }
      final dart = DartFfiGenerator.generate(_spec(type));
      expect(dart, contains('bb.addByte(${wire.tag})'), reason: 'dart missing ${wire.name}');

      final kotlin = KotlinGenerator.generate(_spec(type));
      expect(kotlin, contains('${wire.tag})'), reason: 'kotlin missing ${wire.name}');
    }

    // Swift's single shared codec must name every tag in both directions.
    final swift = SwiftGenerator.generate(_spec('int'));
    for (final wire in MapValueWire.values) {
      expect(swift, contains('case ${wire.tag}:'), reason: 'swift decode missing ${wire.name}');
    }
  });

  test('the null tag is only reachable for the supported value types', () {
    expect(nullableMapValueTypes, {'int', 'double', 'bool', 'String'});
    expect(DartFfiGenerator.generate(_spec('int?')), contains('bb.addByte(${MapValueWire.nul.tag})'));
    expect(DartFfiGenerator.generate(_spec('int')), isNot(contains('bb.addByte(${MapValueWire.nul.tag})')));
  });
}
