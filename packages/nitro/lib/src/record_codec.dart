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
  final _builder = BytesBuilder(copy: false);

  /// Returns the accumulated bytes and resets the writer (internal use only).
  Uint8List _takeBytes() => _builder.takeBytes();

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
      w._builder.add(b);
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
  final Uint8List _bytes;
  int _pos;

  RecordReader._(this._bytes, [this._pos = 0]);

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
    return _cache[index] ??=
        _readItem(RecordReader.fromPayloadOffset(_ptr, _offsets[index]));
  }

  @override
  void operator []=(int index, T value) =>
      throw UnsupportedError('LazyRecordList is read-only');

  @override
  set length(int _) =>
      throw UnsupportedError('LazyRecordList is read-only');
}
