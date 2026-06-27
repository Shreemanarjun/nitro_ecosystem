import 'dart:ffi';
import 'record_codec.dart';

// ── NitroNullable<T> — collision-free nullable primitive types ────────────────
//
// Standard nullable primitives (int?, double?, bool?) use sentinel values to
// signal null over the C bridge, which can collide with real values:
//   int?    → Int64.min sentinel  → the value Int64.min is unreachable
//   double? → NaN sentinel        → double.nan is unreachable
//   bool?   → -1 sentinel         → works but requires platform workarounds
//
// NitroNullable types eliminate ALL collisions by using a binary null flag:
//   Wire: [1B hasValue][nB value]   — null state is separate from value field
//
// The full value domain is preserved: NitroNullableInt can carry any int64,
// including -1, 0, Int64.min, and Int64.max, without ambiguity.
//
// Usage example:
//   // In your spec:
//   NitroNullableInt safeCount();          // no collision possible
//
//   // In Dart code:
//   final r = module.safeCount();
//   final dart = r.nullable;              // int?  — null or actual value
//   // Or create from Dart:
//   final arg = NitroNullableInt.fromNullable(-1); // works correctly

// ── NitroNullableInt ─────────────────────────────────────────────────────────

/// Collision-free nullable `int` for Nitro bridges.
///
/// Wire format (binary, as a [@HybridRecord]):
///   [1B: hasValue (bool)][8B: value (int64_le)]  = 9 bytes
///
/// Unlike `int?` (Int64.min sentinel), **every** int64 value is representable.
/// Null is encoded as `hasValue=false`; the `value` field is ignored when null.
///
/// ```dart
/// // In a spec:
/// NitroNullableInt getCount();          // no sentinel collision
///
/// // In Dart call sites:
/// final r = module.getCount();
/// final n = r.nullable;                // int? — idiomatic Dart
/// ```
class NitroNullableInt {
  final bool hasValue;
  final int value;

  const NitroNullableInt({required this.hasValue, required this.value});

  /// Wraps a Dart `int?` — null becomes `hasValue=false`.
  factory NitroNullableInt.fromNullable(int? v) => v == null
      ? const NitroNullableInt(hasValue: false, value: 0)
      : NitroNullableInt(hasValue: true, value: v);

  /// Null sentinel (hasValue=false).
  static const NitroNullableInt nullValue =
      NitroNullableInt(hasValue: false, value: 0);

  /// Unwraps to a Dart `int?`.
  int? get nullable => hasValue ? value : null;

  // ── @HybridRecord binary codec ────────────────────────────────────────────

  static NitroNullableInt fromNative(Pointer<Uint8> ptr) =>
      fromReader(RecordReader.fromNative(ptr));

  static NitroNullableInt fromReader(RecordReader r) =>
      NitroNullableInt(hasValue: r.readBool(), value: r.readInt());

  void writeFields(RecordWriter writer) {
    writer.writeBool(hasValue);
    writer.writeInt(value);
  }

  Pointer<Uint8> toNative(Allocator alloc) {
    final w = RecordWriter();
    writeFields(w);
    return w.toNative(alloc);
  }

  @override
  String toString() =>
      hasValue ? 'NitroNullableInt($value)' : 'NitroNullableInt(null)';

  @override
  bool operator ==(Object other) =>
      other is NitroNullableInt &&
      hasValue == other.hasValue &&
      value == other.value;

  @override
  int get hashCode => Object.hash(hasValue, value);
}

// ── NitroNullableDouble ──────────────────────────────────────────────────────

/// Collision-free nullable `double` for Nitro bridges.
///
/// Wire format:  [1B: hasValue (bool)][8B: value (float64_le)]  = 9 bytes
///
/// Unlike `double?` (NaN sentinel), **every** double value is representable —
/// including `double.nan`, `double.infinity`, `-double.infinity`, and `0.0`.
class NitroNullableDouble {
  final bool hasValue;
  final double value;

  const NitroNullableDouble({required this.hasValue, required this.value});

  factory NitroNullableDouble.fromNullable(double? v) => v == null
      ? const NitroNullableDouble(hasValue: false, value: 0.0)
      : NitroNullableDouble(hasValue: true, value: v);

  static const NitroNullableDouble nullValue =
      NitroNullableDouble(hasValue: false, value: 0.0);

  double? get nullable => hasValue ? value : null;

  static NitroNullableDouble fromNative(Pointer<Uint8> ptr) =>
      fromReader(RecordReader.fromNative(ptr));

  static NitroNullableDouble fromReader(RecordReader r) =>
      NitroNullableDouble(hasValue: r.readBool(), value: r.readDouble());

  void writeFields(RecordWriter writer) {
    writer.writeBool(hasValue);
    writer.writeDouble(value);
  }

  Pointer<Uint8> toNative(Allocator alloc) {
    final w = RecordWriter();
    writeFields(w);
    return w.toNative(alloc);
  }

  @override
  String toString() => hasValue
      ? 'NitroNullableDouble($value)'
      : 'NitroNullableDouble(null)';

  @override
  bool operator ==(Object other) =>
      other is NitroNullableDouble &&
      hasValue == other.hasValue &&
      value == other.value;

  @override
  int get hashCode => Object.hash(hasValue, value);
}

// ── NitroNullableBool ────────────────────────────────────────────────────────

/// Collision-free nullable `bool` for Nitro bridges.
///
/// Wire format:  [1B: hasValue (bool)][1B: value (bool)]  = 2 bytes
///
/// Unlike `bool?` (platform-specific -1/jboolean workarounds), this type
/// works identically on iOS, Android, and macOS with zero platform differences.
class NitroNullableBool {
  final bool hasValue;
  final bool value;

  const NitroNullableBool({required this.hasValue, required this.value});

  factory NitroNullableBool.fromNullable(bool? v) => v == null
      ? const NitroNullableBool(hasValue: false, value: false)
      : NitroNullableBool(hasValue: true, value: v);

  static const NitroNullableBool nullValue =
      NitroNullableBool(hasValue: false, value: false);

  bool? get nullable => hasValue ? value : null;

  static NitroNullableBool fromNative(Pointer<Uint8> ptr) =>
      fromReader(RecordReader.fromNative(ptr));

  static NitroNullableBool fromReader(RecordReader r) =>
      NitroNullableBool(hasValue: r.readBool(), value: r.readBool());

  void writeFields(RecordWriter writer) {
    writer.writeBool(hasValue);
    writer.writeBool(value);
  }

  Pointer<Uint8> toNative(Allocator alloc) {
    final w = RecordWriter();
    writeFields(w);
    return w.toNative(alloc);
  }

  @override
  String toString() =>
      hasValue ? 'NitroNullableBool($value)' : 'NitroNullableBool(null)';

  @override
  bool operator ==(Object other) =>
      other is NitroNullableBool &&
      hasValue == other.hasValue &&
      value == other.value;

  @override
  int get hashCode => Object.hash(hasValue, value);
}

// ── Extension helpers for ergonomic conversion ────────────────────────────────

extension IntNullableExt on int? {
  /// Wraps as [NitroNullableInt] for collision-free bridge transport.
  NitroNullableInt toNitroNullable() => NitroNullableInt.fromNullable(this);
}

extension DoubleNullableExt on double? {
  /// Wraps as [NitroNullableDouble] for collision-free bridge transport.
  NitroNullableDouble toNitroNullable() =>
      NitroNullableDouble.fromNullable(this);
}

extension BoolNullableExt on bool? {
  /// Wraps as [NitroNullableBool] for collision-free bridge transport.
  NitroNullableBool toNitroNullable() => NitroNullableBool.fromNullable(this);
}

extension NitroNullableIntExt on NitroNullableInt {
  /// Shorthand: `nitroVal.asInt` → `int?`
  int? get asInt => nullable;
}

extension NitroNullableDoubleExt on NitroNullableDouble {
  double? get asDouble => nullable;
}

extension NitroNullableBoolExt on NitroNullableBool {
  bool? get asBool => nullable;
}
