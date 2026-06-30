import 'dart:ffi';
import 'record_codec.dart';

// ── AnyValue type tags (wire format) ─────────────────────────────────────────
//
// Mirrors RN Nitro's `std::variant<NullType, bool, double, int64, string, array, object>`.
// Each AnyValue is encoded as [1B tag][value bytes].
//
// Tag | Dart type        | Bytes after tag
// ----|------------------|-----------------
//  0  | null             | (none)
//  1  | bool             | 1B (0=false, 1=true)
//  2  | int (int64)      | 8B LE
//  3  | double (float64) | 8B LE
//  4  | String           | 4B len (LE) + UTF-8 bytes
//  5  | List<AnyValue>   | 4B count (LE) + [AnyValue...]
//  6  | Map<String, AnyValue> | 4B count (LE) + [[4B key_len][key_UTF8][AnyValue]...]

const int _tagNull = 0;
const int _tagBool = 1;
const int _tagInt = 2;
const int _tagDouble = 3;
const int _tagString = 4;
const int _tagList = 5;
const int _tagObject = 6;

// ── NitroAnyValue — sealed discriminated union ────────────────────────────────
//
// The Dart/FFI equivalent of RN Nitro's `AnyValue` variant type.
// Supports the same 7 cases: null, bool, int64, float64, string, array, object.

sealed class NitroAnyValue {
  const NitroAnyValue();

  /// Convert from a Dart `dynamic` value.
  /// Accepts null, bool, int, double, String, List, and Map. Throws on unsupported types.
  static NitroAnyValue from(Object? value) {
    if (value == null) return const NitroAnyNull();
    if (value is bool) return NitroAnyBool(value);
    if (value is int) return NitroAnyInt(value);
    if (value is double) return NitroAnyDouble(value);
    if (value is String) return NitroAnyString(value);
    if (value is List) {
      return NitroAnyList(value.map(NitroAnyValue.from).toList(growable: false));
    }
    if (value is Map) {
      return NitroAnyObject({
        for (final e in value.entries) e.key.toString(): NitroAnyValue.from(e.value as Object?),
      });
    }
    throw ArgumentError('Cannot represent $value (${value.runtimeType}) as NitroAnyValue');
  }

  /// Convert back to a plain Dart value (null, bool, int, double, String,
  /// `List<dynamic>`, or `Map<String, dynamic>`).
  Object? toDart();

  // ── Binary codec helpers (called by NitroAnyMap / recursively) ──

  void _write(RecordWriter w) {
    switch (this) {
      case NitroAnyNull():
        w.writeInt8(_tagNull);
      case NitroAnyBool(value: final v):
        w.writeInt8(_tagBool);
        w.writeInt8(v ? 1 : 0);
      case NitroAnyInt(value: final v):
        w.writeInt8(_tagInt);
        w.writeInt(v);
      case NitroAnyDouble(value: final v):
        w.writeInt8(_tagDouble);
        w.writeDouble(v);
      case NitroAnyString(value: final v):
        w.writeInt8(_tagString);
        w.writeString(v);
      case NitroAnyList(value: final v):
        w.writeInt8(_tagList);
        w.writeInt32(v.length);
        for (final item in v) {
          item._write(w);
        }
      case NitroAnyObject(value: final v):
        w.writeInt8(_tagObject);
        w.writeInt32(v.length);
        for (final entry in v.entries) {
          w.writeString(entry.key);
          entry.value._write(w);
        }
    }
  }

  static NitroAnyValue _read(RecordReader r) {
    final tag = r.readInt8();
    return switch (tag) {
      _tagNull => const NitroAnyNull(),
      _tagBool => NitroAnyBool(r.readInt8() != 0),
      _tagInt => NitroAnyInt(r.readInt()),
      _tagDouble => NitroAnyDouble(r.readDouble()),
      _tagString => NitroAnyString(r.readString()),
      _tagList => NitroAnyList(List.generate(r.readInt32(), (_) => _read(r), growable: false)),
      _tagObject => () {
          final n = r.readInt32();
          final entries = <String, NitroAnyValue>{};
          for (var i = 0; i < n; i++) {
            entries[r.readString()] = _read(r);
          }
          return NitroAnyObject(entries);
        }(),
      _ => throw StateError('Unknown NitroAnyValue tag: $tag'),
    };
  }
}

// ── Concrete variants ─────────────────────────────────────────────────────────

final class NitroAnyNull extends NitroAnyValue {
  const NitroAnyNull();

  @override
  Object? toDart() => null;

  @override
  String toString() => 'NitroAnyNull()';
}

final class NitroAnyBool extends NitroAnyValue {
  final bool value;

  const NitroAnyBool(this.value);

  @override
  Object? toDart() => value;

  @override
  String toString() => 'NitroAnyBool($value)';
}

final class NitroAnyInt extends NitroAnyValue {
  final int value;

  const NitroAnyInt(this.value);

  @override
  Object? toDart() => value;

  @override
  String toString() => 'NitroAnyInt($value)';
}

final class NitroAnyDouble extends NitroAnyValue {
  final double value;

  const NitroAnyDouble(this.value);

  @override
  Object? toDart() => value;

  @override
  String toString() => 'NitroAnyDouble($value)';
}

final class NitroAnyString extends NitroAnyValue {
  final String value;

  const NitroAnyString(this.value);

  @override
  Object? toDart() => value;

  @override
  String toString() => 'NitroAnyString($value)';
}

final class NitroAnyList extends NitroAnyValue {
  final List<NitroAnyValue> value;

  const NitroAnyList(this.value);

  @override
  Object? toDart() => value.map((e) => e.toDart()).toList(growable: false);

  @override
  String toString() => 'NitroAnyList(${value.length} items)';
}

final class NitroAnyObject extends NitroAnyValue {
  final Map<String, NitroAnyValue> value;

  const NitroAnyObject(this.value);

  @override
  Object? toDart() => {for (final e in value.entries) e.key: e.value.toDart()};

  NitroAnyMap toMap() => NitroAnyMap._(Map.of(value));

  @override
  String toString() => 'NitroAnyObject(${value.length} keys)';
}

// ── NitroAnyMap ───────────────────────────────────────────────────────────────
//
// The Dart/FFI equivalent of RN Nitro's `AnyMap`.
// A heterogeneous string-keyed map whose values are [NitroAnyValue] variants.
//
// Wire format (outer RecordWriter envelope = 4B length prefix + payload):
//   payload = AnyValue tag 6 body: [4B count LE][[4B key_len][key_UTF8][AnyValue]...]
//
// Usage:
//   final map = NitroAnyMap();
//   map.setInt('count', 42);
//   map.setDouble('score', 3.14);
//   map.setString('name', 'hello');
//   // Pass to bridge:
//   final ptr = map.toNative(arena);
//
//   // Receive from bridge:
//   final result = NitroAnyMap.fromNative(ptr);
//   final count = result.getInt('count');   // int?

class NitroAnyMap {
  final Map<String, NitroAnyValue> _map;

  NitroAnyMap() : _map = {};
  NitroAnyMap._(this._map);

  /// Build from a plain Dart `Map<String, dynamic>`.
  factory NitroAnyMap.fromDynamic(Map<String, dynamic> source) => NitroAnyMap._(
    source.map((k, v) => MapEntry(k, NitroAnyValue.from(v))),
  );

  // ── Containment ────────────────────────────────────────────────────────────

  bool contains(String key) => _map.containsKey(key);
  void remove(String key) => _map.remove(key);
  void clear() => _map.clear();
  Iterable<String> get keys => _map.keys;
  int get length => _map.length;

  // ── Type probes (mirrors AnyMap.isXxx) ────────────────────────────────────

  bool isNull(String key) => _map[key] is NitroAnyNull;
  bool isBool(String key) => _map[key] is NitroAnyBool;
  bool isInt(String key) => _map[key] is NitroAnyInt;
  bool isDouble(String key) => _map[key] is NitroAnyDouble;
  bool isString(String key) => _map[key] is NitroAnyString;
  bool isList(String key) => _map[key] is NitroAnyList;
  bool isObject(String key) => _map[key] is NitroAnyObject;

  // ── Typed getters ─────────────────────────────────────────────────────────

  bool? getBool(String key) {
    final v = _map[key];
    return v is NitroAnyBool ? v.value : null;
  }

  int? getInt(String key) {
    final v = _map[key];
    return v is NitroAnyInt ? v.value : null;
  }

  double? getDouble(String key) {
    final v = _map[key];
    return v is NitroAnyDouble ? v.value : null;
  }

  String? getString(String key) {
    final v = _map[key];
    return v is NitroAnyString ? v.value : null;
  }

  List<NitroAnyValue>? getList(String key) {
    final v = _map[key];
    return v is NitroAnyList ? v.value : null;
  }

  NitroAnyMap? getObject(String key) {
    final v = _map[key];
    return v is NitroAnyObject ? v.toMap() : null;
  }

  NitroAnyValue? get(String key) => _map[key];

  // ── Typed setters ─────────────────────────────────────────────────────────

  void setNull(String key) => _map[key] = const NitroAnyNull();
  void setBool(String key, bool v) => _map[key] = NitroAnyBool(v);
  void setInt(String key, int v) => _map[key] = NitroAnyInt(v);
  void setDouble(String key, double v) => _map[key] = NitroAnyDouble(v);
  void setString(String key, String v) => _map[key] = NitroAnyString(v);
  void setList(String key, List<NitroAnyValue> v) => _map[key] = NitroAnyList(v);
  void setObject(String key, NitroAnyMap v) => _map[key] = NitroAnyObject(Map.of(v._map));
  void set(String key, NitroAnyValue v) => _map[key] = v;

  /// Merge all keys from [other] into this map. Existing keys are overwritten.
  void merge(NitroAnyMap other) => _map.addAll(other._map);

  // ── Conversion ─────────────────────────────────────────────────────────────

  /// Convert all values to plain Dart `dynamic` equivalents.
  Map<String, dynamic> toDynamic() => {
    for (final e in _map.entries) e.key: e.value.toDart(),
  };

  // ── Binary codec ──────────────────────────────────────────────────────────

  /// Decode from a native pointer produced by [toNative] or the C bridge.
  ///
  /// Wire: RecordWriter outer 4B length prefix + map entries.
  /// Does NOT free [ptr] — caller is responsible.
  static NitroAnyMap fromNative(Pointer<Uint8> ptr) {
    final r = RecordReader.fromNative(ptr);
    return _readMap(r);
  }

  /// Encode this map to a native buffer wrapped in the RecordWriter 4B envelope.
  ///
  /// The returned pointer is owned by [alloc] and must not be freed separately
  /// when using an Arena (the Arena frees it on scope exit).
  Pointer<Uint8> toNative(Allocator alloc) {
    final w = RecordWriter();
    _writeMap(w);
    return w.toNative(alloc);
  }

  // ── Private binary helpers ─────────────────────────────────────────────────

  void _writeMap(RecordWriter w) {
    w.writeInt32(_map.length);
    for (final entry in _map.entries) {
      w.writeString(entry.key);
      entry.value._write(w);
    }
  }

  static NitroAnyMap _readMap(RecordReader r) {
    final count = r.readInt32();
    final map = <String, NitroAnyValue>{};
    for (var i = 0; i < count; i++) {
      final key = r.readString();
      map[key] = NitroAnyValue._read(r);
    }
    return NitroAnyMap._(map);
  }

  @override
  String toString() => 'NitroAnyMap($_map)';
}

// ── Kotlin/Swift inline binary codec (generated into bridge files) ────────────
//
// To avoid shipping a runtime Kotlin/Swift library, the generator emits these
// encode/decode helpers inline into the generated bridge file.
//
// Kotlin helpers (emitted as top-level private functions):
//
//   private const val ANY_NULL   = 0.toByte()
//   private const val ANY_BOOL   = 1.toByte()
//   private const val ANY_INT    = 2.toByte()
//   private const val ANY_DOUBLE = 3.toByte()
//   private const val ANY_STRING = 4.toByte()
//   private const val ANY_LIST   = 5.toByte()
//   private const val ANY_OBJECT = 6.toByte()
//
//   private fun ByteBuffer.writeAnyValue(v: Any?) { ... }
//   private fun ByteBuffer.readAnyValue(): Any? { ... }
//
//   fun nitroEncodeAnyMap(map: Map<String, Any?>): ByteArray { ... }
//   fun nitroDecodeAnyMap(bytes: ByteArray): Map<String, Any?> { ... }
//
// Swift helpers (emitted as file-private functions):
//
//   private func writeAnyValue(_ v: Any?, into buffer: inout Data) { ... }
//   private func readAnyValue(from buffer: Data, at offset: inout Int) -> Any? { ... }
//   func nitroEncodeAnyMap(_ map: [String: Any?]) -> Data { ... }
//   func nitroDecodeAnyMap(_ data: Data) -> [String: Any?] { ... }

// ── DartDoc-visible codec for generated code ──────────────────────────────────

/// Kotlin inline encoder/decoder source, emitted as a string constant for the
/// generator to inject into bridge .kt files.
const String kNitroAnyMapKotlinHelper = r'''
  // NitroAnyMap binary codec — generated inline by Nitrogen
  private object NitroAnyMapCodec {
    private const val ANY_NULL: Byte = 0
    private const val ANY_BOOL: Byte = 1
    private const val ANY_INT: Byte = 2
    private const val ANY_DOUBLE: Byte = 3
    private const val ANY_STRING: Byte = 4
    private const val ANY_LIST: Byte = 5
    private const val ANY_OBJECT: Byte = 6

    fun encode(map: Map<String, Any?>): ByteArray {
      val buf = java.io.ByteArrayOutputStream()
      val out = java.io.DataOutputStream(buf)
      writeMap(out, map)
      val payload = buf.toByteArray()
      val result = java.io.ByteArrayOutputStream(4 + payload.size)
      val header = java.io.DataOutputStream(result)
      header.writeIntLE(payload.size)
      result.write(payload)
      return result.toByteArray()
    }

    fun decode(bytes: ByteArray): Map<String, Any?> {
      val len = java.nio.ByteBuffer.wrap(bytes, 0, 4).order(java.nio.ByteOrder.LITTLE_ENDIAN).getInt()
      val buf = java.io.DataInputStream(bytes.inputStream().also { it.skip(4) })
      return readMap(buf)
    }

    private fun writeValue(out: java.io.DataOutputStream, v: Any?) {
      when (v) {
        null -> out.writeByte(ANY_NULL.toInt())
        is Boolean -> { out.writeByte(ANY_BOOL.toInt()); out.writeByte(if (v) 1 else 0) }
        is Long -> { out.writeByte(ANY_INT.toInt()); out.writeLongLE(v) }
        is Int -> { out.writeByte(ANY_INT.toInt()); out.writeLongLE(v.toLong()) }
        is Double -> { out.writeByte(ANY_DOUBLE.toInt()); out.writeDoubleLE(v) }
        is Float -> { out.writeByte(ANY_DOUBLE.toInt()); out.writeDoubleLE(v.toDouble()) }
        is String -> { out.writeByte(ANY_STRING.toInt()); writeStr(out, v) }
        is List<*> -> { out.writeByte(ANY_LIST.toInt()); out.writeIntLE(v.size); v.forEach { writeValue(out, it) } }
        is Map<*, *> -> { out.writeByte(ANY_OBJECT.toInt()); out.writeIntLE(v.size); v.forEach { (k, vv) -> writeStr(out, k.toString()); writeValue(out, vv) } }
        else -> throw IllegalArgumentException("Cannot encode $v as NitroAnyValue")
      }
    }

    private fun writeStr(out: java.io.DataOutputStream, s: String) {
      val b = s.toByteArray(Charsets.UTF_8); out.writeIntLE(b.size); out.write(b)
    }

    private fun readValue(buf: java.io.DataInputStream): Any? = when (buf.readByte()) {
      ANY_NULL -> null
      ANY_BOOL -> buf.readByte() != 0.toByte()
      ANY_INT -> buf.readLongLE()
      ANY_DOUBLE -> buf.readDoubleLE()
      ANY_STRING -> readStr(buf)
      ANY_LIST -> List(buf.readIntLE()) { readValue(buf) }
      ANY_OBJECT -> (0 until buf.readIntLE()).associate { readStr(buf) to readValue(buf) }
      else -> throw IllegalArgumentException("Unknown NitroAnyValue tag")
    }

    private fun readStr(buf: java.io.DataInputStream): String {
      val len = buf.readIntLE(); val b = ByteArray(len); buf.readFully(b); return b.toString(Charsets.UTF_8)
    }

    private fun writeMap(out: java.io.DataOutputStream, map: Map<String, Any?>) {
      out.writeIntLE(map.size); map.forEach { (k, v) -> writeStr(out, k); writeValue(out, v) }
    }

    private fun readMap(buf: java.io.DataInputStream): Map<String, Any?> =
      (0 until buf.readIntLE()).associate { readStr(buf) to readValue(buf) }

    private fun java.io.DataOutputStream.writeIntLE(v: Int) { write(v and 0xFF); write((v shr 8) and 0xFF); write((v shr 16) and 0xFF); write((v shr 24) and 0xFF) }
    private fun java.io.DataOutputStream.writeLongLE(v: Long) { (0..7).forEach { write(((v shr (it * 8)) and 0xFF).toInt()) } }
    private fun java.io.DataOutputStream.writeDoubleLE(v: Double) = writeLongLE(java.lang.Double.doubleToRawLongBits(v))
    private fun java.io.DataInputStream.readIntLE(): Int = (read() or (read() shl 8) or (read() shl 16) or (read() shl 24))
    private fun java.io.DataInputStream.readLongLE(): Long = (0..7).fold(0L) { acc, i -> acc or (read().toLong() shl (i * 8)) }
    private fun java.io.DataInputStream.readDoubleLE(): Double = java.lang.Double.longBitsToDouble(readLongLE())
  }
''';

/// Swift inline encoder/decoder source, emitted by the generator into bridge .swift files.
const String kNitroAnyMapSwiftHelper = r'''
  // NitroAnyMap binary codec — generated inline by Nitrogen
  private enum _AnyTag: UInt8 { case null_ = 0, bool_ = 1, int_ = 2, double_ = 3, string_ = 4, list_ = 5, object_ = 6 }

  private func _writeLE32(_ v: Int32, into data: inout Data) {
    var n = v.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) }
  }
  private func _writeLE64(_ v: Int64, into data: inout Data) {
    var n = v.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) }
  }
  private func _readLE32(_ data: Data, at offset: inout Int) -> Int32 {
    let v = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: Int32.self) }
    offset += 4; return Int32(littleEndian: v)
  }
  private func _readLE64(_ data: Data, at offset: inout Int) -> Int64 {
    let v = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: Int64.self) }
    offset += 8; return Int64(littleEndian: v)
  }
  private func _writeStr(_ s: String, into data: inout Data) {
    let bytes = Array(s.utf8); _writeLE32(Int32(bytes.count), into: &data); data.append(contentsOf: bytes)
  }
  private func _readStr(_ data: Data, at offset: inout Int) -> String {
    let len = Int(_readLE32(data, at: &offset))
    let s = String(bytes: data[offset..<(offset + len)], encoding: .utf8) ?? ""
    offset += len; return s
  }
  private func _writeAnyValue(_ v: Any?, into data: inout Data) {
    switch v {
    case nil: data.append(_AnyTag.null_.rawValue)
    case let b as Bool: data.append(_AnyTag.bool_.rawValue); data.append(b ? 1 : 0)
    case let i as Int64: data.append(_AnyTag.int_.rawValue); _writeLE64(i, into: &data)
    case let i as Int: data.append(_AnyTag.int_.rawValue); _writeLE64(Int64(i), into: &data)
    case let d as Double: data.append(_AnyTag.double_.rawValue); _writeLE64(Int64(bitPattern: d.bitPattern), into: &data)
    case let s as String: data.append(_AnyTag.string_.rawValue); _writeStr(s, into: &data)
    case let arr as [Any?]: data.append(_AnyTag.list_.rawValue); _writeLE32(Int32(arr.count), into: &data); arr.forEach { _writeAnyValue($0, into: &data) }
    case let obj as [String: Any?]: data.append(_AnyTag.object_.rawValue); _writeLE32(Int32(obj.count), into: &data); obj.forEach { k, vv in _writeStr(k, into: &data); _writeAnyValue(vv, into: &data) }
    default: fatalError("Cannot encode \(String(describing: v)) as NitroAnyValue")
    }
  }
  private func _readAnyValue(_ data: Data, at offset: inout Int) -> Any? {
    let tag = _AnyTag(rawValue: data[offset])!; offset += 1
    switch tag {
    case .null_: return nil
    case .bool_: let b = data[offset] != 0; offset += 1; return b
    case .int_: return _readLE64(data, at: &offset)
    case .double_: return Double(bitPattern: UInt64(bitPattern: _readLE64(data, at: &offset)))
    case .string_: return _readStr(data, at: &offset)
    case .list_: let n = Int(_readLE32(data, at: &offset)); return (0..<n).map { _ in _readAnyValue(data, at: &offset) }
    case .object_: let n = Int(_readLE32(data, at: &offset)); var d = [String: Any?](); (0..<n).forEach { _ in d[_readStr(data, at: &offset)] = _readAnyValue(data, at: &offset) }; return d
    }
  }
  private func _encodeAnyMap(_ map: [String: Any?]) -> Data {
    var payload = Data()
    _writeLE32(Int32(map.count), into: &payload)
    map.forEach { k, v in _writeStr(k, into: &payload); _writeAnyValue(v, into: &payload) }
    var result = Data(capacity: 4 + payload.count)
    _writeLE32(Int32(payload.count), into: &result)
    result.append(payload)
    return result
  }
  private func _decodeAnyMap(_ data: Data) -> [String: Any?] {
    // skip the outer 4-byte length prefix
    var offset = 4
    let count = Int(_readLE32(data, at: &offset))
    var map = [String: Any?](minimumCapacity: count)
    for _ in 0..<count { map[_readStr(data, at: &offset)] = _readAnyValue(data, at: &offset) }
    return map
  }
''';
