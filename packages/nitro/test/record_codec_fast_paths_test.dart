// The record codec's fast paths must be indistinguishable from the plain ones:
// the ASCII string decode from the UTF-8 decoder, and the whole-list writers
// from a loop of single writes.
import 'dart:math';

import 'package:nitro/nitro.dart';
import 'package:test/test.dart';

/// Decodes one string field written by [RecordWriter.writeString].
String _roundTrip(String s) {
  final w = RecordWriter()..writeString(s);
  final p = w.toNative(malloc);
  try {
    return RecordReader.fromNative(p).readString();
  } finally {
    malloc.free(p);
  }
}

void main() {
  group('readString', () {
    test('every length around the 8-byte scan, ASCII and not', () {
      for (var n = 0; n <= 40; n++) {
        final ascii = String.fromCharCodes(List.generate(n, (i) => 0x20 + (i * 7) % 95));
        expect(_roundTrip(ascii), ascii, reason: 'ascii, $n chars');
        // One non-ASCII character at each position: the scan must see it
        // whether it lands in a full word or in the tail.
        for (var at = 0; at < n; at++) {
          final mixed = '${ascii.substring(0, at)}é${ascii.substring(at + 1)}';
          expect(_roundTrip(mixed), mixed, reason: 'é at $at of $n');
        }
      }
    });

    test('a code unit above 0xFF is never mistaken for ASCII, wherever it sits', () {
      // The encoder packs eight units into one word; U+0100 has no bit 7 set
      // and would look like ASCII in a neighbouring byte if only the word were checked.
      for (final ch in ['\u0100', '\u017F', '\u4e00', '\u{1F600}']) {
        for (var n = 14; n <= 34; n++) {
          final ascii = 'abcdefghijklmnopqrstuvwxyz0123456789'.substring(0, n);
          for (var at = 0; at <= n; at++) {
            final s = '${ascii.substring(0, at)}$ch${ascii.substring(at)}';
            expect(_roundTrip(s), s, reason: '${ch.runes.first.toRadixString(16)} at $at of $n');
          }
        }
      }
    });

    test('the top of the ASCII range is ASCII; the byte after it is not', () {
      expect(_roundTrip('\x7f' * 17), '\x7f' * 17);
      expect(_roundTrip('\x80' * 17), '\x80' * 17);
      expect(_roundTrip('\xff' * 9), '\xff' * 9);
    });

    test('a leading U+FEFF is data, not a signature to drop', () {
      for (final s in ['\u{FEFF}', '\u{FEFF}text', '\u{FEFF}\u{FEFF}twice', 'mid\u{FEFF}dle', '\u{FEFF}日本語']) {
        expect(_roundTrip(s), s);
      }
    });

    test('random strings match dart:convert', () {
      final random = Random(7);
      for (var i = 0; i < 2000; i++) {
        final n = random.nextInt(64);
        // Mostly ASCII, with the occasional multi-byte or astral character.
        final s = String.fromCharCodes([
          for (var j = 0; j < n; j++)
            switch (random.nextInt(20)) {
              0 => 0x80 + random.nextInt(0x700),
              1 => 0x4e00 + random.nextInt(0x1000),
              2 => 0x1F600 + random.nextInt(60),
              _ => 0x20 + random.nextInt(95),
            },
        ]);
        expect(_roundTrip(s), utf8.decode(utf8.encode(s), allowMalformed: false), reason: s);
        expect(_roundTrip(s), s);
      }
    });
  });

  group('whole-list writers write what a loop of single writes does', () {
    Uint8List bytesOf(void Function(RecordWriter w) write) {
      final w = RecordWriter();
      write(w);
      return w.takeFramedBytes();
    }

    for (final n in [0, 1, 3, 31, 32, 33, 1000]) {
      test('$n items', () {
        final ints = List.generate(n, (i) => i.isEven ? i * 1000003 : -i * 4294967311);
        final doubles = List.generate(n, (i) => i == 3 ? double.nan : i / 7 - 1e9);
        final bools = List.generate(n, (i) => i % 3 == 0);
        expect(
          bytesOf((w) => w.writeIntList(ints)),
          bytesOf((w) {
            w.writeInt32(n);
            ints.forEach(w.writeInt);
          }),
        );
        expect(
          bytesOf((w) => w.writeDoubleList(doubles)),
          bytesOf((w) {
            w.writeInt32(n);
            doubles.forEach(w.writeDouble);
          }),
        );
        expect(
          bytesOf((w) => w.writeBoolList(bools)),
          bytesOf((w) {
            w.writeInt32(n);
            bools.forEach(w.writeBool);
          }),
        );
        // The whole-list readers return the same values, in order, and each
        // leaves the reader exactly past its list (the marker still reads).
        final r = RecordReaderBase.fromFramedBytes(
          bytesOf(
            (w) => w
              ..writeIntList(ints)
              ..writeBoolList(bools)
              ..writeDoubleList(doubles)
              ..writeInt(-77),
          ),
        );
        expect(r.readIntList(), ints);
        expect(r.readBoolList(), bools);
        expect(r.readDoubleList().map((d) => d.toString()), doubles.map((d) => d.toString())); // NaN != NaN
        expect(r.readInt(), -77);
      });
    }

    test('extreme ints and a list that grows the buffer mid-record', () {
      const extremes = [0, -1, 9223372036854775807, -9223372036854775808];
      final w = RecordWriter(8)
        ..writeString('before')
        ..writeIntList(extremes)
        ..writeDoubleList(List.filled(5000, 1.5))
        ..writeString('after');
      final r = RecordReaderBase.fromFramedBytes(w.takeFramedBytes());
      expect(r.readString(), 'before');
      // readIntList must leave the reader exactly past the list, and hand
      // back a list the caller can still grow.
      expect(r.readIntList()..add(7), [...extremes, 7]);
      expect(r.readDoubleList(), List.filled(5000, 1.5));
      expect(r.readString(), 'after');
    });
  });
}
