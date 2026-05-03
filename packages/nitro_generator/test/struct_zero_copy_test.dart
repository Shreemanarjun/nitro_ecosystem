import 'package:nitro_generator/src/generators/struct_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

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
      
      // Constructor should use ByteArray
      expect(out, contains('val bytes: ByteArray'));
      
      // decodeFrom should use ByteArray decoding
      expect(out, contains('val bytes = { val len = buf.int; val b = ByteArray(len); buf.get(b); b }()'));
      
      // writeFieldsTo should use size and out.write
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
      
      // Constructor should use java.nio.ByteBuffer
      expect(out, contains('val data: java.nio.ByteBuffer'));
      
      // decodeFrom should handle the Long pointer and return an empty ByteBuffer (placeholder)
      expect(out, contains('val data = { buf.long; java.nio.ByteBuffer.allocate(0) }()'));
      
      // writeFieldsTo should write a 0L placeholder for the address
      expect(out, contains('writeInt(0L)'));
    });
  });
}
