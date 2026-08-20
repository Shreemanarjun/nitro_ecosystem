import 'dart:typed_data';

import 'nitro_wasm_module.dart';

/// Scoped allocator over a WASM module heap — the web analog of package:ffi's
/// `Arena`. Every allocation is freed when the scope exits.
final class WasmArena {
  final NitroWasmModule module;
  final List<int> _allocations = [];
  bool _released = false;

  WasmArena(this.module);

  /// Allocates [byteCount] bytes of scratch heap, freed on [releaseAll].
  int alloc(int byteCount) {
    if (_released) throw StateError('WasmArena already released');
    final p = module.malloc(byteCount);
    _allocations.add(p);
    return p;
  }

  /// Copies [bytes] into a fresh arena allocation and returns its offset.
  int copyIn(Uint8List bytes) {
    final p = alloc(bytes.isEmpty ? 1 : bytes.length);
    module.writeBytes(p, bytes);
    return p;
  }

  /// Encodes [s] as a NUL-terminated C string in the arena.
  int cString(String s) => copyIn(NitroWasmModule.encodeCString(s));

  /// Frees every allocation. Idempotent.
  void releaseAll() {
    if (_released) return;
    _released = true;
    for (final p in _allocations) {
      module.free(p);
    }
    _allocations.clear();
  }
}

/// Runs [action] with a scoped [WasmArena] over [module], freeing all arena
/// allocations afterwards — the web analog of `withArena`/`using`.
T withWasmArena<T>(NitroWasmModule module, T Function(WasmArena arena) action) {
  final arena = WasmArena(module);
  try {
    return action(arena);
  } finally {
    arena.releaseAll();
  }
}

// ── ZeroCopy buffers (web) ────────────────────────────────────────────────────
//
// Same class names and getters as the native zero-copy buffers, different
// semantics: the data is copied out of the module heap ONCE at construction
// (a live view would detach on memory growth, and `.toDart` copies under
// dart2wasm anyway), then the native allocation is released eagerly.
// `release()` stays for API parity and is a no-op after construction.

abstract class _WebZeroCopyBase {
  bool _released = false;

  /// API parity with the native buffers; the native allocation was already
  /// returned at construction, so this only flips the guard.
  void release() => _released = true;

  void _assertNotReleased() {
    if (_released) throw StateError('ZeroCopyBuffer already released');
  }
}

/// Buffer of `uint8_t` — maps to [Uint8List]. Web: one bulk copy at creation.
class ZeroCopyBuffer extends _WebZeroCopyBase {
  final Uint8List _snapshot;
  final int length;

  ZeroCopyBuffer.fromSnapshot(this._snapshot) : length = _snapshot.length;

  Uint8List get bytes {
    _assertNotReleased();
    return _snapshot;
  }
}

/// Buffer of `int8_t` — maps to [Int8List].
class ZeroCopyInt8Buffer extends _WebZeroCopyBase {
  final Int8List _snapshot;
  final int length;

  ZeroCopyInt8Buffer.fromSnapshot(this._snapshot) : length = _snapshot.length;

  Int8List get values {
    _assertNotReleased();
    return _snapshot;
  }
}

/// Buffer of `int16_t` — maps to [Int16List].
class ZeroCopyInt16Buffer extends _WebZeroCopyBase {
  final Int16List _snapshot;
  final int length;

  ZeroCopyInt16Buffer.fromSnapshot(this._snapshot) : length = _snapshot.length;

  Int16List get values {
    _assertNotReleased();
    return _snapshot;
  }
}

/// Buffer of `uint16_t` — maps to [Uint16List].
class ZeroCopyUint16Buffer extends _WebZeroCopyBase {
  final Uint16List _snapshot;
  final int length;

  ZeroCopyUint16Buffer.fromSnapshot(this._snapshot) : length = _snapshot.length;

  Uint16List get values {
    _assertNotReleased();
    return _snapshot;
  }
}

/// Buffer of `int32_t` — maps to [Int32List].
class ZeroCopyInt32Buffer extends _WebZeroCopyBase {
  final Int32List _snapshot;
  final int length;

  ZeroCopyInt32Buffer.fromSnapshot(this._snapshot) : length = _snapshot.length;

  Int32List get values {
    _assertNotReleased();
    return _snapshot;
  }
}

/// Buffer of `uint32_t` — maps to [Uint32List].
class ZeroCopyUint32Buffer extends _WebZeroCopyBase {
  final Uint32List _snapshot;
  final int length;

  ZeroCopyUint32Buffer.fromSnapshot(this._snapshot) : length = _snapshot.length;

  Uint32List get values {
    _assertNotReleased();
    return _snapshot;
  }
}

/// Buffer of `float` — maps to [Float32List].
class ZeroCopyFloat32Buffer extends _WebZeroCopyBase {
  final Float32List _snapshot;
  final int length;

  ZeroCopyFloat32Buffer.fromSnapshot(this._snapshot) : length = _snapshot.length;

  Float32List get floats {
    _assertNotReleased();
    return _snapshot;
  }
}

/// Buffer of `double` — maps to [Float64List].
class ZeroCopyFloat64Buffer extends _WebZeroCopyBase {
  final Float64List _snapshot;
  final int length;

  ZeroCopyFloat64Buffer.fromSnapshot(this._snapshot) : length = _snapshot.length;

  Float64List get doubles {
    _assertNotReleased();
    return _snapshot;
  }
}

/// Buffer of `int64_t` — maps to [Int64List].
class ZeroCopyInt64Buffer extends _WebZeroCopyBase {
  final Int64List _snapshot;
  final int length;

  ZeroCopyInt64Buffer.fromSnapshot(this._snapshot) : length = _snapshot.length;

  Int64List get values {
    _assertNotReleased();
    return _snapshot;
  }
}
