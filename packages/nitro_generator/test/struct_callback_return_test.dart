// A callback that returns a `@HybridStruct`. The value travels back to native
// as a malloc'd `[4B len][fields]` block, exactly as a record does, so no
// pointer into Dart-owned memory crosses and nothing can outlive the call —
// the reason this used to be refused (L6).
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/languages/cpp_native/cpp_interface_generator.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:nitro_generator/src/generators/languages/web/web_bridge_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

BridgeField _field(String name, String type) => BridgeField(name: name, type: BridgeType(name: type, isNullable: type.endsWith('?')), isNamed: true);

BridgeSpec _spec({bool allCpp = false, bool web = false, List<BridgeField>? fields, String returns = 'Point'}) => BridgeSpec(
  dartClassName: 'Geo',
  lib: 'geo',
  namespace: 'geo',
  iosImpl: allCpp ? NativeImpl.cpp : NativeImpl.swift,
  androidImpl: allCpp ? NativeImpl.cpp : NativeImpl.kotlin,
  webImpl: web ? NativeImpl.wasm : null,
  sourceUri: 'geo.native.dart',
  structs: [BridgeStruct(name: 'Point', packed: false, fields: fields ?? [_field('x', 'double'), _field('label', 'String')])],
  recordTypes: [
    BridgeRecordType(name: 'Config', fields: [BridgeRecordField(name: 'name', dartType: 'String', kind: RecordFieldKind.primitive)]),
  ],
  functions: [
    BridgeFunction(
      dartName: 'sum',
      cSymbol: 'geo_sum',
      isAsync: false,
      returnType: BridgeType(name: 'double'),
      params: [
        BridgeParam(
          name: 'pointAt',
          type: BridgeType(name: '$returns Function(int)', isFunction: true, functionReturnType: returns, functionParams: [BridgeType(name: 'int')]),
        ),
        BridgeParam(name: 'n', type: BridgeType(name: 'int')),
      ],
    ),
  ],
);

void main() {
  group('validator', () {
    Iterable<ValidationIssue> issues(BridgeSpec s) => SpecValidator.validate(s).where((i) => i.code == 'UNSUPPORTED_FUNCTION_TYPE');

    test('a struct of non-null int / double / bool / String fields is a valid return', () {
      expect(issues(_spec()), isEmpty);
      expect(issues(_spec(fields: [_field('a', 'int'), _field('b', 'bool'), _field('c', 'double'), _field('d', 'String')])), isEmpty);
      expect(_spec().callbackReturnStructs, {'Point'});
      expect(_spec().structsCarriedAsBytes, {'Point'});
    });

    test('any other field kind is refused, with a hint that names the fix', () {
      for (final field in [_field('n', 'int?'), _field('bytes', 'Uint8List'), _field('inner', 'Point')]) {
        final found = issues(_spec(fields: [_field('x', 'double'), field])).toList();
        expect(found, hasLength(1), reason: field.type.name);
        expect(found.single.hint, contains('may only have non-null int, double, bool and String fields'));
        expect(found.single.hint, contains('Make "Point" a @HybridRecord'));
      }
    });

    test('a record return is unchanged', () {
      expect(issues(_spec(returns: 'Config')), isEmpty);
      expect(_spec(returns: 'Config').callbackReturnStructs, isEmpty);
    });
  });

  test('Dart encodes the struct after the callback returns, with the module allocator', () {
    final out = DartFfiGenerator.generate(_spec());
    expect(out, contains('Pointer<Uint8> Function(Int64)'));
    expect(out, contains('final _w = RecordWriter.acquire(); try { _v.writeFields(_w); return _w.toNative(_nitroNativeAllocator); } finally { RecordWriter.release(_w); }'));
    // The struct's byte codec is generated although no record embeds it.
    expect(out, contains('extension PointRecordExt on Point {'));
    // The callback is invoked before the scratch writer is taken.
    final at = out.indexOf('final _w = RecordWriter.acquire(); try { _v.writeFields(_w);');
    expect(out.lastIndexOf('final _v = ', at), greaterThan(out.lastIndexOf('(() {', at)));
  });

  test('Kotlin decodes the block with the struct decoder', () {
    final out = KotlinGenerator.generate(_spec());
    expect(out, contains('fun sum(pointAt: (p0: Long) -> Point, n: Long): Double'));
    expect(out, contains('@JvmStatic external fun _invoke_pointAt(callbackPtr: Long, arg0: Long): ByteArray'));
    expect(out, contains('val _bb = java.nio.ByteBuffer.wrap(_b).order(java.nio.ByteOrder.LITTLE_ENDIAN); _bb.getInt(); Point.decodeFrom(_bb) }'));
  });

  test('JNI hands the block to Kotlin as a byte array and frees it', () {
    final out = CppBridgeGenerator.generate(_spec());
    expect(out, contains(RegExp(r'JNIEXPORT jbyteArray JNICALL Java_\S+_1invoke_1pointAt\(')));
    final at = out.indexOf('_1invoke_1pointAt(');
    final body = out.substring(at, out.indexOf('\n}\n', at));
    expect(body, contains('typedef uint8_t* (*CB)(int64_t);'));
    expect(body, contains('if (!_ret) return nullptr;'));
    expect(body, contains('free(_ret);'));
  });

  test('Swift reads the block with the struct\'s byte codec and frees it', () {
    final out = SwiftGenerator.generate(_spec());
    expect(out, contains('func sum(pointAt: @escaping (Int64) -> Point, n: Int64) -> Double'));
    expect(out, contains('_ pointAt: @convention(c) (Int64) -> UnsafeMutablePointer<UInt8>?'));
    expect(out, contains('{ guard let _p = pointAt(arg0) else { _nitroCallbackReturnedNothing("pointAt") }; let _r = Point.fromReader(NitroRecordReader(ptr: _p)); free(_p); return _r }()'));
    expect(out, contains('extension Point {\n  public static func fromReader(_ r: NitroRecordReader) -> Point {'));
  });

  // A Dart callback that throws hands native nothing. Kotlin gets a null array
  // (an exception), C++ throws; Swift used to force-unwrap, which is a trap.
  test('Swift reports a callback that returned nothing instead of trapping', () {
    for (final returns in ['Point', 'Config']) {
      final out = SwiftGenerator.generate(_spec(returns: returns));
      expect(out, contains('private func _nitroCallbackReturnedNothing(_ name: String) -> Never {'), reason: returns);
      expect(out, contains('NSException(name: NSExceptionName("NitroCallbackError"), reason: "\\(name): the Dart callback threw and returned no value", userInfo: nil).raise()'), reason: returns);
      expect(out, isNot(contains('pointAt(arg0)!')), reason: returns);
    }
    // No value-returning callback: the helper is not emitted.
    final plain = BridgeSpec(dartClassName: 'Geo', lib: 'geo', namespace: 'geo', iosImpl: NativeImpl.swift, androidImpl: NativeImpl.kotlin, sourceUri: 'geo.native.dart');
    expect(SwiftGenerator.generate(plain), isNot(contains('_nitroCallbackReturnedNothing')));
  });

  group('C++', () {
    test('the impl gets the struct by value; a record is still the raw block', () {
      expect(CppInterfaceGenerator.generate(_spec(allCpp: true)), contains('virtual double sum(std::function<Point(int64_t)> pointAt, int64_t n) = 0;'));
      expect(CppInterfaceGenerator.generate(_spec(allCpp: true, returns: 'Config')), contains('virtual double sum(std::function<void*(int64_t)> pointAt, int64_t n) = 0;'));
    });

    test('the bridge decodes the block and releases it even when the decode throws', () {
      final out = CppBridgeGenerator.generate(_spec(allCpp: true));
      expect(out, contains('auto _rawfn_pointAt = reinterpret_cast<uint8_t* (*)(int64_t)>(pointAt);'));
      expect(out, contains('std::unique_ptr<uint8_t, void (*)(void*)> _rp(_rawfn_pointAt((int64_t)_a0), free);'));
      expect(out, contains('if (!_rp) throw std::runtime_error("pointAt: the callback returned no Point");'));
      expect(out, contains('NitroRecordReader _rr(_rp.get() + 4, (size_t)_rn);'));
      expect(out, contains('return nitro_Point_fromReader(_rr);'));
    });

    // An int64_t return cannot hold a pointer on a 32-bit ABI, and wasm
    // type-checks the call: a block is returned as a pointer on both.
    test('a block return is pointer-typed on native and on web', () {
      for (final returns in ['Point', 'Config']) {
        final out = CppBridgeGenerator.generate(_spec(allCpp: true, web: true, returns: returns));
        expect('reinterpret_cast<uint8_t* (*)(int64_t)>(pointAt)'.allMatches(out).length, 2, reason: returns);
        expect(out, isNot(contains('reinterpret_cast<int64_t (*)(int64_t)>(pointAt)')), reason: returns);
      }
    });
  });

  test('web returns the framed fields from a module allocation', () {
    final out = WebBridgeGenerator.generate(_spec(allCpp: true, web: true));
    expect(out, contains('return _module.nitroAllocBytes(_nitroEncodeFramed((w) => _r.writeFields(w))).toJS;'));
  });
}
