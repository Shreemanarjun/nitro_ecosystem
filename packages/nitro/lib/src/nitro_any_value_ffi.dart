import 'dart:ffi';

import 'nitro_any_value.dart';
import 'record_codec.dart';

// ── Native (dart:ffi) edge for NitroAnyMap ────────────────────────────────────
//
// The NitroAnyValue/NitroAnyMap types are pure Dart (shared with web); this
// file adds the pointer codec used by generated FFI bridges.

/// Decode a [NitroAnyMap] from a native pointer produced by [NitroAnyMapNative.toNative]
/// or the C bridge.
///
/// Wire: RecordWriter outer 4B length prefix + map entries.
/// Does NOT free [ptr] — caller is responsible.
NitroAnyMap nitroAnyMapFromNative(Pointer<Uint8> ptr) => NitroAnyMap.readFrom(RecordReader.fromNative(ptr));

extension NitroAnyMapNative on NitroAnyMap {
  /// Encode this map to a native buffer wrapped in the RecordWriter 4B envelope.
  ///
  /// The returned pointer is owned by [alloc] and must not be freed separately
  /// when using an Arena (the Arena frees it on scope exit).
  Pointer<Uint8> toNative(Allocator alloc) {
    final w = RecordWriter();
    writeTo(w);
    return w.toNative(alloc);
  }
}
