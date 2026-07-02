// Tests for @NitroVariant sealed/union type code generation (P1).
//
// Covers:
//   - Dart fromReader / writeFields extensions (VariantGenerator)
//   - Kotlin sealed class + companion fromReader + writeFields
//   - Swift enum + static fromReader + writeFields
//   - SpecValidator E014 (empty variants, >10 cases)
//   - BridgeSpec.isVariantName O(1) lookup

import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/languages/cpp_native/cpp_interface_generator.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:nitro_generator/src/generators/variant_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// ── Fixture specs ─────────────────────────────────────────────────────────────

/// FilterResult variant: two cases, one with a field, one unit.
BridgeVariant _filterVariant() => BridgeVariant(
  name: 'FilterResult',
  cases: [
    BridgeVariantCase(
      name: 'FilterAccepted',
      label: 'accepted',
      fields: [
        BridgeRecordField(
          name: 'id',
          dartType: 'String',
          kind: RecordFieldKind.primitive,
        ),
      ],
    ),
    BridgeVariantCase(
      name: 'FilterRejected',
      label: 'rejected',
      fields: [],
    ),
  ],
);

/// Minimal BridgeSpec with a single @NitroVariant.
BridgeSpec _variantSpec() => BridgeSpec(
  dartClassName: 'Foo',
  lib: 'foo',
  namespace: 'foo',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'foo.native.dart',
  variants: [_filterVariant()],
);

/// Type-only spec — no @NitroModule, just the variant declaration.
BridgeSpec _typeOnlyVariantSpec() => BridgeSpec(
  dartClassName: '',
  lib: 'foo',
  namespace: '',
  sourceUri: 'foo.native.dart',
  variants: [_filterVariant()],
  isTypeOnly: true,
);

BridgeSpec _typeOnlyVariantEnumSpec() => BridgeSpec(
  dartClassName: '',
  lib: 'foo',
  namespace: '',
  sourceUri: 'foo.native.dart',
  enums: [
    BridgeEnum(name: 'Quality', startValue: 10, values: ['low', 'normal', 'high']),
  ],
  variants: [
    BridgeVariant(
      name: 'QualityEvent',
      cases: [
        BridgeVariantCase(
          name: 'QualityChanged',
          label: 'changed',
          fields: [
            BridgeRecordField(
              name: 'quality',
              dartType: 'Quality',
              kind: RecordFieldKind.enumValue,
            ),
          ],
        ),
      ],
    ),
  ],
  isTypeOnly: true,
);

BridgeSpec _typeOnlyNullableVariantSpec() => BridgeSpec(
  dartClassName: '',
  lib: 'foo',
  namespace: '',
  sourceUri: 'foo.native.dart',
  enums: [
    BridgeEnum(name: 'Quality', startValue: 10, values: ['low', 'normal', 'high']),
  ],
  recordTypes: [
    BridgeRecordType(
      name: 'Payload',
      fields: [
        BridgeRecordField(name: 'id', dartType: 'String', kind: RecordFieldKind.primitive),
      ],
    ),
  ],
  variants: [
    BridgeVariant(
      name: 'NullableEvent',
      cases: [
        BridgeVariantCase(
          name: 'NullableChanged',
          label: 'changed',
          fields: [
            BridgeRecordField(
              name: 'count',
              dartType: 'int?',
              kind: RecordFieldKind.primitive,
              isNullable: true,
            ),
            BridgeRecordField(
              name: 'quality',
              dartType: 'Quality?',
              kind: RecordFieldKind.enumValue,
              isNullable: true,
            ),
            BridgeRecordField(
              name: 'payload',
              dartType: 'Payload?',
              kind: RecordFieldKind.recordObject,
              isNullable: true,
            ),
            BridgeRecordField(
              name: 'samples',
              dartType: 'List<int>?',
              kind: RecordFieldKind.listPrimitive,
              itemTypeName: 'int',
              isNullable: true,
            ),
          ],
        ),
      ],
    ),
  ],
  isTypeOnly: true,
);

BridgeSpec _variantMethodSpec({NativeImpl iosImpl = NativeImpl.swift, NativeImpl androidImpl = NativeImpl.kotlin}) => BridgeSpec(
  dartClassName: 'Filter',
  lib: 'mylib',
  namespace: 'mylib',
  iosImpl: iosImpl,
  macosImpl: iosImpl,
  androidImpl: androidImpl,
  sourceUri: 'filter.native.dart',
  variants: [_filterVariant()],
  functions: [
    BridgeFunction(
      dartName: 'process',
      cSymbol: 'mylib_process',
      isAsync: false,
      isNativeAsync: false,
      returnType: BridgeType(name: 'FilterResult', isRecord: false, isFunction: false),
      params: [
        BridgeParam(
          name: 'input',
          type: BridgeType(name: 'FilterResult', isRecord: false, isFunction: false),
        ),
      ],
    ),
  ],
);

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('BridgeSpec — @NitroVariant', () {
    test('isVariantName returns true for declared variant', () {
      final spec = _variantSpec();
      expect(spec.isVariantName('FilterResult'), isTrue);
      expect(spec.isVariantName('Unknown'), isFalse);
    });

    test('variantByName returns correct variant', () {
      final spec = _variantSpec();
      final v = spec.variantByName('FilterResult');
      expect(v, isNotNull);
      expect(v!.cases.length, equals(2));
    });

    test('localVariants excludes imported variants', () {
      final spec = BridgeSpec(
        dartClassName: '',
        lib: 'foo',
        namespace: '',
        sourceUri: 'foo.native.dart',
        variants: [
          BridgeVariant(
            name: 'A',
            cases: [BridgeVariantCase(name: 'AX', label: 'x', fields: [])],
          ),
          BridgeVariant(
            name: 'B',
            cases: [BridgeVariantCase(name: 'BY', label: 'y', fields: [])],
            isImported: true,
          ),
        ],
        isTypeOnly: true,
      );
      expect(spec.localVariants.map((v) => v.name), equals(['A']));
    });
  });

  group('VariantGenerator — Dart extensions', () {
    test('emits fromNative / fromReader / writeFields / toNative for variant', () {
      final code = VariantGenerator.generateDartExtensions(_typeOnlyVariantSpec());
      expect(code, contains('extension FilterResultVariantExt on FilterResult'));
      expect(code, contains('static FilterResult fromNative'));
      expect(code, contains('static FilterResult fromReader'));
      expect(code, contains('void writeFields(RecordWriter writer)'));
      expect(code, contains('Pointer<Uint8> toNative(Allocator alloc)'));
    });

    test('fromReader uses tag switch for each case', () {
      final code = VariantGenerator.generateDartExtensions(_typeOnlyVariantSpec());
      expect(code, contains('final tag = r.readInt8()'));
      expect(code, contains('return switch (tag)'));
      // case 0 → FilterAccepted, decodes the String field
      expect(code, contains('0 =>'));
      expect(code, contains('FilterAccepted'));
      // case 1 → FilterRejected (unit)
      expect(code, contains('1 =>'));
      expect(code, contains('FilterRejected'));
    });

    test('writeFields emits tag byte then case-specific fields', () {
      final code = VariantGenerator.generateDartExtensions(_typeOnlyVariantSpec());
      expect(code, contains('writer.writeInt8(0)'));
      expect(code, contains('writer.writeInt8(1)'));
      // FilterAccepted has a String id field
      expect(code, contains('writer.writeString'));
    });

    test('unit case writes only tag — no field write', () {
      final code = VariantGenerator.generateDartExtensions(_typeOnlyVariantSpec());
      // FilterRejected is unit → only the tag line inside its case
      expect(code, contains('case FilterRejected():'));
      expect(code, contains('writer.writeInt8(1)'));
    });

    test('returns empty string when no variants', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        sourceUri: 'foo.native.dart',
      );
      expect(VariantGenerator.generateDartExtensions(spec), isEmpty);
    });
  });

  group('DartFfiGenerator — @NitroVariant', () {
    test('emits VariantExt in generated .g.dart output', () {
      final code = DartFfiGenerator.generate(_variantSpec());
      expect(code, contains('FilterResultVariantExt'));
    });
  });

  group('KotlinGenerator — @NitroVariant type-only', () {
    test('emits sealed class with sub-classes', () {
      final code = KotlinGenerator.generate(_typeOnlyVariantSpec());
      expect(code, contains('sealed class FilterResult'));
      expect(code, contains('data class FilterAccepted'));
      expect(code, contains('data object FilterRejected'));
    });

    test('emits companion object with fromReader', () {
      final code = KotlinGenerator.generate(_typeOnlyVariantSpec());
      expect(code, contains('companion object'));
      expect(code, contains('fun fromReader(r: RecordReader): FilterResult'));
    });

    test('fromReader uses when with correct tags', () {
      final code = KotlinGenerator.generate(_typeOnlyVariantSpec());
      expect(code, contains('0 -> FilterAccepted'));
      expect(code, contains('1 -> FilterRejected'));
    });

    test('emits writeFields with when block', () {
      final code = KotlinGenerator.generate(_typeOnlyVariantSpec());
      expect(code, contains('fun writeFields(w: RecordWriter)'));
      expect(code, contains('is FilterAccepted'));
      expect(code, contains('is FilterRejected'));
      expect(code, contains('w.writeInt8(0)'));
      expect(code, contains('w.writeInt8(1)'));
    });

    test('enum fields decode and encode nativeValue, not ordinal', () {
      final code = KotlinGenerator.generate(_typeOnlyVariantEnumSpec());
      expect(code, contains('quality = Quality.fromNative(r.readInt64())'));
      expect(code, contains('w.writeInt64(quality.nativeValue)'));
      expect(code, isNot(contains('quality.ordinal.toLong()')));
      expect(code, isNot(contains('it.ordinal == r.readInt64().toInt()')));
    });
  });

  group('SwiftGenerator — @NitroVariant type-only', () {
    test('emits enum with cases', () {
      final code = SwiftGenerator.generate(_typeOnlyVariantSpec());
      expect(code, contains('enum FilterResult'));
      expect(code, contains('case accepted'));
      expect(code, contains('case rejected'));
    });

    test('emits static fromReader', () {
      final code = SwiftGenerator.generate(_typeOnlyVariantSpec());
      expect(code, contains('static func fromReader'));
      expect(code, contains('case 0: return .accepted'));
      expect(code, contains('case 1: return .rejected'));
    });

    test('emits writeFields with switch on self', () {
      final code = SwiftGenerator.generate(_typeOnlyVariantSpec());
      expect(code, contains('func writeFields(to w: NitroRecordWriter)'));
      expect(code, contains('case .accepted'));
      expect(code, contains('case .rejected'));
      expect(code, contains('w.bytes.append(UInt8(0))'));
      expect(code, contains('w.bytes.append(UInt8(1))'));
      expect(code, contains('func toNative() -> UnsafeMutablePointer<UInt8>?'));
    });
  });

  group('SpecValidator — E014 (@NitroVariant case count)', () {
    test('E014 error for empty variant (zero cases)', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        sourceUri: 'foo.native.dart',
        variants: [BridgeVariant(name: 'Empty', cases: [])],
      );
      final result = SpecValidator.validate(spec);
      expect(result.any((i) => i.code == 'E014'), isTrue, reason: 'E014 expected for empty variant');
    });

    test('E014 error when variant has more than 255 cases', () {
      final manyCases = List.generate(
        256,
        (i) => BridgeVariantCase(name: 'Case$i', label: 'case$i', fields: []),
      );
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        sourceUri: 'foo.native.dart',
        variants: [BridgeVariant(name: 'Big', cases: manyCases)],
      );
      final result = SpecValidator.validate(spec);
      final e014 = result.where((i) => i.code == 'E014').toList();
      expect(e014, isNotEmpty, reason: 'E014 expected for >255 cases');
      expect(e014.first.message, contains('256 cases'));
    });

    test('no E014 for valid variant (2 cases)', () {
      final spec = _variantSpec();
      final result = SpecValidator.validate(spec);
      expect(result.where((i) => i.code == 'E014'), isEmpty);
    });

    test('no E014 for variant with exactly 255 cases', () {
      final maxCases = List.generate(
        255,
        (i) => BridgeVariantCase(name: 'Case$i', label: 'case$i', fields: []),
      );
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        sourceUri: 'foo.native.dart',
        variants: [BridgeVariant(name: 'Max', cases: maxCases)],
      );
      final result = SpecValidator.validate(spec);
      expect(result.where((i) => i.code == 'E014'), isEmpty);
    });

    test('no E014 for variant with exactly 10 cases (was old limit, now allowed)', () {
      final tenCases = List.generate(
        10,
        (i) => BridgeVariantCase(name: 'Case$i', label: 'case$i', fields: []),
      );
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        sourceUri: 'foo.native.dart',
        variants: [BridgeVariant(name: 'Max', cases: tenCases)],
      );
      final result = SpecValidator.validate(spec);
      expect(result.where((i) => i.code == 'E014'), isEmpty);
    });
  });

  group('@NitroVariant nullable case fields', () {
    test('Dart writes a presence flag before nullable field payloads', () {
      final code = VariantGenerator.generateDartExtensions(_typeOnlyNullableVariantSpec());
      expect(code, contains('writer.writeBool(count != null);'));
      expect(code, contains('writer.writeInt(count)'));
      expect(code, contains('writer.writeBool(quality != null);'));
      expect(code, contains('writer.writeInt(quality.index)'));
      expect(code, contains('writer.writeBool(payload != null);'));
      expect(code, contains('payload.writeFields(writer);'));
      expect(code, contains('writer.writeBool(samples != null);'));
      expect(code, contains('writer.writeInt32(samples.length); for (final e in samples)'));
    });

    test('Kotlin reads nullable fields using presence flags', () {
      final code = KotlinGenerator.generate(_typeOnlyNullableVariantSpec());
      expect(code, contains('val count: Long?'));
      expect(code, contains('val quality: Quality?'));
      expect(code, contains('val payload: Payload?'));
      expect(code, contains('val samples: List<Long>?'));
      expect(code, contains('count = if (r.readBool()) r.readInt64() else null'));
      expect(code, contains('quality = if (r.readBool()) Quality.fromNative(r.readInt64()) else null'));
      expect(code, contains('payload = if (r.readBool()) Payload.decodeFrom(r.buf) else null'));
      expect(code, contains('samples = if (r.readBool()) List(r.readInt32()) { r.readInt64() } else null'));
    });

    test('Kotlin writes nullable fields without dereferencing nullable receivers', () {
      final code = KotlinGenerator.generate(_typeOnlyNullableVariantSpec());
      expect(code, contains('w.writeBool(count != null); count?.let { w.writeInt64(it) }'));
      expect(code, contains('w.writeBool(quality != null); quality?.let { w.writeInt64(it.nativeValue) }'));
      expect(code, contains('w.writeBool(payload != null); payload?.let { it.writeFieldsTo(w.out, w.tmp) }'));
      expect(code, contains('w.writeBool(samples != null); samples?.let { w.writeInt32(it.size); it.forEach { w.writeInt64(it) } }'));
      expect(code, isNot(contains('quality.nativeValue')));
      expect(code, isNot(contains('payload.writeFields(w)')));
      expect(code, isNot(contains('it.writeFields(w)')));
    });

    test('Swift reads and writes nullable fields using presence flags', () {
      final code = SwiftGenerator.generate(_typeOnlyNullableVariantSpec());
      expect(code, contains('case changed(count: Int64?, quality: Quality?, payload: Payload?, samples: [Int64]?)'));
      expect(code, contains('count: r.readBool() ? r.readInt() : nil'));
      expect(code, contains('quality: r.readBool() ? Quality(rawValue: r.readInt())! : nil'));
      expect(code, contains('payload: r.readBool() ? Payload.fromReader(r) : nil'));
      expect(code, contains('samples: r.readBool() ? (0..<Int(r.readInt32())).map { _ in r.readInt() } : nil'));
      expect(code, contains('w.writeBool(quality != nil); if let value = quality { w.writeInt(value.rawValue) }'));
      expect(code, contains('w.writeBool(payload != nil); if let value = payload { value.writeFields(w) }'));
    });

    test('SpecValidator allows nullable variant fields', () {
      final result = SpecValidator.validate(_typeOnlyNullableVariantSpec());
      expect(result.where((i) => i.code == 'E016'), isEmpty);
    });
  });

  // ── C++ variant codegen (S4-P1) ─────────────────────────────────────────────

  group('CppInterfaceGenerator — @NitroVariant', () {
    late BridgeSpec cppSpec;
    late String cppOutput;

    setUp(() {
      cppSpec = BridgeSpec(
        dartClassName: 'Filter',
        lib: 'mylib',
        namespace: 'mylib',
        iosImpl: NativeImpl.cpp,
        androidImpl: NativeImpl.cpp,
        sourceUri: 'filter.native.dart',
        variants: [_filterVariant()],
        functions: [
          BridgeFunction(
            dartName: 'process',
            cSymbol: 'mylib_process',
            isAsync: false,
            isNativeAsync: false,
            returnType: BridgeType(name: 'FilterResult', isRecord: false, isFunction: false),
            params: [
              BridgeParam(
                name: 'input',
                type: BridgeType(name: 'FilterResult', isRecord: false, isFunction: false),
              ),
            ],
          ),
        ],
      );
      cppOutput = CppInterfaceGenerator.generate(cppSpec);
    });

    test('includes <variant> header', () {
      expect(cppOutput, contains('#include <variant>'));
    });

    test('emits FilterAccepted struct with id field', () {
      expect(cppOutput, contains('struct FilterAccepted {'));
      expect(cppOutput, contains('std::string id;'));
    });

    test('emits FilterRejected as unit struct', () {
      expect(cppOutput, contains('struct FilterRejected {};'));
    });

    test('emits std::variant<> typedef', () {
      expect(cppOutput, contains('using FilterResult = std::variant<FilterAccepted, FilterRejected>;'));
    });

    test('emits nitro_decode_FilterResult function', () {
      expect(cppOutput, contains('inline FilterResult nitro_decode_FilterResult(NitroCppBuffer buf)'));
      expect(cppOutput, contains('case 0:')); // FilterAccepted tag
      expect(cppOutput, contains('case 1:')); // FilterRejected tag (actually no — only 2 cases so tag 0 and implicit)
    });

    test('emits nitro_encode_FilterResult function', () {
      expect(cppOutput, contains('inline std::pair<uint8_t*, size_t> nitro_encode_FilterResult'));
      expect(cppOutput, contains('std::visit'));
    });

    test('variant parameter in method uses NitroCppBuffer', () {
      expect(cppOutput, contains('virtual NitroCppBuffer process(NitroCppBuffer input) = 0;'));
    });

    test('variant type-only spec generates no abstract class', () {
      final typeOnly = BridgeSpec(
        dartClassName: '',
        lib: 'foo',
        namespace: '',
        sourceUri: 'foo.native.dart',
        variants: [_filterVariant()],
      );
      // type-only → not a hasCppImpl spec, returns placeholder
      final out = CppInterfaceGenerator.generate(typeOnly);
      expect(out, contains('Not applicable'));
    });
  });

  group('CppBridgeGenerator — @NitroVariant', () {
    test('Swift shim uses uint8_t* for variant return to match the C header', () {
      final out = CppBridgeGenerator.generate(_variantMethodSpec());

      expect(out, contains('extern uint8_t* _mylib_call_process(void* input);'));
      expect(out, contains('uint8_t* mylib_process(int64_t instanceId, void* input, NitroError* _nitro_err) {'));
      expect(out, isNot(contains('void* mylib_process(int64_t instanceId, void* input, NitroError* _nitro_err) {')));
    });

    test('direct C++ bridge treats variant params and returns as NitroCppBuffer', () {
      final out = CppBridgeGenerator.generate(
        _variantMethodSpec(iosImpl: NativeImpl.cpp, androidImpl: NativeImpl.cpp),
      );

      expect(out, contains('uint8_t* mylib_process(int64_t instanceId, void* input, NitroError* _nitro_err) {'));
      expect(
        out,
        contains('NitroCppBuffer _buf_input = { (const uint8_t*)input + 4, (size_t)*(int32_t*)input };'),
      );
      expect(out, contains('NitroCppBuffer _res = _impl->process(_buf_input);'));
      expect(out, contains('return (uint8_t*)_res.data;'));
    });
  });

  // ── Swift protocol — variant and @NitroResult regression guards ───────────

  group('SwiftGenerator — protocol signatures', () {
    test('variant method param/return uses concrete variant type, not Any', () {
      final out = SwiftGenerator.generate(_variantMethodSpec());
      // Protocol must use FilterResult, never Any.
      expect(out, contains('func process(input: FilterResult) -> FilterResult'));
      expect(out, isNot(contains('func process(input: Any)')));
    });

    test('@NitroResult method in protocol uses throws + inner return type', () {
      final spec = BridgeSpec(
        dartClassName: 'Calc',
        lib: 'calc',
        namespace: 'calc',
        iosImpl: NativeImpl.swift,
        sourceUri: 'calc.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'safeDiv',
            cSymbol: 'calc_safe_div',
            isAsync: false,
            isResult: true,
            returnType: BridgeType(name: 'double'),
            params: [
              BridgeParam(
                name: 'a',
                type: BridgeType(name: 'double'),
              ),
              BridgeParam(
                name: 'b',
                type: BridgeType(name: 'double'),
              ),
            ],
          ),
        ],
      );
      final out = SwiftGenerator.generate(spec);
      expect(out, contains('func safeDiv(a: Double, b: Double) throws -> Double'));
      expect(out, isNot(contains('func safeDiv(a: Double, b: Double) -> Double\n')));
    });

    test('@NitroResult<String> method in protocol uses throws -> String', () {
      final spec = BridgeSpec(
        dartClassName: 'Validator',
        lib: 'validator',
        namespace: 'validator',
        iosImpl: NativeImpl.swift,
        sourceUri: 'validator.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'validateLabel',
            cSymbol: 'validator_validate_label',
            isAsync: false,
            isResult: true,
            returnType: BridgeType(name: 'String'),
            params: [
              BridgeParam(
                name: 'label',
                type: BridgeType(name: 'String'),
              ),
            ],
          ),
        ],
      );
      final out = SwiftGenerator.generate(spec);
      expect(out, contains('func validateLabel(label: String) throws -> String'));
    });

    test('@NitroOwned method in protocol uses UnsafeMutableRawPointer? return', () {
      final spec = BridgeSpec(
        dartClassName: 'Alloc',
        lib: 'alloc',
        namespace: 'alloc',
        iosImpl: NativeImpl.swift,
        sourceUri: 'alloc.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'acquireBuffer',
            cSymbol: 'alloc_acquire_buffer',
            isAsync: false,
            isOwned: true,
            returnType: BridgeType(name: 'NativeHandle<Void>', isNativeHandle: true, nativeHandleTypeParam: 'Void'),
            params: [
              BridgeParam(
                name: 'size',
                type: BridgeType(name: 'int'),
              ),
            ],
          ),
        ],
      );
      final out = SwiftGenerator.generate(spec);
      expect(out, contains('func acquireBuffer(size: Int64) -> UnsafeMutableRawPointer?'));
    });

    test('@NitroOwned bridge stub guard uses return nil, not return ()', () {
      // Regression: isNativeHandle path must emit `return nil` for early-return guard,
      // not `return ()` (void), which would fail Swift compilation.
      final spec = BridgeSpec(
        dartClassName: 'Alloc',
        lib: 'alloc',
        namespace: 'alloc',
        iosImpl: NativeImpl.swift,
        sourceUri: 'alloc.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'acquireBuffer',
            cSymbol: 'alloc_acquire_buffer',
            isAsync: false,
            isOwned: true,
            returnType: BridgeType(name: 'NativeHandle<Void>', isNativeHandle: true, nativeHandleTypeParam: 'Void'),
            params: [
              BridgeParam(
                name: 'size',
                type: BridgeType(name: 'int'),
              ),
            ],
          ),
        ],
      );
      final out = SwiftGenerator.generate(spec);
      // The guard must use `return nil` not `return ()`.
      expect(out, contains('guard let impl = AllocRegistry.impl else { return nil }'));
      expect(out, isNot(contains('else { return () }')));
      // Bridge stub directly delegates to impl.
      expect(out, contains('return impl.acquireBuffer(size: size)'));
    });
  });

  // ── Async combinations (@nitroAsync + NitroOwned / NitroResult / NitroVariant) ──

  group('SpecValidator — @NitroResult + async', () {
    BridgeSpec asyncResultSpec({bool isNativeAsync = false}) => BridgeSpec(
      dartClassName: 'Calc',
      lib: 'calc',
      namespace: 'calc',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'calc.native.dart',
      functions: [
        BridgeFunction(
          dartName: 'asyncSafeDiv',
          cSymbol: 'calc_async_safe_div',
          isAsync: !isNativeAsync,
          isNativeAsync: isNativeAsync,
          isResult: true,
          returnType: BridgeType(name: 'double', isFuture: !isNativeAsync),
          params: [
            BridgeParam(
              name: 'a',
              type: BridgeType(name: 'double'),
            ),
            BridgeParam(
              name: 'b',
              type: BridgeType(name: 'double'),
            ),
          ],
        ),
      ],
    );

    test('@NitroResult + @nitroAsync no longer produces E015', () {
      final issues = SpecValidator.validate(asyncResultSpec());
      expect(issues.where((i) => i.code == 'E015'), isEmpty, reason: '@nitroAsync is now allowed with @NitroResult');
    });

    test('@NitroResult + @NitroNativeAsync still produces E015', () {
      final issues = SpecValidator.validate(asyncResultSpec(isNativeAsync: true));
      expect(issues.any((i) => i.code == 'E015'), isTrue, reason: 'NativeAsync cannot encode NitroResultValue buffers via Dart_PostCObject_DL');
    });

    test('@NitroResult + @nitroAsync message no longer mentions @nitroAsync', () {
      // Regression: old message told users to "remove @nitroAsync" — should not say that now.
      final issues = SpecValidator.validate(asyncResultSpec(isNativeAsync: true));
      final e015 = issues.firstWhere((i) => i.code == 'E015', orElse: () => throw 'no E015');
      expect(e015.message, isNot(contains('@nitroAsync')));
      expect(e015.message, contains('@NitroNativeAsync'));
    });
  });

  group('SwiftGenerator — @nitroAsync + annotation combos', () {
    BridgeSpec asyncOwnedSpec() => BridgeSpec(
      dartClassName: 'Alloc',
      lib: 'alloc',
      namespace: 'alloc',
      iosImpl: NativeImpl.swift,
      sourceUri: 'alloc.native.dart',
      functions: [
        BridgeFunction(
          dartName: 'acquireBuffer',
          cSymbol: 'alloc_acquire_buffer',
          isAsync: true,
          isOwned: true,
          returnType: BridgeType(name: 'NativeHandle<Void>', isNativeHandle: true, nativeHandleTypeParam: 'Void', isFuture: true),
          params: [
            BridgeParam(
              name: 'size',
              type: BridgeType(name: 'int'),
            ),
          ],
        ),
      ],
    );

    BridgeSpec asyncResultSpec() => BridgeSpec(
      dartClassName: 'Calc',
      lib: 'calc',
      namespace: 'calc',
      iosImpl: NativeImpl.swift,
      sourceUri: 'calc.native.dart',
      functions: [
        BridgeFunction(
          dartName: 'asyncSafeDiv',
          cSymbol: 'calc_async_safe_div',
          isAsync: true,
          isResult: true,
          returnType: BridgeType(name: 'double', isFuture: true),
          params: [
            BridgeParam(
              name: 'a',
              type: BridgeType(name: 'double'),
            ),
            BridgeParam(
              name: 'b',
              type: BridgeType(name: 'double'),
            ),
          ],
        ),
      ],
    );

    BridgeSpec asyncVariantSpec() => BridgeSpec(
      dartClassName: 'Filter',
      lib: 'mylib',
      namespace: 'mylib',
      iosImpl: NativeImpl.swift,
      sourceUri: 'filter.native.dart',
      variants: [_filterVariant()],
      functions: [
        BridgeFunction(
          dartName: 'asyncProcess',
          cSymbol: 'mylib_async_process',
          isAsync: true,
          returnType: BridgeType(name: 'FilterResult', isFuture: true),
          params: [
            BridgeParam(
              name: 'input',
              type: BridgeType(name: 'FilterResult'),
            ),
          ],
        ),
      ],
    );

    test('@nitroAsync @NitroOwned uses DispatchSemaphore + _ownedPtr', () {
      final out = SwiftGenerator.generate(asyncOwnedSpec());
      expect(out, contains('DispatchSemaphore'));
      expect(out, contains('var _ownedPtr: UnsafeMutableRawPointer? = nil'));
      expect(out, contains('try? await impl.acquireBuffer(size: size)'));
      expect(out, contains('return _ownedPtr'));
    });

    test('@nitroAsync @NitroOwned does not emit `return ()` or `return impl.method()` directly', () {
      final out = SwiftGenerator.generate(asyncOwnedSpec());
      // Must NOT call impl directly on the calling thread.
      expect(out, isNot(contains('return impl.acquireBuffer')));
      // Must NOT fall through to void/default path.
      expect(out, isNot(contains('else { return () }')));
    });

    test('@nitroAsync @NitroResult uses DispatchSemaphore + try/catch + encode', () {
      final out = SwiftGenerator.generate(asyncResultSpec());
      expect(out, contains('DispatchSemaphore'));
      expect(out, contains('var _nitroOk: Double? = nil'));
      expect(out, contains('var _nitroErr: Error? = nil'));
      expect(out, contains('do { _nitroOk = try await impl.asyncSafeDiv(a: a, b: b) }'));
      expect(out, contains('catch { _nitroErr = error }'));
      expect(out, contains('_nitroEncodeResultError'));
      expect(out, contains('_nitroEncodeResultFloat64'));
    });

    test('@nitroAsync @NitroResult does not call impl synchronously', () {
      final out = SwiftGenerator.generate(asyncResultSpec());
      // Must not have a direct synchronous try/do without sema.
      expect(out, isNot(contains('let result = try impl.asyncSafeDiv')));
    });

    test('@nitroAsync @NitroVariant uses DispatchSemaphore + NitroRecordWriter', () {
      final out = SwiftGenerator.generate(asyncVariantSpec());
      expect(out, contains('DispatchSemaphore'));
      expect(out, contains('var _vResult: FilterResult? = nil'));
      expect(out, contains('try? await impl.asyncProcess'));
      expect(out, contains('guard let _vr = _vResult else { return nil }'));
      expect(out, contains('NitroRecordWriter()'));
      expect(out, contains('_vr.writeFields(to: _vw)'));
      expect(out, contains('_vw.toNative().map { UnsafeMutablePointer'));
    });

    test('@nitroAsync @NitroVariant does not call impl synchronously', () {
      final out = SwiftGenerator.generate(asyncVariantSpec());
      expect(out, isNot(contains('let _vResult = impl.asyncProcess')));
    });
  });

  group('KotlinGenerator — @nitroAsync + annotation combos', () {
    BridgeSpec asyncResultSpec() => BridgeSpec(
      dartClassName: 'Calc',
      lib: 'calc',
      namespace: 'calc',
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'calc.native.dart',
      functions: [
        BridgeFunction(
          dartName: 'asyncSafeDiv',
          cSymbol: 'calc_async_safe_div',
          isAsync: true,
          isResult: true,
          returnType: BridgeType(name: 'double', isFuture: true),
          params: [
            BridgeParam(
              name: 'a',
              type: BridgeType(name: 'double'),
            ),
            BridgeParam(
              name: 'b',
              type: BridgeType(name: 'double'),
            ),
          ],
        ),
      ],
    );

    BridgeSpec asyncVariantSpec() => BridgeSpec(
      dartClassName: 'Filter',
      lib: 'mylib',
      namespace: 'mylib',
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'filter.native.dart',
      variants: [_filterVariant()],
      functions: [
        BridgeFunction(
          dartName: 'asyncProcess',
          cSymbol: 'mylib_async_process',
          isAsync: true,
          returnType: BridgeType(name: 'FilterResult', isFuture: true),
          params: [
            BridgeParam(
              name: 'input',
              type: BridgeType(name: 'FilterResult'),
            ),
          ],
        ),
      ],
    );

    BridgeSpec asyncOwnedSpec() => BridgeSpec(
      dartClassName: 'Alloc',
      lib: 'alloc',
      namespace: 'alloc',
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'alloc.native.dart',
      functions: [
        BridgeFunction(
          dartName: 'asyncAcquireBuffer',
          cSymbol: 'alloc_async_acquire_buffer',
          isAsync: true,
          isOwned: true,
          returnType: BridgeType(name: 'NativeHandle<Void>', isNativeHandle: true, nativeHandleTypeParam: 'Void', isFuture: true),
          params: [
            BridgeParam(
              name: 'size',
              type: BridgeType(name: 'int'),
            ),
          ],
        ),
      ],
    );

    test('@nitroAsync @NitroResult uses _asyncExecutor.submit with runBlocking', () {
      final out = KotlinGenerator.generate(asyncResultSpec());
      expect(out, contains('_asyncExecutor.submit'));
      expect(out, contains('runBlocking { impl.asyncSafeDiv(a, b) }'));
    });

    test('@nitroAsync @NitroResult encodes ok and err paths', () {
      final out = KotlinGenerator.generate(asyncResultSpec());
      expect(out, contains('nitroEncodeResultFloat64(_result)'));
      expect(out, contains('nitroEncodeResultError(_e.message'));
    });

    test('@nitroAsync @NitroResult does not call impl synchronously', () {
      final out = KotlinGenerator.generate(asyncResultSpec());
      expect(out, isNot(contains('val _result = impl.asyncSafeDiv')));
    });

    test('@nitroAsync @NitroVariant uses _asyncExecutor.submit with runBlocking', () {
      final out = KotlinGenerator.generate(asyncVariantSpec());
      expect(out, contains('_asyncExecutor.submit'));
      expect(out, contains('runBlocking { impl.asyncProcess('));
    });

    test('@nitroAsync @NitroVariant still encodes via RecordWriter + writeFields', () {
      final out = KotlinGenerator.generate(asyncVariantSpec());
      expect(out, contains('RecordWriter()'));
      expect(out, contains('_vResult.writeFields(_vw)'));
    });

    test('@nitroAsync @NitroVariant does not call impl synchronously', () {
      final out = KotlinGenerator.generate(asyncVariantSpec());
      expect(out, isNot(contains('val _vResult = impl.asyncProcess')));
    });

    test('@nitroAsync @NitroOwned uses _asyncExecutor.submit and returns Long', () {
      final out = KotlinGenerator.generate(asyncOwnedSpec());
      expect(out, contains('_asyncExecutor.submit'));
      expect(out, contains('runBlocking { impl.asyncAcquireBuffer(size) }'));
      // JNI bridge return type is Long (jlong handle).
      expect(out, contains('asyncAcquireBuffer_call(instanceId: Long, size: Long): Long'));
    });
  });

  group('CppBridgeGenerator — @NitroOwned release symbol', () {
    BridgeSpec ownedSpec() => BridgeSpec(
      dartClassName: 'Alloc',
      lib: 'alloc',
      namespace: 'alloc',
      iosImpl: NativeImpl.swift,
      sourceUri: 'alloc.native.dart',
      functions: [
        BridgeFunction(
          dartName: 'acquireBuffer',
          cSymbol: 'alloc_acquire_buffer',
          isAsync: false,
          isOwned: true,
          returnType: BridgeType(name: 'NativeHandle<Void>', isNativeHandle: true, nativeHandleTypeParam: 'Void'),
          params: [
            BridgeParam(
              name: 'size',
              type: BridgeType(name: 'int'),
            ),
          ],
        ),
      ],
    );

    test('generates _release symbol for @NitroOwned function', () {
      final out = CppBridgeGenerator.generate(ownedSpec());
      expect(out, contains('void alloc_acquire_buffer_release(void* handle)'));
    });

    test('_release calls free(handle) on all platforms (Point 8 fix — no Android no-op)', () {
      final out = CppBridgeGenerator.generate(ownedSpec());
      // After Point 8 fix: Android uses real malloc pointers (sun.misc.Unsafe.allocateMemory),
      // so _release always calls free() regardless of platform.
      expect(out, contains('if (handle) { free(handle); }'));
      expect(out, isNot(contains('(void)handle;')));
    });

    test('_release is in the global section (before platform guards)', () {
      final out = CppBridgeGenerator.generate(ownedSpec());
      // The _release must appear BEFORE any #ifdef __ANDROID__ platform guard.
      final releasePos = out.indexOf('alloc_acquire_buffer_release');
      final androidGuardPos = out.indexOf('#ifdef __ANDROID__');
      expect(releasePos, lessThan(androidGuardPos == -1 ? out.length : androidGuardPos + 1));
    });

    test('_release symbol matches header declaration (cSymbol + _release)', () {
      // Regression: the released symbol name must equal the C call symbol + "_release"
      // so Dart's dlsym lookup finds it at runtime.
      final out = CppBridgeGenerator.generate(ownedSpec());
      expect(out, contains('alloc_acquire_buffer_release'));
      // Must NOT use a wrong/generic name.
      expect(out, isNot(contains('void _release(')));
    });
  });

  // ── Finding 8: Union optimization for prim-only @NitroVariant ──────────────

  /// A prim-only variant: every case is either unit or has exactly one
  /// non-nullable int/double/bool field. The generator should emit a dart:ffi
  /// Union + a zero-copy fromNative instead of going through RecordReader.
  BridgeVariant _primOnlyVariant() => BridgeVariant(
    name: 'PrimResult',
    cases: [
      BridgeVariantCase(
        name: 'PrimInt',
        label: 'primInt',
        fields: [
          BridgeRecordField(
            name: 'value',
            dartType: 'int',
            kind: RecordFieldKind.primitive,
          ),
        ],
      ),
      BridgeVariantCase(
        name: 'PrimDouble',
        label: 'primDouble',
        fields: [
          BridgeRecordField(
            name: 'amount',
            dartType: 'double',
            kind: RecordFieldKind.primitive,
          ),
        ],
      ),
      BridgeVariantCase(
        name: 'PrimBool',
        label: 'primBool',
        fields: [
          BridgeRecordField(
            name: 'flag',
            dartType: 'bool',
            kind: RecordFieldKind.primitive,
          ),
        ],
      ),
      BridgeVariantCase(
        name: 'PrimUnit',
        label: 'primUnit',
        fields: [],
      ),
    ],
  );

  BridgeSpec _primOnlyVariantSpec() => BridgeSpec(
    dartClassName: '',
    lib: 'prim',
    namespace: '',
    sourceUri: 'prim.native.dart',
    variants: [_primOnlyVariant()],
    isTypeOnly: true,
  );

  group('Finding 8 — @Native Union optimization for prim-only @NitroVariant', () {
    test('prim-only variant emits Union payload type before extension', () {
      final code = VariantGenerator.generateDartExtensions(_primOnlyVariantSpec());
      expect(code, contains('final class _PrimResultPayload extends Union'));
      // Union must appear BEFORE the extension
      final unionPos = code.indexOf('_PrimResultPayload extends Union');
      final extPos = code.indexOf('extension PrimResultVariantExt');
      expect(unionPos, lessThan(extPos));
    });

    test('prim-only Union has @Int64 asInt, @Double asDouble, @Uint8 asBool fields', () {
      final code = VariantGenerator.generateDartExtensions(_primOnlyVariantSpec());
      expect(code, contains('@Int64() external int asInt;'));
      expect(code, contains('@Double() external double asDouble;'));
      expect(code, contains('@Uint8() external int asBool;'));
    });

    test('prim-only fromNative uses pointer cast instead of RecordReader', () {
      final code = VariantGenerator.generateDartExtensions(_primOnlyVariantSpec());
      expect(code, contains('(ptr + 1).cast<_PrimResultPayload>().ref'));
      // The optimized path does NOT call fromReader
      final fromNativeStart = code.indexOf('static PrimResult fromNative(Pointer<Uint8> ptr)');
      final fromReaderStart = code.indexOf('static PrimResult fromReader(RecordReader r)');
      final fromNativeBody = code.substring(fromNativeStart, fromReaderStart);
      expect(fromNativeBody, isNot(contains('fromReader')));
    });

    test('prim-only fromNative reads int via p.asInt', () {
      final code = VariantGenerator.generateDartExtensions(_primOnlyVariantSpec());
      expect(code, contains('PrimInt(value: p.asInt)'));
    });

    test('prim-only fromNative reads double via p.asDouble', () {
      final code = VariantGenerator.generateDartExtensions(_primOnlyVariantSpec());
      expect(code, contains('PrimDouble(amount: p.asDouble)'));
    });

    test('prim-only fromNative reads bool via p.asBool != 0', () {
      final code = VariantGenerator.generateDartExtensions(_primOnlyVariantSpec());
      expect(code, contains('PrimBool(flag: p.asBool != 0)'));
    });

    test('prim-only fromNative emits unit case correctly', () {
      final code = VariantGenerator.generateDartExtensions(_primOnlyVariantSpec());
      expect(code, contains('3 => PrimUnit()'));
    });

    test('prim-only fromReader is still emitted (used for list deserialization)', () {
      final code = VariantGenerator.generateDartExtensions(_primOnlyVariantSpec());
      expect(code, contains('static PrimResult fromReader(RecordReader r)'));
      // fromReader still uses readInt8() tag
      expect(code, contains('r.readInt8()'));
    });

    test('non-prim variant (String field) does NOT emit Union', () {
      // FilterResult has a String id field — not prim-only.
      final code = VariantGenerator.generateDartExtensions(_typeOnlyVariantSpec());
      expect(code, isNot(contains('extends Union')));
    });

    test('non-prim variant fromNative still delegates to fromReader', () {
      final code = VariantGenerator.generateDartExtensions(_typeOnlyVariantSpec());
      expect(code, contains('fromReader(RecordReader.fromNative(ptr))'));
    });

    test('non-prim fromReader is unchanged', () {
      final code = VariantGenerator.generateDartExtensions(_typeOnlyVariantSpec());
      expect(code, contains('static FilterResult fromReader(RecordReader r)'));
      expect(code, contains('r.readString()'));
    });

    test('prim-only writeFields and toNative are unchanged', () {
      final code = VariantGenerator.generateDartExtensions(_primOnlyVariantSpec());
      expect(code, contains('void writeFields(RecordWriter writer)'));
      expect(code, contains('Pointer<Uint8> toNative(Allocator alloc)'));
    });

    test('nullable prim field disqualifies variant from Union optimization', () {
      final nullableVariant = BridgeVariant(
        name: 'NullableResult',
        cases: [
          BridgeVariantCase(
            name: 'WithNullableInt',
            label: 'withNullableInt',
            fields: [
              BridgeRecordField(
                name: 'count',
                dartType: 'int?',
                kind: RecordFieldKind.primitive,
                isNullable: true,
              ),
            ],
          ),
        ],
      );
      final spec = BridgeSpec(
        dartClassName: '',
        lib: 'n',
        namespace: '',
        sourceUri: 'n.native.dart',
        variants: [nullableVariant],
        isTypeOnly: true,
      );
      final code = VariantGenerator.generateDartExtensions(spec);
      // Nullable field → not prim-only → no Union
      expect(code, isNot(contains('extends Union')));
      expect(code, contains('fromReader(RecordReader.fromNative(ptr))'));
    });

    test('enum field disqualifies variant from Union optimization', () {
      final enumVariant = BridgeVariant(
        name: 'EnumResult',
        cases: [
          BridgeVariantCase(
            name: 'WithEnum',
            label: 'withEnum',
            fields: [
              BridgeRecordField(
                name: 'quality',
                dartType: 'Quality',
                kind: RecordFieldKind.enumValue,
              ),
            ],
          ),
        ],
      );
      final spec = BridgeSpec(
        dartClassName: '',
        lib: 'e',
        namespace: '',
        sourceUri: 'e.native.dart',
        variants: [enumVariant],
        isTypeOnly: true,
      );
      final code = VariantGenerator.generateDartExtensions(spec);
      expect(code, isNot(contains('extends Union')));
    });
  });
}
