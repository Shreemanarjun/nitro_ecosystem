import 'dart:ffi';
import 'package:ffi/ffi.dart' show Arena;
import 'nitro_nullable.dart';

/// Codec for a type [T] that can be transported across the C FFI bridge as an
/// optional value. This is the Dart/FFI equivalent of RN Nitro's
/// `JSIConverter<std::optional<T>>`.
///
/// Built-in codecs: [NitroIntCodec], [NitroDoubleCodec], [NitroBoolCodec].
///
/// Example custom codec:
/// ```dart
/// class ColorCodec extends NitroFfiCodec<Color> {
///   const ColorCodec();
///   @override int get encodedSize => 5;   // 1B flag + 4B RGBA
///
///   @override Pointer<Uint8> encode(Color? v, Arena alloc) {
///     final ptr = alloc<Uint8>(5);
///     ptr[0] = v != null ? 1 : 0;
///     if (v != null) { ptr[1] = v.r; ptr[2] = v.g; ptr[3] = v.b; ptr[4] = v.a; }
///     return ptr;
///   }
///
///   @override Color? decode(Pointer<Uint8> ptr) {
///     if (ptr[0] == 0) return null;
///     return Color(ptr[1], ptr[2], ptr[3], ptr[4]);
///   }
/// }
/// ```
abstract class NitroFfiCodec<T extends Object> {
  const NitroFfiCodec();

  /// Number of bytes this optional type occupies in native memory.
  int get encodedSize;

  /// Encode [value] (possibly null) into Arena-allocated native memory.
  /// Returns a pointer valid for the lifetime of [alloc].
  Pointer<Uint8> encode(T? value, Arena alloc);

  /// Decode from native memory. First byte is the hasValue flag.
  /// Does NOT free the pointer — caller is responsible.
  T? decode(Pointer<Uint8> ptr);
}

/// Built-in codec for [int?] — backed by [NitroOptInt64].
class NitroIntCodec extends NitroFfiCodec<int> {
  const NitroIntCodec();

  @override
  int get encodedSize => 9;

  @override
  Pointer<Uint8> encode(int? v, Arena alloc) => alloc.packInt(v).cast();

  @override
  int? decode(Pointer<Uint8> ptr) => ptr.cast<NitroOptInt64>().decoded;
}

/// Built-in codec for [double?] — backed by [NitroOptFloat64].
class NitroDoubleCodec extends NitroFfiCodec<double> {
  const NitroDoubleCodec();

  @override
  int get encodedSize => 9;

  @override
  Pointer<Uint8> encode(double? v, Arena alloc) => alloc.packDouble(v).cast();

  @override
  double? decode(Pointer<Uint8> ptr) => ptr.cast<NitroOptFloat64>().decoded;
}

/// Built-in codec for [bool?] — backed by [NitroOptBool].
class NitroBoolCodec extends NitroFfiCodec<bool> {
  const NitroBoolCodec();

  @override
  int get encodedSize => 2;

  @override
  Pointer<Uint8> encode(bool? v, Arena alloc) => alloc.packBool(v).cast();

  @override
  bool? decode(Pointer<Uint8> ptr) => ptr.cast<NitroOptBool>().decoded;
}
