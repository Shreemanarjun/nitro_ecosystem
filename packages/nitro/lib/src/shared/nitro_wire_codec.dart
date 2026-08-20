import 'dart:typed_data';

import 'nitro_bytes.dart';

/// Platform-neutral codec for a `@NitroCustomType` [T] transported across the
/// bridge as an optional fixed-size value: `[1B hasValue][encodedSize-1 bytes]`.
///
/// This is the byte-level counterpart of the native-only `NitroFfiCodec<T>`
/// (which speaks `Pointer<Uint8>`): the same wire layout expressed over
/// [ByteData], so one codec implementation works on native AND web.
///
/// Web-targeting specs with `@NitroCustomType` must provide a
/// [NitroWireCodec]; native-only specs may keep using `NitroFfiCodec`.
///
/// Example:
/// ```dart
/// class ColorWireCodec extends NitroWireCodec<Color> {
///   const ColorWireCodec();
///   @override int get encodedSize => 5;   // 1B flag + 4B RGBA
///
///   @override void write(ByteData out, int offset, Color? v) {
///     out.setUint8(offset, v != null ? 1 : 0);
///     if (v != null) { out.setUint8(offset + 1, v.r); /* ... */ }
///   }
///
///   @override Color? read(ByteData bytes, int offset) {
///     if (bytes.getUint8(offset) == 0) return null;
///     return Color(bytes.getUint8(offset + 1), /* ... */);
///   }
/// }
/// ```
abstract class NitroWireCodec<T extends Object> {
  const NitroWireCodec();

  /// Number of bytes this optional type occupies on the wire, including the
  /// leading hasValue flag byte.
  int get encodedSize;

  /// Encodes [value] (possibly null) at [byteOffset]. Must write exactly
  /// [encodedSize] bytes ([out] is zeroed when freshly allocated, but a codec
  /// must not rely on that for the hasValue flag).
  void write(ByteData out, int byteOffset, T? value);

  /// Decodes from [byteOffset]. First byte is the hasValue flag.
  T? read(ByteData bytes, int byteOffset);

  /// Convenience: encodes into a fresh buffer of exactly [encodedSize] bytes.
  Uint8List encodeBytes(T? value) {
    final out = Uint8List(encodedSize);
    write(ByteData.sublistView(out), 0, value);
    return out;
  }

  /// Convenience: decodes a buffer produced by [encodeBytes] (or the bridge).
  T? decodeBytes(Uint8List bytes, [int byteOffset = 0]) => read(ByteData.sublistView(bytes), byteOffset);
}

/// Built-in wire codec for `int?` — the byte layout of `NitroOptInt64`
/// (`[1B hasValue][8B int64 LE]`, packed).
class NitroIntWireCodec extends NitroWireCodec<int> {
  const NitroIntWireCodec();

  @override
  int get encodedSize => 9;

  @override
  void write(ByteData out, int byteOffset, int? value) {
    out.setUint8(byteOffset, value != null ? 1 : 0);
    setInt64LE(out, byteOffset + 1, value ?? 0);
  }

  @override
  int? read(ByteData bytes, int byteOffset) => bytes.getUint8(byteOffset) != 0 ? getInt64LE(bytes, byteOffset + 1) : null;
}

/// Built-in wire codec for `double?` — the byte layout of `NitroOptFloat64`
/// (`[1B hasValue][8B float64 LE]`, packed).
class NitroDoubleWireCodec extends NitroWireCodec<double> {
  const NitroDoubleWireCodec();

  @override
  int get encodedSize => 9;

  @override
  void write(ByteData out, int byteOffset, double? value) {
    out.setUint8(byteOffset, value != null ? 1 : 0);
    out.setFloat64(byteOffset + 1, value ?? 0.0, Endian.little);
  }

  @override
  double? read(ByteData bytes, int byteOffset) => bytes.getUint8(byteOffset) != 0 ? bytes.getFloat64(byteOffset + 1, Endian.little) : null;
}

/// Built-in wire codec for `bool?` — the byte layout of `NitroOptBool`
/// (`[1B hasValue][1B value]`, packed).
class NitroBoolWireCodec extends NitroWireCodec<bool> {
  const NitroBoolWireCodec();

  @override
  int get encodedSize => 2;

  @override
  void write(ByteData out, int byteOffset, bool? value) {
    out.setUint8(byteOffset, value != null ? 1 : 0);
    out.setUint8(byteOffset + 1, value == true ? 1 : 0);
  }

  @override
  bool? read(ByteData bytes, int byteOffset) => bytes.getUint8(byteOffset) != 0 ? bytes.getUint8(byteOffset + 1) != 0 : null;
}
