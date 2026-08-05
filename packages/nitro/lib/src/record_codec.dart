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
  /// been written. [pos] must already be within the written region ([_length]).
  void _patchInt64(int pos, int v) {
    _data.setInt64(pos, v, Endian.little);
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
    // Write the length prefix + payload straight into native memory. Copies
    // the accumulated buffer once (setRange) instead of first taking a
    // sublist (`_takeBytes`) and then copying that — and takes one asTypedList
    // view, not two (issue #34, PR #38).
    final total = 4 + _length;
    final ptr = alloc<Uint8>(total);
    final typed = ptr.asTypedList(total);
    ByteData.sublistView(typed).setInt32(0, _length, Endian.little);
    typed.setRange(4, total, _buffer);
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
    // Payload layout: [4B count][8B×n offset table][item bytes]. Offsets are
    // from the payload start (the byte immediately after the outer 4-byte
    // length that toNative prepends).
    //
    // A single writer, with each item written directly into it and the offset
    // table backpatched afterward — no per-item RecordWriter and no
    // intermediate blob copies (perf-audit "#1"). The old path allocated one
    // 256-byte RecordWriter per item, took each item's bytes with a copy, then
    // copied every item a second time into a final writer; this does one
    // writer and writes each item once.
    final n = items.length;
    final w = RecordWriter();
    w.writeInt32(n);
    const offsetTableStart = 4; // right after the 4-byte count, within payload
    for (var i = 0; i < n; i++) {
      w.writeInt(0); // reserve an int64 slot; backpatched below
    }
    // w._length is now the payload offset where item 0 begins (== old
    // `4 + 8*n`). Record each item's start offset as we write it.
    final offsets = List<int>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      offsets[i] = w._length;
      writeItem(w, items[i]);
    }
    for (var i = 0; i < n; i++) {
      w._patchInt64(offsetTableStart + i * 8, offsets[i]);
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

  /// Fallback finalizer: package:ffi's free. Only correct when the buffer
  /// was allocated with package:ffi's allocators — on Windows this is
  /// CoTaskMemFree, which corrupts the heap on a C-runtime malloc'd buffer.
  /// Generated bridges pass their module's `<lib>_nitro_free` via
  /// [decode]'s `nativeFree` parameter instead.
  static final _finalizer = NativeFinalizer(malloc.nativeFree);

  /// One [NativeFinalizer] per distinct native free function, cached by the
  /// function pointer's address (in practice: one entry per Nitro module).
  static final _nativeFinalizers = <int, NativeFinalizer>{};

  LazyRecordList._(
    this._ptr,
    this.length,
    this._offsets,
    this._readItem,
    this._cache,
    int byteLen,
    NativeFinalizer finalizer,
  ) {
    // externalSize hints the GC about native bytes owned by this list so it
    // schedules collection before native memory balloons (dart:ffi @Since('3.4')).
    finalizer.attach(this, _ptr.cast(), detach: this, externalSize: byteLen);
  }

  /// Decodes the offset table from [ptr] and returns a lazy list.
  ///
  /// [ptr] must have been produced by [RecordWriter.encodeIndexedList].
  ///
  /// [nativeFree] is the native free function matching the allocator that
  /// produced [ptr] — for buffers returned by a Nitro bridge, the module's
  /// exported `<lib>_nitro_free`. When omitted, falls back to package:ffi's
  /// free (wrong for native-malloc'd buffers on Windows).
  static LazyRecordList<T> decode<T>(
    Pointer<Uint8> ptr,
    T Function(RecordReader r) readItem, {
    Pointer<NativeFinalizerFunction>? nativeFree,
  }) {
    final r = RecordReader.fromNative(ptr);
    final count = r.readInt32();
    final offsets = List<int>.generate(count, (_) => r.readInt(), growable: false);
    // Buffer layout: [4B payload-length prefix][payload bytes].
    // Read the prefix to give the GC an accurate native-size hint.
    final totalBytes = 4 + ByteData.view(ptr.asTypedList(4).buffer).getInt32(0, Endian.little);
    final finalizer = nativeFree == null
        ? _finalizer
        : _nativeFinalizers.putIfAbsent(
            nativeFree.address,
            () => NativeFinalizer(nativeFree),
          );
    return LazyRecordList<T>._(
      ptr,
      count,
      offsets,
      readItem,
      List<T?>.filled(count, null),
      totalBytes,
      finalizer,
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
