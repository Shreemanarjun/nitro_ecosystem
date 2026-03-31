import 'dart:ffi';
import 'dart:typed_data';
import 'package:nitro/nitro.dart';
import 'package:test/test.dart';
import 'package:ffi/ffi.dart';

// A tiny record type for testing — mimics what the generator would produce.
class _Point {
  final int x;
  final int y;
  _Point(this.x, this.y);
  @override
  bool operator ==(Object other) =>
      other is _Point && other.x == x && other.y == y;
  @override
  int get hashCode => Object.hash(x, y);

  void writeFields(RecordWriter w) {
    w.writeInt(x);
    w.writeInt(y);
  }

  static _Point fromReader(RecordReader r) => _Point(r.readInt(), r.readInt());
}

// Allocates via malloc so that LazyRecordList's NativeFinalizer exclusively
// owns the buffer (no arena double-free conflict).
Pointer<Uint8> _encodePoints(List<_Point> items) =>
    RecordWriter.encodeIndexedList<_Point>(
      items,
      (w, e) => e.writeFields(w),
      malloc,
    );

void main() {
  group('RecordWriter.encodeIndexedList / LazyRecordList.decode', () {
    test('round-trips a simple list of records', () {
      final items = [_Point(1, 2), _Point(3, 4), _Point(5, 6)];
      final lazy = LazyRecordList.decode(_encodePoints(items), _Point.fromReader);
      expect(lazy.length, 3);
      expect(lazy[0], _Point(1, 2));
      expect(lazy[1], _Point(3, 4));
      expect(lazy[2], _Point(5, 6));
    });

    test('empty list encodes and decodes to empty LazyRecordList', () {
      final lazy = LazyRecordList.decode(_encodePoints([]), _Point.fromReader);
      expect(lazy.length, 0);
      expect(lazy.isEmpty, isTrue);
    });

    test('item access is lazy: first call decodes, second returns cache', () {
      final items = [_Point(10, 20), _Point(30, 40)];
      final lazy = LazyRecordList.decode(_encodePoints(items), _Point.fromReader);
      // Access index 1 before index 0 (random access should work).
      final item1 = lazy[1];
      expect(item1, _Point(30, 40));
      // Second access returns same (cached) object instance.
      expect(identical(lazy[1], item1), isTrue);
    });

    test('out-of-bounds access throws RangeError', () {
      final lazy = LazyRecordList.decode(_encodePoints([_Point(0, 0)]), _Point.fromReader);
      expect(() => lazy[1], throwsRangeError);
      expect(() => lazy[-1], throwsRangeError);
    });

    test('list iteration visits all items in order', () {
      final items = List.generate(10, (i) => _Point(i, i * 2));
      final lazy = LazyRecordList.decode(_encodePoints(items), _Point.fromReader);
      final decoded = lazy.toList();
      expect(decoded, items);
    });

    test('single-item list works correctly', () {
      final lazy = LazyRecordList.decode(_encodePoints([_Point(42, 99)]), _Point.fromReader);
      expect(lazy.length, 1);
      expect(lazy.first, _Point(42, 99));
    });

    test('random access order: accessing later items before earlier is correct', () {
      final items = [_Point(1, 1), _Point(2, 2), _Point(3, 3), _Point(4, 4)];
      final lazy = LazyRecordList.decode(_encodePoints(items), _Point.fromReader);
      // Access in reverse order — offset table allows O(1) jumps.
      expect(lazy[3], _Point(4, 4));
      expect(lazy[2], _Point(3, 3));
      expect(lazy[1], _Point(2, 2));
      expect(lazy[0], _Point(1, 1));
    });

    test('encodeIndexedPrimitiveList round-trips with decodePrimitiveList', () {
      final items = [10, 20, 30, 40, 50];
      final ptr = RecordWriter.encodeIndexedPrimitiveList<int>(
        items,
        (w, e) => w.writeInt(e),
        malloc,
      );
      // The indexed format is a superset: decoding with LazyRecordList works too.
      final lazy = LazyRecordList.decode(ptr, (r) => r.readInt());
      expect(lazy.toList(), items);
    });

    test('LazyRecordList is a readable List<T> (supports all ListBase ops)', () {
      final items = [_Point(1, 2), _Point(3, 4)];
      final lazy = LazyRecordList.decode(_encodePoints(items), _Point.fromReader);
      expect(lazy.contains(_Point(1, 2)), isTrue);
      expect(lazy.contains(_Point(99, 99)), isFalse);
      expect(lazy.map((p) => p.x).toList(), [1, 3]);
      expect(lazy.where((p) => p.x > 1).length, 1);
    });

    test('LazyRecordList operator []= throws UnsupportedError', () {
      final lazy = LazyRecordList.decode(_encodePoints([_Point(0, 0)]), _Point.fromReader);
      expect(() => lazy[0] = _Point(1, 1), throwsUnsupportedError);
    });

    test('setting length throws UnsupportedError', () {
      final lazy = LazyRecordList.decode(_encodePoints([_Point(0, 0)]), _Point.fromReader);
      expect(() => lazy.length = 0, throwsUnsupportedError);
    });

    test('wire format: payload starts with int32 count then int64 offsets', () {
      final items = [_Point(7, 8), _Point(9, 10)];
      final ptr = _encodePoints(items);
      // Validate the raw bytes of the payload (after the 4-byte outer length).
      final outerLen = ByteData.view(ptr.asTypedList(4).buffer)
          .getInt32(0, Endian.little);
      expect(outerLen, greaterThan(0));

      final payload = (ptr + 4).asTypedList(outerLen);
      final bd = ByteData.view(payload.buffer, payload.offsetInBytes);

      // count = 2
      final count = bd.getInt32(0, Endian.little);
      expect(count, 2);

      // offset[0]: after count(4) + 2*offset(16) = byte 20
      final off0 = bd.getInt64(4, Endian.little);
      expect(off0, 4 + 8 * 2); // 4 bytes count + 16 bytes offsets

      // offset[1]: off0 + size of one _Point (2 x int64 = 16 bytes)
      final off1 = bd.getInt64(12, Endian.little);
      expect(off1, off0 + 16);

      // Clean up (LazyRecordList.decode would take ownership, but we didn't decode here)
      malloc.free(ptr);
    });

    test('large list (100 items) decodes correctly and lazily', () {
      final items = List.generate(100, (i) => _Point(i, i + 1));
      final lazy = LazyRecordList.decode(_encodePoints(items), _Point.fromReader);
      expect(lazy.length, 100);
      // Spot-check random indices.
      expect(lazy[0], _Point(0, 1));
      expect(lazy[49], _Point(49, 50));
      expect(lazy[99], _Point(99, 100));
    });
  });

  group('RecordReader.fromPayloadOffset', () {
    test('positions reader at given byte offset within payload', () {
      // Write two ints sequentially; fromPayloadOffset should jump to the second.
      final w = RecordWriter();
      w.writeInt(111);
      w.writeInt(222);
      final ptr = w.toNative(malloc);
      // offset 0 → reads 111
      expect(RecordReader.fromPayloadOffset(ptr, 0).readInt(), 111);
      // offset 8 → reads 222
      expect(RecordReader.fromPayloadOffset(ptr, 8).readInt(), 222);
      malloc.free(ptr);
    });

    test('throws StateError on null pointer', () {
      expect(
        () => RecordReader.fromPayloadOffset(Pointer.fromAddress(0), 0),
        throwsStateError,
      );
    });
  });
}
