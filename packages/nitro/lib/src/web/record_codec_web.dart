import 'dart:typed_data';

import '../shared/record_codec_base.dart';

export '../shared/record_codec_base.dart' show RecordReaderBase, RecordWriterBase;

/// Streaming binary writer for @HybridRecord types (web edge).
///
/// Same wire format as the native `RecordWriter` (all field writers live in
/// [RecordWriterBase]); instead of a pointer edge, the web bridge copies
/// [RecordWriterBase.takeFramedBytes] into the WASM module heap in one bulk
/// write.
class RecordWriter extends RecordWriterBase {
  RecordWriter([super.initialCapacity]);

  /// Encodes a list of @HybridRecord objects into framed bytes
  /// (`[4B len][payload]`) ready to copy into the module heap.
  static Uint8List encodeListBytes<T>(
    List<T> items,
    void Function(RecordWriter w, T item) writeItem,
  ) {
    final w = RecordWriter();
    RecordWriterBase.writeListPayload(w, items, writeItem);
    return w.takeFramedBytes();
  }

  /// Encodes a list of primitive values (int / double / bool / String).
  static Uint8List encodePrimitiveListBytes<T>(
    List<T> items,
    void Function(RecordWriter w, T item) writeItem,
  ) => encodeListBytes(items, writeItem);

  /// Encodes a list of nullable items:
  /// `[4B count][for each: 1B hasValue][item bytes (only if hasValue)]`.
  static Uint8List encodeNullableListBytes<T>(
    List<T?> items,
    void Function(RecordWriter w, T item) writeItem,
  ) {
    final w = RecordWriter();
    RecordWriterBase.writeNullableListPayload(w, items, writeItem);
    return w.takeFramedBytes();
  }

  /// Encodes a list with an O(1) offset index table:
  /// `[4B count][8B×n offset table][item bytes]`.
  static Uint8List encodeIndexedListBytes<T>(
    List<T> items,
    void Function(RecordWriter w, T item) writeItem,
  ) {
    final w = RecordWriter();
    RecordWriterBase.writeIndexedListPayload(w, items, writeItem);
    return w.takeFramedBytes();
  }
}

/// Streaming binary reader for @HybridRecord types (web edge).
///
/// Counterpart to [RecordWriter]. Wraps framed bytes copied out of the WASM
/// module heap.
class RecordReader extends RecordReaderBase {
  /// Wraps framed bytes (`[4B len][payload]`) without further copying,
  /// optionally positioned at [payloadOffset] within the payload.
  RecordReader.fromFramedBytes(super.framed, [super.payloadOffset]) : super.fromFramedBytes();

  /// Positions the reader at [pos] within an unframed payload.
  RecordReader.fromPayload(super.payload, [super.pos]) : super.fromPayload();

  /// Decodes a list of @HybridRecord objects from framed bytes.
  static List<T> decodeListBytes<T>(
    Uint8List framed,
    T Function(RecordReader r) readItem,
  ) {
    final r = RecordReader.fromFramedBytes(framed);
    final count = r.readInt32();
    return List.generate(count, (_) => readItem(r));
  }

  /// Decodes a list of primitives from framed bytes.
  static List<T> decodePrimitiveListBytes<T>(
    Uint8List framed,
    T Function(RecordReader r) readItem,
  ) => decodeListBytes(framed, readItem);

  /// Decodes a list of nullable items from framed bytes.
  static List<T?> decodeNullableListBytes<T>(
    Uint8List framed,
    T Function(RecordReader r) readItem,
  ) {
    final r = RecordReader.fromFramedBytes(framed);
    final count = r.readInt32();
    return List.generate(count, (_) {
      final hasValue = r.readBool();
      return hasValue ? readItem(r) : null;
    });
  }

  /// Decodes an indexed list (`[4B count][8B×n offsets][items]`) eagerly.
  ///
  /// The web copies the framed buffer out of the module heap anyway, so a
  /// lazy view buys nothing — decode all items in one pass.
  static List<T> decodeIndexedListBytes<T>(
    Uint8List framed,
    T Function(RecordReader r) readItem,
  ) {
    final header = RecordReader.fromFramedBytes(framed);
    final count = header.readInt32();
    final offsets = List<int>.generate(count, (_) => header.readInt(), growable: false);
    return List<T>.generate(
      count,
      (i) => readItem(RecordReader.fromFramedBytes(framed, offsets[i])),
      growable: false,
    );
  }
}
