/// Canonical [buildExtensions] map for [NitroGeneratorBuilder].
///
/// Extracted into a standalone file so that tests can import just this map
/// without transitively pulling in `source_gen` (which imports `dart:mirrors`)
/// — a library that is unavailable in the Flutter test runner.
const Map<String, List<String>> nitroBuilderExtensions = {
  '^lib/{{dir}}/{{file}}.native.dart': [
    'lib/{{dir}}/{{file}}.g.dart',
    'lib/{{dir}}/generated/kotlin/{{file}}.bridge.g.kt',
    'lib/{{dir}}/generated/swift/{{file}}.bridge.g.swift',
    'lib/{{dir}}/generated/cpp/{{file}}.bridge.g.h',
    'lib/{{dir}}/generated/cpp/{{file}}.bridge.g.cpp',
    'lib/{{dir}}/generated/cmake/{{file}}.CMakeLists.g.txt',
    // NativeImpl.cpp — direct C++ implementation support
    'lib/{{dir}}/generated/cpp/{{file}}.native.g.h',
    'lib/{{dir}}/generated/cpp/{{file}}.impl.g.cpp',
    'lib/{{dir}}/generated/cpp/test/{{file}}.mock.g.h',
    'lib/{{dir}}/generated/cpp/test/{{file}}.test.g.cpp',
    // PX18: NativeImpl.wasm — dart:js_interop bridge for web targets
    'lib/{{dir}}/generated/web/{{file}}.web.bridge.g.dart',
    // 0.7.0 web split: for web-targeting specs the dart:ffi implementation
    // moves out of the part into a standalone native-only library, reached
    // through a conditional-export platform shim.
    'lib/{{dir}}/generated/native/{{file}}.ffi.g.dart',
    'lib/{{dir}}/{{file}}.platform.g.dart',
  ],
};
