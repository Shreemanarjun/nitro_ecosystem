import 'dart:convert';
import 'dart:typed_data';

import 'nitro_bytes.dart';

/// Platform-neutral core of the @HybridRecord binary writer.
///
/// Wire format (all integers little-endian):
///   int     → 8 bytes (int64)
///   double  → 8 bytes (float64)
///   bool    → 1 byte  (0 = false, 1 = true)
///   String  → 4-byte UTF-8 byte count, then UTF-8 bytes
///   null tag → 1 byte (0 = null, 1 = present); written before any nullable
///   list    → 4-byte element count, then elements back-to-back
///
/// The framed form prefixes the payload with a 4-byte int32 total length so
/// the receiver knows how many bytes to consume. The native `RecordWriter`
/// adds `toNative(Allocator)`; the web bridge copies [takeFramedBytes] into
/// the module heap.
class RecordWriterBase {
  static const _initialCapacity = 256;

  Uint8List _buffer;
  late ByteData _data;
  int _length = 0;

  RecordWriterBase([int initialCapacity = _initialCapacity]) : _buffer = Uint8List(initialCapacity) {
    _data = ByteData.view(_buffer.buffer);
  }

  void _ensureCapacity(int additionalBytes) {
    final required = _length + additionalBytes;
    if (required <= _buffer.length) return;

    var next = _buffer.length;
    while (next < required) {
      next *= 2;
    }

    final grown = Uint8List(next)..setRange(0, _length, _buffer);
    _buffer = grown;
    _data = ByteData.view(_buffer.buffer);
  }

  void _writeBytes(List<int> bytes) {
    _ensureCapacity(bytes.length);
    _buffer.setRange(_length, _length + bytes.length, bytes);
    _length += bytes.length;
  }

  /// Overwrites the int64 at absolute payload offset [pos] with [v]. Used to
  /// backpatch a reserved offset-table slot after the items it points at have
  /// been written. [pos] must already be within the written region.
  void _patchInt64(int pos, int v) {
    setInt64LE(_data, pos, v);
  }

  void writeInt(int v) {
    _ensureCapacity(8);
    setInt64LE(_data, _length, v);
    _length += 8;
  }

  void writeInt64(int v) => writeInt(v);

  void writeInt8(int v) {
    _ensureCapacity(1);
    _buffer[_length++] = v & 0xff;
  }

  void writeInt32(int v) {
    _ensureCapacity(4);
    _data.setInt32(_length, v, Endian.little);
    _length += 4;
  }

  void writeDouble(double v) {
    _ensureCapacity(8);
    _data.setFloat64(_length, v, Endian.little);
    _length += 8;
  }

  void writeFloat64(double v) => writeDouble(v);

  void writeBool(bool v) {
    _ensureCapacity(1);
    _buffer[_length++] = v ? 1 : 0;
  }

  void writeString(String s) {
    final encoded = utf8.encode(s);
    writeInt32(encoded.length);
    _writeBytes(encoded);
  }

  void writeBlob(Uint8List blob) {
    writeInt32(blob.length);
    _writeBytes(blob);
  }

  /// Writes a 1-byte null tag.  0 = null, 1 = value follows.
  void writeNullTag(bool isNull) {
    _ensureCapacity(1);
    _buffer[_length++] = isNull ? 0 : 1;
  }

  /// Number of payload bytes written so far.
  int get payloadLength => _length;

  /// A view of the payload written so far. Valid only until the next write —
  /// a capacity grow replaces the backing buffer.
  Uint8List payloadView() => Uint8List.sublistView(_buffer, 0, _length);

  /// Copies the accumulated payload into a fresh framed byte list:
  /// `[4-byte payload length][payload bytes]`.
  Uint8List takeFramedBytes() {
    final total = 4 + _length;
    final framed = Uint8List(total);
    ByteData.sublistView(framed).setInt32(0, _length, Endian.little);
    framed.setRange(4, total, _buffer);
    return framed;
  }

  // ── Payload builders shared by the native and web encode entry points ─────

  /// `[4B count][items...]`
  static void writeListPayload<T, W extends RecordWriterBase>(
    W w,
    List<T> items,
    void Function(W w, T item) writeItem,
  ) {
    w.writeInt32(items.length);
    for (final e in items) {
      writeItem(w, e);
    }
  }

  /// `[4B count][for each: 1B hasValue][item bytes (only if hasValue)]`
  static void writeNullableListPayload<T, W extends RecordWriterBase>(
    W w,
    List<T?> items,
    void Function(W w, T item) writeItem,
  ) {
    w.writeInt32(items.length);
    for (final e in items) {
      w.writeBool(e != null);
      if (e != null) writeItem(w, e);
    }
  }

  /// `[4B count][8B×n offset table][item bytes]` — offsets from payload start.
  /// This layout allows O(1) random item access (see the native LazyRecordList).
  static void writeIndexedListPayload<T, W extends RecordWriterBase>(
    W w,
    List<T> items,
    void Function(W w, T item) writeItem,
  ) {
    // One writer: reserve the offset table, write each item directly into it,
    // then backpatch the offsets — no per-item writer, no intermediate copies.
    final n = items.length;
    w.writeInt32(n);
    const offsetTableStart = 4; // right after the 4-byte count, within payload
    for (var i = 0; i < n; i++) {
      w.writeInt(0); // reserve an int64 slot; backpatched below
    }
    // w._length now points at where item 0 begins; record each item's offset.
    final offsets = List<int>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      offsets[i] = w._length;
      writeItem(w, items[i]);
    }
    for (var i = 0; i < n; i++) {
      w._patchInt64(offsetTableStart + i * 8, offsets[i]);
    }
  }
}

/// Platform-neutral core of the @HybridRecord binary reader.
///
/// Counterpart to [RecordWriterBase].  Fields must be read in the same order
/// they were written.
class RecordReaderBase {
  static const _utf8Decoder = Utf8Decoder();

  final Uint8List _bytes;
  late final ByteData _data;
  int _pos;

  /// Positions the reader at [pos] within [payload] — the region after the
  /// 4-byte outer length prefix of the framed form.
  RecordReaderBase.fromPayload(Uint8List payload, [this._pos = 0]) : _bytes = payload {
    _data = ByteData.sublistView(_bytes);
  }

  /// Wraps a framed byte list (`[4B len][payload]`) without copying: reads the
  /// length prefix and views the payload.
  RecordReaderBase.fromFramedBytes(Uint8List framed, [int payloadOffset = 0])
      : _bytes = Uint8List.sublistView(
          framed,
          4,
          4 + ByteData.sublistView(framed).getInt32(0, Endian.little),
        ),
        _pos = payloadOffset {
    _data = ByteData.sublistView(_bytes);
  }

  int readInt() {
    final v = getInt64LE(_data, _pos);
    _pos += 8;
    return v;
  }

  int readInt64() => readInt();

  int readInt8() {
    final v = _bytes[_pos];
    _pos += 1;
    return v;
  }

  int readInt32() {
    final v = _data.getInt32(_pos, Endian.little);
    _pos += 4;
    return v;
  }

  double readDouble() {
    final v = _data.getFloat64(_pos, Endian.little);
    _pos += 8;
    return v;
  }

  double readFloat64() => readDouble();

  bool readBool() => _bytes[_pos++] != 0;

  String readString() {
    final len = readInt32();
    final s = _utf8Decoder.convert(_bytes, _pos, _pos + len);
    _pos += len;
    return s;
  }

  Uint8List readBlob() {
    final len = readInt32();
    final blob = _bytes.sublist(_pos, _pos + len);
    _pos += len;
    return blob;
  }

  /// Returns `true` if the next value is null (tag byte == 0).
  bool readNullTag() => _bytes[_pos++] == 0;
}
