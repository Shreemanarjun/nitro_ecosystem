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

    // A zero-length buffer never grows by doubling — `0 * 2` is still 0 and
    // the loop spins forever. Start from at least one byte and floor the
    // result at `required` so a single huge write cannot loop either.
    var next = _buffer.isEmpty ? 1 : _buffer.length;
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
    // ASCII fast path: the code units go straight into the buffer — no
    // utf8.encode allocation and no second copy. Falls back to UTF-8 on the
    // first non-ASCII unit (nothing was committed yet).
    final n = s.length;
    _ensureCapacity(4 + n);
    final base = _length + 4;
    if (_writeAscii(s, n, base)) {
      _data.setInt32(_length, n, Endian.little);
      _length = base + n;
      return;
    }
    final encoded = utf8.encode(s);
    writeInt32(encoded.length);
    _writeBytes(encoded);
  }

  /// Copies [s]'s code units to [base] if every one is ASCII; false otherwise
  /// (what was written is then not committed).
  bool _writeAscii(String s, int n, int base) {
    var i = 0;
    // Eight units per store from 16 characters up: about 35% less per
    // character than a store each (measured, AOT). Shorter strings gain
    // nothing from it, and dart2js has no 64-bit ByteData access.
    if (!kNitroWeb && n >= 16) {
      final data = _data;
      for (final end = n - 7; i < end; i += 8) {
        final c0 = s.codeUnitAt(i), c1 = s.codeUnitAt(i + 1), c2 = s.codeUnitAt(i + 2), c3 = s.codeUnitAt(i + 3);
        final c4 = s.codeUnitAt(i + 4), c5 = s.codeUnitAt(i + 5), c6 = s.codeUnitAt(i + 6), c7 = s.codeUnitAt(i + 7);
        // The units themselves, not the packed word: a unit like U+0100 has
        // no bit 7 and would pass for ASCII once shifted into its lane.
        // Checked per word, so text that is not ASCII leaves after eight units
        // instead of paying for a full pass before the UTF-8 one.
        if ((c0 | c1 | c2 | c3 | c4 | c5 | c6 | c7) >= 0x80) return false;
        data.setUint64(base + i, c0 | c1 << 8 | c2 << 16 | c3 << 24 | c4 << 32 | c5 << 40 | c6 << 48 | c7 << 56, Endian.little);
      }
    }
    final buffer = _buffer;
    for (; i < n; i++) {
      final c = s.codeUnitAt(i);
      if (c >= 0x80) return false;
      buffer[base + i] = c;
    }
    return true;
  }

  void writeBlob(Uint8List blob) {
    writeInt32(blob.length);
    _writeBytes(blob);
  }

  // Whole primitive lists, `[4B count][items]`: one capacity check for the
  // list instead of one per item (about 3x faster than a writeInt loop, AOT).

  void writeIntList(List<int> items) {
    final n = items.length;
    _ensureCapacity(4 + n * 8);
    final data = _data;
    var o = _length;
    data.setInt32(o, n, Endian.little);
    o += 4;
    for (var i = 0; i < n; i++) {
      setInt64LE(data, o, items[i]);
      o += 8;
    }
    _length = o;
  }

  void writeDoubleList(List<double> items) {
    final n = items.length;
    _ensureCapacity(4 + n * 8);
    final data = _data;
    var o = _length;
    data.setInt32(o, n, Endian.little);
    o += 4;
    for (var i = 0; i < n; i++) {
      data.setFloat64(o, items[i], Endian.little);
      o += 8;
    }
    _length = o;
  }

  void writeBoolList(List<bool> items) {
    final n = items.length;
    _ensureCapacity(4 + n);
    final buffer = _buffer;
    var o = _length;
    _data.setInt32(o, n, Endian.little);
    o += 4;
    for (var i = 0; i < n; i++) {
      buffer[o++] = items[i] ? 1 : 0;
    }
    _length = o;
  }

  /// Writes a 1-byte null tag.  0 = null, 1 = value follows.
  void writeNullTag(bool isNull) {
    _ensureCapacity(1);
    _buffer[_length++] = isNull ? 0 : 1;
  }

  /// Number of payload bytes written so far.
  int get payloadLength => _length;

  /// Copies the payload into [dst] at [dstOffset] without allocating a view.
  void copyPayloadTo(Uint8List dst, int dstOffset) => dst.setRange(dstOffset, dstOffset + _length, _buffer);

  /// Rewinds the writer so its buffer can be reused for the next payload.
  ///
  /// A buffer that one large payload grew past [_retainLimit] is dropped: the
  /// shared scratch writer lives as long as its isolate, and would otherwise
  /// hold the largest record ever sent.
  void reset() {
    _length = 0;
    if (_buffer.length > _retainLimit) {
      _buffer = Uint8List(_initialCapacity);
      _data = ByteData.view(_buffer.buffer);
    }
  }

  static const _retainLimit = 4 * 1024 * 1024;

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

  // Whole-list readers. The closure indexes the payload from locals: reading
  // each item through readInt() (a position store per item) cost 1.4–1.9×
  // more (AOT).
  List<int> readIntList() {
    final n = readInt32(), p = _pos, data = _data;
    _pos = p + n * 8;
    return List<int>.generate(n, (i) => getInt64LE(data, p + i * 8));
  }

  List<double> readDoubleList() {
    final n = readInt32(), p = _pos, data = _data;
    _pos = p + n * 8;
    return List<double>.generate(n, (i) => data.getFloat64(p + i * 8, Endian.little));
  }

  List<bool> readBoolList() {
    final n = readInt32(), p = _pos, bytes = _bytes;
    _pos = p + n;
    return List<bool>.generate(n, (i) => bytes[p + i] != 0);
  }

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
    final start = _pos, end = start + len;
    // ASCII, the common case, needs no decoder: check eight bytes at a time and
    // build the string from the bytes directly (about 3x faster at 1 KiB, AOT).
    // dart2js has no 64-bit ByteData access, so the web keeps the decoder.
    final s = !kNitroWeb && _isAscii(start, end) ? String.fromCharCodes(_bytes, start, end) : _decodeUtf8(start, end);
    _pos = end;
    return s;
  }

  /// UTF-8 to String, keeping any leading U+FEFF. dart:convert's decoder takes
  /// a leading BOM for a stream signature and drops it; a field's text is data,
  /// so count the BOMs, decode the rest, and put them back.
  String _decodeUtf8(int start, int end) {
    final bytes = _bytes;
    var from = start;
    while (from + 3 <= end && bytes[from] == 0xEF && bytes[from + 1] == 0xBB && bytes[from + 2] == 0xBF) {
      from += 3;
    }
    final decoded = _utf8Decoder.convert(bytes, from, end);
    return from == start ? decoded : String.fromCharCode(0xFEFF) * ((from - start) ~/ 3) + decoded;
  }

  // 0x80 in every byte. Built by shifting: as one literal it is not
  // representable on the web, where this file also compiles.
  static const _highBits = (0x80808080 << 32) | 0x80808080;

  /// True when no byte in `[start, end)` has its high bit set.
  bool _isAscii(int start, int end) {
    final data = _data;
    var i = start;
    var seen = 0;
    for (final lastWord = end - 8; i <= lastWord; i += 8) {
      seen |= data.getUint64(i, Endian.host);
    }
    final bytes = _bytes;
    while (i < end) {
      seen |= bytes[i++];
    }
    return seen & _highBits == 0;
  }

  Uint8List readBlob() {
    final len = readInt32();
    final blob = _bytes.sublist(_pos, _pos + len);
    _pos += len;
    return blob;
  }

  /// The bytes of a typed-data field the caller keeps. Copies like [readBlob],
  /// unless the reader owns the buffer under its payload and can lend them
  /// ([lendBytes]). [alignment] is the element size of the list the caller
  /// builds on the result (`Float32List.view(r.readBlobView(4).buffer)`).
  Uint8List readBlobView([int alignment = 1]) {
    final len = readInt32();
    final blob = lendBytes(_pos, len, alignment) ?? _bytes.sublist(_pos, _pos + len);
    _pos += len;
    return blob;
  }

  /// [length] payload bytes at [offset], at an address that is a multiple of
  /// [alignment], without copying into the Dart heap and kept alive for as long
  /// as the returned list is; or null to have them copied. Only a reader that
  /// owns its buffer can lend; this one does not.
  Uint8List? lendBytes(int offset, int length, int alignment) => null;

  /// Returns `true` if the next value is null (tag byte == 0).
  bool readNullTag() => _bytes[_pos++] == 0;
}
