// @HybridStruct field dispatch matched `f.type.name` EXACTLY, so a `String?`
// field matched nothing:
//   * freeFields emitted no nativeFree  → the strdup'd string leaked;
//   * toNative fell to `ptr.ref.f = f;` → assigning String? to Pointer<Utf8>,
//     which does not compile, so the whole generated part file was broken;
//   * toDart fell through to the raw pointer.
// The validator stripped `?` before checking, so such a spec passed.
//
// A flat C struct can represent absence only in a POINTER field. Scalars and
// enums have no spare bit — those are now E019.
import 'package:nitro_generator/src/generators/languages/web/web_bridge_generator.dart';
import 'package:nitro_generator/src/generators/struct_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

BridgeSpec _structSpec(List<BridgeField> fields, {List<BridgeStruct> extra = const []}) => BridgeSpec(
  dartClassName: 'M',
  lib: 'm',
  namespace: 'm',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'm.native.dart',
  structs: [BridgeStruct(name: 'S', packed: false, fields: fields), ...extra],
);

Set<String> _codes(BridgeSpec s) => SpecValidator.validate(s).where((i) => i.isError).map((i) => i.code).toSet();

void main() {
  group('nullable pointer-shaped fields are supported', () {
    final spec = _structSpec([BridgeField(name: 'label', type: BridgeType(name: 'String?'))]);

    test('accepted by the validator', () {
      expect(_codes(spec), isNot(contains('E019')));
    });

    test('is freed — the strdup\'d string used to leak', () {
      expect(StructGenerator.generateDartExtensions(spec), contains('nativeFree(label)'));
    });

    test('encodes null as nullptr instead of assigning String? to a pointer', () {
      final out = StructGenerator.generateDartExtensions(spec);
      expect(out, contains('label == null ? nullptr :'));
      expect(out, isNot(contains('ptr.ref.label = label;')), reason: 'would not compile');
    });

    test('decodes nullptr back to null', () {
      expect(StructGenerator.generateDartExtensions(spec), contains('label.address == 0 ? null :'));
    });

    test('a non-nullable String is unchanged', () {
      final out = StructGenerator.generateDartExtensions(
        _structSpec([BridgeField(name: 'label', type: BridgeType(name: 'String'))]),
      );
      expect(out, contains('label.toNativeUtf8(allocator: arena)'));
      expect(out, isNot(contains('label == null ?')));
      expect(out, contains('nativeFree(label)'));
    });

    test('a nullable nested struct is also pointer-shaped', () {
      final nested = BridgeStruct(name: 'P', packed: false, fields: [BridgeField(name: 'x', type: BridgeType(name: 'int'))]);
      final s = _structSpec([BridgeField(name: 'origin', type: BridgeType(name: 'P?'))], extra: [nested]);
      expect(_codes(s), isNot(contains('E019')));
      expect(StructGenerator.generateDartExtensions(s), contains('origin == null ? nullptr :'));
    });
  });

  group('nullable scalar/enum fields ride a synthesized presence byte', () {
    // A flat C struct has no spare bit in an int64_t/double/int8_t slot, so
    // absence is carried in `<field>HasValue` — the same convention the
    // NitroOptInt64/Float64/Bool param wrappers use.
    BridgeSpec scalarSpec(String type) => _structSpec([
      BridgeField(name: 'v', type: BridgeType(name: type)),
      BridgeField(name: 'keep', type: BridgeType(name: 'int')),
    ]);

    for (final t in ['int?', 'double?', 'bool?']) {
      test('$t is accepted, not rejected', () {
        expect(_codes(scalarSpec(t)), isEmpty);
      });

      test('$t emits the presence byte in BOTH the C struct and the FFI struct', () {
        expect(StructGenerator.generateCStructs(scalarSpec(t)), contains('int8_t vHasValue;'));
        final dart = StructGenerator.generateDartExtensions(scalarSpec(t));
        expect(dart, contains('external int vHasValue;'));
        expect(dart, contains('@Uint8()'));
      });

      test('$t writes 0 to the payload slot when absent', () {
        final out = StructGenerator.generateDartExtensions(scalarSpec(t));
        expect(out, contains('ptr.ref.vHasValue = v == null ? 0 : 1;'));
        expect(out, contains('ptr.ref.v = v == null ?'));
      });

      test('$t decodes back to null when the byte is 0', () {
        expect(StructGenerator.generateDartExtensions(scalarSpec(t)), contains('v: vHasValue != 0 ?'));
      });
    }

    test('a non-nullable scalar gets NO presence byte — layout is unchanged', () {
      for (final t in ['int', 'double', 'bool']) {
        final c = StructGenerator.generateCStructs(scalarSpec(t.replaceAll('?', '')));
        expect(c, isNot(contains('HasValue')), reason: t);
      }
    });

    test('the presence byte sits directly after its own field', () {
      // Order matters: every backend derives offsets from this sequence.
      final c = StructGenerator.generateCStructs(scalarSpec('int?'));
      final lines = c.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
      final vIdx = lines.indexWhere((l) => l.startsWith('int64_t v;'));
      expect(vIdx, greaterThanOrEqualTo(0));
      expect(lines[vIdx + 1], startsWith('int8_t vHasValue;'));
    });

    test('a nullable enum uses the byte too, and keeps its int32 slot', () {
      final spec = BridgeSpec(
        dartClassName: 'M', lib: 'm', namespace: 'm',
        iosImpl: NativeImpl.swift, androidImpl: NativeImpl.kotlin,
        sourceUri: 'm.native.dart',
        enums: [BridgeEnum(name: 'Mode', startValue: 0, values: ['a', 'b'])],
        structs: [BridgeStruct(name: 'S', packed: false, fields: [
          BridgeField(name: 'mode', type: BridgeType(name: 'Mode?')),
        ])],
      );
      expect(_codes(spec), isEmpty);
      expect(StructGenerator.generateCStructs(spec), contains('int8_t modeHasValue;'));
      expect(StructGenerator.generateDartExtensions(spec), contains('mode: modeHasValue != 0 ? mode.toMode() : null'));
    });

    test('a packed struct still gets the byte (alignment 1 either way)', () {
      final spec = _structSpec([BridgeField(name: 'v', type: BridgeType(name: 'int?'))]);
      final packed = BridgeSpec(
        dartClassName: 'M', lib: 'm', namespace: 'm',
        iosImpl: NativeImpl.swift, androidImpl: NativeImpl.kotlin,
        sourceUri: 'm.native.dart',
        structs: [BridgeStruct(name: 'S', packed: true, fields: spec.structs.first.fields)],
      );
      expect(StructGenerator.generateCStructs(packed), contains('int8_t vHasValue;'));
      expect(StructGenerator.generateCStructs(packed), contains('#pragma pack'));
    });
  });

  // The wasm32 layout is computed independently of the C typedef, so the two
  // must agree explicitly — an offset that drifts by one byte reads a
  // neighbouring field's bits (that failure showed up as a garbage double).
  group('web wasm32 layout reserves the presence byte', () {
    BridgeSpec webSpec(List<BridgeField> fields) => BridgeSpec(
      dartClassName: 'M', lib: 'm', namespace: 'm',
      iosImpl: NativeImpl.swift, androidImpl: NativeImpl.kotlin,
      webImpl: NativeImpl.wasm,
      sourceUri: 'm.native.dart',
      structs: [BridgeStruct(name: 'S', packed: false, fields: fields)],
      functions: [
        BridgeFunction(
          dartName: 'echo', cSymbol: 'm_echo', isAsync: false,
          returnType: BridgeType(name: 'S'),
          params: [BridgeParam(name: 'v', type: BridgeType(name: 'S'))],
        ),
      ],
    );

    test('writes and reads the byte on both sides', () {
      final out = WebBridgeGenerator.generate(webSpec([
        BridgeField(name: 'count', type: BridgeType(name: 'int?')),
        BridgeField(name: 'keep', type: BridgeType(name: 'int')),
      ]));
      // int64 payload at 0, presence byte at 8, `keep` re-aligned to 16.
      expect(out, contains('bd.setUint8(8, v.count == null ? 0 : 1);'));
      expect(out, contains('bd.getUint8(8) != 0 ?'));
      expect(out, contains('setInt64LE(bd, 16, v.keep);'), reason: 'the byte must push the next field past padding');
    });

    test('a bool? needs no padding before its byte', () {
      final out = WebBridgeGenerator.generate(webSpec([
        BridgeField(name: 'flag', type: BridgeType(name: 'bool?')),
        BridgeField(name: 'n', type: BridgeType(name: 'int')),
      ]));
      expect(out, contains('bd.setUint8(1, v.flag == null ? 0 : 1);'));
      expect(out, contains('setInt64LE(bd, 8, v.n);'));
    });

    test('a struct with no nullable scalars emits no presence byte', () {
      final out = WebBridgeGenerator.generate(webSpec([
        BridgeField(name: 'n', type: BridgeType(name: 'int')),
      ]));
      expect(out, isNot(contains('HasValue')));
      expect(out, isNot(contains('setUint8(')));
    });
  });

  // DateTime and uint64 are legal struct field types. DateTime was broken in
  // BOTH forms — the encode assigned a DateTime straight into the int64 slot,
  // which does not compile.
  group('DateTime and uint64 struct fields', () {
    String gen(String t) => StructGenerator.generateDartExtensions(
      _structSpec([BridgeField(name: 'v', type: BridgeType(name: t))]),
    );

    test('DateTime encodes as ms-epoch and decodes back', () {
      final out = gen('DateTime');
      expect(out, contains('ptr.ref.v = v.millisecondsSinceEpoch;'));
      expect(out, contains('DateTime.fromMillisecondsSinceEpoch(v)'));
      expect(out, isNot(contains('ptr.ref.v = v;')), reason: 'assigning a DateTime to an int64 slot does not compile');
    });

    test('DateTime? adds the presence byte on top of the ms-epoch slot', () {
      final out = gen('DateTime?');
      expect(out, contains('ptr.ref.v = v == null ? 0 : v!.millisecondsSinceEpoch;'));
      expect(out, contains('v: vHasValue != 0 ? DateTime.fromMillisecondsSinceEpoch(v) : null'));
    });

    test('uint64 and uint64? stay plain int slots', () {
      expect(gen('uint64'), contains('ptr.ref.v = v;'));
      final n = gen('uint64?');
      expect(n, contains('ptr.ref.v = v == null ? 0 : v!;'));
      expect(n, contains('v: vHasValue != 0 ? v : null'));
    });
  });

}
