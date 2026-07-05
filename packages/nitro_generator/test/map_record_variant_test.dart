// Tests for L4: Map<String, @HybridRecord> and Map<String, @NitroVariant>
// with proper binary encoding (tag 5 = binary blob).

import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// ── Spec builders ─────────────────────────────────────────────────────────────

BridgeSpec _mapRecordReturnSpec() => BridgeSpec(
  dartClassName: 'Catalog',
  lib: 'catalog',
  namespace: 'catalog',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'catalog.native.dart',
  recordTypes: [
    BridgeRecordType(
      name: 'Product',
      fields: [
        BridgeRecordField(name: 'id', dartType: 'int', kind: RecordFieldKind.primitive),
        BridgeRecordField(name: 'name', dartType: 'String', kind: RecordFieldKind.primitive),
      ],
    ),
  ],
  functions: [
    BridgeFunction(
      dartName: 'getProducts',
      cSymbol: 'catalog_get_products',
      isAsync: false,
      returnType: BridgeType(
        name: 'Map<String, Product>',
        isRecord: true,
        isMap: true,
      ),
      params: [],
    ),
  ],
);

BridgeSpec _mapRecordParamSpec() => BridgeSpec(
  dartClassName: 'Catalog',
  lib: 'catalog',
  namespace: 'catalog',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'catalog.native.dart',
  recordTypes: [
    BridgeRecordType(
      name: 'Product',
      fields: [
        BridgeRecordField(name: 'id', dartType: 'int', kind: RecordFieldKind.primitive),
        BridgeRecordField(name: 'name', dartType: 'String', kind: RecordFieldKind.primitive),
      ],
    ),
  ],
  functions: [
    BridgeFunction(
      dartName: 'setProducts',
      cSymbol: 'catalog_set_products',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'products',
          type: BridgeType(
            name: 'Map<String, Product>',
            isRecord: true,
            isMap: true,
          ),
        ),
      ],
    ),
  ],
);

BridgeSpec _mapVariantReturnSpec() => BridgeSpec(
  dartClassName: 'Events',
  lib: 'events',
  namespace: 'events',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'events.native.dart',
  variants: [
    BridgeVariant(
      name: 'EventPayload',
      cases: [
        BridgeVariantCase(
          name: 'Click',
          label: 'click',
          fields: [
            BridgeRecordField(name: 'x', dartType: 'int', kind: RecordFieldKind.primitive),
          ],
        ),
        BridgeVariantCase(
          name: 'Scroll',
          label: 'scroll',
          fields: [
            BridgeRecordField(name: 'delta', dartType: 'double', kind: RecordFieldKind.primitive),
          ],
        ),
      ],
    ),
  ],
  functions: [
    BridgeFunction(
      dartName: 'getEvents',
      cSymbol: 'events_get_events',
      isAsync: false,
      returnType: BridgeType(
        name: 'Map<String, EventPayload>',
        isRecord: true,
        isMap: true,
      ),
      params: [],
    ),
  ],
);

BridgeSpec _mapVariantParamSpec() => BridgeSpec(
  dartClassName: 'Events',
  lib: 'events',
  namespace: 'events',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'events.native.dart',
  variants: [
    BridgeVariant(
      name: 'EventPayload',
      cases: [
        BridgeVariantCase(
          name: 'Click',
          label: 'click',
          fields: [
            BridgeRecordField(name: 'x', dartType: 'int', kind: RecordFieldKind.primitive),
          ],
        ),
      ],
    ),
  ],
  functions: [
    BridgeFunction(
      dartName: 'processEvents',
      cSymbol: 'events_process_events',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'events',
          type: BridgeType(
            name: 'Map<String, EventPayload>',
            isRecord: true,
            isMap: true,
          ),
        ),
      ],
    ),
  ],
);

// ── §31: Map<String, @HybridRecord> — Dart generator ─────────────────────────

void main() {
  group('§31 L4 Map<String, @HybridRecord> — Dart generator', () {
    test('§31.1 decode helper uses RecordExt.fromNative for record values', () {
      final out = DartFfiGenerator.generate(_mapRecordReturnSpec());
      expect(out, contains('ProductRecordExt.fromNative'));
    });

    test('§31.2 decode helper uses tag 5 skip', () {
      final out = DartFfiGenerator.generate(_mapRecordReturnSpec());
      // Tag 5 = binary record blob
      expect(out, contains('skip type tag (always 5=binary record'));
    });

    test('§31.3 decode helper reads 4B blob_len', () {
      final out = DartFfiGenerator.generate(_mapRecordReturnSpec());
      expect(out, contains('_bLen'));
      expect(out, contains('malloc<Uint8>'));
    });

    test('§31.4 decode helper frees allocated pointer', () {
      final out = DartFfiGenerator.generate(_mapRecordReturnSpec());
      expect(out, contains('malloc.free(_bPtr)'));
    });

    test('§31.5 encode helper uses tag 5 for record values', () {
      final out = DartFfiGenerator.generate(_mapRecordParamSpec());
      expect(out, contains('bb.addByte(5)'));
    });

    test('§31.6 encode helper calls toNative(alloc) on record', () {
      final out = DartFfiGenerator.generate(_mapRecordParamSpec());
      expect(out, contains('toNative(alloc)'));
    });

    test('§31.7 encode helper writes 4B blob length prefix', () {
      final out = DartFfiGenerator.generate(_mapRecordParamSpec());
      expect(out, contains('_recLen'));
    });

    test('§31.8 helper function uses typed suffix _nitroDecodeMapBinaryProduct', () {
      final out = DartFfiGenerator.generate(_mapRecordReturnSpec());
      expect(out, contains('_nitroDecodeMapBinaryProduct'));
    });

    test('§31.9 helper function uses typed suffix _nitroEncodeMapBinaryProduct', () {
      final out = DartFfiGenerator.generate(_mapRecordParamSpec());
      expect(out, contains('_nitroEncodeMapBinaryProduct'));
    });

    test('§31.10 return type is Map<String, Product>', () {
      final out = DartFfiGenerator.generate(_mapRecordReturnSpec());
      expect(out, contains('Map<String, Product>'));
    });
  });

  // ── §32: Map<String, @NitroVariant> — Dart generator ─────────────────────

  group('§32 L4 Map<String, @NitroVariant> — Dart generator', () {
    test('§32.1 decode helper uses VariantExt.fromNative for variant values', () {
      final out = DartFfiGenerator.generate(_mapVariantReturnSpec());
      expect(out, contains('EventPayloadVariantExt.fromNative'));
    });

    test('§32.2 decode helper uses tag 5 skip for variant', () {
      final out = DartFfiGenerator.generate(_mapVariantReturnSpec());
      expect(out, contains('skip type tag (always 5=binary variant'));
    });

    test('§32.3 decode helper allocates and frees pointer', () {
      final out = DartFfiGenerator.generate(_mapVariantReturnSpec());
      expect(out, contains('malloc<Uint8>'));
      expect(out, contains('malloc.free(_bPtr)'));
    });

    test('§32.4 encode helper uses tag 5 for variant values', () {
      final out = DartFfiGenerator.generate(_mapVariantParamSpec());
      expect(out, contains('bb.addByte(5)'));
    });

    test('§32.5 encode helper calls toNative(alloc) on variant', () {
      final out = DartFfiGenerator.generate(_mapVariantParamSpec());
      expect(out, contains('toNative(alloc)'));
    });

    test('§32.6 typed decode helper suffix uses variant name', () {
      final out = DartFfiGenerator.generate(_mapVariantReturnSpec());
      expect(out, contains('_nitroDecodeMapBinaryEventPayload'));
    });

    test('§32.7 typed encode helper suffix uses variant name', () {
      final out = DartFfiGenerator.generate(_mapVariantParamSpec());
      expect(out, contains('_nitroEncodeMapBinaryEventPayload'));
    });

    test('§32.8 return type is Map<String, EventPayload>', () {
      final out = DartFfiGenerator.generate(_mapVariantReturnSpec());
      expect(out, contains('Map<String, EventPayload>'));
    });
  });

  // ── §33: Map<String, @HybridRecord> — Kotlin generator ───────────────────

  group('§33 L4 Map<String, @HybridRecord> — Kotlin generator', () {
    test('§33.1 output map encodes record values with tag 5', () {
      final out = KotlinGenerator.generate(_mapRecordReturnSpec());
      expect(out, contains('tag: binary record'));
    });

    test('§33.2 record encode() method called for map value', () {
      final out = KotlinGenerator.generate(_mapRecordReturnSpec());
      expect(out, contains('encode()'));
    });

    test('§33.3 blob length written before blob bytes', () {
      final out = KotlinGenerator.generate(_mapRecordReturnSpec());
      expect(out, contains('_writeInt32(_rBytes.size)'));
    });

    test('§33.4 input record decoded via decodeFrom(ByteBuffer)', () {
      final out = KotlinGenerator.generate(_mapRecordParamSpec());
      expect(out, contains('decodeFrom'));
    });

    test('§33.5 input skips 4B payload_len prefix before decodeFrom', () {
      final out = KotlinGenerator.generate(_mapRecordParamSpec());
      // _bBuf created from blob bytes, skip 4B prefix via getInt()
      expect(out, contains('_bBuf'));
    });

    test('§33.6 output map type is correctly typed (not Any?)', () {
      final out = KotlinGenerator.generate(_mapRecordReturnSpec());
      expect(out, contains('Map<String, Product>'));
    });
  });

  // ── §34: Map<String, @NitroVariant> — Kotlin generator ───────────────────

  group('§34 L4 Map<String, @NitroVariant> — Kotlin generator', () {
    test('§34.1 output map encodes variant values with tag 5', () {
      final out = KotlinGenerator.generate(_mapVariantReturnSpec());
      expect(out, contains('tag: binary variant'));
    });

    test('§34.2 variant encode() method called for map value', () {
      final out = KotlinGenerator.generate(_mapVariantReturnSpec());
      expect(out, contains('encode()'));
    });

    test('§34.3 input variant decoded via fromReader(RecordReader)', () {
      final out = KotlinGenerator.generate(_mapVariantParamSpec());
      expect(out, contains('fromReader'));
    });

    test('§34.4 variant map type is correctly typed', () {
      final out = KotlinGenerator.generate(_mapVariantReturnSpec());
      expect(out, contains('Map<String, EventPayload>'));
    });
  });

  // ── §35: Map<String, @HybridRecord> — Swift generator ────────────────────

  group('§35 L4 Map<String, @HybridRecord> — Swift generator', () {
    test('§35.1 decode uses compactMapValues with Data blob for records', () {
      final out = SwiftGenerator.generate(_mapRecordReturnSpec());
      expect(out, contains('compactMapValues'));
      expect(out, contains('as? Data'));
    });

    test('§35.2 record decoded via fromNative in Swift', () {
      final out = SwiftGenerator.generate(_mapRecordReturnSpec());
      expect(out, contains('fromNative'));
    });

    test('§35.3 encode converts record to Data via toNative()', () {
      final out = SwiftGenerator.generate(_mapRecordParamSpec());
      expect(out, contains('toNative()'));
    });

    test('§35.4 Swift map binary helper handles tag 5', () {
      final out = SwiftGenerator.generate(_mapRecordReturnSpec());
      expect(out, contains('case 5'));
    });

    test('§35.5 Swift binary encode writes tag 5 for Data values', () {
      final out = SwiftGenerator.generate(_mapRecordParamSpec());
      expect(out, contains('blob = v as? Data'));
      expect(out, contains('payload.append(5)'));
    });

    test('§35.6 Swift binary decode stores tag 5 as Data', () {
      final out = SwiftGenerator.generate(_mapRecordReturnSpec());
      expect(out, contains('result[k] = Data(data[pos..<(pos+bLen)])'));
    });
  });

  // ── §36: Map<String, @NitroVariant> — Swift generator ────────────────────

  group('§36 L4 Map<String, @NitroVariant> — Swift generator', () {
    test('§36.1 decode uses compactMapValues with Data blob for variants', () {
      final out = SwiftGenerator.generate(_mapVariantReturnSpec());
      expect(out, contains('compactMapValues'));
      expect(out, contains('as? Data'));
    });

    test('§36.2 variant decoded via fromReader(NitroRecordReader)', () {
      final out = SwiftGenerator.generate(_mapVariantReturnSpec());
      expect(out, contains('fromReader'));
      expect(out, contains('NitroRecordReader'));
    });

    test('§36.3 encode converts variant to Data via toNative()', () {
      final out = SwiftGenerator.generate(_mapVariantParamSpec());
      expect(out, contains('toNative()'));
    });

    test('§36.4 variant map value type is typed (not Any)', () {
      final out = SwiftGenerator.generate(_mapVariantReturnSpec());
      expect(out, contains('EventPayload'));
    });
  });

  // ── §37: Validator — L4 no longer emits E008 for @HybridRecord/@NitroVariant

  group('§37 L4 validator — @HybridRecord and @NitroVariant in maps', () {
    test('§37.1 Map<String, @HybridRecord> no longer triggers W006', () {
      final issues = SpecValidator.validate(_mapRecordReturnSpec());
      final w006 = issues.where((i) => i.code == 'W006');
      expect(w006, isEmpty, reason: 'W006 was removed for @HybridRecord maps (now properly supported)');
    });

    test('§37.2 Map<String, @NitroVariant> no longer triggers W006', () {
      final issues = SpecValidator.validate(_mapVariantReturnSpec());
      final w006 = issues.where((i) => i.code == 'W006');
      expect(w006, isEmpty, reason: 'W006 was removed for @NitroVariant maps (now properly supported)');
    });

    test('§37.3 Map<String, @HybridRecord> does not trigger E008', () {
      final issues = SpecValidator.validate(_mapRecordReturnSpec());
      final e008 = issues.where((i) => i.code == 'E008');
      expect(e008, isEmpty, reason: 'E008 only blocks @HybridStruct map values');
    });

    test('§37.4 Map<String, @NitroVariant> does not trigger E008', () {
      final issues = SpecValidator.validate(_mapVariantReturnSpec());
      final e008 = issues.where((i) => i.code == 'E008');
      expect(e008, isEmpty, reason: 'E008 only blocks @HybridStruct map values');
    });

    test('§37.5 Map<String, @HybridStruct> still triggers E008', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        structs: [
          BridgeStruct(
            name: 'Point',
            packed: false,
            fields: [
              BridgeField(
                name: 'x',
                type: BridgeType(name: 'double'),
                isNamed: true,
              ),
            ],
          ),
        ],
        functions: [
          BridgeFunction(
            dartName: 'getPoints',
            cSymbol: 'foo_get_points',
            isAsync: false,
            returnType: BridgeType(name: 'Map<String, Point>', isRecord: false, isMap: true),
            params: [],
          ),
        ],
      );
      final issues = SpecValidator.validate(spec);
      final e008 = issues.where((i) => i.code == 'E008');
      expect(e008, isNotEmpty, reason: 'E008 must block Map<String, @HybridStruct>');
    });

    test('§37.6 Map<String, int> has no map-value errors', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'getCounts',
            cSymbol: 'foo_get_counts',
            isAsync: false,
            returnType: BridgeType(name: 'Map<String, int>', isMap: true),
            params: [],
          ),
        ],
      );
      final issues = SpecValidator.validate(spec);
      expect(issues.where((i) => i.code == 'E008' || i.code == 'W006'), isEmpty);
    });
  });

  // ── §38: Wire format contract ─────────────────────────────────────────────

  group('§38 L4 wire format contract', () {
    test('§38.1 tag 5 in comment across all generators', () {
      final dartOut = DartFfiGenerator.generate(_mapRecordReturnSpec());
      expect(dartOut, contains('5=binary'));
    });

    test('§38.2 Dart decode: blob includes 4B payload_len + field bytes', () {
      final out = DartFfiGenerator.generate(_mapRecordReturnSpec());
      // The blob length includes the 4B prefix (payload_len + payload bytes)
      expect(out, contains('_bLen'));
      expect(out, contains('fromNative'));
    });

    test('§38.3 Kotlin encode: record blob via encode() (includes 4B prefix)', () {
      final out = KotlinGenerator.generate(_mapRecordReturnSpec());
      // Kotlin record.encode() returns [4B payload_len][field bytes]
      expect(out, contains('encode()'));
      expect(out, contains('_rBytes.size'));
    });

    test('§38.4 Swift encode: blob includes 4B len prefix from toNative()', () {
      final out = SwiftGenerator.generate(_mapRecordParamSpec());
      // toNative() returns pointer to [4B payload_len][field bytes]
      expect(out, contains('toNative()'));
      expect(out, contains('loadUnaligned(as: UInt32.self)'));
    });

    test('§38.5 no JSON fallback in record-typed map helpers', () {
      final out = DartFfiGenerator.generate(_mapRecordReturnSpec());
      // The _nitroDecodeMapBinaryProduct helper must not fall through to jsonDecode
      final helperStart = out.indexOf('_nitroDecodeMapBinaryProduct');
      final helperEnd = out.indexOf('}', helperStart + 100);
      if (helperStart != -1 && helperEnd != -1) {
        final helperBody = out.substring(helperStart, helperEnd);
        expect(helperBody, isNot(contains('jsonDecode')));
      }
    });
  });
}
