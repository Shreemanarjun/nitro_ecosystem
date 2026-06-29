import 'dart:collection';
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

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
  static const _initialCapacity = 256;

  Uint8List _buffer;
  late ByteData _data;
  int _length = 0;

  RecordWriter([int initialCapacity = _initialCapacity]) : _buffer = Uint8List(initialCapacity) {
    _data = ByteData.view(_buffer.buffer);
  }

  /// Returns the accumulated bytes and resets the writer (internal use only).
  Uint8List _takeBytes() {
    final bytes = Uint8List.sublistView(_buffer, 0, _length);
    _buffer = Uint8List(_initialCapacity);
    _data = ByteData.view(_buffer.buffer);
    _length = 0;
    return bytes;
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

  void writeInt(int v) {
    _ensureCapacity(8);
    _data.setInt64(_length, v, Endian.little);
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

  /// Copies the accumulated payload to an allocator-owned native buffer.
  ///
  /// Layout: `[4-byte payload length][payload bytes]`
  ///
  /// The caller / arena is responsible for freeing the pointer.
  Pointer<Uint8> toNative(Allocator alloc) {
    final payload = _takeBytes();
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

  /// Encodes a list of nullable items.
  ///
  /// Wire format: `[4B count][for each: 1B hasValue][item bytes (only if hasValue)]`
  ///
  /// Used for `List<@HybridEnum?>` and `List<@NitroVariant?>`.
  /// Counterpart: [RecordReader.decodeNullableList].
  static Pointer<Uint8> encodeNullableList<T>(
    List<T?> items,
    void Function(RecordWriter w, T item) writeItem,
    Allocator alloc,
  ) {
    final w = RecordWriter();
    w.writeInt32(items.length);
    for (final e in items) {
      w.writeBool(e != null);
      if (e != null) writeItem(w, e);
    }
    return w.toNative(alloc);
  }

  // ── Indexed list encoding ────────────────────────────────────────────────
  //
  // Wire format (payload — after the outer 4-byte length prefix):
  //   int32          count
  //   int64[count]   item_byte_offsets  — from payload start (after 4-byte length)
  //   item_bytes...
  //
  // This layout allows O(1) random item access via [LazyRecordList].

  /// Encodes a list of @HybridRecord objects with an O(1) offset index table.
  ///
  /// Counterpart: [LazyRecordList.decode].
  static Pointer<Uint8> encodeIndexedList<T>(
    List<T> items,
    void Function(RecordWriter w, T item) writeItem,
    Allocator alloc,
  ) {
    // Serialize each item into its own byte blob.
    final blobs = items.map((e) {
      final w = RecordWriter();
      writeItem(w, e);
      return w._takeBytes();
    }).toList();

    // Payload layout: 4B count + 8B*n offsets + item bytes.
    // Offsets are from the payload start (the byte immediately after the 4-byte outer length).
    var pos = 4 + 8 * blobs.length;
    final offsets = <int>[];
    for (final b in blobs) {
      offsets.add(pos);
      pos += b.length;
    }

    final w = RecordWriter();
    w.writeInt32(blobs.length);
    for (final off in offsets) {
      w.writeInt(off); // writeInt emits int64
    }
    for (final b in blobs) {
      w._writeBytes(b);
    }
    return w.toNative(alloc);
  }

  /// Encodes a list of primitive values with an O(1) offset index table.
  static Pointer<Uint8> encodeIndexedPrimitiveList<T>(
    List<T> items,
    void Function(RecordWriter w, T item) writeItem,
    Allocator alloc,
  ) => encodeIndexedList(items, writeItem, alloc);
}

/// Streaming binary reader for @HybridRecord types.
///
/// Counterpart to [RecordWriter].  Fields must be read in the same order
/// they were written.
class RecordReader {
  static const _utf8Decoder = Utf8Decoder();

  final Uint8List _bytes;
  late final ByteData _data;
  int _pos;

  RecordReader._(this._bytes, [this._pos = 0]) {
    _data = ByteData.sublistView(_bytes);
  }

  /// Wraps the native pointer emitted by [RecordWriter.toNative].
  ///
  /// Reads the 4-byte length prefix and creates a view over the payload
  /// without copying any bytes.
  factory RecordReader.fromNative(Pointer<Uint8> ptr) {
    if (ptr.address == 0) throw StateError('RecordReader.fromNative: null pointer');
    final len = ByteData.view(ptr.asTypedList(4).buffer).getInt32(
      0,
      Endian.little,
    );
    final payload = (ptr + 4).asTypedList(len);
    return RecordReader._(payload);
  }

  /// Creates a reader positioned at [byteOffset] within the payload
  /// (the region after the 4-byte outer length prefix).
  ///
  /// Used by [LazyRecordList] to jump directly to an item without scanning
  /// from the start.
  factory RecordReader.fromPayloadOffset(Pointer<Uint8> ptr, int byteOffset) {
    if (ptr.address == 0) {
      throw StateError('RecordReader.fromPayloadOffset: null pointer');
    }
    final len = ByteData.view(ptr.asTypedList(4).buffer).getInt32(
      0,
      Endian.little,
    );
    final payload = (ptr + 4).asTypedList(len);
    return RecordReader._(payload, byteOffset);
  }

  int readInt() {
    final v = _data.getInt64(_pos, Endian.little);
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

  /// Decodes a list of nullable items.
  ///
  /// Wire format: `[4B count][for each: 1B hasValue][item bytes (only if hasValue)]`
  ///
  /// Counterpart: [RecordWriter.encodeNullableList].
  static List<T?> decodeNullableList<T>(
    Pointer<Uint8> ptr,
    T Function(RecordReader r) readItem,
  ) {
    final r = RecordReader.fromNative(ptr);
    final count = r.readInt32();
    return List.generate(count, (_) {
      final hasValue = r.readBool();
      return hasValue ? readItem(r) : null;
    });
  }
}

// ── LazyRecordList ────────────────────────────────────────────────────────────

/// A read-only [List] backed directly by a native binary buffer produced by
/// [RecordWriter.encodeIndexedList].
///
/// Items are decoded on first access and cached.  The underlying native memory
/// is freed automatically when the list is garbage-collected (via
/// [NativeFinalizer]).
///
/// ## Wire format expected
/// ```
/// [int32 count | int64[count] byte_offsets | item_bytes...]
/// ```
/// The offsets are relative to the payload start (i.e. the byte immediately
/// after the outer 4-byte length prefix written by [RecordWriter.toNative]).
final class LazyRecordList<T> extends ListBase<T> implements Finalizable {
  final Pointer<Uint8> _ptr;
  final T Function(RecordReader) _readItem;

  @override
  final int length;

  /// Byte offsets of each item from the payload start.
  final List<int> _offsets;

  /// Decoded item cache; null = not yet decoded.
  final List<T?> _cache;

  static final _finalizer = NativeFinalizer(malloc.nativeFree);

  LazyRecordList._(
    this._ptr,
    this.length,
    this._offsets,
    this._readItem,
    this._cache,
  ) {
    _finalizer.attach(this, _ptr.cast(), detach: this);
  }

  /// Decodes the offset table from [ptr] and returns a lazy list.
  ///
  /// [ptr] must have been produced by [RecordWriter.encodeIndexedList].
  static LazyRecordList<T> decode<T>(
    Pointer<Uint8> ptr,
    T Function(RecordReader r) readItem,
  ) {
    final r = RecordReader.fromNative(ptr);
    final count = r.readInt32();
    final offsets = List<int>.generate(count, (_) => r.readInt(), growable: false);
    return LazyRecordList<T>._(
      ptr,
      count,
      offsets,
      readItem,
      List<T?>.filled(count, null),
    );
  }

  @override
  T operator [](int index) {
    RangeError.checkValidIndex(index, this);
    return _cache[index] ??= _readItem(RecordReader.fromPayloadOffset(_ptr, _offsets[index]));
  }

  @override
  void operator []=(int index, T value) => throw UnsupportedError('LazyRecordList is read-only');

  @override
  set length(int _) => throw UnsupportedError('LazyRecordList is read-only');
}
