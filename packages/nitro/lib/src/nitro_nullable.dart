import 'dart:ffi';
import 'package:ffi/ffi.dart' show Arena;
import 'record_codec.dart';
import 'shared/nitro_nullable_core.dart';

export 'shared/nitro_nullable_core.dart';

// ── Native (dart:ffi) edges for the NitroNullable* value types ────────────────
//
// The pure classes live in shared/nitro_nullable_core.dart so they exist on
// web too; this file adds the pointer codecs used by generated FFI bridges.

/// Decodes a [NitroNullableInt] from the framed buffer produced by
/// `toNative` / a native bridge.
NitroNullableInt nitroNullableIntFromNative(Pointer<Uint8> ptr) => NitroNullableInt.fromReader(RecordReader.fromNative(ptr));

/// Decodes a [NitroNullableDouble] from a framed native buffer.
NitroNullableDouble nitroNullableDoubleFromNative(Pointer<Uint8> ptr) => NitroNullableDouble.fromReader(RecordReader.fromNative(ptr));

/// Decodes a [NitroNullableBool] from a framed native buffer.
NitroNullableBool nitroNullableBoolFromNative(Pointer<Uint8> ptr) => NitroNullableBool.fromReader(RecordReader.fromNative(ptr));

extension NitroNullableIntNative on NitroNullableInt {
  Pointer<Uint8> toNative(Allocator alloc) {
    final w = RecordWriter();
    writeFields(w);
    return w.toNative(alloc);
  }
}

extension NitroNullableDoubleNative on NitroNullableDouble {
  Pointer<Uint8> toNative(Allocator alloc) {
    final w = RecordWriter();
    writeFields(w);
    return w.toNative(alloc);
  }
}

extension NitroNullableBoolNative on NitroNullableBool {
  Pointer<Uint8> toNative(Allocator alloc) {
    final w = RecordWriter();
    writeFields(w);
    return w.toNative(alloc);
  }
}

// ── NitroOpt* — packed C-ABI structs for nullable primitive bridge transport ──
//
// Wire format: [1B hasValue][N bytes value] — NO RecordWriter 4-byte prefix.
// Fixed-size types don't need a length prefix; the struct size is constant.
//
// @Packed(1) eliminates inter-field padding so the layout matches the C struct:
//   typedef struct { uint8_t hasValue; int64_t value; } NitroOptInt64;
//
// These are used in GENERATED bridge code for `int?`, `double?`, `bool?`
// param and return transport. Dart FFI uses Pointer<NitroOptXxx> instead of
// Pointer<Uint8>, giving field-name access and self-documenting C signatures.

@Packed(1)
base class NitroOptInt64 extends Struct {
  /// 1 = value present, 0 = null.
  @Uint8()
  external int hasValue;

  /// int64 payload; meaningful only when hasValue != 0.
  @Int64()
  external int value;
}

@Packed(1)
base class NitroOptFloat64 extends Struct {
  @Uint8()
  external int hasValue;
  @Double()
  external double value;
}

@Packed(1)
base class NitroOptBool extends Struct {
  @Uint8()
  external int hasValue;
  @Uint8()
  external int value;
}

// ── Value-type decode extensions (for sync struct-by-value returns) ───────────

extension NitroOptInt64Decode on NitroOptInt64 {
  int? get decoded => hasValue != 0 ? value : null;
}

extension NitroOptFloat64Decode on NitroOptFloat64 {
  double? get decoded => hasValue != 0 ? value : null;
}

extension NitroOptBoolDecode on NitroOptBool {
  bool? get decoded => hasValue != 0 ? value != 0 : null;
}

// ── Pointer decode extensions (for async / NativeAsync pointer returns) ───────

extension NitroOptInt64Pointer on Pointer<NitroOptInt64> {
  /// Unwraps the struct to a Dart `int?`. `.decoded` is the canonical name;
  /// `.nullable` is kept for backward compatibility.
  int? get decoded => ref.hasValue != 0 ? ref.value : null;
  int? get nullable => decoded;
}

extension NitroOptFloat64Pointer on Pointer<NitroOptFloat64> {
  double? get decoded => ref.hasValue != 0 ? ref.value : null;
  double? get nullable => decoded;
}

extension NitroOptBoolPointer on Pointer<NitroOptBool> {
  bool? get decoded => ref.hasValue != 0 ? ref.value != 0 : null;
  bool? get nullable => decoded;
}

// ── Arena extension for encoding nullable primitives into NitroOpt* structs ───
//
// Scoped to Arena (not Allocator) to avoid polluting every allocator in user
// code. Mirrors the pattern: alloc.packInt(v) → Pointer<NitroOptInt64>.

extension NitroOptArena on Arena {
  Pointer<NitroOptInt64> packInt(int? v) {
    final p = this<NitroOptInt64>();
    p.ref.hasValue = v != null ? 1 : 0;
    p.ref.value = v ?? 0;
    return p;
  }

  Pointer<NitroOptFloat64> packDouble(double? v) {
    final p = this<NitroOptFloat64>();
    p.ref.hasValue = v != null ? 1 : 0;
    p.ref.value = v ?? 0.0;
    return p;
  }

  Pointer<NitroOptBool> packBool(bool? v) {
    final p = this<NitroOptBool>();
    p.ref.hasValue = v != null ? 1 : 0;
    p.ref.value = v == true ? 1 : 0;
    return p;
  }
}
