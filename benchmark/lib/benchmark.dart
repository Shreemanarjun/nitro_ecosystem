// On native (iOS/Android/macOS/Windows/Linux): use the FFI-backed Nitro
// implementations compiled from the .native.dart specs.
//
// On web: use the pure-Dart stubs in benchmark_web.dart — no dart:ffi, no
// native bridge. Web results represent pure Dart dispatch overhead and serve
// as a baseline comparison against native bridge numbers.
export 'src/benchmark_cpp.native.dart'
    if (dart.library.js_interop) 'src/benchmark_web.dart';
export 'src/benchmark.native.dart'
    if (dart.library.js_interop) 'src/benchmark_web.dart'
    show Benchmark;
