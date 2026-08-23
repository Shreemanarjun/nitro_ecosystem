// Edge cases for RecordWriterBase growth. RecordWriter's capacity argument is
// public, so a caller can hand it 0 — which used to spin forever in
// _ensureCapacity because `0 * 2` is still 0.
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
}
