# nitro_annotations

[![Pub Version](https://img.shields.io/pub/v/nitro_annotations)](https://pub.dev/packages/nitro_annotations)

A pure-Dart package containing the core annotations and enums for the **Nitro Modules** (Nitrogen) ecosystem.

This package is designed to be lightweight and has **zero dependencies**, ensuring it is compatible with all platforms (Flutter, Dart Server, CLI) and can be used in your speculative `.native.dart` definitions without pulling in the full `nitro` runtime or any Flutter-specific constraints.

## Usage

Annotations from this package are used by `nitro_generator` to generate high-performance FFI bridges between Dart and native code (C++, Swift, or Kotlin).

### Key Annotations

- **`@NitroModule`**: Marks a class as a native module.
- **`@HybridStruct`**: Generates high-performance FFI structs for hot-path data transfer.
- **`@HybridRecord`**: Generates JSON-coded classes for complex, infrequent data transfer.
- **`@nitroAsync`**: Offloads synchronous native calls to a background isolate pool.
- **`@NitroStream`**: Configures high-performance native-to-Dart event streams with built-in backpressure strategies (e.g., `Backpressure.dropLatest`).

## Integration

If you are building a plugin using Nitro, you should typically depend on `package:nitro` (the runtime), which re-exports everything in this package for convenience. 

However, if you are building metadata-based tools or generators (like `nitro_generator`), you should depend directly on `nitro_annotations` to keep your project cross-platform and minimize transitive dependencies.

---

For more details on the Nitro ecosystem, visit [The Nitrogen Repository](https://github.com/Shreemanarjun/nitro_ecosystem).
