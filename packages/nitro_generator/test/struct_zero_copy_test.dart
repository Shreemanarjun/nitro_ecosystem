import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/struct_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// Helpers

BridgeSpec _spec(List<BridgeStruct> structs) => BridgeSpec(
  dartClassName: 'X',
  lib: 'x',
  namespace: 'x',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'x.native.dart',
  structs: structs,
  functions: [],
);

BridgeStruct _pcmChunkNoCompanion() => BridgeStruct(
  name: 'PcmChunk',
  packed: false,
  fields: [
    BridgeField(
      name: 'pcm',
      type: BridgeType(name: 'Uint8List'),
      zeroCopy: true,
    ),
    BridgeField(
      name: 'timestampMs',
      type: BridgeType(name: 'int'),
    ),
    BridgeField(
      name: 'sampleRate',
      type: BridgeType(name: 'int'),
    ),
  ],
);

BridgeStruct _frameWithLength() => BridgeStruct(
  name: 'Frame',
  packed: false,
  fields: [
    BridgeField(
      name: 'data',
      type: BridgeType(name: 'Uint8List'),
      zeroCopy: true,
    ),
    BridgeField(
      name: 'length',
      type: BridgeType(name: 'int'),
    ),
  ],
);

void main() {
  group('StructGenerator Kotlin TypedData/zeroCopy', () {
    test('Kotlin data class with non-zeroCopy TypedData (Uint8List)', () {
      final spec = BridgeSpec(
        dartClassName: 'X',
        lib: 'x',
        namespace: 'x',
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'x.native.dart',
        structs: [
          BridgeStruct(
            name: 'NormalData',
            packed: false,
            fields: [
              BridgeField(
                name: 'bytes',
                type: BridgeType(name: 'Uint8List'),
              ),
            ],
          ),
        ],
      );
      final out = StructGenerator.generateKotlin(spec);

      expect(out, contains('val bytes: ByteArray'));
      expect(out, contains('val bytes = { val len = buf.int; val b = ByteArray(len); buf.get(b); b }()'));
      expect(out, contains('writeInt32(bytes.size); out.write(bytes)'));
    });

    test('Kotlin data class with zeroCopy TypedData (Uint8List)', () {
      final spec = BridgeSpec(
        dartClassName: 'X',
        lib: 'x',
        namespace: 'x',
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'x.native.dart',
        structs: [
          BridgeStruct(
            name: 'ZeroData',
            packed: false,
            fields: [
              BridgeField(
                name: 'data',
                type: BridgeType(name: 'Uint8List'),
                zeroCopy: true,
              ),
            ],
          ),
        ],
      );
      final out = StructGenerator.generateKotlin(spec);

      expect(out, contains('val data: java.nio.ByteBuffer'));
      expect(out, contains('val data = { buf.long; java.nio.ByteBuffer.allocate(0) }()'));
      expect(out, contains('writeInt(0L)'));
    });
  });

  group('StructGenerator — synthetic pcmLength field (no explicit companion)', () {
    test('generateCStructs injects pcmLength into C struct', () {
      final out = StructGenerator.generateCStructs(_spec([_pcmChunkNoCompanion()]));
      expect(out, contains('uint8_t* pcm; /* zero-copy */'));
      expect(out, contains('int64_t pcmLength; /* synthesized'));
      // Synthetic field must appear directly after pcm.
      final pcmIdx = out.indexOf('uint8_t* pcm;');
      final lenIdx = out.indexOf('int64_t pcmLength;');
      expect(lenIdx, greaterThan(pcmIdx));
    });

    test('generateCStructs does NOT inject synthetic field when explicit companion exists', () {
      final out = StructGenerator.generateCStructs(_spec([_frameWithLength()]));
      expect(out, isNot(contains('int64_t dataLength;')));
      expect(out, contains('int64_t length;'));
    });

    test('generateDartExtensions includes pcmLength in FFI struct', () {
      final out = StructGenerator.generateDartExtensions(_spec([_pcmChunkNoCompanion()]));
      expect(out, contains('external int pcmLength;'));
      expect(out, contains('@Int64()'));
    });

    test('generateDartExtensions toDart() uses pcmLength for asTypedList', () {
      final out = StructGenerator.generateDartExtensions(_spec([_pcmChunkNoCompanion()]));
      expect(out, contains('pcm.asTypedList(pcmLength)'));
      expect(out, isNot(contains('asTypedList(0)')));
    });

    test('generateDartExtensions toNative() sets pcmLength from pcm.length', () {
      final out = StructGenerator.generateDartExtensions(_spec([_pcmChunkNoCompanion()]));
      expect(out, contains('ptr.ref.pcmLength = pcm.length;'));
    });

    test('generateDartProxies pcm getter uses pcmLength', () {
      final out = StructGenerator.generateDartProxies(_spec([_pcmChunkNoCompanion()]));
      expect(out, contains('asTypedList(_native.ref.pcmLength)'));
      expect(out, isNot(contains('asTypedList(0)')));
    });

    test('generateSwift includes pcmLength field', () {
      final out = StructGenerator.generateSwift(_spec([_pcmChunkNoCompanion()]));
      expect(out, contains('public var pcmLength: Int64'));
    });

    test('generateSwift does NOT inject synthetic field when explicit companion exists', () {
      final out = StructGenerator.generateSwift(_spec([_frameWithLength()]));
      expect(out, isNot(contains('dataLength')));
    });
  });

  group('CppBridgeGenerator — synthetic pcmLength in JNI bridge', () {
    late String bridge;

    setUpAll(() {
      bridge = CppBridgeGenerator.generate(
        _spec([_pcmChunkNoCompanion()]),
      );
    });

    test('pack_from_jni populates pcmLength from GetDirectBufferCapacity', () {
      expect(bridge, contains('result.pcmLength = (int64_t)env->GetDirectBufferCapacity(buf_pcm)'));
    });

    test('unpack_to_jni uses pcmLength in NewDirectByteBuffer', () {
      expect(bridge, contains('NewDirectByteBuffer((void*)st->pcm, st->pcmLength)'));
    });

    test('no st->size reference when no explicit companion', () {
      expect(bridge, isNot(contains('st->size')));
    });

    test('when explicit companion length field exists, no synthetic pcmLength in pack_from_jni', () {
      final bridgeWithLen = CppBridgeGenerator.generate(
        _spec([_frameWithLength()]),
      );
      expect(bridgeWithLen, isNot(contains('result.dataLength')));
      // Uses the explicit length field name from the struct.
      expect(bridgeWithLen, contains('st->length'));
    });
  });
}
