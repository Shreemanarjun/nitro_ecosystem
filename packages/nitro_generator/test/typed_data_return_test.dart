// Typed data returned without `@zeroCopy`, nullable or not, in every dispatch
// mode. The implementation returns its ordinary array (`ByteArray`, `Data`,
// `[Float]`, `std::vector<float>`); the bridge copies it into a
// `[8B byteLength][bytes]` block, and Dart copies a small block and views a
// large one. Until 0.9.0 the validator refused the return type outright.
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_header_generator.dart';
import 'package:nitro_generator/src/generators/languages/cpp_native/cpp_impl_generator.dart';
import 'package:nitro_generator/src/generators/languages/cpp_native/cpp_interface_generator.dart';
import 'package:nitro_generator/src/generators/languages/cpp_native/cpp_mock_generator.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:nitro_generator/src/generators/languages/web/web_bridge_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

BridgeFunction _fn(String name, String type, {bool isAsync = false, bool isNativeAsync = false, bool zeroCopy = false}) => BridgeFunction(
  dartName: name,
  cSymbol: 'td_$name',
  isAsync: isAsync,
  isNativeAsync: isNativeAsync,
  zeroCopyReturn: zeroCopy,
  returnType: BridgeType(name: type, isNullable: type.endsWith('?'), isFuture: isAsync || isNativeAsync),
  params: [BridgeParam(name: 'n', type: BridgeType(name: 'int'))],
);

BridgeSpec _spec({bool allCpp = false, bool web = false, List<BridgeFunction>? functions}) => BridgeSpec(
  dartClassName: 'Td',
  lib: 'td',
  namespace: 'td',
  iosImpl: allCpp ? NativeImpl.cpp : NativeImpl.swift,
  androidImpl: allCpp ? NativeImpl.cpp : NativeImpl.kotlin,
  webImpl: web ? NativeImpl.wasm : null,
  sourceUri: 'td.native.dart',
  functions:
      functions ??
      [
        _fn('bytes', 'Uint8List'),
        _fn('floats', 'Float32List'),
        _fn('doublesOrNull', 'Float64List?'),
        _fn('later', 'Float32List?', isAsync: true),
        _fn('posted', 'Uint8List', isNativeAsync: true),
        _fn('postedOrNull', 'Int32List?', isNativeAsync: true),
      ],
);

String _body(String out, String marker) {
  final at = out.indexOf(marker);
  expect(at, isNonNegative, reason: 'no "$marker"');
  return out.substring(at, out.indexOf('\n}\n', at));
}

void main() {
  test('the validator accepts it in every mode, and still guards @zeroCopy', () {
    expect(SpecValidator.validate(_spec()).where((i) => i.isError), isEmpty);
    expect(SpecValidator.validate(_spec(allCpp: true)).where((i) => i.isError), isEmpty);
    final zc = _spec(functions: [_fn('z', 'Uint8List', isNativeAsync: true, zeroCopy: true)]);
    expect(SpecValidator.validate(zc).map((i) => i.code), contains('INVALID_ZERO_COPY_RETURN'));
  });

  test('a copied return exports the adopt function; a @zeroCopy one alone does not', () {
    expect(_spec().hasCopiedTypedDataReturn, isTrue);
    expect(_spec().exportsAdopt, isTrue);
    final zc = _spec(functions: [_fn('z', 'Uint8List', zeroCopy: true)]);
    expect(zc.hasCopiedTypedDataReturn, isFalse);
    expect(zc.exportsAdopt, isFalse);
    expect(CppHeaderGenerator.generate(_spec()), contains('NITRO_EXPORT void td_nitro_adopt(void* list, void* ptr, intptr_t size);'));
    expect(CppHeaderGenerator.generate(zc), isNot(contains('td_nitro_adopt(')));
    expect(CppBridgeGenerator.generate(_spec()), contains('NITRO_EXPORT void td_nitro_adopt(void* list, void* ptr, intptr_t size) {'));
  });

  group('Dart', () {
    final out = DartFfiGenerator.generate(_spec());

    test('a large block is viewed and owned, a small one copied and freed', () {
      final body = _body(out, '  Float32List floats(int n) {');
      expect(body, contains('final payload = Pointer<Float>.fromAddress(res.address + 8).asTypedList(byteLength ~/ 4);'));
      expect(body, contains('if (byteLength >= RecordReader.lendMinBytes) {'));
      expect(body, contains('_nitroAdopt(payload, res.cast<Void>(), byteLength);'));
      expect(body, contains('return Float32List.fromList(payload);'));
      // The lent path returns before the free; the copied one frees.
      expect(body.indexOf('return payload;'), lessThan(body.indexOf('_nitroFree(res);')));
    });

    test('null pointer: null for a nullable return, an error otherwise', () {
      expect(_body(out, '  Float64List? doublesOrNull(int n) {'), contains('if (res == nullptr) {\n        return null;'));
      expect(_body(out, '  Uint8List bytes(int n) {'), contains("throw StateError('Native Uint8List return was null');"));
    });

    test('@nitroNativeAsync takes the list itself or the address of its block', () {
      final body = _body(out, '  Future<Uint8List> posted(int n) {');
      expect(body, contains('if (raw is Uint8List) return raw;'));
      expect(body, contains('final rawPtr = Pointer<Uint8>.fromAddress(raw as int);'));
      expect(body, contains('_nitroAdopt(payload, rawPtr.cast<Void>(), byteLength);'));
      expect(body, contains('native posted null for a non-nullable Uint8List result'));
      final nullable = _body(out, '  Future<Int32List?> postedOrNull(int n) {');
      expect(nullable, contains('if (raw is Int32List) return raw;'));
      expect(nullable, contains('if (raw == null || raw == 0) { return null; }'));
      expect(nullable, contains('asTypedList(byteLength ~/ 4)'));
    });
  });

  group('Kotlin', () {
    final out = KotlinGenerator.generate(_spec());

    test('the interface returns ordinary arrays', () {
      expect(out, contains('fun bytes(n: Long): ByteArray'));
      expect(out, contains('fun floats(n: Long): FloatArray'));
      expect(out, contains('fun doublesOrNull(n: Long): DoubleArray?'));
      expect(out, contains('suspend fun later(n: Long): FloatArray?'));
      expect(out, isNot(contains('java.nio.ByteBuffer\n')));
    });

    test('sync and @nitroAsync hand the array to JNI as it is', () {
      expect(out, contains('fun doublesOrNull_call(instanceId: Long, n: Long): DoubleArray? {'));
      expect(out, contains('return impl.doublesOrNull(n)'));
      expect(out, contains('fun later_call(instanceId: Long, n: Long): FloatArray? {'));
    });

    test('@nitroNativeAsync posts the block; a null array is address 0', () {
      expect(
        out,
        contains(
          'postBytesToPort(dartPort, result.let { a -> java.nio.ByteBuffer.allocate(8 + a.size * 1).order(java.nio.ByteOrder.LITTLE_ENDIAN).also { it.putLong(a.size.toLong() * 1); it.put(a) }.array() })',
        ),
      );
      expect(out, contains('result?.let { a -> java.nio.ByteBuffer.allocate(8 + a.size * 4)'));
      expect(out, contains('it.putLong(a.size.toLong() * 4); it.asIntBuffer().put(a) }.array() })'));
    });

    test('every element type has its buffer view', () {
      const views = {
        'Uint8List': ('1', 'it.put(a)'),
        'Int8List': ('1', 'it.put(a)'),
        'Int16List': ('2', 'it.asShortBuffer().put(a)'),
        'Uint16List': ('2', 'it.asShortBuffer().put(a)'),
        'Int32List': ('4', 'it.asIntBuffer().put(a)'),
        'Uint32List': ('4', 'it.asIntBuffer().put(a)'),
        'Float32List': ('4', 'it.asFloatBuffer().put(a)'),
        'Float64List': ('8', 'it.asDoubleBuffer().put(a)'),
        'Int64List': ('8', 'it.asLongBuffer().put(a)'),
        'Uint64List': ('8', 'it.asLongBuffer().put(a)'),
      };
      for (final MapEntry(key: type, value: (size, put)) in views.entries) {
        final kotlin = KotlinGenerator.generate(_spec(functions: [_fn('p', type, isNativeAsync: true)]));
        expect(kotlin, contains('allocate(8 + a.size * $size)'), reason: type);
        expect(kotlin, contains('it.putLong(a.size.toLong() * $size); $put }'), reason: type);
      }
    });
  });

  group('JNI', () {
    final out = CppBridgeGenerator.generate(_spec());

    // On a device this aborted: "incompatible array type double[] expected byte[]".
    test('a nullable typed list is read with its own array type', () {
      final body = _body(out, 'uint8_t* td_doublesOrNull(int64_t instanceId');
      expect(body, contains('jdoubleArray jarr = (jdoubleArray)env->CallStaticObjectMethod('));
      expect(body, contains('env->GetDoubleArrayRegion(jarr, 0, len, (jdouble*)(result + sizeof(int64_t)));'));
      expect(body, contains('size_t byteLen = (size_t)len * sizeof(double);'));
      expect(body, isNot(contains('GetByteArrayRegion')));
      expect(out, contains('"doublesOrNull_call", "(JJ)[D"'));
    });

    test('a null array is a null pointer, and the block starts with its byte length', () {
      final body = _body(out, 'uint8_t* td_floats(int64_t instanceId');
      expect(body, contains('if (jarr == nullptr) {'));
      expect(body, contains('*((int64_t*)result) = (int64_t)byteLen;'));
    });
  });

  group('Swift', () {
    final out = SwiftGenerator.generate(_spec());

    test('the protocol returns Data or an array, optional when nullable', () {
      expect(out, contains('func bytes(n: Int64) -> Data'));
      expect(out, contains('func floats(n: Int64) -> [Float]'));
      expect(out, contains('func doublesOrNull(n: Int64) -> [Double]?'));
      expect(out, contains('func later(n: Int64) async throws -> [Float]?'));
    });

    // `[Float]??` did not compile, and `try?` turned a thrown error into null.
    test('@nitroAsync: one optional, and a thrown error is raised', () {
      final body = _body(out, '_td_call_later');
      expect(body, contains('var result: [Float]? = nil'));
      expect(body, isNot(contains('??')));
      expect(body, contains('do { result = try await impl.later(n: n) }'));
      expect(body, contains('catch { _thrownError = error }'));
      expect(body, contains('NSException('));
      expect(body, contains('guard let r = result else { return nil }'));
      expect(body, contains('return _nitroCopyTypedDataArrayReturn(r)'));
    });

    test('@nitroNativeAsync posts the address of the copy, 0 for nil', () {
      final body = _body(out, '_td_call_postedOrNull');
      expect(body, contains('let _result: [Int32]? = try await impl.postedOrNull(n: n)'));
      expect(body, contains('let _recPtr = _result.map { _nitroCopyTypedDataArrayReturn(\$0) } ?? nil'));
      expect(body, contains('_obj.value.as_int64 = _recPtr != nil ? Int64(bitPattern: UInt64(UInt(bitPattern: _recPtr!))) : 0'));
    });
  });

  group('C++', () {
    final spec = _spec(allCpp: true);

    test('the impl returns a vector of the element type, optional when nullable', () {
      final iface = CppInterfaceGenerator.generate(spec);
      expect(iface, contains('virtual std::vector<uint8_t> bytes(int64_t n) = 0;'));
      expect(iface, contains('virtual std::vector<float> floats(int64_t n) = 0;'));
      expect(iface, contains('virtual std::optional<std::vector<double>> doublesOrNull(int64_t n) = 0;'));
      expect(iface, contains('virtual std::optional<std::vector<float>> later(int64_t n) = 0;'));
      expect(iface, contains('virtual void posted(int64_t n, NitroError* _nitro_err, int64_t dartPort) = 0;'));
      // @zeroCopy keeps the ownership-transferring buffer.
      final zc = CppInterfaceGenerator.generate(_spec(allCpp: true, functions: [_fn('z', 'Uint8List', zeroCopy: true)]));
      expect(zc, contains('virtual NitroCppBuffer z(int64_t n) = 0;'));
    });

    test('the bridge copies the vector into the block; a null optional is nullptr', () {
      final bridge = CppBridgeGenerator.generate(spec);
      final body = _body(bridge, 'uint8_t* td_doublesOrNull(int64_t instanceId');
      expect(body, contains('auto _res = _impl->doublesOrNull(n);'));
      expect(body, contains('if (!_res) return nullptr;'));
      expect(body, contains('const size_t _n = (*_res).size() * sizeof((*_res)[0]);'));
      expect(body, contains('uint8_t* _blk = (uint8_t*)malloc(sizeof(int64_t) + _n);'));
      expect(body, contains('*(int64_t*)_blk = (int64_t)_n;'));
      expect(body, contains('if (_n != 0) memcpy(_blk + sizeof(int64_t), (*_res).data(), _n);'));
      expect(_body(bridge, 'uint8_t* td_bytes(int64_t instanceId'), contains('const size_t _n = _res.size() * sizeof(_res[0]);'));
    });

    test('the starter and the mock declare the interface\'s own signatures', () {
      final starter = CppImplGenerator.generate(spec);
      expect(starter, contains('std::vector<uint8_t> bytes(int64_t n) override {'));
      expect(starter, contains('std::optional<std::vector<double>> doublesOrNull(int64_t n) override {'));
      expect(starter, contains('void posted(int64_t n, NitroError* _nitro_err, int64_t dartPort) override {'));
      expect(starter, contains('// Typed-data result: post it as kTypedData (the VM copies it), or'));
      final mock = CppMockGenerator.generateMockHeader(spec);
      expect(mock, contains('MOCK_METHOD(std::vector<uint8_t>, bytes, (int64_t n), (override));'));
      expect(mock, contains('MOCK_METHOD(std::optional<std::vector<double>>, doublesOrNull, (int64_t n), (override));'));
      expect(mock, contains('MOCK_METHOD(void, posted, (int64_t n, NitroError* _nitro_err, int64_t dartPort), (override));'));
    });
  });

  test('web: @nitroNativeAsync takes the list or the address of its block', () {
    final out = WebBridgeGenerator.generate(_spec(allCpp: true, web: true));
    final body = _body(out, '  Future<Int32List?> postedOrNull(int n) {');
    expect(body, contains('if (raw is Int32List) return raw;'));
    expect(body, contains('if (raw == null || raw == 0) return null;'));
    expect(body, contains('final _byteLen = _m.readI64(_ptr);'));
    expect(body, contains('final _bytes = _m.readBytes(_ptr + 8, _byteLen);'));
    expect(body, contains('_m.nitroFree(_ptr);'));
    expect(body, isNot(contains('RecordExt')));
  });
}
