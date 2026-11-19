// Nullable record fields in the Kotlin codec. Both forms below once produced
// Kotlin that did not compile; tool/verify_record_wire.dart compiles and runs
// the real thing, this pins the text.
import 'package:nitro_generator/src/generators/record_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

BridgeRecordField _f(String name, String type, RecordFieldKind kind, [String? item]) =>
    BridgeRecordField(name: name, dartType: type, kind: kind, itemTypeName: item, isNullable: true);

void main() {
  final kotlin = RecordGenerator.generateKotlin(
    BridgeSpec(
      dartClassName: 'M',
      lib: 'm',
      namespace: 'm',
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'm.native.dart',
      recordTypes: [
        BridgeRecordType(name: 'Item', fields: [BridgeRecordField(name: 'id', dartType: 'int', kind: RecordFieldKind.primitive)]),
        BridgeRecordType(
          name: 'Opt',
          fields: [
            _f('s', 'String?', RecordFieldKind.primitive),
            _f('bytes', 'Uint8List?', RecordFieldKind.typedData),
            _f('floats', 'Float32List?', RecordFieldKind.typedData),
            _f('ints', 'List<int>?', RecordFieldKind.listPrimitive, 'int'),
            _f('items', 'List<Item>?', RecordFieldKind.listRecordObject, 'Item'),
          ],
        ),
      ],
    ),
  );

  test('a block read after the null check is `run { }`, never `{ }()`', () {
    // After `else`, `{ ... }` is a block: calling its value is a compile error.
    expect(kotlin, contains('val s = (if (r.byte() == 0) null else r.string())'));
    expect(kotlin, contains('val bytes = (if (r.byte() == 0) null else r.bytes())'));
    expect(kotlin, contains('val floats = (if (r.byte() == 0) null else run { val _len = r.int32();'));
    expect(kotlin, isNot(contains('}()')));
  });

  test('a nullable list field is declared nullable', () {
    // The decode yields List<T>?; a non-null declaration did not accept it.
    expect(kotlin, contains('val ints: List<Long>?'));
    expect(kotlin, contains('val items: List<Item>?'));
  });

  test('encode() writes into a stream the record fills directly', () {
    // One top-level class per generated file (each file has its own package).
    expect('class NitroRecordOut(size: Int) : java.io.ByteArrayOutputStream(size) {'.allMatches(kotlin), hasLength(1));
    expect(kotlin, contains('val _tlsOut = ThreadLocal.withInitial { NitroRecordOut('));
    // The contract other emitters call is unchanged; a plain stream still works.
    expect(kotlin, contains('fun writeFieldsTo(out: java.io.ByteArrayOutputStream, buf: java.nio.ByteBuffer) {'));
    expect(kotlin, contains('val fast = out as? NitroRecordOut'));
    expect(kotlin, contains('fun writeInt(v: Long) { if (fast != null) fast.putInt64(v) else { buf.clear(); buf.putLong(v); out.write(buf.array()) } }'));
  });

  test('strings and primitive lists go through the stream\'s whole-value writers', () {
    expect(kotlin, contains('fun writeString(v: String) { if (fast != null) fast.putString(v) else {'));
    expect(kotlin, contains('fun putInt64s(v: List<Long>)'));
    // A decoded list is written back from its array, not item by item.
    expect(kotlin, contains('if (v is NitroLongList) {'));
    // ASCII is decoded as Latin-1 (faster on ART); anything else as UTF-8.
    expect(kotlin, contains('if (i == to) Charsets.ISO_8859_1 else Charsets.UTF_8'));
  });

  test('primitive lists are read into an array and exposed as a List', () {
    expect(kotlin, contains('val _a = LongArray(r.int32()); r.take(_a.size * 8).asLongBuffer().get(_a); NitroLongList(_a)'));
  });
}
