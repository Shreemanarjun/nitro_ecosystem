import 'dart:typed_data';

/// Web twin of `NitroBuffer`: there is no native memory, so [bytes] is a plain
/// heap list and the web bridge copies it into the WASM heap like any other
/// list. Same API, so app code that builds frames into a buffer stays portable.
final class NitroBuffer {
  NitroBuffer(int capacity) : _bytes = Uint8List(capacity);

  Uint8List _bytes;
  bool _disposed = false;

  int get capacity => _bytes.length;
  bool get isDisposed => _disposed;

  Uint8List get bytes {
    _check();
    return _bytes;
  }

  Uint8List view(int length) {
    _check();
    RangeError.checkValueInInterval(length, 0, _bytes.length, 'length');
    return Uint8List.sublistView(_bytes, 0, length);
  }

  void ensureCapacity(int minCapacity) {
    _check();
    if (minCapacity <= _bytes.length) return;
    _bytes = Uint8List(minCapacity)..setAll(0, _bytes);
  }

  void dispose() => _disposed = true;

  void _check() {
    if (_disposed) throw StateError('NitroBuffer used after dispose()');
  }
}
