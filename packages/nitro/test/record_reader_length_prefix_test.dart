// A `Pointer<Uint8>` carries no length, so RecordReader trusted the 4-byte
// prefix and handed it straight to asTypedList(). A corrupt or stale buffer —
// a use-after-free, a partially written record, a hostile payload — produced a
// view stretching past the allocation, and every subsequent read silently
// returned whatever memory followed it.

import 'package:nitro/nitro.dart';
import 'package:test/test.dart';

/// Allocates a buffer whose 4-byte prefix claims [declaredLen] bytes but which
/// really only holds [actualPayload] bytes.
Pointer<Uint8> _bufferClaiming(int declaredLen, {int actualPayload = 8}) {
  final ptr = calloc<Uint8>(4 + actualPayload);
  ptr.asTypedList(4).buffer.asByteData().setInt32(0, declaredLen, Endian.little);
  return ptr;
}

void main() {
  test('a negative length prefix is rejected, not turned into a view', () {
    final ptr = _bufferClaiming(-1);
    addTearDown(() => calloc.free(ptr));
    expect(
      () => RecordReader.fromNative(ptr),
      throwsA(isA<StateError>().having((e) => e.message, 'message', contains('negative length prefix'))),
    );
  });

  test('an absurd length prefix is rejected', () {
    final ptr = _bufferClaiming(RecordReader.maxPayloadBytes + 1);
    addTearDown(() => calloc.free(ptr));
    expect(
      () => RecordReader.fromNative(ptr),
      throwsA(isA<StateError>().having((e) => e.message, 'message', contains('exceeds'))),
    );
  });

  test('a null pointer is still rejected first', () {
    expect(() => RecordReader.fromNative(nullptr), throwsA(isA<StateError>()));
  });

  test('a legitimate prefix still works', () {
    final w = RecordWriter()..writeInt(7)..writeString('ok');
    final bytes = w.takeFramedBytes();
    final ptr = calloc<Uint8>(bytes.length);
    ptr.asTypedList(bytes.length).setAll(0, bytes);
    addTearDown(() => calloc.free(ptr));

    final r = RecordReader.fromNative(ptr);
    expect(r.readInt(), 7);
    expect(r.readString(), 'ok');
  });

  test('zero-length payload is valid, not treated as corrupt', () {
    final ptr = _bufferClaiming(0);
    addTearDown(() => calloc.free(ptr));
    expect(() => RecordReader.fromNative(ptr), returnsNormally);
  });

  test('the boundary value itself is accepted', () {
    // maxPayloadBytes is the largest LEGAL prefix; only above it throws.
    expect(() => RecordReader.checkPayloadLength(RecordReader.maxPayloadBytes, 'probe'), returnsNormally);
    expect(() => RecordReader.checkPayloadLength(RecordReader.maxPayloadBytes + 1, 'probe'), throwsA(isA<StateError>()));
    expect(() => RecordReader.checkPayloadLength(0, 'probe'), returnsNormally);
    expect(() => RecordReader.checkPayloadLength(-1, 'probe'), throwsA(isA<StateError>()));
  });
}
