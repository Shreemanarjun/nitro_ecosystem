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

    test('§31.3 decode helper reads 4B blob_len and decodes the record in place', () {
      final out = DartFfiGenerator.generate(_mapRecordReturnSpec());
      expect(out, contains('final _bLen = bd.getInt32(pos, Endian.little); pos += 4;'));
      // The blob is a framed record inside the map's buffer: no copy per entry.
      expect(out, contains('.fromNative(ptr + 4 + pos); pos += _bLen;'));
    });

    test('§31.4 decode helper neither copies the payload nor allocates per entry', () {
      final out = DartFfiGenerator.generate(_mapRecordReturnSpec());
      expect(out, contains('final bytes = (ptr + 4).asTypedList(payLen);'));
      expect(out, isNot(contains('_bPtr')));
      expect(out, isNot(contains('bd.buffer')));
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

    test('§32.3 decode helper decodes the variant in place', () {
      final out = DartFfiGenerator.generate(_mapVariantReturnSpec());
      expect(out, contains('.fromNative(ptr + 4 + pos); pos += _bLen;'));
      expect(out, isNot(contains('_bPtr')));
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
      expect(out, contains('nitroEncodeMap(_result, 5) { o, v ->'));
    });

    test('§33.2 record encode() method called for map value', () {
      final out = KotlinGenerator.generate(_mapRecordReturnSpec());
      expect(out, contains('encode()'));
    });

    test('§33.3 blob length written before blob bytes', () {
      final out = KotlinGenerator.generate(_mapRecordReturnSpec());
      expect(out, contains('val b = v.encode(); o.putInt32(b.size); o.write(b, 0, b.size)'));
    });

    test('§33.4 input record decoded via decodeFrom(ByteBuffer)', () {
      final out = KotlinGenerator.generate(_mapRecordParamSpec());
      expect(out, contains('decodeFrom'));
    });

    test('§33.5 input skips the blob length and the record\'s own prefix before decodeFrom', () {
      final out = KotlinGenerator.generate(_mapRecordParamSpec());
      expect(out, contains('nitroDecodeMap(products) { r -> r.p++; r.blob { Product.decodeFrom(it) } }'));
      // blob(): past `[4B blobLen][4B len]`, and on to the blob's end afterwards.
      expect(out, contains('val n = int32(); val end = p + n'));
      expect(out, contains('p = end'));
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
      expect(out, contains('nitroEncodeMap(_result, 5) { o, v ->'));
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
    test('§35.1 decode reads records straight into [String: Product]', () {
      final out = SwiftGenerator.generate(_mapRecordParamSpec());
      expect(out, contains('let productsMap: [String: Product] = products.map { _nitroDecodeMap(\$0) { r in r.pos += 8; return Product.fromReader(r) } } ?? [:]'));
      expect(out, isNot(contains('compactMapValues')));
      expect(out, isNot(contains('as? Data')));
    });

    test('§35.2 record decoded via fromNative in Swift', () {
      final out = SwiftGenerator.generate(_mapRecordReturnSpec());
      expect(out, contains('fromNative'));
    });

    test('§35.3 encode converts record to Data via toNative()', () {
      final out = SwiftGenerator.generate(_mapRecordParamSpec());
      expect(out, contains('toNative()'));
    });

    test('§35.4 Swift encode writes a record under tag 5, framed in place', () {
      final out = SwiftGenerator.generate(_mapRecordReturnSpec());
      expect(out, contains('_nitroEncodeMap(result, 5) { w, v in w.writeFramed { v.writeFields(\$0) } }'));
    });

    test('§35.5 writeFramed patches both lengths: the blob\'s and the record\'s own', () {
      final out = SwiftGenerator.generate(_mapRecordReturnSpec());
      expect(out, contains('var inner = Int32(count - at - 8).littleEndian'));
      expect(out, contains('var outer = Int32(count - at - 4).littleEndian'));
    });

    test('§35.6 the helpers are generic: no [String: Any] and no Data per value', () {
      final out = SwiftGenerator.generate(_mapRecordReturnSpec());
      expect(out, contains('private func _nitroEncodeMap<V>(_ map: [String: V], _ tag: UInt8, _ write: (NitroRecordWriter, V) -> Void)'));
      expect(out, isNot(contains('_nitroEncodeMapBinary')));
      expect(out, isNot(contains('_nitroDecodeMapBinary')));
    });
  });

  // ── §36: Map<String, @NitroVariant> — Swift generator ────────────────────

  group('§36 L4 Map<String, @NitroVariant> — Swift generator', () {
    test('§36.1 decode reads variants straight into [String: EventPayload]', () {
      final out = SwiftGenerator.generate(_mapVariantParamSpec());
      expect(out, contains('{ r in r.pos += 8; return EventPayload.fromReader(r) }'));
      expect(out, isNot(contains('compactMapValues')));
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

    test('§37.5 Map<String, @HybridStruct> is E008 only when the struct is not flat', () {
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
      // One double field: every backend can carry it as bytes.
      expect(SpecValidator.validate(spec).where((i) => i.code == 'E008'), isEmpty);
      expect(spec.isFlatStruct('Point'), isTrue);
      expect(spec.mapValueStructs, {'Point'});
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
      expect(out, contains('val b = v.encode(); o.putInt32(b.size)'));
    });

    test('§38.4 Swift encode: the blob carries the record\'s own 4B length', () {
      final out = SwiftGenerator.generate(_mapRecordReturnSpec());
      // writeFramed reserves `[4B blobLen][4B len]`, then the fields.
      expect(out, contains('w.writeFramed { v.writeFields(\$0) }'));
      expect(out, contains('_ = room(8)'));
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
