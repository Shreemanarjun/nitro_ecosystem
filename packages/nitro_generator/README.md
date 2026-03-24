# nitro_generator

A high-performance code generator for **Nitro Modules** (Nitrogen). This package converts your Dart interface specifications into optimized native bindings for **Android (Kotlin/JNI)**, **iOS (Swift)**, and **C++**.

## Features

- **Performance-First**: Generates lean, zero-copy FFI bindings.
- **Cross-Platform**: Unified generation for Dart, Kotlin, Swift, and C++.
- **Type-Safe**: Maps Dart types to their native counterparts with strict validation.
- **Complex Types**: Supports `@HybridObject`, `@HybridStruct`, and `@HybridEnum`.
- **Async Support**: seamless `@nitroAsync` bridging for non-blocking native calls.
- **Streaming**: Robust `@NitroStream` support with configurable backpressure strategies.
- **Binary Records**: High-performance `@HybridRecord` support using a compact binary protocol, eliminating JSON serialization overhead.

## Usage

1. Define your native module interface in a `.native.dart` file.
2. Annotate your classes with `@HybridObject`, structs with `@HybridStruct`, etc.
3. Run the generator:

```bash
flutter pub run build_runner build
```

The generator will produce:
- `lib/src/generated/*.g.dart`: Dart FFI bindings.
- `android/src/main/kotlin/.../*.bridge.g.kt`: Kotlin JNI bridge.
- `ios/Classes/*.bridge.g.swift`: Swift bridge.
- `ios/Classes/*.bridge.g.mm`: Objective-C++ bridge (for exception safety).
- `src/*.bridge.g.h`: C++ headers.

## Documentation

For full documentation and getting started guides, visit [nitro.shreeman.dev](https://nitro.shreeman.dev).

## License

MIT
