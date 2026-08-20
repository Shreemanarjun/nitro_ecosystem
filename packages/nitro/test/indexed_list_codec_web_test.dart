// Round-trips a List<record> through the WEB codec pair —
// RecordWriter.encodeIndexedListBytes → RecordReader.decodeIndexedListBytes.
//
// The web edge copies framed bytes in and out of the WASM heap rather than
// handing over a pointer, so it has its own encode/decode pair. That pair was
// briefly mismatched: the generated bridge encoded arguments PLAIN while
// decoding returns INDEXED, so the receiver read item bytes as an offset
// table. dart2js threw a RangeError; dart2wasm silently decoded garbage
// because the bogus offsets were multiples of 2^32 and wrapped to 0 under i32
// indexing. Nothing in this package caught it — the pointer-edge twin is
// covered by indexed_list_codec_test.dart, and the parity test only compares
// the WRITER against native bytes, never the web pair against itself.
//
// These records deliberately carry variable-length strings. A fixed-size
// record can mask an offset-table bug whose stride happens to stay uniform.
import 'dart:typed_data';

import 'package:nitro/src/shared/nitro_bytes.dart';
import 'package:nitro/src/web/record_codec_web.dart';
import 'package:test/test.dart';

typedef _Row = (int id, String name, double score);

Uint8List encodeRows(List<_Row> rows) => RecordWriter.encodeIndexedListBytes<_Row>(
  rows,
  (w, r) {
    w.writeInt(r.$1);
    w.writeString(r.$2);
    w.writeDouble(r.$3);
  },
);

List<_Row> decodeRows(Uint8List framed) => RecordReader.decodeIndexedListBytes<_Row>(
  framed,
  (r) => (r.readInt(), r.readString(), r.readDouble()),
);

void roundTrip(List<_Row> rows) {
  final decoded = decodeRows(encodeRows(rows));
  expect(decoded.length, rows.length);
  for (var i = 0; i < rows.length; i++) {
    expect(decoded[i].$1, rows[i].$1, reason: 'row $i id');
    expect(decoded[i].$2, rows[i].$2, reason: 'row $i name');
    expect(decoded[i].$3, closeTo(rows[i].$3, 1e-9), reason: 'row $i score');
  }
}

void main() {
  group('web encodeIndexedListBytes ↔ decodeIndexedListBytes', () {
    test('empty list', () {
      roundTrip(const []);
    });

    test('single item', () {
      roundTrip(const [(42, 'hello', 3.5)]);
    });

    test('multiple items, varying string lengths', () {
      roundTrip([
        (1, '', 1.0),
        (2, 'a', 2.0),
        (3, 'longer string here', 3.0),
        (4, 'x' * 300, 4.0), // forces the writer to grow mid-list
      ]);
    });

    test('16-item list decodes every item at the right offset', () {
      roundTrip([for (var i = 0; i < 16; i++) (i, 'row_$i', i * 1.5)]);
    });

    test('each item lands at its own offset, not a uniform stride', () {
      // Strings grow per item, so a decoder that walks a fixed stride — or
      // ignores the offset table and reads sequentially — desynchronises.
      roundTrip([for (var i = 0; i < 10; i++) (i * 7, 'item-$i-${'z' * i}', i.toDouble())]);
    });

    test('unicode + multi-byte strings survive', () {
      roundTrip(const [
        (1, 'héllo wörld', 1.0),
        (2, '日本語テキスト', 2.0),
        (3, '👋🏽 emoji', 3.0),
      ]);
    });

    test('large list stays consistent', () {
      roundTrip([for (var i = 0; i < 500; i++) (i, 'n$i', i / 3)]);
    });
  });

  group('web indexed wire shape', () {
    test('payload is [4B count][8B x n offsets][items] and offsets ascend', () {
      final rows = [for (var i = 0; i < 4; i++) (i, 'name-${'q' * i}', i.toDouble())];
      final framed = encodeRows(rows);

      final bd = ByteData.sublistView(framed);
      expect(bd.getInt32(0, Endian.little), framed.length - 4, reason: 'frame header');

      final count = bd.getInt32(4, Endian.little);
      expect(count, 4);

      // Offsets are payload-relative and strictly increasing; the first item
      // begins immediately after the offset table.
      var previous = 0;
      for (var i = 0; i < count; i++) {
        // getInt64LE, not ByteData.getInt64 — the latter throws on dart2js,
        // which is half of what this file exists to cover.
        final off = getInt64LE(bd, 4 + 4 + i * 8);
        expect(off, greaterThanOrEqualTo(4 + count * 8), reason: 'offset $i past table');
        expect(off, greaterThan(previous), reason: 'offset $i ascends');
        expect(off, lessThan(framed.length - 4), reason: 'offset $i inside payload');
        previous = off;
      }
    });

    test('a PLAIN-encoded list never round-trips through the INDEXED reader', () {
      // The exact shape of the bug: encode without the offset table, decode
      // expecting one. Whether that throws is data-dependent — the original
      // bug threw on dart2js but decoded silent garbage on dart2wasm, because
      // those particular offsets were multiples of 2^32 and wrapped to 0 under
      // i32 indexing. So assert the invariant that holds either way: the
      // mismatched pair must not reproduce the input.
      final rows = [for (var i = 0; i < 16; i++) (i, 'row_$i', i * 1.5)];
      final plain = RecordWriter.encodeListBytes<_Row>(rows, (w, r) {
        w.writeInt(r.$1);
        w.writeString(r.$2);
        w.writeDouble(r.$3);
      });

      List<_Row>? decoded;
      try {
        decoded = decodeRows(plain);
      } catch (_) {
        return; // threw — the mismatch was caught loudly, which is fine
      }
      expect(decoded, isNot(equals(rows)),
          reason: 'plain bytes decoded as indexed must not yield the original');
    });
  });
}
