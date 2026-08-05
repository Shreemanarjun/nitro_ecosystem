// Round-trips a List<record> through RecordWriter.encodeIndexedList and
// LazyRecordList.fromNative, verifying the offset table and item bytes are
// correct. Guards the single-writer + backpatched-offset-table encode
// (perf-audit "#1"): a wrong backpatch would make LazyRecordList jump to the
// wrong payload offset and decode garbage.
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:nitro/src/record_codec.dart';
import 'package:test/test.dart';
// ignore_for_file: library_private_types_in_public_api

typedef _Row = (int id, String name, double score);

Pointer<Uint8> encodeRows(List<_Row> rows) => RecordWriter.encodeIndexedList<_Row>(
  rows,
  (w, r) {
    w.writeInt(r.$1);
    w.writeString(r.$2);
    w.writeDouble(r.$3);
  },
  calloc,
);

LazyRecordList<_Row> decodeRows(Pointer<Uint8> ptr) => LazyRecordList.decode<_Row>(
  ptr,
  (r) => (r.readInt(), r.readString(), r.readDouble()),
  nativeFree: null,
);

void roundTrip(List<_Row> rows) {
  final ptr = encodeRows(rows);
  final list = decodeRows(ptr);
  expect(list.length, rows.length);
  for (var i = 0; i < rows.length; i++) {
    expect(list[i].$1, rows[i].$1, reason: 'row $i id');
    expect(list[i].$2, rows[i].$2, reason: 'row $i name');
    expect(list[i].$3, closeTo(rows[i].$3, 1e-9), reason: 'row $i score');
  }
}

void main() {
  group('encodeIndexedList round-trip (perf-audit #1)', () {
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
      final rows = [
        for (var i = 0; i < 16; i++) (i, 'row_$i', i * 1.5),
      ];
      roundTrip(rows);
    });

    test('random access hits correct offsets (not sequential)', () {
      final rows = [
        for (var i = 0; i < 10; i++) (i * 7, 'item-$i-${'z' * i}', i.toDouble()),
      ];
      final list = decodeRows(encodeRows(rows));
      // Read out of order — each must resolve via its own offset-table entry.
      for (final i in [9, 0, 5, 2, 7, 1, 8, 3, 6, 4]) {
        expect(list[i].$1, rows[i].$1);
        expect(list[i].$2, rows[i].$2);
      }
        });

    test('unicode + multi-byte strings survive', () {
      roundTrip(const [
        (1, 'café', 1.0),
        (2, '日本語', 2.0),
        (3, '🚀 emoji', 3.0),
      ]);
    });
  });
}
