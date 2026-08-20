/// Web twin of `nitro_nullable.dart`: the pure NitroNullable* value types.
///
/// The `NitroOpt*` packed structs and Arena pack extensions are native-only;
/// the web bridge encodes the same `[1B hasValue][N bytes]` layouts with the
/// `NitroIntWireCodec` / `NitroDoubleWireCodec` / `NitroBoolWireCodec` wire
/// codecs from `shared/nitro_wire_codec.dart`.
library;

export '../shared/nitro_nullable_core.dart';
