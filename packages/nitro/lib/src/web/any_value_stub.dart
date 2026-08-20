/// Web twin of `nitro_any_value_ffi.dart`.
///
/// `NitroAnyValue`/`NitroAnyMap` themselves are pure Dart and exported
/// unconditionally. The pointer codec (`nitroAnyMapFromNative` / `toNative`)
/// is native-only; the web bridge frames `NitroAnyMap.writeTo` /
/// `NitroAnyMap.readFrom` through the module heap instead.
library;
