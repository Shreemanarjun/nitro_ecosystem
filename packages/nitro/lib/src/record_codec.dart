import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

/// Streaming binary writer for @HybridRecord types.
///
/// Wire format (all integers little-endian):
///   int     → 8 bytes (int64)
///   double  → 8 bytes (float64)
///   bool    → 1 byte  (0 = false, 1 = true)
///   String  → 4-byte UTF-8 byte count, then UTF-8 bytes
///   null tag → 1 byte (0 = null, 1 = present); written before any nullable
///   list    → 4-byte element count, then elements back-to-back
///
/// [toNative] prefixes the payload with a 4-byte int32 total length so the
/// C / Kotlin / Swift receiver knows how many bytes to consume.
class RecordWriter {
  final _builder = BytesBuilder(copy: false);

  void writeInt(int v) {
    final d = ByteData(8)..setInt64(0, v, Endian.little);
    _builder.add(d.buffer.asUint8List());
  }

  void writeInt32(int v) {
    final d = ByteData(4)..setInt32(0, v, Endian.little);
    _builder.add(d.buffer.asUint8List());
  }

  void writeDouble(double v) {
    final d = ByteData(8)..setFloat64(0, v, Endian.little);
    _builder.add(d.buffer.asUint8List());
  }

  void writeBool(bool v) => _builder.addByte(v ? 1 : 0);

  void writeString(String s) {
    final encoded = utf8.encode(s);
    writeInt32(encoded.length);
    _builder.add(encoded);
  }

  /// Writes a 1-byte null tag.  0 = null, 1 = value follows.
  void writeNullTag(bool isNull) => _builder.addByte(isNull ? 0 : 1);

  /// Copies the accumulated payload to an allocator-owned native buffer.
  ///
  /// Layout: `[4-byte payload length][payload bytes]`
  ///
  /// The caller / arena is responsible for freeing the pointer.
  Pointer<Uint8> toNative(Allocator alloc) {
    final payload = _builder.takeBytes();
    final total = 4 + payload.length;
    final ptr = alloc<Uint8>(total);
    final view = ByteData.view(ptr.asTypedList(total).buffer);
    view.setInt32(0, payload.length, Endian.little);
    ptr.asTypedList(total).setRange(4, total, payload);
    return ptr;
  }

  /// Encodes a list of @HybridRecord objects into a single native buffer.
  ///
  /// [writeItem] should call the record's `writeFields(w)` method.
  static Pointer<Uint8> encodeList<T>(
    List<T> items,
    void Function(RecordWriter w, T item) writeItem,
    Allocator alloc,
  ) {
    final w = RecordWriter();
    w.writeInt32(items.length);
    for (final e in items) {
      writeItem(w, e);
    }
    return w.toNative(alloc);
  }

  /// Encodes a list of primitive values (int / double / bool / String).
  ///
  /// [writeItem] should call the appropriate `w.writeXxx(e)` method.
  static Pointer<Uint8> encodePrimitiveList<T>(
    List<T> items,
    void Function(RecordWriter w, T item) writeItem,
    Allocator alloc,
  ) => encodeList(items, writeItem, alloc);
}

/// Streaming binary reader for @HybridRecord types.
///
/// Counterpart to [RecordWriter].  Fields must be read in the same order
/// they were written.
class RecordReader {
  final Uint8List _bytes;
  int _pos = 0;

  RecordReader._(this._bytes);

  /// Wraps the native pointer emitted by [RecordWriter.toNative].
  ///
  /// Reads the 4-byte length prefix and creates a view over the payload
  /// without copying any bytes.
  factory RecordReader.fromNative(Pointer<Uint8> ptr) {
    final len = ByteData.view(ptr.asTypedList(4).buffer).getInt32(
      0,
      Endian.little,
    );
    final payload = (ptr + 4).asTypedList(len);
    return RecordReader._(payload);
  }

  int readInt() {
    final v = ByteData.view(
      _bytes.buffer,
      _bytes.offsetInBytes + _pos,
      8,
    ).getInt64(0, Endian.little);
    _pos += 8;
    return v;
  }

  int readInt32() {
    final v = ByteData.view(
      _bytes.buffer,
      _bytes.offsetInBytes + _pos,
      4,
    ).getInt32(0, Endian.little);
    _pos += 4;
    return v;
  }

  double readDouble() {
    final v = ByteData.view(
      _bytes.buffer,
      _bytes.offsetInBytes + _pos,
      8,
    ).getFloat64(0, Endian.little);
    _pos += 8;
    return v;
  }

  bool readBool() => _bytes[_pos++] != 0;

  String readString() {
    final len = readInt32();
    final s = utf8.decode(_bytes.sublist(_pos, _pos + len));
    _pos += len;
    return s;
  }

  /// Returns `true` if the next value is null (tag byte == 0).
  bool readNullTag() => _bytes[_pos++] == 0;

  /// Decodes a list of @HybridRecord objects from a native pointer.
  ///
  /// [readItem] should call the record's `fromReader(r)` factory.
  static List<T> decodeList<T>(
    Pointer<Uint8> ptr,
    T Function(RecordReader r) readItem,
  ) {
    final r = RecordReader.fromNative(ptr);
    final count = r.readInt32();
    return List.generate(count, (_) => readItem(r));
  }

  /// Decodes a list of primitives.
  ///
  /// [readItem] should call the appropriate `r.readXxx()` method.
  static List<T> decodePrimitiveList<T>(
    Pointer<Uint8> ptr,
    T Function(RecordReader r) readItem,
  ) => decodeList(ptr, readItem);
}
