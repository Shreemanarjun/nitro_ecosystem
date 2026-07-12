// Tests for the three generator fixes that make non-zero-copy Uint8List fields
// work correctly across all platforms:
//
//  1. Struct generator: synthetic `dataLength` injected into C struct, Dart FFI
//     struct, toNative(), toDart(), proxy getter, and freeFields().
//  2. Swift generator: C-ABI shadow structs (_StructC) to avoid Swift SSO
//     memory-layout mismatch when returning structs from @_cdecl functions.
//  3. C++ bridge generator: proper jbyteArray extraction in pack_from_jni and
//     NewByteArray emission in unpack_to_jni for non-zero-copy typed data.

import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/struct_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// ── Shared spec helpers ───────────────────────────────────────────────────────

/// A struct with a non-zero-copy Uint8List field — mirrors PrintDocument.data.
BridgeSpec _nonZcSpec() => BridgeSpec(
  dartClassName: 'Printer',
  lib: 'printer',
  namespace: 'printer',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'printer.native.dart',
  structs: [
    BridgeStruct(
      name: 'Document',
      packed: false,
      fields: [
        BridgeField(
          name: 'id',
          type: BridgeType(name: 'String'),
        ),
        BridgeField(
          name: 'data',
          type: BridgeType(name: 'Uint8List'),
        ),
      ],
    ),
  ],
  functions: [
    BridgeFunction(
      dartName: 'printDoc',
      cSymbol: 'printer_print_doc',
      isAsync: true,
      returnType: BridgeType(name: 'bool'),
      params: [
        BridgeParam(
          name: 'doc',
          type: BridgeType(name: 'Document'),
        ),
      ],
    ),
  ],
);

/// A struct with String fields only — used to verify C-ABI shadow struct
/// (Swift SSO fix) for structs that have no typed-data fields.
BridgeSpec _stringFieldSpec() => BridgeSpec(
  dartClassName: 'Device',
  lib: 'device',
  namespace: 'device',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'device.native.dart',
  structs: [
    BridgeStruct(
      name: 'DeviceInfo',
      packed: false,
      fields: [
        BridgeField(
          name: 'id',
          type: BridgeType(name: 'String'),
        ),
        BridgeField(
          name: 'name',
          type: BridgeType(name: 'String'),
        ),
        BridgeField(
          name: 'isDefault',
          type: BridgeType(name: 'bool'),
        ),
      ],
    ),
  ],
  functions: [
    BridgeFunction(
      dartName: 'getDefault',
      cSymbol: 'device_get_default',
      isAsync: false,
      returnType: BridgeType(name: 'DeviceInfo'),
      params: [],
    ),
    BridgeFunction(
      dartName: 'configure',
      cSymbol: 'device_configure',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'info',
          type: BridgeType(name: 'DeviceInfo'),
        ),
      ],
    ),
  ],
);

/// Spec with a struct that has BOTH a String field and a Uint8List field,
/// and a stream that emits the struct — covers all code paths in one spec.
BridgeSpec _richStructSpec() => BridgeSpec(
  dartClassName: 'Hub',
  lib: 'hub',
  namespace: 'hub',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'hub.native.dart',
  structs: [
    BridgeStruct(
      name: 'Packet',
      packed: false,
      fields: [
        BridgeField(
          name: 'tag',
          type: BridgeType(name: 'String'),
        ),
        BridgeField(
          name: 'payload',
          type: BridgeType(name: 'Uint8List'),
        ),
      ],
    ),
  ],
  streams: [
    BridgeStream(
      dartName: 'packets',
      registerSymbol: 'hub_register_packets_stream',
      releaseSymbol: 'hub_release_packets_stream',
      itemType: BridgeType(name: 'Packet'),
      backpressure: Backpressure.dropLatest,
    ),
  ],
);

// ── 1. StructGenerator — C struct synthetic length field ─────────────────────

void main() {
  group('StructGenerator — non-zero-copy Uint8List: C struct', () {
    late String cStructs;
    setUpAll(() => cStructs = StructGenerator.generateCStructs(_nonZcSpec()));

    test('injects int64_t dataLength into C struct for non-ZC field', () {
      expect(cStructs, contains('int64_t dataLength;'));
    });

    test('dataLength comment says synthesized', () {
      expect(cStructs, contains('/* synthesized'));
    });

    test('data pointer precedes dataLength in C struct', () {
      final dataIdx = cStructs.indexOf('uint8_t* data;');
      final lenIdx = cStructs.indexOf('int64_t dataLength;');
      expect(dataIdx, isNot(-1));
      expect(lenIdx, greaterThan(dataIdx));
    });
  });

  group('StructGenerator — non-zero-copy Uint8List: Dart FFI struct', () {
    late String dartExt;
    setUpAll(() => dartExt = StructGenerator.generateDartExtensions(_nonZcSpec()));

    test('adds @Int64() external int dataLength to FFI struct', () {
      expect(dartExt, contains('@Int64()'));
      expect(dartExt, contains('external int dataLength'));
    });

    test('toDart() calls asTypedList(dataLength) not asTypedList(0)', () {
      expect(dartExt, contains('asTypedList(dataLength)'));
      expect(dartExt, isNot(contains('asTypedList(0)')));
    });

    test('toNative() sets ptr.ref.dataLength = data.length', () {
      expect(dartExt, contains('ptr.ref.dataLength = data.length'));
    });

    test('freeFields() frees the data pointer for non-ZC typed data', () {
      expect(dartExt, contains('if (data != nullptr) {'));
      expect(dartExt, contains('nativeFree(data);'));
    });
  });

  group('StructGenerator — non-zero-copy Uint8List: Dart proxy getter', () {
    late String proxies;
    setUpAll(() => proxies = StructGenerator.generateDartProxies(_nonZcSpec()));

    test('proxy data getter uses _native.ref.dataLength', () {
      expect(proxies, contains('_native.ref.dataLength'));
      expect(proxies, isNot(contains('asTypedList(0)')));
    });
  });

  // ── 2. StructGenerator — Swift C-ABI shadow structs ──────────────────────

  group('StructGenerator — Swift shadow struct for String fields (SSO fix)', () {
    late String swift;
    setUpAll(() => swift = StructGenerator.generateSwift(_stringFieldSpec()));

    test('emits fileprivate _DeviceInfoC shadow struct', () {
      expect(swift, contains('fileprivate struct _DeviceInfoC'));
    });

    test('String fields become UnsafeMutablePointer<CChar>? in shadow', () {
      expect(swift, contains('var id: UnsafeMutablePointer<CChar>?'));
      expect(swift, contains('var name: UnsafeMutablePointer<CChar>?'));
    });

    test('Bool fields become Int8 in shadow struct', () {
      expect(swift, contains('var isDefault: Int8'));
    });

    test('fromSwift uses strdup for String fields', () {
      expect(swift, contains('strdup(s.id)'));
      expect(swift, contains('strdup(s.name)'));
    });

    test('fromSwift converts Bool to Int8 ternary', () {
      expect(swift, contains('s.isDefault ? 1 : 0'));
    });

    test('toSwift converts CChar* to Swift String with optional map', () {
      expect(swift, contains('id.map { String(cString: \$0) } ?? ""'));
    });

    test('toSwift converts Int8 to Bool', () {
      expect(swift, contains('isDefault != 0'));
    });
  });

  group('StructGenerator — Swift shadow struct for Uint8List (non-ZC)', () {
    late String swift;
    setUpAll(() => swift = StructGenerator.generateSwift(_nonZcSpec()));

    test('emits _DocumentC shadow struct', () {
      expect(swift, contains('fileprivate struct _DocumentC'));
    });

    test('Uint8List becomes UnsafeMutablePointer<UInt8>? in shadow', () {
      expect(swift, contains('var data: UnsafeMutablePointer<UInt8>?'));
    });

    test('shadow struct has payloadLength field for Uint8List', () {
      // synthesized length field name: ${fieldName}Length
      expect(swift, contains('var dataLength: Int64'));
    });

    test('fromSwift copies Data bytes via allocate + copyBytes for Uint8List', () {
      // fromSwift must allocate a buffer and copy bytes for non-ZC typed data
      expect(swift, contains('.allocate(capacity: s.data.count)'));
      expect(swift, contains('s.data.copyBytes(to:'));
    });

    test('toSwift reconstructs Data from pointer + dataLength', () {
      expect(swift, contains('Data(bytes:'));
    });
  });

  // ── 3. SwiftGenerator — @_cdecl functions use _StructC shadow ────────────

  group('SwiftGenerator — struct return uses _StructC shadow (SSO fix)', () {
    late String swift;
    setUpAll(() => swift = SwiftGenerator.generate(_stringFieldSpec()));

    test('sync struct return allocates _DeviceInfoC not DeviceInfo', () {
      expect(
        swift,
        contains('UnsafeMutablePointer<_DeviceInfoC>.allocate(capacity: 1)'),
      );
      expect(
        swift,
        isNot(contains('UnsafeMutablePointer<DeviceInfo>.allocate')),
      );
    });

    test('sync struct return initializes with fromSwift', () {
      expect(swift, contains('_DeviceInfoC.fromSwift('));
    });
  });

  group('SwiftGenerator — struct param uses _StructC shadow (SSO fix)', () {
    late String swift;
    setUpAll(() => swift = SwiftGenerator.generate(_stringFieldSpec()));

    test('struct param binds via _DeviceInfoC.toSwift()', () {
      expect(swift, contains('assumingMemoryBound(to: _DeviceInfoC.self).pointee.toSwift()'));
    });

    test('never binds directly as DeviceInfo (old broken pattern)', () {
      expect(swift, isNot(contains('assumingMemoryBound(to: DeviceInfo.self)')));
    });
  });

  group('SwiftGenerator — struct stream item uses _StructC shadow', () {
    late String swift;
    setUpAll(() => swift = SwiftGenerator.generate(_richStructSpec()));

    test('stream emit allocates _PacketC not Packet', () {
      expect(swift, contains('UnsafeMutablePointer<_PacketC>.allocate(capacity: 1)'));
      expect(swift, isNot(contains('UnsafeMutablePointer<Packet>.allocate')));
    });

    test('stream emit uses _PacketC.fromSwift(item)', () {
      expect(swift, contains('_PacketC.fromSwift(item)'));
    });
  });

  // ── 4. CppBridgeGenerator — JNI jbyteArray extraction ───────────────────

  group('CppBridgeGenerator — non-ZC Uint8List in pack_from_jni', () {
    late String bridge;
    setUpAll(() => bridge = CppBridgeGenerator.generate(_nonZcSpec()));

    test('casts GetObjectField result to jbyteArray', () {
      expect(bridge, contains('(jbyteArray)env->GetObjectField'));
    });

    test('uses GetArrayLength to determine byte count', () {
      expect(bridge, contains('env->GetArrayLength(j_data)'));
    });

    test('mallocs a buffer sized to array length', () {
      expect(bridge, contains('malloc(_len_data'));
    });

    test('uses GetByteArrayRegion to copy bytes into buffer', () {
      expect(bridge, contains('GetByteArrayRegion'));
    });

    test('sets result.dataLength from _len_data', () {
      expect(bridge, contains('result.dataLength = (int64_t)_len_data'));
    });

    test('does NOT directly assign jobject to uint8_t*', () {
      // The old broken pattern was: result.data = env->GetObjectField(...)
      // That assigns jobject → uint8_t* which is a compile error.
      expect(bridge, isNot(contains('result.data = env->GetObjectField')));
    });
  });

  group('CppBridgeGenerator — non-ZC Uint8List in unpack_to_jni', () {
    late String bridge;
    setUpAll(() => bridge = CppBridgeGenerator.generate(_nonZcSpec()));

    test('creates jbyteArray from st->dataLength', () {
      expect(bridge, contains('env->NewByteArray((jsize)st->dataLength)'));
    });

    test('copies bytes via SetByteArrayRegion', () {
      expect(bridge, contains('SetByteArrayRegion'));
    });
  });

  group('CppBridgeGenerator — release function frees data buffer', () {
    late String bridge;
    setUpAll(() => bridge = CppBridgeGenerator.generate(_nonZcSpec()));

    test('release_Document calls free(st_ptr->data)', () {
      expect(bridge, contains('free(st_ptr->data)'));
    });
  });

  // ── 5. Regression: zero-copy fields are unaffected ───────────────────────

  group('Regression — zero-copy Uint8List still uses DirectByteBuffer path', () {
    // _pcmChunkNoCompanion from struct_zero_copy_test uses zeroCopy: true.
    // Verify that our changes to the non-ZC path did not break the ZC path.
    final zeroCopySpec = BridgeSpec(
      dartClassName: 'Audio',
      lib: 'audio',
      namespace: 'audio',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'audio.native.dart',
      structs: [
        BridgeStruct(
          name: 'AudioChunk',
          packed: false,
          fields: [
            BridgeField(
              name: 'samples',
              type: BridgeType(name: 'Uint8List'),
              zeroCopy: true,
            ),
          ],
        ),
      ],
    );

    test('ZC field still generates GetDirectBufferCapacity (not GetArrayLength)', () {
      final bridge = CppBridgeGenerator.generate(zeroCopySpec);
      expect(bridge, contains('GetDirectBufferCapacity'));
      expect(bridge, isNot(contains('GetByteArrayRegion')));
    });

    test('ZC field still generates NewDirectByteBuffer (not NewByteArray)', () {
      final bridge = CppBridgeGenerator.generate(zeroCopySpec);
      expect(bridge, contains('NewDirectByteBuffer'));
      expect(bridge, isNot(contains('env->NewByteArray')));
    });

    test('ZC Dart proxy getter uses samplesLength (not 0)', () {
      final proxies = StructGenerator.generateDartProxies(zeroCopySpec);
      expect(proxies, isNot(contains('asTypedList(0)')));
    });
  });
}
