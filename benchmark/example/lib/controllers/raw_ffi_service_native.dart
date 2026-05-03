// Native implementation — loaded when dart.library.io is present.
// Wraps dart:ffi DynamicLibrary operations so the controllers themselves
// never import dart:ffi directly, allowing the same controller source to
// compile on web (where the web stub above is used instead).

import 'dart:typed_data';
import 'package:nitro/nitro.dart';

class RawFfiService {
  static final RawFfiService instance = RawFfiService._();
  RawFfiService._() {
    _initBenchmark();
    _initBenchmarkCpp();
  }

  // ── benchmark lib (Swift/Kotlin bridge tests) ─────────────────────────────

  DynamicLibrary? _benchDylib;
  double Function(double, double)? _benchRawAdd;

  void _initBenchmark() {
    try {
      _benchDylib = NitroRuntime.loadLib('benchmark');
      _benchRawAdd = _benchDylib!
          .lookup<NativeFunction<Double Function(Double, Double)>>('add_double')
          .asFunction<double Function(double, double)>();
    } catch (_) {}
  }

  // ── benchmark_cpp lib (direct C++ tests) ─────────────────────────────────

  DynamicLibrary? _cppDylib;
  double Function(double, double)? _cppRawAdd;
  int Function(Pointer<Uint8>, int)? _sendBuffer;
  int Function(Pointer<Uint8>, int)? _sendBufferNoop;

  void _initBenchmarkCpp() {
    try {
      _cppDylib = NitroRuntime.loadLib('benchmark_cpp');
      _cppRawAdd = _cppDylib!
          .lookupFunction<Double Function(Double, Double), double Function(double, double)>(
              'add_double');
      try {
        _sendBuffer = _cppDylib!.lookupFunction<
            Int64 Function(Pointer<Uint8>, Int64),
            int Function(Pointer<Uint8>, int)>('send_large_buffer');
      } catch (_) {}
      try {
        _sendBufferNoop = _cppDylib!.lookupFunction<
            Int64 Function(Pointer<Uint8>, Int64),
            int Function(Pointer<Uint8>, int)>('send_large_buffer_noop');
      } catch (_) {}
    } catch (_) {}
  }

  // ── Public API ────────────────────────────────────────────────────────────

  bool get isAvailable => _benchRawAdd != null || _cppRawAdd != null;

  double rawAdd(double a, double b) => _benchRawAdd?.call(a, b) ?? a + b;

  double rawAddCpp(double a, double b) => _cppRawAdd?.call(a, b) ?? a + b;

  int sendBuffer(Uint8List buffer) {
    final fn = _sendBuffer;
    if (fn == null) return 0;
    return withArena((arena) => fn(buffer.toPointer(arena), buffer.length));
  }

  int sendBufferNoop(Uint8List buffer) {
    final fn = _sendBufferNoop;
    if (fn == null) return 0;
    return withArena((arena) => fn(buffer.toPointer(arena), buffer.length));
  }

  /// Allocates a native buffer of [byteSize] bytes and passes it to the
  /// noop send function — measures dispatch + pinning cost without memcpy.
  int sendBufferUnsafe(int byteSize) {
    final fn = _sendBufferNoop;
    if (fn == null) return 0;
    final ptr = malloc<Uint8>(byteSize);
    try {
      return fn(ptr, byteSize);
    } finally {
      malloc.free(ptr);
    }
  }
}
