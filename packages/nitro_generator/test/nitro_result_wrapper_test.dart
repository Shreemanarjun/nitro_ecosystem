// @NitroResult values that have no result encoding of their own — a nullable
// value, a list, typed data, a struct — travel as a hidden one-field record
// (BridgeSpec.resultWrapper). A one-field record is encoded exactly as its
// field, so every backend reuses its record codec and Dart reads the field
// back without ever seeing the wrapper.
//
// Run end to end (C++, Swift and Kotlin implementations) by the §88 group of
// the nitro_type_coverage plugin; these pin the generated shapes.

import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/languages/cpp_native/cpp_interface_generator.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:nitro_generator/src/generators/languages/web/web_bridge_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

BridgeFunction _result(String name, String type, RecordFieldKind kind, {String? item, bool isRecord = false, bool isAsync = false}) => BridgeFunction(
  dartName: name,
  cSymbol: 'res_$name',
  isAsync: isAsync,
  isResult: true,
  returnType: BridgeType(
    name: type,
    isRecord: isRecord,
    isNullable: type.endsWith('?'),
    isFuture: isAsync,
    recordListItemType: item,
    recordListItemIsPrimitive: const {'int', 'double', 'bool', 'String'}.contains(item),
  ),
  // What the extractor records for a @NitroResult method.
  resultField: BridgeRecordField(name: 'value', dartType: type, kind: kind, itemTypeName: item, isNullable: type.endsWith('?')),
  params: [BridgeParam(name: 'code', type: BridgeType(name: 'int'))],
);

BridgeSpec _spec({bool allCpp = false, List<BridgeFunction>? functions}) => BridgeSpec(
  dartClassName: 'Res',
  lib: 'res',
  namespace: 'res',
  androidImpl: allCpp ? NativeImpl.cpp : NativeImpl.kotlin,
  iosImpl: allCpp ? NativeImpl.cpp : NativeImpl.swift,
  macosImpl: allCpp ? NativeImpl.cpp : NativeImpl.swift,
  windowsImpl: NativeImpl.cpp,
  linuxImpl: NativeImpl.cpp,
  sourceUri: 'res.native.dart',
  enums: [
    BridgeEnum(name: 'Mode', startValue: 0, values: ['a', 'b']),
  ],
  structs: [
    BridgeStruct(
      name: 'Pt',
      packed: false,
      fields: [
        BridgeField(name: 'x', type: BridgeType(name: 'double')),
      ],
    ),
  ],
  recordTypes: [
    BridgeRecordType(
      name: 'Reply',
      fields: [BridgeRecordField(name: 'status', dartType: 'int', kind: RecordFieldKind.primitive)],
    ),
  ],
  functions:
      functions ??
      [
        _result('optInt', 'int?', RecordFieldKind.primitive),
        _result('ints', 'List<int>', RecordFieldKind.listPrimitive, item: 'int', isRecord: true),
        _result('bytes', 'Uint8List', RecordFieldKind.typedData),
        _result('point', 'Pt', RecordFieldKind.struct),
        _result('laterInts', 'List<int>', RecordFieldKind.listPrimitive, item: 'int', isRecord: true, isAsync: true),
        // Values with an encoding of their own: no wrapper.
        _result('count', 'int', RecordFieldKind.primitive),
        _result('mode', 'Mode', RecordFieldKind.enumValue),
        _result('reply', 'Reply', RecordFieldKind.recordObject, isRecord: true),
      ],
);

void main() {
  group('BridgeSpec.resultWrapper', () {
    final spec = _spec();
    BridgeRecordType? wrapperOf(String name) => spec.resultWrapper(spec.functions.firstWhere((f) => f.dartName == name));

    test('a nullable value, a list, typed data and a struct get a one-field wrapper', () {
      expect(spec.resultWrappers.map((w) => w.name), ['ResOptIntOk', 'ResIntsOk', 'ResBytesOk', 'ResPointOk', 'ResLaterIntsOk']);
      final ints = wrapperOf('ints')!;
      expect(ints.fields, hasLength(1));
      expect([ints.fields.single.name, ints.fields.single.kind, ints.fields.single.itemTypeName], ['value', RecordFieldKind.listPrimitive, 'int']);
    });

    test('a scalar, an enum and a record keep their own encoding', () {
      expect([wrapperOf('count'), wrapperOf('mode'), wrapperOf('reply')], [null, null, null]);
    });

    test('every nullable form wraps; a list of anything but scalars, enums or records does not', () {
      BridgeRecordType? wrap(String type, RecordFieldKind kind, {String? item}) {
        final f = _result('x', type, kind, item: item);
        return _spec(functions: [f]).resultWrapper(f);
      }

      expect(wrap('String?', RecordFieldKind.primitive), isNotNull);
      expect(wrap('Mode?', RecordFieldKind.enumValue), isNotNull);
      expect(wrap('Reply?', RecordFieldKind.recordObject), isNotNull);
      expect(wrap('Pt?', RecordFieldKind.struct), isNotNull);
      expect(wrap('List<Mode>', RecordFieldKind.listEnumValue, item: 'Mode'), isNotNull);
      expect(wrap('List<Reply>', RecordFieldKind.listRecordObject, item: 'Reply'), isNotNull);
      // The extractor files an unknown item type under listPrimitive.
      expect(wrap('List<DateTime>', RecordFieldKind.listPrimitive, item: 'DateTime'), isNull);
      // The record codec has no nullable list items.
      expect(wrap('List<int?>', RecordFieldKind.listPrimitive, item: 'int'), isNull);
    });

    test('DateTime and uint64 wrap as an int64, nullable or not', () {
      for (final (type, wire) in [('DateTime', WrappedWire.dateTime), ('DateTime?', WrappedWire.dateTime), ('uint64', WrappedWire.uint64), ('uint64?', WrappedWire.uint64)]) {
        final f = _result('x', type, RecordFieldKind.primitive);
        final carrier = _spec(functions: [f]).resultCarrier(f) as WrappedCarrier;
        expect([carrier.wire, carrier.wrapper.fields.single.dartType], [wire, type.endsWith('?') ? 'int?' : 'int'], reason: type);
      }
    });

    test('a method that is not a result method, or has no result field, has none', () {
      final plain = BridgeFunction(dartName: 'n', cSymbol: 'res_n', isAsync: false, returnType: BridgeType(name: 'int?'), params: []);
      final bare = BridgeFunction(dartName: 'm', cSymbol: 'res_m', isAsync: false, isResult: true, returnType: BridgeType(name: 'int?'), params: []);
      expect([_spec().resultWrapper(plain), _spec().resultWrapper(bare)], [null, null]);
    });

    test('native codecs declare the wrappers after the module\'s own records; Dart gets no class for them', () {
      expect(spec.nativeRecordTypes.map((r) => r.name), ['Reply', 'ResOptIntOk', 'ResIntsOk', 'ResBytesOk', 'ResPointOk', 'ResLaterIntsOk']);
      expect(spec.localRecordTypes.map((r) => r.name), ['Reply']);
      expect(DartFfiGenerator.generate(spec), isNot(contains('ResIntsOk')));
    });
  });

  group('Dart decodes a wrapped value as the wrapper\'s one field', () {
    final dart = DartFfiGenerator.generate(_spec());

    test('each kind is read with the record field read for it', () {
      expect(dart, contains('return NitroOk(r.readNullTag() ? null : r.readInt());'));
      expect(dart, contains('return NitroOk(r.readIntList());'));
      expect(dart, contains('return NitroOk(r.readBlobView());'));
      expect(dart, contains('return NitroOk(PtRecordExt.fromReader(r));'));
    });

    test('the Dart API keeps the declared types', () {
      expect(dart, contains('NitroResultValue<int?> optInt(int code)'));
      expect(dart, contains('NitroResultValue<List<int>> ints(int code)'));
      expect(dart, contains('NitroResultValue<Uint8List> bytes(int code)'));
      expect(dart, contains('Future<NitroResultValue<List<int>>> laterInts(int code)'));
    });

    test('a struct carried by a wrapper gets its Dart codec, though no record names it', () {
      expect(dart, contains('extension PtRecordExt on Pt'));
    });

    test('a null pointer is reported, never read through', () {
      // A sync bridge that could not run the method leaves the reason in the
      // error slot; an async one has none.
      expect(dart, contains('if (res == nullptr) {'));
      expect(dart, contains("NitroRuntime.throwIfOutParamError(_nitroErr, nativeFree: _nitroFree, methodName: 'ints');"));
      expect(dart, contains('return NitroErr(e.message);'));
      expect(dart, contains("return NitroErr('laterInts: the native side returned no result');"));
    });

    test('an enum result is decoded with the generated toMode() extension', () {
      expect(dart, contains('return NitroOk(_r.readInt().toMode());'));
      expect(dart, isNot(contains('EnumExt.fromNativeValue')));
    });

    test('web reads the same field out of the framed bytes', () {
      final web = WebBridgeGenerator.generate(
        BridgeSpec(
          dartClassName: 'Res',
          lib: 'res',
          namespace: 'res',
          androidImpl: NativeImpl.cpp,
          iosImpl: NativeImpl.cpp,
          webImpl: NativeImpl.wasm,
          sourceUri: 'res.native.dart',
          functions: [_result('ints', 'List<int>', RecordFieldKind.listPrimitive, item: 'int', isRecord: true)],
        ),
      );
      expect(web, contains('final r = RecordReader.fromFramedBytes(_m.readFramed(_p + 1));'));
      expect(web, contains('return NitroOk(r.readIntList());'));
      expect(web, contains("if (_p == 0) return NitroErr<List<int>>('ints: the native side returned no result');"));
    });
  });

  group('Kotlin', () {
    final kotlin = KotlinGenerator.generate(_spec());

    test('the wrapper is a record class and the value is encoded through it', () {
      expect(kotlin, contains('data class ResIntsOk(val value: List<Long>)'));
      expect(kotlin, contains('data class ResOptIntOk(val value: Long?)'));
      expect(kotlin, contains('data class ResBytesOk(val value: ByteArray)'));
      expect(kotlin, contains('nitroWriteResultTag(0, ResIntsOk(_result).encode())'));
      expect(kotlin, contains('nitroWriteResultTag(0, ResPointOk(_result).encode())'));
    });

    test('the implementation returns the value itself', () {
      expect(kotlin, contains('fun ints(code: Long): List<Long>'));
      expect(kotlin, contains('fun optInt(code: Long): Long?'));
      expect(kotlin, contains('fun bytes(code: Long): ByteArray'));
    });

    test('a scalar keeps its own encoder', () {
      expect(kotlin, contains('nitroEncodeResultInt64(_result)'));
      expect(kotlin, isNot(contains('ResCountOk')));
    });
  });

  group('Swift', () {
    final swift = SwiftGenerator.generate(_spec());

    test('the wrapper is a record struct and the value is encoded through it', () {
      expect(swift, contains('public struct ResIntsOk: NitroEncodable {'));
      expect(swift, contains('return _nitroEncodeResultRecord(ResIntsOk(value: result))'));
      expect(swift, contains('return _nitroEncodeResultRecord(ResOptIntOk(value: result))'));
      // @nitroAsync: the awaited value.
      expect(swift, contains('return _nitroEncodeResultRecord(ResLaterIntsOk(value: _ok))'));
    });

    test('an enum goes out as its raw value', () {
      // `enum Mode: Int64` does not convert to Int64 on its own.
      expect(swift, contains('return _nitroEncodeResultInt64(result.rawValue)'));
    });

    test('the block length is its 4-byte prefix, and the block is freed', () {
      // It was `payload.pointee` — one byte: a value encoding to 256 bytes or
      // more was copied short and Dart read past the allocation. It also leaked.
      expect(swift, contains('if let block = block { memcpy(&length, block, 4) }'));
      expect(swift, contains('let blockLen = 4 + Int(Int32(littleEndian: length))'));
      expect(swift, contains('memcpy(buf + 1, block, blockLen); free(block)'));
      expect(swift, isNot(contains('payload.pointee')));
    });

    test('every exit is a result blob, never nil', () {
      expect(swift, contains('else { return _nitroEncodeResultError("Res is not registered") }'));
      expect(swift, contains('else { return _nitroEncodeResultError("laterInts produced no result") }'));
      expect(RegExp(r'Registry\.impl else \{ return nil \}\n    do \{').hasMatch(swift), isFalse);
    });

    test('an async nullable result keeps "no result" apart from a nil value', () {
      final s = SwiftGenerator.generate(_spec(functions: [_result('later', 'int?', RecordFieldKind.primitive, isAsync: true)]));
      expect(s, contains('var _nitroOk: Optional<Int64?> = nil'));
    });
  });

  group('C++', () {
    test('the implementation returns the wrapper\'s field type, not a pre-encoded buffer', () {
      final iface = CppInterfaceGenerator.generate(_spec());
      expect(iface, contains('virtual std::optional<int64_t> optInt(int64_t code) = 0;'));
      expect(iface, contains('virtual std::vector<int64_t> ints(int64_t code) = 0;'));
      expect(iface, contains('virtual std::vector<uint8_t> bytes(int64_t code) = 0;'));
      expect(iface, contains('virtual Pt point(int64_t code) = 0;'));
      // Unwrapped: a record is still handed over already encoded.
      expect(iface, contains('virtual NitroCppBuffer reply(int64_t code) = 0;'));
      expect(iface, contains('struct ResIntsOk {'));
    });

    for (final (label, allCpp) in [('desktop dispatch of a Kotlin/Swift module', false), ('all-C++ module', true)]) {
      test('$label wraps, encodes and tags the value', () {
        final bridge = CppBridgeGenerator.generate(_spec(allCpp: allCpp));
        expect(bridge, contains('ResIntsOk _ok;'));
        expect(bridge, contains('_ok.value = _impl->ints(code);'));
        expect(bridge, contains('NitroCppBuffer _res = _ok.toNativeBuffer();'));
        // The block is freed on the allocation-failure path too.
        expect(bridge, contains('if (!_out) { free((void*)_res.data); return nullptr; }'));
      });
    }
  });

  // ── Values that are already a self-describing block ────────────────────────
  // A map, an any-map, a list of variants and a nullable variant go out behind
  // the tag as the block their plain return produces; tag 2 is "ok, null".
  group('BlockCarrier', () {
    BridgeFunction block(String name, String type, {bool isMap = false, bool isAnyMap = false, bool isVariantList = false, bool isAsync = false}) => BridgeFunction(
      dartName: name,
      cSymbol: 'res_$name',
      isAsync: isAsync,
      isResult: true,
      returnType: BridgeType(
        name: type,
        // As the extractor types it: an any-map is not a record.
        isRecord: !isAnyMap,
        isNullable: type.endsWith('?'),
        isFuture: isAsync,
        isMap: isMap,
        isAnyMap: isAnyMap,
        isVariantList: isVariantList,
        recordListItemType: isVariantList ? 'Event' : null,
      ),
      resultField: BridgeRecordField(name: 'value', dartType: type, kind: RecordFieldKind.primitive, isNullable: type.endsWith('?')),
      params: [],
    );
    final variants = [
      BridgeVariant(
        name: 'Event',
        cases: [
          BridgeVariantCase(
            name: 'EventTap',
            label: 'tap',
            fields: [
              BridgeRecordField(name: 'x', dartType: 'int', kind: RecordFieldKind.primitive),
              BridgeRecordField(name: 'label', dartType: 'String', kind: RecordFieldKind.primitive),
            ],
          ),
        ],
      ),
    ];
    final functions = [
      block('table', 'Map<String, int>', isMap: true),
      block('optTable', 'Map<String, int>?', isMap: true),
      block('any', 'NitroAnyMap', isAnyMap: true),
      block('events', 'List<Event>', isVariantList: true),
      block('optEvent', 'Event?'),
      block('event', 'Event'),
    ];
    BridgeSpec spec({bool allCpp = false}) => BridgeSpec(
      dartClassName: 'Res',
      lib: 'res',
      namespace: 'res',
      androidImpl: allCpp ? NativeImpl.cpp : NativeImpl.kotlin,
      iosImpl: allCpp ? NativeImpl.cpp : NativeImpl.swift,
      windowsImpl: NativeImpl.cpp,
      linuxImpl: NativeImpl.cpp,
      sourceUri: 'res.native.dart',
      variants: variants,
      functions: functions,
    );

    test('classification', () {
      final s = spec();
      String carrier(String name) => switch (s.resultCarrier(s.functions.firstWhere((f) => f.dartName == name))) {
        BlockCarrier(:final kind, :final isNullable) => '${kind.name}${isNullable ? '?' : ''}',
        final other => other.runtimeType.toString(),
      };
      expect(
        [for (final f in functions) carrier(f.dartName)],
        ['map', 'map?', 'anyMap', 'variantList', 'variant?', 'RecordCarrier'],
      );
      expect(SpecValidator.validate(s).where((i) => i.code == 'E015'), isEmpty);
    });

    test('Dart checks the null tag before the error branch, then decodes the block', () {
      final dart = DartFfiGenerator.generate(spec());
      // Tag 2 must not be read as an error message.
      final optTable = dart.substring(dart.indexOf('NitroResultValue<Map<String, int>?> optTable('));
      expect(optTable.indexOf('if (_tag == 2) return NitroOk(null);'), lessThan(optTable.indexOf('if (_tag != 0) {')));
      expect(dart, contains('return NitroOk(EventVariantExt.fromNative(res + 1));'));
      expect(dart, contains('return NitroOk(nitroAnyMapFromNative(res + 1));'));
      expect(dart, contains('RecordReader.decodeList(res + 1, (r) => EventVariantExt.fromReader(r))'));
    });

    test('Kotlin builds the block with the encoder the plain return uses', () {
      final kotlin = KotlinGenerator.generate(spec());
      expect(kotlin, contains('nitroWriteResultTag(0, nitroEncodeMap(_result, 1) { o, v -> o.putInt64(v) })'));
      expect(kotlin, contains('if (_result == null) byteArrayOf(2, 0, 0, 0, 0) else {'));
      expect(kotlin, contains('nitroWriteResultTag(0, NitroAnyMapCodec.encode(_result))'));
      expect(kotlin, contains('nitroWriteResultTag(0, _buf.array())'));
      expect(kotlin, contains('nitroWriteResultTag(0, _result.encode())'));
    });

    test('Swift builds the block with the encoder the plain return uses', () {
      final swift = SwiftGenerator.generate(spec());
      // The impl returns a typed dictionary: there is no cast that could fail.
      expect(swift, contains('return _nitroWriteResultTag(0, _nitroEncodeMap(result, 1) { w, v in w.writeInt(v) })'));
      expect(swift, contains('guard let result = result else { return _nitroWriteResultTag(2, nil) }'));
      expect(swift, contains('return _nitroWriteResultTag(0, _nitroEncodeAnyMapBinary(result))'));
      expect(swift, contains('return _nitroWriteResultTag(0, NitroRecordWriter.encodeList(result) { w, e in e.writeFields(to: w) })'));
      expect(swift, contains('return _nitroWriteResultTag(0, result.toNative())'));
      expect(swift, isNot(contains('returned a value of the wrong type')));
    });

    test('C++ passes the impl\'s block through; a buffer with no data is null or an error', () {
      final bridge = CppBridgeGenerator.generate(spec(allCpp: true));
      expect(bridge, contains('if (!_res.data) { NitroRecordWriter _w; return _nitro_desktop_result_blob(2, _w); }'));
      expect(bridge, contains('if (!_res.data) { return _nitro_desktop_result_err("table returned no value"); }'));
      // An any-map impl returns the block's address, not a NitroCppBuffer.
      expect(bridge, contains('const uint8_t* _blk = static_cast<const uint8_t*>(_impl->any());'));
    });
  });

  group('DateTime and uint64 travel as an int64', () {
    final functions = [
      _result('at', 'DateTime', RecordFieldKind.primitive),
      _result('optAt', 'DateTime?', RecordFieldKind.primitive),
      _result('big', 'uint64', RecordFieldKind.primitive),
      _result('optBig', 'uint64?', RecordFieldKind.primitive),
    ];

    test('Dart rebuilds the DateTime; a uint64 is the int', () {
      final dart = DartFfiGenerator.generate(_spec(functions: functions));
      expect(dart, contains('return NitroOk(DateTime.fromMillisecondsSinceEpoch(r.readInt()));'));
      expect(dart, contains('return NitroOk(r.readNullTag() ? null : DateTime.fromMillisecondsSinceEpoch(r.readInt()));'));
      expect(dart, contains('return NitroOk(r.readNullTag() ? null : r.readInt());'));
    });

    test('Swift converts Date (rounded to the millisecond) and UInt64 (same bits)', () {
      final swift = SwiftGenerator.generate(_spec(functions: functions));
      expect(swift, contains('ResAtOk(value: Int64((result.timeIntervalSince1970 * 1000).rounded()))'));
      expect(swift, contains(r'ResOptAtOk(value: result.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) })'));
      expect(swift, contains('ResBigOk(value: Int64(bitPattern: result))'));
      expect(swift, contains(r'ResOptBigOk(value: result.map { Int64(bitPattern: $0) })'));
    });

    test('a C++ impl keeps its usual scalar types', () {
      final iface = CppInterfaceGenerator.generate(_spec(functions: functions));
      expect(iface, contains('virtual int64_t at(int64_t code) = 0;'));
      expect(iface, contains('virtual std::optional<uint64_t> optBig(int64_t code) = 0;'));
    });
  });

  group('SpecValidator', () {
    List<String> codes(BridgeSpec spec) => SpecValidator.validate(spec).where((i) => i.isError).map((i) => i.code).toList();

    test('typed data is allowed as a result value (it travels in the wrapper)', () {
      expect(codes(_spec()), isEmpty);
      // So is the same return on a plain method: the bridge copies it.
      final naked = BridgeFunction(dartName: 'raw', cSymbol: 'res_raw', isAsync: false, returnType: BridgeType(name: 'Uint8List'), params: []);
      expect(codes(_spec(functions: [naked])), isEmpty);
    });

    test('E015: a value no backend can carry', () {
      // A list with nullable items is not a record field, and no block either.
      final holes = _result('holes', 'List<int?>', RecordFieldKind.listPrimitive, item: 'int', isRecord: true);
      final issues = SpecValidator.validate(_spec(functions: [holes])).where((i) => i.code == 'E015').toList();
      expect(issues, hasLength(1));
      expect(issues.single.message, contains('"List<int?>" is not supported as a @NitroResult value'));
      // On an all-C++ module too: the carrier is the same for every backend.
      expect(codes(_spec(allCpp: true, functions: [holes])), contains('E015'));
    });
  });
}
