import 'dart:ffi';
import 'package:ffi/ffi.dart';

/// A C-compatible struct for passing exception data over the FFI boundary.
///
/// Matches the C `NitroError` out-param struct written by generated bridges.
/// Native-only — on web the same struct is read from module linear memory at
/// its wasm32 layout (see `web/nitro_error_web.dart`).
final class NitroErrorFfi extends Struct {
  @Int8()
  external int hasError;

  external Pointer<Utf8> name;
  external Pointer<Utf8> message;
  external Pointer<Utf8> code;
  external Pointer<Utf8> stackTrace;
}
