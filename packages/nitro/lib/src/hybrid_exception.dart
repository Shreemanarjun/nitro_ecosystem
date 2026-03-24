import 'dart:ffi';
import 'package:ffi/ffi.dart';

/// Represents a native exception propagated from Kotlin, Swift, or C++.
class HybridException implements Exception {
  /// The type or name of the exception (e.g. 'java.lang.RuntimeException').
  final String name;

  /// The human-readable error message.
  final String message;

  /// An optional machine-readable error code (e.g. 'CAMERA_NOT_FOUND').
  final String? code;

  /// The native stack trace if available.
  final String? stackTrace;

  const HybridException({
    required this.name,
    required this.message,
    this.code,
    this.stackTrace,
  });

  @override
  String toString() {
    final sb = StringBuffer('HybridException: $name: $message');
    if (code != null) sb.write(' (Code: $code)');
    if (stackTrace != null) {
      sb.writeln();
      sb.write('Native StackTrace:\n$stackTrace');
    }
    return sb.toString();
  }
}

/// A C-compatible struct for passing exception data over the FFI boundary.
final class NitroErrorFfi extends Struct {
  @Int8()
  external int hasError;

  external Pointer<Utf8> name;
  external Pointer<Utf8> message;
  external Pointer<Utf8> code;
  external Pointer<Utf8> stackTrace;
}
