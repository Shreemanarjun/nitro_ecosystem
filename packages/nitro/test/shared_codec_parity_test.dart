// The 0.7.0 web split moved the record wire format into a shared core used by
// BOTH the native (pointer) and web (framed bytes) edges. These tests pin the
// properties that keep the two edges interchangeable:
//   1. the portable int64 helpers match ByteData's native accessors bit-for-bit
//   2. takeFramedBytes() is byte-identical to what toNative() writes
//   3. the NitroWireCodec byte layouts equal the @Packed(1) NitroOpt* structs
//   4. the web encode*Bytes helpers equal the native encode* buffers
import 'package:nitro/nitro.dart';
import 'package:test/test.dart';

Uint8List _pointerBytes(Pointer<Uint8> ptr) {
  final len = 4 + ByteData.sublistView(ptr.asTypedList(4)).getInt32(0, Endian.little);
  return Uint8List.fromList(ptr.asTypedList(len));
}

void main() {
  group('portable int64 helpers', () {
    const edges = <int>[
      0,
      1,
      -1,
      42,
      -42,
      1 << 32,
      -(1 << 32),
      (1 << 40) + 12345,
      0x7FFFFFFFFFFFFFFF, // int64 max
      -0x8000000000000000, // int64 min
    ];

    test('setInt64LE matches ByteData.setInt64 for edge values', () {
      for (final v in edges) {
        final a = ByteData(8);
        final b = ByteData(8);
        setInt64LE(a, 0, v);
        b.setInt64(0, v, Endian.little);
        expect(
          a.buffer.asUint8List(),
          b.buffer.asUint8List(),
          reason: 'encoding of $v',
        );
      }
    });

    test('getInt64LE round-trips every edge value', () {
      for (final v in edges) {
        final bd = ByteData(8)..setInt64(0, v, Endian.little);
        expect(getInt64LE(bd, 0), v, reason: 'decoding of $v');
      }
    });

    test('helpers work at unaligned offsets', () {
      final bd = ByteData(11);
      setInt64LE(bd, 3, -123456789012345);
      expect(getInt64LE(bd, 3), -123456789012345);
    });
  });

  group('framed-bytes vs pointer edge parity', () {
    RecordWriter buildSample() => RecordWriter()
      ..writeInt(-7)
      ..writeDouble(3.25)
      ..writeBool(true)
      ..writeNullTag(false)
      ..writeString('unicode ⚡')
      ..writeBlob(Uint8List.fromList([9, 8, 7]))
      ..writeInt8(200)
      ..writeInt32(123456);

    test('takeFramedBytes is byte-identical to toNative', () {
      final framed = buildSample().takeFramedBytes();
      using((arena) {
        final ptr = buildSample().toNative(arena);
        expect(framed, _pointerBytes(ptr));
      });
    });

    test('RecordReaderBase.fromFramedBytes decodes what toNative wrote', () {
      using((arena) {
        final ptr = buildSample().toNative(arena);
        final r = RecordReaderBase.fromFramedBytes(_pointerBytes(ptr));
        expect(r.readInt(), -7);
        expect(r.readDouble(), 3.25);
        expect(r.readBool(), isTrue);
        expect(r.readNullTag(), isFalse);
        expect(r.readString(), 'unicode ⚡');
        expect(r.readBlob(), [9, 8, 7]);
        expect(r.readInt8(), 200);
        expect(r.readInt32(), 123456);
      });
    });

    test('indexed-list payload builder matches the native encodeIndexedList', () {
      final items = ['a', 'bb', 'ccc'];
      void writeItem(RecordWriterBase w, String s) => w.writeString(s);

      final w = RecordWriter();
      RecordWriterBase.writeIndexedListPayload(w, items, writeItem);
      final framed = w.takeFramedBytes();

      using((arena) {
        final ptr = RecordWriter.encodeIndexedList<String>(items, writeItem, arena);
        expect(framed, _pointerBytes(ptr));
      });

      // And the offsets actually address the items.
      final header = RecordReaderBase.fromFramedBytes(framed);
      final count = header.readInt32();
      expect(count, 3);
      final offsets = List.generate(count, (_) => header.readInt());
      for (var i = 0; i < count; i++) {
        final r = RecordReaderBase.fromFramedBytes(framed, offsets[i]);
        expect(r.readString(), items[i]);
      }
    });

    test('nullable-list payload builder matches encodeNullableList', () {
      final items = <int?>[1, null, 3];
      void writeItem(RecordWriterBase w, int v) => w.writeInt(v);

      final w = RecordWriter();
      RecordWriterBase.writeNullableListPayload(w, items, writeItem);
      final framed = w.takeFramedBytes();

      using((arena) {
        final ptr = RecordWriter.encodeNullableList<int>(items, writeItem, arena);
        expect(framed, _pointerBytes(ptr));
      });
    });
  });

  group('NitroWireCodec vs @Packed(1) NitroOpt* layout', () {
    test('NitroIntWireCodec bytes equal a packed NitroOptInt64', () {
      for (final v in <int?>[null, 0, -1, 0x7FFFFFFFFFFFFFFF, -0x8000000000000000]) {
        final wire = const NitroIntWireCodec().encodeBytes(v);
        using((arena) {
          final p = arena.packInt(v);
          expect(wire, p.cast<Uint8>().asTypedList(9), reason: 'value $v');
        });
        expect(const NitroIntWireCodec().decodeBytes(wire), v);
      }
    });

    test('NitroDoubleWireCodec bytes equal a packed NitroOptFloat64', () {
      for (final v in <double?>[null, 0.0, -1.5, double.infinity]) {
        final wire = const NitroDoubleWireCodec().encodeBytes(v);
        using((arena) {
          final p = arena.packDouble(v);
          expect(wire, p.cast<Uint8>().asTypedList(9), reason: 'value $v');
        });
        expect(const NitroDoubleWireCodec().decodeBytes(wire), v);
      }
    });

    test('NitroBoolWireCodec bytes equal a packed NitroOptBool', () {
      for (final v in <bool?>[null, true, false]) {
        final wire = const NitroBoolWireCodec().encodeBytes(v);
        using((arena) {
          final p = arena.packBool(v);
          expect(wire, p.cast<Uint8>().asTypedList(2), reason: 'value $v');
        });
        expect(const NitroBoolWireCodec().decodeBytes(wire), v);
      }
    });

    test('NaN round-trips through the double codec as NaN', () {
      final wire = const NitroDoubleWireCodec().encodeBytes(double.nan);
      expect(const NitroDoubleWireCodec().decodeBytes(wire)!.isNaN, isTrue);
    });
  });

  group('NitroAnyMap pure codec entry points', () {
    test('writeTo/readFrom round-trip equals the native pointer path', () {
      final map = NitroAnyMap()
        ..setInt('i', 42)
        ..setString('s', 'x')
        ..setList('l', [NitroAnyValue.from(1), NitroAnyValue.from('two')]);

      // Pure path: frame the payload by hand.
      final w = RecordWriter();
      map.writeTo(w);
      final framed = w.takeFramedBytes();
      final decodedPure = NitroAnyMap.readFrom(RecordReaderBase.fromFramedBytes(framed));
      expect(decodedPure.toDynamic(), map.toDynamic());

      // Native path produces the identical frame.
      using((arena) {
        final ptr = map.toNative(arena);
        expect(framed, _pointerBytes(ptr));
        expect(nitroAnyMapFromNative(ptr).toDynamic(), map.toDynamic());
      });
    });
  });

  // The parity groups above prove the web and native Dart edges agree with EACH
  // OTHER — but both derive from the same shared codec, so a lockstep change to
  // the layout passes parity while silently breaking the C++/Swift/Kotlin
  // decoders (and any persisted bytes). These frozen vectors pin the ABSOLUTE
  // wire bytes: a diff here means the format moved, and every native emitter +
  // the ABI version must move with it on purpose. See doc/wire_format.md.
  group('absolute wire-format golden vectors (cross-backend contract)', () {
    test('NitroIntWireCodec layout is frozen ([1B flag][8B int64 LE])', () {
      expect(const NitroIntWireCodec().encodeBytes(null), [0, 0, 0, 0, 0, 0, 0, 0, 0]);
      expect(const NitroIntWireCodec().encodeBytes(1), [1, 1, 0, 0, 0, 0, 0, 0, 0]);
      expect(const NitroIntWireCodec().encodeBytes(-1), [1, 255, 255, 255, 255, 255, 255, 255, 255]);
      expect(const NitroIntWireCodec().encodeBytes(0x0102030405060708), [1, 8, 7, 6, 5, 4, 3, 2, 1]);
    });

    test('NitroDoubleWireCodec layout is frozen ([1B flag][8B float64 LE])', () {
      expect(const NitroDoubleWireCodec().encodeBytes(null), [0, 0, 0, 0, 0, 0, 0, 0, 0]);
      expect(const NitroDoubleWireCodec().encodeBytes(1.0), [1, 0, 0, 0, 0, 0, 0, 0xf0, 0x3f]);
      expect(const NitroDoubleWireCodec().encodeBytes(-2.5), [1, 0, 0, 0, 0, 0, 0, 0x04, 0xc0]);
    });

    test('NitroBoolWireCodec layout is frozen ([1B flag][1B value])', () {
      expect(const NitroBoolWireCodec().encodeBytes(null), [0, 0]);
      expect(const NitroBoolWireCodec().encodeBytes(true), [1, 1]);
      expect(const NitroBoolWireCodec().encodeBytes(false), [1, 0]);
    });

    test('RecordWriter framed layout is frozen (len32 ++ int64 ++ bool ++ str32+utf8)', () {
      final framed = (RecordWriter()
            ..writeInt(1)
            ..writeBool(true)
            ..writeString('Hi'))
          .takeFramedBytes();
      expect(framed, [
        0x0f, 0x00, 0x00, 0x00, // framed payload length = 15
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // int64 LE = 1
        0x01, // bool true
        0x02, 0x00, 0x00, 0x00, 0x48, 0x69, // string: len32=2, "Hi"
      ]);
    });
  });
}
