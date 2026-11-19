// A typed-data field of a returned @HybridRecord reaches Dart as a view of the
// record's own buffer instead of a copy.
//
// Dart: a decode that owns the buffer passes the module's adopt to the reader,
//       and `_nitroFree` leaves a buffer alone once a field keeps it alive.
// C++ : the writer builds the record in the block Dart receives.
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_header_generator.dart';
import 'package:nitro_generator/src/generators/languages/cpp_native/cpp_interface_generator.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/record_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

BridgeRecordField _field(String name, String type, RecordFieldKind kind, {String? item}) => BridgeRecordField(name: name, dartType: type, kind: kind, itemTypeName: item, isNullable: type.endsWith('?'));

BridgeFunction _returning(String name, String type, {bool nativeAsync = false, bool result = false}) => BridgeFunction(
  dartName: name,
  cSymbol: 'http_$name',
  isAsync: false,
  isNativeAsync: nativeAsync,
  isResult: result,
  returnType: BridgeType(name: type, isRecord: true),
  params: [],
);

/// `Response` carries typed data itself, `Page` only through a nested record,
/// and `Stats` has none.
BridgeSpec _spec({
  bool withBytes = true,
  NativeImpl android = NativeImpl.kotlin,
  NativeImpl apple = NativeImpl.swift,
  NativeImpl? desktop,
}) => BridgeSpec(
  dartClassName: 'Http',
  lib: 'http',
  namespace: 'http',
  iosImpl: apple,
  macosImpl: apple,
  androidImpl: android,
  windowsImpl: desktop,
  linuxImpl: desktop,
  sourceUri: 'http.native.dart',
  recordTypes: [
    BridgeRecordType(
      name: 'Stats',
      fields: [_field('count', 'int', RecordFieldKind.primitive), _field('label', 'String', RecordFieldKind.primitive)],
    ),
    if (withBytes) ...[
      BridgeRecordType(
        name: 'Response',
        fields: [
          _field('status', 'int', RecordFieldKind.primitive),
          _field('body', 'Uint8List', RecordFieldKind.typedData),
          _field('trailer', 'Uint8List?', RecordFieldKind.typedData),
          _field('samples', 'Float64List', RecordFieldKind.typedData),
          _field('pcm', 'Int16List?', RecordFieldKind.typedData),
        ],
      ),
      BridgeRecordType(
        name: 'Page',
        fields: [_field('items', 'List<Response>', RecordFieldKind.listRecordObject, item: 'Response')],
      ),
    ],
  ],
  functions: [
    _returning('stats', 'Stats'),
    if (withBytes) ...[
      _returning('fetch', 'Response'),
      _returning('fetchAsync', 'Response', nativeAsync: true),
      _returning('page', 'Page'),
      _returning('tryFetch', 'Response', result: true),
    ],
  ],
  streams: [
    if (withBytes)
      BridgeStream(
        dartName: 'responses',
        registerSymbol: 'http_register_responses_stream',
        releaseSymbol: 'http_release_responses_stream',
        itemType: BridgeType(name: 'Response', isRecord: true),
        backpressure: Backpressure.dropLatest,
      ),
  ],
);

void main() {
  const owning = 'RecordReader.fromNative(res, adopt: _nitroAdopt)';

  group('Dart: owned record buffers', () {
    late String dart;
    setUpAll(() => dart = DartFfiGenerator.generate(_spec()));

    test('every typed list is read as a view, with its element size as the alignment', () {
      final codec = RecordGenerator.generateDartExtensions(_spec());
      expect(codec, contains('body: r.readBlobView()'));
      expect(codec, contains('trailer: r.readNullTag() ? null : r.readBlobView()'));
      expect(codec, contains('samples: Float64List.view(r.readBlobView(8).buffer)'));
      expect(codec, contains('pcm: r.readNullTag() ? null : Int16List.view(r.readBlobView(2).buffer)'));
    });

    test('a sync return of a record with a typed-data field decodes through an owning reader', () {
      expect(dart, contains('decoded = ResponseRecordExt.fromReader($owning);'));
    });

    test('a record that only nests one does too', () {
      expect(dart, contains('decoded = PageRecordExt.fromReader($owning);'));
    });

    test('native-async returns and stream items do too', () {
      const viaPort = 'ResponseRecordExt.fromReader(RecordReader.fromNative(rawPtr, adopt: _nitroAdopt))';
      expect(viaPort.allMatches(dart), hasLength(greaterThanOrEqualTo(2)));
    });

    test('a record without a typed-data field keeps the plain decode', () {
      expect(dart, contains('decoded = StatsRecordExt.fromNative(res);'));
    });

    test('a @NitroResult payload is not lent: its pointer is inside the result blob', () {
      expect(dart, contains('ResponseRecordExt.fromNative(res + 1)'));
      expect(dart, isNot(contains('fromNative(res + 1, adopt:')));
    });

    test('_nitroFree leaves a buffer alone once a field keeps it alive', () {
      expect(dart, contains('void _nitroFree(Pointer<NativeType> ptr) { if (!RecordReader.keptAlive(ptr)) _nitroFreePtr(ptr.cast()); }'));
    });

    test('the adopt export is bound as a non-leaf call taking the list as a handle', () {
      expect(
        dart,
        contains(
          "_nitroAdopt = _dylib.lookupFunction<Void Function(Handle, Pointer<Void>, IntPtr), void Function(Object, Pointer<Void>, int)>('http_nitro_adopt');",
        ),
      );
    });

    test('on the native-assets path the adopt export is an @Native external and the Dart API is initialised', () {
      final spec = _spec(android: NativeImpl.cpp, apple: NativeImpl.cpp, desktop: NativeImpl.cpp)..nativeAssets = true;
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains("@Native<Void Function(Handle, Pointer<Void>, IntPtr)>(symbol: 'http_nitro_adopt'"));
      expect(out, contains('external void _nitroAdopt(Object _list, Pointer<Void> _ptr, int _size);'));
      // A finalizable handle is a DL-API call: the module must initialise it even
      // when it has no stream or async method that would.
      expect(out, contains('_initDartApiDlPtr(NativeApi.initializeApiDLData)'));
    });

    test('a module with no such record is generated exactly as before', () {
      final plain = DartFfiGenerator.generate(_spec(withBytes: false));
      expect(plain, contains('void _nitroFree(Pointer<NativeType> ptr) => _nitroFreePtr(ptr.cast());'));
      expect(plain, isNot(contains('keptAlive')));
      expect(plain, isNot(contains('_nitroAdopt')));
    });
  });

  group('C: the buffer is handed to the list with a finalizable handle', () {
    // dart:ffi's asTypedList(finalizer:) frees when the creating isolate exits,
    // which dangles a list returned from Isolate.run. The handle is per group.
    for (final (name, spec) in [
      ('kotlin + swift', _spec()),
      ('desktop c++', _spec(desktop: NativeImpl.cpp)),
      ('all c++', _spec(android: NativeImpl.cpp, apple: NativeImpl.cpp, desktop: NativeImpl.cpp)),
    ]) {
      test('$name: every free export has an adopt export next to it', () {
        final bridge = CppBridgeGenerator.generate(spec);
        final frees = 'NITRO_EXPORT void http_nitro_free(void* ptr)'.allMatches(bridge).length;
        expect(frees, greaterThan(0));
        expect('NITRO_EXPORT void http_nitro_adopt(void* list, void* ptr, intptr_t size) {'.allMatches(bridge), hasLength(frees));
        expect(bridge, contains('Dart_NewFinalizableHandle_DL((Dart_Handle)list, ptr, size, http_nitro_adopted_gone);'));
        expect(CppHeaderGenerator.generate(spec), contains('NITRO_EXPORT void http_nitro_adopt(void* list, void* ptr, intptr_t size);'));
      });
    }

    test('a @zeroCopy typed-data return gets its own adopt export, releasing through the module', () {
      final spec = BridgeSpec(
        dartClassName: 'Dsp',
        lib: 'dsp',
        namespace: 'dsp',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'dsp.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'snapshot',
            cSymbol: 'dsp_snapshot',
            isAsync: false,
            returnType: BridgeType(name: 'Uint8List'),
            zeroCopyReturn: true,
            params: [],
          ),
        ],
      );
      final bridge = CppBridgeGenerator.generate(spec);
      final releases = 'NITRO_EXPORT void dsp_release_typed_data_return(void* ptr) {'.allMatches(bridge).length;
      expect(releases, greaterThan(0));
      expect('NITRO_EXPORT void dsp_nitro_adopt_typed_data_return(void* list, void* ptr, intptr_t size) {'.allMatches(bridge), hasLength(releases));
      expect(bridge, contains('dsp_release_typed_data_return(ptr); }'));
      expect(bridge, isNot(contains('dsp_nitro_adopt(')));
      expect(CppHeaderGenerator.generate(spec), contains('NITRO_EXPORT void dsp_nitro_adopt_typed_data_return(void* list, void* ptr, intptr_t size);'));
    });

    test('a module that lends nothing exports nothing new', () {
      final spec = _spec(withBytes: false);
      expect(CppBridgeGenerator.generate(spec), isNot(contains('nitro_adopt')));
      expect(CppHeaderGenerator.generate(spec), isNot(contains('nitro_adopt')));
    });
  });

  group('C++: the writer builds the block Dart receives', () {
    test('the writer sits in a versioned inline namespace', () {
      // Its layout differs from the std::vector one in older generated headers;
      // shared linker names would mix the two in a binary that holds both.
      final header = CppInterfaceGenerator.generate(_spec(desktop: NativeImpl.cpp));
      final open = header.indexOf('inline namespace nitro_writer_v2 {');
      final close = header.indexOf('} // namespace nitro_writer_v2');
      expect(open, isNonNegative);
      expect(header.indexOf('struct NitroRecordWriter {'), inInclusiveRange(open, close));
    });

    test('generated code does not reach into the writer', () {
      // _nitro_desktop_result_blob read `_w._buf`, a member that no longer exists.
      final bridge = CppBridgeGenerator.generate(_spec(desktop: NativeImpl.cpp));
      expect(bridge, contains('_nitro_desktop_result_blob'));
      expect(bridge, isNot(contains('._buf')));
      expect(CppInterfaceGenerator.generate(_spec(desktop: NativeImpl.cpp)), isNot(contains('_buf')));
    });
  });

  group('BridgeSpec.recordLendsBytes', () {
    test('own field, nested field, any typed list, a cycle, and an unknown name', () {
      final spec = BridgeSpec(
        dartClassName: 'X',
        lib: 'x',
        namespace: 'x',
        sourceUri: 'x.native.dart',
        recordTypes: [
          BridgeRecordType(name: 'Leaf', fields: [_field('b', 'Uint8List?', RecordFieldKind.typedData)]),
          BridgeRecordType(name: 'Holder', fields: [_field('leaf', 'Leaf?', RecordFieldKind.recordObject)]),
          BridgeRecordType(name: 'Floats', fields: [_field('f', 'Float32List', RecordFieldKind.typedData)]),
          BridgeRecordType(name: 'Loop', fields: [_field('next', 'Loop?', RecordFieldKind.recordObject)]),
        ],
      );
      expect(spec.recordLendsBytes('Leaf'), isTrue);
      expect(spec.recordLendsBytes('Holder'), isTrue);
      expect(spec.recordLendsBytes('Floats'), isTrue);
      expect(spec.recordLendsBytes('Loop'), isFalse);
      expect(spec.recordLendsBytes('Missing'), isFalse);
    });
  });
}
