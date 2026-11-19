// Edge cases for RecordWriterBase growth. RecordWriter's capacity argument is
// public, so a caller can hand it 0 — which used to spin forever in
// _ensureCapacity because `0 * 2` is still 0.
import 'dart:typed_data';

import 'package:nitro/src/record_codec.dart';
import 'package:test/test.dart';

void main() {
  test('a zero-capacity writer still grows (was an infinite loop)', () {
    final w = RecordWriter(0);
    w.writeInt(42);
    final bytes = w.takeFramedBytes();
    expect(bytes, isNotEmpty);
  }, timeout: const Timeout(Duration(seconds: 5)));

  test('capacity 1 grows past a single doubling', () {
    final w = RecordWriter(1);
    w.writeString('a longer string than one byte');
    expect(w.takeFramedBytes(), isNotEmpty);
  }, timeout: const Timeout(Duration(seconds: 5)));

  test('one write larger than any doubling of the initial capacity', () {
    final w = RecordWriter(2);
    w.writeString('x' * 10000);
    expect(w.takeFramedBytes().length, greaterThan(10000));
  }, timeout: const Timeout(Duration(seconds: 5)));

  test('the default-capacity path is unchanged', () {
    final w = RecordWriter();
    w.writeInt(1);
    w.writeString('x');
    expect(w.takeFramedBytes(), isNotEmpty);
  });

  test('the shared scratch writer does not keep a very large payload\'s buffer', () {
    // It lives as long as the isolate; one 8 MiB record must not pin 8 MiB.
    final big = RecordWriter.acquire()..writeBlob(Uint8List(8 << 20));
    expect(big.payloadView().lengthInBytes, greaterThan(8 << 20));
    RecordWriter.release(big);
    final next = RecordWriter.acquire()..writeInt(1);
    expect(next.payloadView().buffer.lengthInBytes, lessThan(1 << 20));
    RecordWriter.release(next);

    // A payload under the limit keeps its buffer, so steady traffic does not regrow.
    final medium = RecordWriter.acquire()..writeBlob(Uint8List(1 << 20));
    RecordWriter.release(medium);
    final after = RecordWriter.acquire()..writeInt(1);
    expect(after.payloadView().buffer.lengthInBytes, greaterThan(1 << 20));
    RecordWriter.release(after);
  });
}
