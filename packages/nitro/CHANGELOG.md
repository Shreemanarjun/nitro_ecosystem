## 0.2.0

- **New: `RecordWriter` and `RecordReader` binary codec** — compact little-endian binary protocol for `@HybridRecord` types. Eliminates JSON text serialization in favour of sequential field reads/writes over a raw `uint8_t*` buffer.
  - Wire format: `int64` (8 B), `float64` (8 B), `bool` (1 B), `String` (4-byte length + UTF-8), nullable (1-byte null tag + value), `list` (4-byte count + elements).
  - `RecordWriter.encodeList` / `encodePrimitiveList` for `List<@HybridRecord T>` and `List<primitive>`.
  - `RecordReader.decodeList` / `decodePrimitiveList` as counterparts.
  - All classes exported from `package:nitro/nitro.dart`.
- **`dart:convert` re-export retained** — `jsonEncode` / `jsonDecode` remain available for `Map<String, T>` bridges which still use the JSON text path.

## 0.1.0

- Initial release of Nitro runtime.
- Support for `HybridObject`, `HybridStruct`, and `HybridEnum`.
- Support for synchronous and asynchronous bridge calls.
- Unified FFI bridge support for Android and iOS.
