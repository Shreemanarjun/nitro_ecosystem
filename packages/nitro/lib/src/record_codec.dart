import 'dart:collection';
import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

import 'shared/record_codec_base.dart';

export 'shared/record_codec_base.dart' show RecordReaderBase, RecordWriterBase;

/// Streaming binary writer for @HybridRecord types (native dart:ffi edge).
///
/// The wire format and all field writers live in [RecordWriterBase];
/// this class adds the pointer edge: [toNative] and the `encode*` helpers
/// that copy the payload into allocator-owned native memory.
class RecordWriter extends RecordWriterBase {
  RecordWriter([super.initialCapacity]);

  /// Copies the accumulated payload to an allocator-owned native buffer.
  ///
  /// Layout: `[4-byte payload length][payload bytes]`
  ///
  /// The caller / arena is responsible for freeing the pointer.
  Pointer<Uint8> toNative(Allocator alloc) {
    // Copy the accumulated buffer once, straight into native memory, over a
    // single typed-list view.
    final payload = payloadView();
    final total = 4 + payload.length;
    final ptr = alloc<Uint8>(total);
    final typed = ptr.asTypedList(total);
    ByteData.sublistView(typed).setInt32(0, payload.length, Endian.little);
    typed.setRange(4, total, payload);
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
    RecordWriterBase.writeListPayload(w, items, writeItem);
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
    RecordWriterBase.writeNullableListPayload(w, items, writeItem);
    return w.toNative(alloc);
  }

  /// Encodes a list of @HybridRecord objects with an O(1) offset index table.
  ///
  /// Payload: `[4B count][8B×n offset table][item bytes]` — offsets from the
  /// payload start (after the outer 4-byte length prefix [toNative] prepends).
  ///
  /// Counterpart: [LazyRecordList.decode].
  static Pointer<Uint8> encodeIndexedList<T>(
    List<T> items,
    void Function(RecordWriter w, T item) writeItem,
    Allocator alloc,
  ) {
    final w = RecordWriter();
    RecordWriterBase.writeIndexedListPayload(w, items, writeItem);
    return w.toNative(alloc);
  }

  /// Encodes a list of primitive values with an O(1) offset index table.
  static Pointer<Uint8> encodeIndexedPrimitiveList<T>(
    List<T> items,
    void Function(RecordWriter w, T item) writeItem,
    Allocator alloc,
  ) => encodeIndexedList(items, writeItem, alloc);
}

/// Streaming binary reader for @HybridRecord types (native dart:ffi edge).
///
/// Counterpart to [RecordWriter].  Fields must be read in the same order
/// they were written. All field readers live in [RecordReaderBase]; this
/// class adds the pointer-wrapping factories and `decode*` helpers.
class RecordReader extends RecordReaderBase {
  /// Wraps the native pointer emitted by [RecordWriter.toNative].
  ///
  /// Reads the 4-byte length prefix and creates a view over the payload
  /// without copying any bytes.
  RecordReader.fromNative(Pointer<Uint8> ptr) : super.fromPayload(_payloadOf(ptr, 'RecordReader.fromNative'));

  /// Creates a reader positioned at [byteOffset] within the payload
  /// (the region after the 4-byte outer length prefix).
  ///
  /// Used by [LazyRecordList] to jump directly to an item without scanning
  /// from the start.
  RecordReader.fromPayloadOffset(Pointer<Uint8> ptr, int byteOffset) : super.fromPayload(_payloadOf(ptr, 'RecordReader.fromPayloadOffset'), byteOffset);

  static Uint8List _payloadOf(Pointer<Uint8> ptr, String caller) {
    if (ptr.address == 0) throw StateError('$caller: null pointer');
    final len = ByteData.view(ptr.asTypedList(4).buffer).getInt32(
      0,
      Endian.little,
    );
    return (ptr + 4).asTypedList(len);
  }

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
