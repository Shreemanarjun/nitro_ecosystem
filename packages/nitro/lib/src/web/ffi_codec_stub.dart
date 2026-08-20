/// Web twin of `nitro_ffi_codec.dart`.
///
/// `NitroFfiCodec<T>` speaks `Pointer<Uint8>` and is native-only. Custom types
/// on web use the platform-neutral `NitroWireCodec<T>` from
/// `shared/nitro_wire_codec.dart` (exported unconditionally by the barrel).
library;
