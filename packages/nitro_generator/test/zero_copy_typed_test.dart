// Tests for zero-copy TypedData struct field JNI code generation.
//
// Regression coverage for three JNI bugs in pack/unpack helpers when a
// @HybridStruct field uses @zeroCopy with a TypedData type other than
// Uint8List:
//
//   Bug 1 — wrong JNI field descriptor: used "Ljava/lang/Object;" for all
//     zero-copy fields. Must be "Ljava/nio/ByteBuffer;" so GetFieldID
//     locates the right field.
//
//   Bug 2 — wrong C element cast: assigned `void*` (return of
//     GetDirectBufferAddress) to a typed pointer without a cast.
//     E.g. for Float32List the field type is `float*`, not `uint8_t*`.
//
//   Bug 3 — wrong byte count in NewDirectByteBuffer: passed element count
//     instead of byte count.  E.g. for Float32List with 10 floats the byte
//     count is 10 * sizeof(float) = 40, not 10.

import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/cpp_bridge_generator.dart';
import 'package:test/test.dart';

// ── Spec helpers ─────────────────────────────────────────────────────────────

/// Creates a minimal spec with a single zero-copy [typedDataType] struct field.
///
/// The companion length field is always called 'length' (matches the heuristic
/// in `_zeroCopyLenField` which picks 'length' when 'stride'/'size' absent).
BridgeSpec _zeroCopySpec(String typedDataType) {
  return BridgeSpec(
    dartClassName: 'TestMod',
    lib: 'test_mod',
    namespace: 'test_mod',
    iosImpl: NativeImpl.swift,
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'test.native.dart',
    structs: [
      BridgeStruct(
        name: 'TestBuffer',
        packed: false,
        fields: [
          BridgeField(
            name: 'data',
            type: BridgeType(name: typedDataType),
            zeroCopy: true,
          ),
          BridgeField(
            name: 'length',
            type: BridgeType(name: 'int'),
          ),
        ],
      ),
    ],
    functions: [
      BridgeFunction(
        dartName: 'getBuffer',
        cSymbol: 'test_mod_get_buffer',
        isAsync: false,
        returnType: BridgeType(name: 'TestBuffer'),
        params: [],
      ),
    ],
  );
}

// ── Test matrix ──────────────────────────────────────────────────────────────

/// Maps each TypedData type to its expected C element cast and sizeof suffix.
const _typeMatrix = <String, (String cast, String sizeExpr)>{
  'Uint8List': ('uint8_t*', ''),
  'Int8List': ('int8_t*', ''),
  'Int16List': ('int16_t*', ' * sizeof(int16_t)'),
  'Uint16List': ('uint16_t*', ' * sizeof(int16_t)'),
  'Int32List': ('int32_t*', ' * sizeof(int32_t)'),
  'Uint32List': ('uint32_t*', ' * sizeof(int32_t)'),
  'Float32List': ('float*', ' * sizeof(float)'),
  'Float64List': ('double*', ' * sizeof(double)'),
  'Int64List': ('int64_t*', ' * sizeof(int64_t)'),
  'Uint64List': ('uint64_t*', ' * sizeof(int64_t)'),
};

void main() {
  // ── 1. pack_from_jni: correct JNI field descriptor ────────────────────────

  group('CppBridgeGenerator — zero-copy pack_from_jni: ByteBuffer descriptor', () {
    for (final type in _typeMatrix.keys) {
      test('$type field uses "Ljava/nio/ByteBuffer;" descriptor', () {
        final cpp = CppBridgeGenerator.generate(_zeroCopySpec(type));
        // The field lookup must use the ByteBuffer descriptor.
        expect(cpp, contains('"data", "Ljava/nio/ByteBuffer;"'), reason: '$type zero-copy field must use ByteBuffer JNI descriptor');
      });

      test('$type field does NOT use "Ljava/lang/Object;" descriptor', () {
        final cpp = CppBridgeGenerator.generate(_zeroCopySpec(type));
        // Regression: old code used Object as the descriptor for all typed data.
        expect(cpp, isNot(contains('"data", "Ljava/lang/Object;"')), reason: '$type must not fall back to Object descriptor');
      });
    }
  });

  // ── 2. pack_from_jni: GetDirectBufferAddress + correct cast ───────────────

  group('CppBridgeGenerator — zero-copy pack_from_jni: GetDirectBufferAddress', () {
    for (final entry in _typeMatrix.entries) {
      final type = entry.key;
      final cast = entry.value.$1;

      test('$type uses GetDirectBufferAddress (not GetObjectField direct assign)', () {
        final cpp = CppBridgeGenerator.generate(_zeroCopySpec(type));
        expect(cpp, contains('env->GetDirectBufferAddress(buf_data)'), reason: '$type must call GetDirectBufferAddress to extract pointer');
      });

      test('$type casts GetDirectBufferAddress result to $cast', () {
        final cpp = CppBridgeGenerator.generate(_zeroCopySpec(type));
        expect(cpp, contains('($cast)env->GetDirectBufferAddress(buf_data)'), reason: '$type must cast void* to $cast for correct struct assignment');
      });
    }
  });

  // ── 3. unpack_to_jni: constructor signature uses ByteBuffer ───────────────

  group('CppBridgeGenerator — zero-copy unpack_to_jni: ctor signature', () {
    for (final type in _typeMatrix.keys) {
      test('$type ctor signature uses "Ljava/nio/ByteBuffer;" not Object', () {
        final cpp = CppBridgeGenerator.generate(_zeroCopySpec(type));
        // The ctor signature for (ByteBuffer, long) should be "(Ljava/nio/ByteBuffer;J)V"
        expect(cpp, contains('"(Ljava/nio/ByteBuffer;J)V"'), reason: '$type unpack ctor must accept ByteBuffer + long');
        expect(cpp, isNot(contains('"(Ljava/lang/Object;J)V"')), reason: '$type must not use Object in ctor signature');
      });
    }
  });

  // ── 4. unpack_to_jni: NewDirectByteBuffer with correct byte count ─────────

  group('CppBridgeGenerator — zero-copy unpack_to_jni: NewDirectByteBuffer', () {
    for (final entry in _typeMatrix.entries) {
      final type = entry.key;
      final sizeExpr = entry.value.$2;
      final expectedByteCount = 'st->length$sizeExpr';

      test('$type uses NewDirectByteBuffer (not raw pointer cast)', () {
        final cpp = CppBridgeGenerator.generate(_zeroCopySpec(type));
        expect(cpp, contains('env->NewDirectByteBuffer((void*)st->data,'), reason: '$type must use NewDirectByteBuffer for zero-copy unpack');
      });

      test('$type passes correct byte count: $expectedByteCount', () {
        final cpp = CppBridgeGenerator.generate(_zeroCopySpec(type));
        expect(
          cpp,
          contains('env->NewDirectByteBuffer((void*)st->data, $expectedByteCount)'),
          reason: '$type byte count must be $expectedByteCount',
        );
      });
    }
  });

  // ── 5. Non-zero-copy TypedData still uses Object descriptor ───────────────

  group('CppBridgeGenerator — non-zero-copy TypedData keeps Object descriptor', () {
    test('Float32List without zeroCopy uses [F descriptor', () {
      // A Float32List field that is NOT marked zeroCopy should NOT become ByteBuffer.
      final spec = BridgeSpec(
        dartClassName: 'TestMod',
        lib: 'test_mod',
        namespace: 'test_mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'test.native.dart',
        structs: [
          BridgeStruct(
            name: 'TestBuf',
            packed: false,
            fields: [
              // zeroCopy is false by default
              BridgeField(
                name: 'data',
                type: BridgeType(name: 'Float32List'),
              ),
              BridgeField(
                name: 'length',
                type: BridgeType(name: 'int'),
              ),
            ],
          ),
        ],
        functions: [
          BridgeFunction(
            dartName: 'getBuffer',
            cSymbol: 'test_mod_get_buffer',
            isAsync: false,
            returnType: BridgeType(name: 'TestBuf'),
            params: [],
          ),
        ],
      );
      final cpp = CppBridgeGenerator.generate(spec);
      // Non-zero-copy Float32List maps to Kotlin FloatArray, JNI sig [F
      expect(cpp, contains('"data", "[F"'));
      expect(cpp, isNot(contains('GetDirectBufferAddress')));
    });
  });

  // ── 6. Uint8List — byte types require no sizeof multiplication ────────────

  group('CppBridgeGenerator — byte-sized types: no sizeof suffix', () {
    for (final type in ['Uint8List', 'Int8List']) {
      test('$type byte count is exactly st->length (no * sizeof)', () {
        final cpp = CppBridgeGenerator.generate(_zeroCopySpec(type));
        // Must not have a sizeof suffix for 1-byte elements.
        expect(
          cpp,
          isNot(contains('st->length * sizeof')),
          reason: '$type has 1-byte elements — no size multiplication needed',
        );
        expect(
          cpp,
          contains('env->NewDirectByteBuffer((void*)st->data, st->length)'),
        );
      });
    }
  });

  // ── 7. Multi-byte types — sizeof suffix is present ────────────────────────

  group('CppBridgeGenerator — multi-byte types: sizeof suffix', () {
    final multiByteTypes = {
      'Float32List': 'sizeof(float)',
      'Float64List': 'sizeof(double)',
      'Int32List': 'sizeof(int32_t)',
      'Uint32List': 'sizeof(int32_t)',
      'Int16List': 'sizeof(int16_t)',
      'Uint16List': 'sizeof(int16_t)',
      'Int64List': 'sizeof(int64_t)',
      'Uint64List': 'sizeof(int64_t)',
    };

    for (final entry in multiByteTypes.entries) {
      final type = entry.key;
      final sizeofExpr = entry.value;

      test('$type byte count includes * $sizeofExpr', () {
        final cpp = CppBridgeGenerator.generate(_zeroCopySpec(type));
        expect(cpp, contains('st->length * $sizeofExpr'), reason: '$type is multi-byte — byte count must include $sizeofExpr');
      });
    }
  });

  // ── 8. Stride field is preferred as length when present ───────────────────

  group('CppBridgeGenerator — zero-copy length field heuristic', () {
    test('uses stride field as byte count when present', () {
      final specWithStride = BridgeSpec(
        dartClassName: 'TestMod',
        lib: 'test_mod',
        namespace: 'test_mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'test.native.dart',
        structs: [
          BridgeStruct(
            name: 'Frame',
            packed: false,
            fields: [
              BridgeField(
                name: 'pixels',
                type: BridgeType(name: 'Uint8List'),
                zeroCopy: true,
              ),
              BridgeField(
                name: 'width',
                type: BridgeType(name: 'int'),
              ),
              BridgeField(
                name: 'height',
                type: BridgeType(name: 'int'),
              ),
              BridgeField(
                name: 'stride',
                type: BridgeType(name: 'int'),
              ),
            ],
          ),
        ],
        functions: [
          BridgeFunction(
            dartName: 'getFrame',
            cSymbol: 'test_mod_get_frame',
            isAsync: false,
            returnType: BridgeType(name: 'Frame'),
            params: [],
          ),
        ],
      );
      final cpp = CppBridgeGenerator.generate(specWithStride);
      // When stride is present, it should be used as the byte count (not length).
      expect(cpp, contains('env->NewDirectByteBuffer((void*)st->pixels, st->stride)'), reason: 'stride should be preferred as the byte-length field');
    });

    test('falls back to length when stride and size are absent', () {
      final cpp = CppBridgeGenerator.generate(_zeroCopySpec('Float32List'));
      expect(cpp, contains('st->length * sizeof(float)'), reason: 'length field used as element count when stride/size absent');
    });
  });
}
