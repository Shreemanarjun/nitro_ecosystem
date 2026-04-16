// Web stub — no dart:ffi available on web.
// All methods return pure-Dart computed values so the benchmark UI still
// runs and shows "pure Dart" numbers for the Raw FFI bridge slot.
//
// Conditionally imported by the controllers via:
//   import 'raw_ffi_service.dart' if (dart.library.io) 'raw_ffi_service_native.dart';

import 'dart:typed_data';

class RawFfiService {
  static final RawFfiService instance = RawFfiService._();
  RawFfiService._();

  /// False on web — no native library can be loaded.
  bool get isAvailable => false;

  /// Pure Dart add — measures Dart function-call overhead with no bridge.
  double rawAdd(double a, double b) => a + b;

  /// Same lib but loaded from benchmark_cpp on native; same pure Dart on web.
  double rawAddCpp(double a, double b) => a + b;

  /// Stride-walk the buffer — mirrors the native checksum implementation.
  int sendBuffer(Uint8List buffer) {
    var sum = 0;
    for (var i = 0; i < buffer.length; i += 4096) sum += buffer[i];
    return sum;
  }

  /// Noop variant — returns length without touching contents.
  int sendBufferNoop(Uint8List buffer) => buffer.length;

  /// Unsafe variant (no real pointer on web) — returns 0.
  int sendBufferUnsafe(int byteSize) => 0;
}
