// A reader that owns its buffer hands one large typed-data field out as a view
// of that buffer instead of copying it; everything else still copies.
//
// The buffer is given to the list through an `adopt` function. Generated code
// binds the module's native `<lib>_nitro_adopt`; here a stand-in records what
// it was given. The native half (freed by the collector, valid across
// Isolate.run) is checked against a real compiled bridge by
// nitro_generator/tool/verify_record_lend.dart.
import 'dart:isolate';

import 'package:nitro/nitro.dart';
import 'package:test/test.dart';

/// `{int tag, Uint8List a, Uint8List b}` framed in malloc'd memory, as a
/// native bridge returns it.
Pointer<Uint8> _record(Uint8List a, Uint8List b) {
  final w = RecordWriter();
  w.writeInt(7);
  w.writeBlob(a);
  w.writeBlob(b);
  return w.toNative(malloc);
}

/// What the reader handed over: buffer address -> the list that now owns it.
final _adopted = <int, Object>{};
void _adopt(Object list, Pointer<Void> token, int size) => _adopted[token.address] = list;

Uint8List _bytes(int n, int seed) => Uint8List.fromList(List.generate(n, (i) => (i * 31 + seed) & 0xff));

void main() {
  final big = RecordReader.lendMinBytes;

  // The stand-in never frees, so do it here.
  tearDown(() {
    for (final address in _adopted.keys) {
      malloc.free(Pointer<Void>.fromAddress(address));
    }
    _adopted.clear();
  });

  test('a large byte field is a view of the record buffer, not a copy', () {
    final a = _bytes(big, 1);
    final p = _record(a, Uint8List(0));
    final r = RecordReader.fromNative(p, adopt: _adopt);
    expect(r.readInt(), 7);
    final got = r.readBlobView();
    expect(got, a);
    expect(got.buffer.lengthInBytes, big, reason: 'the list is exactly the field, not a window into the record');
    // It aliases the native block: 4B frame + 8B int + 4B length, then the bytes.
    (p + 16).value = 0xEE;
    expect(got[0], 0xEE);
    expect(r.readBlobView(), isEmpty);
    // The list owns the block now, so the decoder must not free it.
    expect(_adopted[p.address], same(got));
    expect(RecordReader.keptAlive(p), isTrue);
    expect(RecordReader.keptAlive(p), isFalse, reason: 'asked once per buffer');
  });

  test('small fields are copied and the caller still frees', () {
    final a = _bytes(big - 1, 2);
    final p = _record(a, _bytes(10, 3));
    final r = RecordReader.fromNative(p, adopt: _adopt)..readInt();
    final got = r.readBlobView();
    (p + 16).value = a[0] ^ 0xFF;
    expect(got[0], a[0], reason: 'a copy does not see later writes');
    expect(r.readBlobView(), _bytes(10, 3));
    expect(RecordReader.keptAlive(p), isFalse);
    malloc.free(p);
  });

  test('only the first large field is lent; the next one is copied', () {
    final a = _bytes(big, 4), b = _bytes(big + 5, 5);
    final p = _record(a, b);
    final r = RecordReader.fromNative(p, adopt: _adopt)..readInt();
    final first = r.readBlobView(), second = r.readBlobView();
    expect(first, a);
    expect(second, b);
    (p + 16 + big + 4).value = b[0] ^ 0xFF; // first byte of the second field
    expect(second[0], b[0]);
    expect(RecordReader.keptAlive(p), isTrue);
  });

  test('a reader that does not own the buffer never lends', () {
    final a = _bytes(big * 2, 6);
    final p = _record(a, Uint8List(0));
    final r = RecordReader.fromNative(p)..readInt();
    final got = r.readBlobView();
    (p + 16).value = a[0] ^ 0xFF;
    expect(got[0], a[0]);
    expect(RecordReader.keptAlive(p), isFalse);
    // readBlob keeps copying even for an owning reader.
    final owning = RecordReader.fromNative(p, adopt: _adopt)..readInt();
    expect(owning.readBlob().length, a.length);
    expect(RecordReader.keptAlive(p), isFalse);
    malloc.free(p);
  });

  test('a length that runs past the payload is not lent', () {
    final p = _record(_bytes(big, 7), Uint8List(0));
    (p + 12).cast<Int32>().value = big + 1000; // corrupt the field length
    final r = RecordReader.fromNative(p, adopt: _adopt)..readInt();
    expect(r.readBlobView, throwsRangeError);
    expect(RecordReader.keptAlive(p), isFalse);
    malloc.free(p);
  });

  test('a lent field sent through a port arrives as a copy', () async {
    final a = _bytes(big * 4, 8);
    final inbox = ReceivePort();
    await Isolate.spawn((SendPort out) {
      final p = _record(_bytes(big * 4, 8), Uint8List(0));
      final r = RecordReader.fromNative(p, adopt: _adopt)..readInt();
      final body = r.readBlobView();
      out.send(body); // copied here
      if (RecordReader.keptAlive(p)) _adopted.clear();
      malloc.free(p);
    }, inbox.sendPort);
    expect(await inbox.first, a);
  });

  test('wider typed lists are lent too, on an aligned address, whatever precedes them', () {
    final values = Float64List.fromList(List.generate(big ~/ 8 + 3, (i) => i * 1.5 - 7));
    final blob = values.buffer.asUint8List();
    // 0..8 one-byte fields before the list put it on every possible alignment.
    for (var lead = 0; lead <= 8; lead++) {
      final w = RecordWriter();
      for (var i = 0; i < lead; i++) {
        w.writeBool(i.isEven);
      }
      w.writeBlob(blob);
      w.writeInt(424242);
      w.writeString('after');
      final p = w.toNative(malloc);
      final r = RecordReader.fromNative(p, adopt: _adopt);
      for (var i = 0; i < lead; i++) {
        expect(r.readBool(), i.isEven);
      }
      final got = Float64List.view(r.readBlobView(8).buffer);
      expect(got, values, reason: '$lead leading bytes');
      expect(got.offsetInBytes, 0);
      // What follows the list is untouched by the in-place alignment.
      expect(r.readInt(), 424242);
      expect(r.readString(), 'after');
      expect(RecordReader.keptAlive(p), isTrue, reason: '$lead leading bytes');
    }
  });

  test('16- and 32-bit lists round-trip through a lent buffer', () {
    final i16 = Int16List.fromList(List.generate(big, (i) => (i * 7) - 20000));
    final u32 = Uint32List.fromList(List.generate(big, (i) => i * 2654435761 & 0xffffffff));
    for (final (bytes, size) in [(i16.buffer.asUint8List(), 2), (u32.buffer.asUint8List(), 4)]) {
      for (var lead = 0; lead < 4; lead++) {
        final w = RecordWriter();
        for (var i = 0; i < lead; i++) {
          w.writeBool(true);
        }
        w.writeBlob(bytes);
        final p = w.toNative(malloc);
        final r = RecordReader.fromNative(p, adopt: _adopt);
        for (var i = 0; i < lead; i++) {
          r.readBool();
        }
        final lent = r.readBlobView(size);
        expect(size == 2 ? Int16List.view(lent.buffer) : Uint32List.view(lent.buffer), size == 2 ? i16 : u32);
        expect(RecordReader.keptAlive(p), isTrue);
      }
    }
  });

  test('a reader that does not own the buffer copies wider lists as before', () {
    final values = Float32List.fromList(List.generate(big, (i) => i / 3));
    final w = RecordWriter()
      ..writeBool(true)
      ..writeBlob(values.buffer.asUint8List());
    final p = w.toNative(malloc);
    final r = RecordReader.fromNative(p)..readBool();
    expect(Float32List.view(r.readBlobView(4).buffer), values);
    expect(RecordReader.keptAlive(p), isFalse);
    malloc.free(p);
  });
}
