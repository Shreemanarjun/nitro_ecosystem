// L12 @NitroTuple generator tests.
//
// Verifies that `@NitroTuple` positional record types are correctly handled:
//   - BridgeType.isTuple=true + isRecord=true → BridgeTypeKind.tuple
//   - Dart: standalone _nitroDecode_/_nitroEncode_ free functions emitted
//   - Dart FFI: Pointer<Uint8> (same as @HybridRecord)
//   - C header: uint8_t* param / return
//   - Kotlin: data class with field0/field1/… names
//   - Swift: struct with field0/field1/… names
//   - Nullable tuple: nullptr sentinel
//   - Params: _nitroEncode_ called from call sites

import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_header_generator.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/record_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// ── Spec helpers ──────────────────────────────────────────────────────────────

/// A BridgeRecordType representing `typedef MyPair = (int, String);`
BridgeRecordType _myPair({bool isTuple = true}) => BridgeRecordType(
      name: 'MyPair',
      isTuple: isTuple,
      fields: [
        BridgeRecordField(
          name: 'field0',
          dartType: 'int',
          kind: RecordFieldKind.primitive,
        ),
        BridgeRecordField(
          name: 'field1',
          dartType: 'String',
          kind: RecordFieldKind.primitive,
        ),
      ],
    );

/// A 3-field tuple: `typedef MyTriple = (int, String, bool);`
BridgeRecordType _myTriple() => BridgeRecordType(
      name: 'MyTriple',
      isTuple: true,
      fields: [
        BridgeRecordField(
          name: 'field0',
          dartType: 'int',
          kind: RecordFieldKind.primitive,
        ),
        BridgeRecordField(
          name: 'field1',
          dartType: 'String',
          kind: RecordFieldKind.primitive,
        ),
        BridgeRecordField(
          name: 'field2',
          dartType: 'bool',
          kind: RecordFieldKind.primitive,
        ),
      ],
    );

BridgeType _tupleType(String name, {bool isNullable = false}) => BridgeType(
      name: name,
      isRecord: true,
      isTuple: true,
      isNullable: isNullable,
    );

BridgeSpec _spec(String returnType, {List<BridgeParam> params = const [], bool isNullable = false}) =>
    BridgeSpec(
      dartClassName: 'Counter',
      lib: 'counter',
      namespace: 'counter',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'counter.native.dart',
      recordTypes: [_myPair(), _myTriple()],
      functions: [
        BridgeFunction(
          dartName: 'getPair',
          cSymbol: 'counter_getPair',
          isAsync: false,
          returnType: BridgeType(
            name: returnType,
            isRecord: returnType == 'MyPair' || returnType == 'MyPair?',
            isTuple: returnType == 'MyPair' || returnType == 'MyPair?',
            isNullable: isNullable,
          ),
          params: params,
        ),
      ],
    );

// ── BridgeType.kind ───────────────────────────────────────────────────────────

void main() {
  group('L12 tuple — BridgeType.kind', () {
    test('isTuple=true → BridgeTypeKind.tuple', () {
      final t = _tupleType('MyPair');
      expect(t.kind, equals(BridgeTypeKind.tuple));
    });

    test('isTuple=true, isRecord=true — kind is tuple not record', () {
      final t = BridgeType(name: 'MyPair', isRecord: true, isTuple: true);
      expect(t.kind, equals(BridgeTypeKind.tuple));
      expect(t.kind, isNot(equals(BridgeTypeKind.record)));
    });

    test('isTuple=false, isRecord=true → BridgeTypeKind.record', () {
      final t = BridgeType(name: 'MyRecord', isRecord: true, isTuple: false);
      expect(t.kind, equals(BridgeTypeKind.record));
    });

    test('BridgeRecordType.isTuple flag defaults to false', () {
      final rt = BridgeRecordType(name: 'Foo', fields: []);
      expect(rt.isTuple, isFalse);
    });

    test('BridgeRecordType.isTuple=true set correctly', () {
      final rt = _myPair();
      expect(rt.isTuple, isTrue);
    });
  });

  // ── Dart record generator ─────────────────────────────────────────────────

  group('L12 tuple — Dart record generator', () {
    late String dartRecordOutput;
    setUp(() {
      final spec = BridgeSpec(
        dartClassName: 'Counter',
        lib: 'counter',
        namespace: 'counter',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'counter.native.dart',
        recordTypes: [_myPair(), _myTriple()],
        functions: [],
      );
      dartRecordOutput = RecordGenerator.generateDartExtensions(spec);
    });

    test('emits _nitroDecode_ free function for tuple', () {
      expect(dartRecordOutput, contains('_nitroDecode_MyPair'));
    });

    test('emits _nitroDecodeNullable_ free function for tuple', () {
      expect(dartRecordOutput, contains('_nitroDecodeNullable_MyPair'));
    });

    test('emits _nitroEncode_ free function for tuple', () {
      expect(dartRecordOutput, contains('_nitroEncode_MyPair'));
    });

    test('decode function uses RecordReader.fromNative', () {
      expect(dartRecordOutput, contains('RecordReader.fromNative'));
    });

    test('decode returns positional record literal', () {
      // e.g. return (r.readInt(), r.readString());
      expect(dartRecordOutput, contains('return (r.readInt(), r.readString())'));
    });

    test('encode uses v.\$1 for first field', () {
      expect(dartRecordOutput, contains(r'v.$1'));
    });

    test('encode uses v.\$2 for second field', () {
      expect(dartRecordOutput, contains(r'v.$2'));
    });

    test('encode ends with writer.toNative(alloc)', () {
      expect(dartRecordOutput, contains('writer.toNative(alloc)'));
    });

    test('decode nullable checks for nullptr', () {
      expect(dartRecordOutput, contains('if (ptr == nullptr) return null'));
    });

    test('3-field triple decode returns 3 elements', () {
      expect(dartRecordOutput, contains('return (r.readInt(), r.readString(), r.readBool())'));
    });

    test('3-field triple encode uses v.\$3', () {
      expect(dartRecordOutput, contains(r'v.$3'));
    });

    test('does NOT emit RecordExt extension for tuple', () {
      expect(dartRecordOutput, isNot(contains('extension MyPairRecordExt')));
    });
  });

  // ── Dart FFI generator (function return/param) ────────────────────────────

  group('L12 tuple — Dart FFI generator', () {
    test('tuple return: FFI native type is Pointer<Uint8>', () {
      final dart = DartFfiGenerator.generate(_spec('MyPair'));
      expect(dart, contains('Pointer<Uint8>'));
    });

    test('tuple return: calls _nitroDecode_MyPair', () {
      final dart = DartFfiGenerator.generate(_spec('MyPair'));
      expect(dart, contains('_nitroDecode_MyPair'));
    });

    test('tuple param: calls _nitroEncode_MyPair', () {
      final spec = BridgeSpec(
        dartClassName: 'Counter',
        lib: 'counter',
        namespace: 'counter',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'counter.native.dart',
        recordTypes: [_myPair()],
        functions: [
          BridgeFunction(
            dartName: 'setPair',
            cSymbol: 'counter_setPair',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'pair',
                type: _tupleType('MyPair'),
              ),
            ],
          ),
        ],
      );
      final dart = DartFfiGenerator.generate(spec);
      expect(dart, contains('_nitroEncode_MyPair'));
    });

    test('nullable tuple return: calls _nitroDecodeNullable_MyPair', () {
      final dart = DartFfiGenerator.generate(_spec('MyPair?', isNullable: true));
      expect(dart, contains('_nitroDecodeNullable_MyPair'));
    });
  });

  // ── C header generator ────────────────────────────────────────────────────
  // Tuples use void* in the public C header (same as @HybridRecord) — the
  // `_typeToC` fallback returns 'void*' for any unrecognised type name.
  // The bridge-level cast to uint8_t* happens inside the JNI bridge (cpp_bridge_generator).

  group('L12 tuple — C header generator', () {
    test('tuple return: C declaration contains void* (same as @HybridRecord)', () {
      final header = CppHeaderGenerator.generate(_spec('MyPair'));
      // The public C header uses void* for record/tuple returns.
      expect(header, contains('void*'));
    });

    test('tuple function is emitted in C header', () {
      final header = CppHeaderGenerator.generate(_spec('MyPair'));
      expect(header, contains('counter_getPair'));
    });

    test('tuple param: C declaration uses void* for param type', () {
      final spec = BridgeSpec(
        dartClassName: 'Counter',
        lib: 'counter',
        namespace: 'counter',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'counter.native.dart',
        recordTypes: [_myPair()],
        functions: [
          BridgeFunction(
            dartName: 'setPair',
            cSymbol: 'counter_setPair',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'pair',
                type: _tupleType('MyPair'),
              ),
            ],
          ),
        ],
      );
      final header = CppHeaderGenerator.generate(spec);
      expect(header, contains('counter_setPair'));
      expect(header, contains('pair')); // param name present
    });
  });

  // ── Kotlin generator ──────────────────────────────────────────────────────

  group('L12 tuple — Kotlin generator', () {
    test('emits data class for tuple', () {
      final kotlin = KotlinGenerator.generate(_spec('MyPair'));
      expect(kotlin, contains('data class MyPair'));
    });

    test('Kotlin data class has positional field0', () {
      final kotlin = KotlinGenerator.generate(_spec('MyPair'));
      expect(kotlin, contains('field0'));
    });

    test('Kotlin data class has positional field1', () {
      final kotlin = KotlinGenerator.generate(_spec('MyPair'));
      expect(kotlin, contains('field1'));
    });

    test('Kotlin data class field0 is Long (for int)', () {
      final kotlin = KotlinGenerator.generate(_spec('MyPair'));
      expect(kotlin, contains('val field0: Long'));
    });

    test('Kotlin data class field1 is String', () {
      final kotlin = KotlinGenerator.generate(_spec('MyPair'));
      expect(kotlin, contains('val field1: String'));
    });

    test('Kotlin emits decode companion', () {
      final kotlin = KotlinGenerator.generate(_spec('MyPair'));
      expect(kotlin, contains('fun decode(bytes: ByteArray)'));
    });

    test('Kotlin emits encode method', () {
      final kotlin = KotlinGenerator.generate(_spec('MyPair'));
      expect(kotlin, contains('fun encode()'));
    });
  });

  // ── @nitroAsync tuple ─────────────────────────────────────────────────────

  group('L12 tuple — @nitroAsync return', () {
    BridgeSpec asyncSpec() => BridgeSpec(
          dartClassName: 'Counter',
          lib: 'counter',
          namespace: 'counter',
          iosImpl: NativeImpl.swift,
          androidImpl: NativeImpl.kotlin,
          sourceUri: 'counter.native.dart',
          recordTypes: [_myPair()],
          functions: [
            BridgeFunction(
              dartName: 'getPairAsync',
              cSymbol: 'counter_getPairAsync',
              isAsync: true,
              returnType: _tupleType('MyPair'),
              params: [],
            ),
          ],
        );

    test('async tuple return: callAsync<Pointer<Uint8>>', () {
      final dart = DartFfiGenerator.generate(asyncSpec());
      expect(dart, contains('callAsync<Pointer<Uint8>>'));
    });

    test('async tuple return: decode calls _nitroDecode_MyPair', () {
      final dart = DartFfiGenerator.generate(asyncSpec());
      expect(dart, contains('_nitroDecode_MyPair'));
    });
  });
}
