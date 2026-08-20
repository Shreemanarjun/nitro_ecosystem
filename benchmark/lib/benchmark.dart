// On native (iOS/Android/macOS/Windows/Linux): use the FFI-backed Nitro
// implementations compiled from the .native.dart specs.
//
// On web: use the pure-Dart stubs in benchmark_web.dart — no dart:ffi, no
// native bridge. Web results represent pure Dart dispatch overhead and serve
// as a baseline comparison against native bridge numbers.
// benchmark_cpp targets web (NativeImpl.wasm) — the real spec + generated
// bridges compile on every platform; the platform shim routes the factory.
export 'src/benchmark_cpp.native.dart';
export 'src/benchmark_cpp.platform.g.dart';
// The Benchmark (Kotlin/Swift) module does not target web — pure-Dart stub.
export 'src/benchmark.native.dart'
    if (dart.library.js_interop) 'src/benchmark_web.dart'
    show Benchmark;
