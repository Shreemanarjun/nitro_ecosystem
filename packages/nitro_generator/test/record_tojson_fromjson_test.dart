// Tests for #2: toJson()/fromJson() in generated Kotlin @HybridRecord data classes.
// Enables Map<String, @HybridRecord> bridging via JSON in Kotlin.

import 'package:nitro_generator/src/generators/record_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

BridgeSpec _simpleRecordSpec() => BridgeSpec(
  dartClassName: 'Foo',
  lib: 'foo',
  namespace: 'foo',
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'foo.native.dart',
  recordTypes: [
    BridgeRecordType(
      name: 'TcConfig',
      fields: [
        BridgeRecordField(
          name: 'name',
          dartType: 'String',
          kind: RecordFieldKind.primitive,
        ),
        BridgeRecordField(
          name: 'count',
          dartType: 'int',
          kind: RecordFieldKind.primitive,
        ),
        BridgeRecordField(
          name: 'enabled',
          dartType: 'bool',
          kind: RecordFieldKind.primitive,
        ),
        BridgeRecordField(
          name: 'threshold',
          dartType: 'double',
          kind: RecordFieldKind.primitive,
        ),
      ],
    ),
  ],
);

void main() {
  group('RecordGenerator — Kotlin toJson/fromJson (#2)', () {
    test('generates toJson() method', () {
      final out = RecordGenerator.generateKotlin(_simpleRecordSpec());
      expect(out, contains('fun toJson(): Map<String, Any?>'));
    });

    test('toJson() contains all field names', () {
      final out = RecordGenerator.generateKotlin(_simpleRecordSpec());
      expect(out, contains('"name" to name'));
      expect(out, contains('"count" to count'));
      expect(out, contains('"enabled" to enabled'));
      expect(out, contains('"threshold" to threshold'));
    });

    test('generates fromJson() method in companion object', () {
      final out = RecordGenerator.generateKotlin(_simpleRecordSpec());
      expect(out, contains('fun fromJson(map: Map<String, Any?>): TcConfig'));
    });

    test('fromJson() uses @JvmStatic', () {
      final out = RecordGenerator.generateKotlin(_simpleRecordSpec());
      expect(out, contains('@JvmStatic fun fromJson'));
    });

    test('fromJson() handles int field via toLong()', () {
      final out = RecordGenerator.generateKotlin(_simpleRecordSpec());
      expect(out, contains('as Number).toLong()'));
    });

    test('fromJson() handles double field via toDouble()', () {
      final out = RecordGenerator.generateKotlin(_simpleRecordSpec());
      expect(out, contains('as Number).toDouble()'));
    });

    test('fromJson() handles String field', () {
      final out = RecordGenerator.generateKotlin(_simpleRecordSpec());
      expect(out, contains('as String'));
    });

    test('fromJson() handles bool field', () {
      final out = RecordGenerator.generateKotlin(_simpleRecordSpec());
      expect(out, contains('as Boolean'));
    });

    test('companion object still has decodeFrom()', () {
      final out = RecordGenerator.generateKotlin(_simpleRecordSpec());
      expect(out, contains('fun decodeFrom(buf: java.nio.ByteBuffer): TcConfig'));
    });

    test('companion object still has decode()', () {
      final out = RecordGenerator.generateKotlin(_simpleRecordSpec());
      expect(out, contains('fun decode(bytes: ByteArray): TcConfig'));
    });

    test('encode() method still present', () {
      final out = RecordGenerator.generateKotlin(_simpleRecordSpec());
      expect(out, contains('fun encode(): ByteArray'));
    });
  });
}
