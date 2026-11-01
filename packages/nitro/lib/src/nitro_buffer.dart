import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'ffi_utils.dart';

/// A reusable buffer in native memory for data Dart produces and hands to
/// native every frame — a serialized overlay, a resized frame, an audio block.
///
/// Write into [bytes] (or a [view]) and pass that same list to a `@zeroCopy`
/// parameter: it crosses the bridge as a pointer with no copy, on every
/// platform and bridge path. A plain `Uint8List(n)` is copied instead (about
/// 0.1 ms for a 4 MB frame) because the Dart heap moves; this memory doesn't.
///
/// Views are borrowed: valid while this buffer is alive and un-disposed and
/// until a growing [ensureCapacity]. Keep the buffer and reuse it across
/// frames. [dispose] frees eagerly; otherwise a finalizer frees the memory
/// when the buffer is garbage-collected.
final class NitroBuffer implements Finalizable {
  NitroBuffer(int capacity)
    : _capacity = capacity,
      _ptr = malloc<Uint8>(capacity) {
    _finalizer.attach(this, _ptr.cast(), detach: this);
    _bytes = nitroRegisterZeroCopyView(_ptr.asTypedList(capacity), _ptr.cast());
  }

  static final _finalizer = NativeFinalizer(malloc.nativeFree);

  Pointer<Uint8> _ptr;
  int _capacity;
  late Uint8List _bytes;
  bool _disposed = false;

  int get capacity => _capacity;
  bool get isDisposed => _disposed;

  /// The native data pointer; valid until [dispose] or a growing [ensureCapacity].
  Pointer<Uint8> get pointer {
    _check();
    return _ptr;
  }

  /// A registered view over the whole [capacity] — the same object every call.
  Uint8List get bytes {
    _check();
    return _bytes;
  }

  /// A registered view over the first [length] bytes. Pass this when the
  /// payload is shorter than [capacity] so native receives the right length.
  Uint8List view(int length) {
    _check();
    RangeError.checkValueInInterval(length, 0, _capacity, 'length');
    return nitroRegisterZeroCopyView(_ptr.asTypedList(length), _ptr.cast());
  }

  /// Grows to at least [minCapacity], preserving contents. Views taken before
  /// are invalid afterwards — take fresh ones from [bytes] / [view].
  void ensureCapacity(int minCapacity) {
    _check();
    if (minCapacity <= _capacity) return;
    final next = malloc<Uint8>(minCapacity);
    next.asTypedList(_capacity).setAll(0, _ptr.asTypedList(_capacity));
    _release();
    _ptr = next;
    _capacity = minCapacity;
    _finalizer.attach(this, _ptr.cast(), detach: this);
    _bytes = nitroRegisterZeroCopyView(_ptr.asTypedList(minCapacity), _ptr.cast());
  }

  /// Frees the native memory now. All views become invalid.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _release();
  }

  void _release() {
    nitroUnregisterZeroCopyView(_bytes);
    _finalizer.detach(this);
    malloc.free(_ptr);
  }

  void _check() {
    if (_disposed) throw StateError('NitroBuffer used after dispose()');
  }
}
