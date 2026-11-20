// A `Map<String, V>` or `NitroAnyMap` in ANY position: a map return with no
// map parameter, a map parameter with a scalar return, a map that is not the
// first parameter, two maps on one method, and a nullable map either way.
// Until 0.9.0 the Kotlin and Swift stubs handled exactly one shape — one map
// parameter and a map return — and everything else either did not compile or
// passed the raw bytes to the implementation.
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_header_generator.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:nitro_generator/src/generators/languages/web/web_bridge_generator.dart';
import 'package:nitro_generator/src/map_wire.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// The shapes the extractor produces.
BridgeType _map(String value, {bool nullable = false}) => BridgeType(name: 'Map<String, $value>${nullable ? '?' : ''}', isRecord: true, isMap: true, isNullable: nullable);
BridgeType _anyMap({bool nullable = false}) => BridgeType(name: 'NitroAnyMap${nullable ? '?' : ''}', isAnyMap: true, isNullable: nullable);
BridgeType _int = BridgeType(name: 'int');
BridgeType _string = BridgeType(name: 'String');

BridgeFunction _fn(String name, BridgeType ret, List<(String, BridgeType)> params, {bool isAsync = false, bool isNativeAsync = false}) => BridgeFunction(
  dartName: name,
  cSymbol: 'shapes_$name',
  isAsync: isAsync,
  isNativeAsync: isNativeAsync,
  returnType: ret,
  params: [for (final (n, t) in params) BridgeParam(name: n, type: t)],
);

BridgeSpec _spec({bool allCpp = false}) => BridgeSpec(
  dartClassName: 'Shapes',
  lib: 'shapes',
  namespace: 'shapes',
  iosImpl: allCpp ? NativeImpl.cpp : NativeImpl.swift,
  androidImpl: allCpp ? NativeImpl.cpp : NativeImpl.kotlin,
  sourceUri: 'shapes.native.dart',
  functions: [
    _fn('make', _map('int'), [('n', _int)]),
    _fn('sum', _int, [('values', _map('int')), ('bias', _int)]),
    _fn('merge', _map('String'), [('a', _map('String')), ('sep', _string), ('b', _map('String'))]),
    _fn('orNull', _map('int', nullable: true), [('n', _int)]),
    _fn('size', _int, [('values', _map('int', nullable: true))]),
    _fn('holes', _map('int?'), [('n', _int)]),
    _fn('anyOf', _anyMap(), [('n', _int)]),
    _fn('anySize', _int, [('bias', _int), ('m', _anyMap())]),
    _fn('anyOrNull', _anyMap(nullable: true), [('m', _anyMap(nullable: true))]),
    _fn('makeLater', BridgeType(name: 'Map<String, int>', isRecord: true, isMap: true, isFuture: true), [('n', _int)], isAsync: true),
    _fn('sumNative', BridgeType(name: 'int', isFuture: true), [('bias', _int), ('values', _map('int?'))], isNativeAsync: true),
  ],
);

void main() {
  test('one pattern reads the value type of a map, nullable or not', () {
    expect(stringMapValueType('Map<String, int>'), 'int');
    expect(stringMapValueType('Map<String, int>?'), 'int');
    expect(stringMapValueType('Map<String, int?>'), 'int?');
    expect(stringMapValueType('Map<String,  Cfg ?>?'), 'Cfg ?');
    expect(stringMapValueType('Map<int, String>'), isNull);
    expect(stringMapValueType('NitroAnyMap'), isNull);
    expect(stringMapValueType('List<int>'), isNull);
  });

  group('Kotlin', () {
    final out = KotlinGenerator.generate(_spec());

    test('the interface is typed, and a nullable map is nullable', () {
      expect(out, contains('fun make(n: Long): Map<String, Long>'));
      expect(out, contains('fun merge(a: Map<String, String>, sep: String, b: Map<String, String>): Map<String, String>'));
      expect(out, contains('fun orNull(n: Long): Map<String, Long>?'));
      expect(out, contains('fun size(values: Map<String, Long>?): Long'));
      expect(out, contains('fun anyOrNull(m: Map<String, Any?>?): Map<String, Any?>?'));
    });

    test('a map return needs no map parameter', () {
      expect(out, contains('val _result = impl.make(n)\n        return nitroEncodeMap(_result, 1) { o, v -> o.putInt64(v) }'));
    });

    test('a map parameter is decoded whatever the return type and position', () {
      expect(out, contains('val valuesDecoded = nitroDecodeMap(values) { r -> r.p++; r.int64() }\n        return impl.sum(valuesDecoded, bias)'));
      expect(out, contains('val mDecoded = NitroAnyMapCodec.decode(m)\n        return impl.anySize(bias, mDecoded)'));
    });

    test('two maps on one method are decoded apart', () {
      expect(out, contains('val aDecoded = nitroDecodeMap(a) { r -> r.p++; r.string() }'));
      expect(out, contains('val bDecoded = nitroDecodeMap(b) { r -> r.p++; r.string() }'));
      expect(out, contains('impl.merge(aDecoded, sep, bDecoded)'));
    });

    test('a null map is a null ByteArray, both ways', () {
      expect(out, contains('fun orNull_call(instanceId: Long, n: Long): ByteArray? {'));
      expect(out, contains('return _result?.let { nitroEncodeMap(it, 1) { o, v -> o.putInt64(v) } }'));
      expect(out, contains('fun size_call(instanceId: Long, values: ByteArray?): Long {'));
      expect(out, contains('val valuesDecoded = values?.let { nitroDecodeMap(it) { r -> r.p++; r.int64() } }'));
      expect(out, contains('fun anyOrNull_call(instanceId: Long, m: ByteArray?): ByteArray? {'));
      expect(out, contains('val mDecoded = m?.let { NitroAnyMapCodec.decode(it) }'));
      expect(out, contains('return _result?.let { NitroAnyMapCodec.encode(it) }'));
    });

    test('@nitroAsync and @nitroNativeAsync use the same codec', () {
      expect(out, contains('runBlocking { impl.makeLater(n) } }).get()\n        return nitroEncodeMap(_result, 1) { o, v -> o.putInt64(v) }'));
      expect(out, contains('val valuesDecoded = nitroDecodeMap(values) { r -> if (r.byte() == 0) null else r.int64() }'));
      expect(out, contains('runBlocking { impl.sumNative(bias, valuesDecoded) }'));
    });

    test('the helpers are emitted once, with the array codec they need', () {
      expect('private inline fun <V> nitroDecodeMap('.allMatches(out).length, 1);
      expect('private inline fun <V : Any> nitroEncodeMap('.allMatches(out).length, 1);
      // No record in this spec: the codec classes still have to be there.
      expect('class NitroRecordOut('.allMatches(out).length, 1);
      expect('class NitroRecordIn('.allMatches(out).length, 1);
      expect(out, isNot(contains('_outBb')));
    });
  });

  group('Swift', () {
    final out = SwiftGenerator.generate(_spec());

    test('the protocol is typed, and a nullable map is optional', () {
      expect(out, contains('func make(n: Int64) -> [String: Int64]'));
      expect(out, contains('func merge(a: [String: String], sep: String, b: [String: String]) -> [String: String]'));
      expect(out, contains('func orNull(n: Int64) -> [String: Int64]?'));
      expect(out, contains('func size(values: [String: Int64]?) -> Int64'));
      expect(out, contains('func holes(n: Int64) -> [String: Int64?]'));
      expect(out, contains('func anyOrNull(m: [String: Any]?) -> [String: Any]?'));
      // No untyped map left in the protocol.
      expect(out, isNot(contains('-> Any\n')));
      expect(out, isNot(contains('values: Any')));
    });

    test('a map return needs no map parameter', () {
      expect(out, contains('let result = impl.make(n: n)\n    return _nitroEncodeMap(result, 1) { w, v in w.writeInt(v) }'));
    });

    test('a map parameter is decoded whatever the return type and position', () {
      expect(out, contains('let valuesMap: [String: Int64] = values.map { _nitroDecodeMap(\$0) { r in r.readInt() } } ?? [:]'));
      expect(out, contains('return impl.sum(values: valuesMap, bias: bias)'));
      expect(out, contains('return impl.anySize(bias: bias, m: mMap)'));
    });

    test('two maps on one method are decoded apart', () {
      expect(out, contains('let aMap: [String: String] = a.map {'));
      expect(out, contains('let bMap: [String: String] = b.map {'));
      expect(out, contains('impl.merge(a: aMap, sep: sepStr, b: bMap)'));
    });

    test('a null map is a nil pointer, both ways', () {
      expect(out, contains('let valuesMap: [String: Int64]? = values.map { _nitroDecodeMap(\$0) { r in r.readInt() } }\n'));
      expect(out, contains('return result.flatMap { m in _nitroEncodeMap(m, 1) { w, v in w.writeInt(v) } }'));
      expect(out, contains('let mMap: [String: Any]? = m.map { _nitroDecodeAnyMapBinary(\$0.assumingMemoryBound(to: UInt8.self)) }\n'));
      expect(out, contains('return result.flatMap { m in _nitroEncodeAnyMapBinary(m) }'));
    });

    test('a thrown error in an @nitroAsync map method is raised, not swallowed', () {
      final at = out.indexOf('_shapes_call_makeLater');
      final body = out.substring(at, out.indexOf('\n}\n', at));
      expect(body, contains('do { _mapResult = try await impl.makeLater(n: n) }'));
      expect(body, contains('catch { _thrownError = error }'));
      expect(body, contains('NSException('));
      expect(body, isNot(contains('try?')));
    });

    test('@nitroNativeAsync decodes its map before the task starts', () {
      final at = out.indexOf('_shapes_call_sumNative');
      final body = out.substring(at, out.indexOf('\n}\n', at));
      expect(body.indexOf('let valuesMap: [String: Int64?] = values.map { _nitroDecodeNullableMap('), lessThan(body.indexOf('Task.detached')));
      expect(body, contains('impl.sumNative(bias: bias, values: valuesMap)'));
    });
  });

  group('Dart', () {
    final out = DartFfiGenerator.generate(_spec());

    test('a nullable map uses the typed codec behind a null guard', () {
      expect(out, contains('values == null ? nullptr : _nitroEncodeMapBinaryInt(values, arena)'));
      expect(out, contains('if (res == nullptr) return null;'));
      // The value type of `Map<String, int>?` is int, not dynamic.
      expect(out, isNot(contains('_nitroEncodeMapBinaryDynamic')));
      expect(out, isNot(contains('_nitroDecodeMapBinaryDynamic')));
    });

    test('a nullable NitroAnyMap keeps its `?` and its null guard', () {
      expect(out, contains('NitroAnyMap? anyOrNull(NitroAnyMap? m)'));
      expect(out, contains('m == null ? nullptr : m.toNative(arena)'));
    });
  });

  // A @HybridStruct of non-null int / double / bool / String fields is a map
  // value: it travels as its bytes, framed like a record.
  group('struct values', () {
    BridgeSpec structSpec({bool web = false}) => BridgeSpec(
      dartClassName: 'Geo',
      lib: 'geo',
      namespace: 'geo',
      iosImpl: web ? NativeImpl.cpp : NativeImpl.swift,
      androidImpl: web ? NativeImpl.cpp : NativeImpl.kotlin,
      webImpl: web ? NativeImpl.wasm : null,
      sourceUri: 'geo.native.dart',
      structs: [
        BridgeStruct(
          name: 'Point',
          packed: false,
          fields: [
            BridgeField(name: 'x', type: BridgeType(name: 'double'), isNamed: true),
            BridgeField(name: 'label', type: BridgeType(name: 'String'), isNamed: true),
          ],
        ),
      ],
      functions: [_fn('echo', _map('Point'), [('points', _map('Point'))])],
    );

    test('Kotlin reads through the struct decoder and writes both lengths', () {
      final out = KotlinGenerator.generate(structSpec());
      expect(out, contains('fun echo(points: Map<String, Point>): Map<String, Point>'));
      expect(out, contains('nitroDecodeMap(points) { r -> r.p++; r.blob { b -> b.via { Point.decodeFrom(it) } } }'));
      // A struct's encode() is its bare fields, with no length of its own.
      expect(out, contains('nitroEncodeMap(_result, 5) { o, v -> val b = v.encode(); o.putInt32(b.size + 4); o.putInt32(b.size); o.write(b, 0, b.size) }'));
    });

    test('Swift types the dictionary and emits the struct\'s byte codec', () {
      final out = SwiftGenerator.generate(structSpec());
      expect(out, contains('func echo(points: [String: Point]) -> [String: Point]'));
      expect(out, contains('{ r in r.pos += 8; return Point.fromReader(r) }'));
      expect(out, contains('_nitroEncodeMap(result, 5) { w, v in w.writeFramed { v.writeFields(\$0) } }'));
      expect(out, contains('extension Point {\n  public static func fromReader(_ r: NitroRecordReader) -> Point {'));
    });

    test('Dart frames the struct\'s fields and reads them where they lie', () {
      final out = DartFfiGenerator.generate(structSpec());
      expect(out, contains('extension PointRecordExt on Point {'));
      expect(out, contains('(v as Point).writeFields(_w);'));
      expect(out, contains('h.setInt32(0, _w.payloadLength + 4, Endian.little); h.setInt32(4, _w.payloadLength, Endian.little);'));
      expect(out, contains('final v = PointRecordExt.fromNative(ptr + 4 + pos); pos += _bLen;'));
      expect(out, isNot(contains('jsonEncode')));
    });

    test('web uses the same blob', () {
      final out = WebBridgeGenerator.generate(structSpec(web: true));
      expect(out, contains('w.writeBlob(_nitroEncodeFramed((rw) => e.value.writeFields(rw)));'));
      expect(out, contains('final v = PointRecordExt.fromReader(RecordReader.fromFramedBytes(r.readBlob()));'));
    });
  });

  // The one shape that stays refused where it cannot build: a property.
  test('a map property on a Kotlin or Swift module is an error that names the method to use', () {
    BridgeSpec withProperty({required bool allCpp, BridgeType? type}) => BridgeSpec(
      dartClassName: 'Shapes',
      lib: 'shapes',
      namespace: 'shapes',
      iosImpl: allCpp ? NativeImpl.cpp : NativeImpl.swift,
      androidImpl: allCpp ? NativeImpl.cpp : NativeImpl.kotlin,
      sourceUri: 'shapes.native.dart',
      properties: [BridgeProperty(dartName: 'config', type: type ?? _map('int'), getSymbol: 'shapes_get_config', setSymbol: 'shapes_set_config', hasGetter: true, hasSetter: true)],
    );
    Iterable<ValidationIssue> found(BridgeSpec s) => SpecValidator.validate(s).where((i) => i.code == 'INVALID_PROPERTY_TYPE');
    final issue = found(withProperty(allCpp: false)).single;
    expect(issue.isError, isTrue);
    expect(issue.message, contains('a "Map<String, int>" property is not supported on a Kotlin or Swift implementation'));
    expect(issue.hint, 'Use methods instead: `Map<String, int> config();` and `void setConfig(Map<String, int> value);`.');
    expect(found(withProperty(allCpp: false, type: _anyMap())), hasLength(1));
    // A C++ module encodes the map itself: nothing to refuse.
    expect(found(withProperty(allCpp: true)), isEmpty);
  });

  group('C bridge', () {
    test('JNI: a null map pointer is not dereferenced', () {
      final out = CppBridgeGenerator.generate(_spec());
      expect(out, contains('jbyteArray j_values = nullptr;\n    if (values != nullptr) {\n        int32_t values_map_len = *((const int32_t*)values) + 4;'));
      // A map that cannot be null is read directly.
      expect(out, contains('    int32_t a_map_len = *((const int32_t*)a) + 4;\n    jbyteArray j_a = env->NewByteArray((jsize)a_map_len);'));
    });

    test('a NitroAnyMap, nullable or not, is a uint8_t* in the header', () {
      final header = CppHeaderGenerator.generate(_spec());
      expect(header, contains('uint8_t* shapes_anyOf(int64_t instanceId, int64_t n, NitroError* _nitro_err);'));
      expect(header, contains('uint8_t* shapes_anyOrNull(int64_t instanceId, uint8_t* m, NitroError* _nitro_err);'));
      expect(header, isNot(contains('void* shapes_any')));
    });

    test('C++: an any-map return is cast from the interface\'s void*', () {
      final out = CppBridgeGenerator.generate(_spec(allCpp: true));
      expect(out, contains('return (uint8_t*)_impl->anyOf(n);'));
      expect(out, contains('return (uint8_t*)_impl->anyOrNull(m);'));
      expect(out, isNot(contains('return _impl->anyOf(n);')));
    });
  });
}
