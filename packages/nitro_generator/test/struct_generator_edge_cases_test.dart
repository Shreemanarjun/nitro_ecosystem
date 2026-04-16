import 'package:nitro_generator/src/generators/struct_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

void main() {
  group('StructGenerator Kotlin Edge Cases', () {
    test('Kotlin data class with nullable and multiple TypedData fields', () {
      final spec = BridgeSpec(
        dartClassName: 'EdgeCaseMod',
        lib: 'edge_case_mod',
        namespace: 'edge_case_mod',
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'edge.native.dart',
        structs: [
          BridgeStruct(
            name: 'ComplexStruct',
            packed: false,
            fields: [
              BridgeField(
                name: 'id',
                type: BridgeType(name: 'String', isNullable: true),
              ),
              BridgeField(
                name: 'data',
                type: BridgeType(name: 'Uint8List'),
                zeroCopy: true,
              ),
              BridgeField(
                name: 'buffer',
                type: BridgeType(name: 'Uint8List', isNullable: true),
                zeroCopy: true,
              ),
              BridgeField(
                name: 'weights',
                type: BridgeType(name: 'Float64List', isNullable: true),
              ),
              BridgeField(
                name: 'count',
                type: BridgeType(name: 'int'),
              ),
            ],
          ),
        ],
      );
      final out = StructGenerator.generateKotlin(spec);
      
      // Constructor signatures
      expect(out, contains('val id: String?'));
      expect(out, contains('val data: java.nio.ByteBuffer'));
      expect(out, contains('val buffer: java.nio.ByteBuffer?'));
      expect(out, contains('val weights: ByteArray?')); // TypedData maps to ByteArray
      expect(out, contains('val count: Long'));

      // decodeFrom — Null checking for each optional field
      // id: String?
      expect(out, contains('val id = (if (buf.get().toInt() != 0) { val len = buf.int; val b = ByteArray(len); buf.get(b); b.toString(Charsets.UTF_8) }() else null)'));
      // data: required zeroCopy
      expect(out, contains('val data = { buf.long; java.nio.ByteBuffer.allocate(0) }()'));
      // buffer: nullable zeroCopy
      expect(out, contains('val buffer = (if (buf.get().toInt() != 0) { buf.long; java.nio.ByteBuffer.allocate(0) }() else null)'));
      // weights: nullable non-zeroCopy TypedData
      expect(out, contains('val weights = (if (buf.get().toInt() != 0) { val len = buf.int; val b = ByteArray(len); buf.get(b); b }() else null)'));

      // writeFieldsTo — Null checking and correct property access
      // id: ?.let { writeString(it) }
      expect(out, contains('out.write(if (id == null) 0 else 1)'));
      expect(out, contains('id?.let { writeString(it) }'));
      
      // data: required writeInt(0L)
      expect(out, contains('writeInt(0L)')); // for data
      
      // buffer: nullable ?.let { writeInt(0L) }
      expect(out, contains('out.write(if (buffer == null) 0 else 1)'));
      expect(out, contains('buffer?.let { writeInt(0L) }'));
      
      // weights: nullable ?.let { writeInt32(it.size); out.write(it) }
      expect(out, contains('out.write(if (weights == null) 0 else 1)'));
      expect(out, contains('weights?.let { writeInt32(it.size); out.write(it) }'));
    });
  });
}
