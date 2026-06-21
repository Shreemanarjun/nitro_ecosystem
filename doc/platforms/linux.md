# Linux Build Guide

Nitro supports Linux via `NativeImpl.cpp` — your module is compiled as a shared `.so` and loaded via `DynamicLibrary.open`.

## Prerequisites

| Tool | Minimum version | How to install |
|---|---|---|
| GCC or Clang | GCC 9+ / Clang 10+ | `apt install build-essential` / `apt install clang` |
| CMake | 3.14+ | `apt install cmake` |
| Flutter | 3.22+ stable | flutter.dev |
| Dart SDK | 3.4+ | bundled with Flutter |
| GTK3 dev headers | any | `apt install libgtk-3-dev` (required by Flutter Linux shell) |

Verify:
```bash
g++ --version     # or clang++ --version
cmake --version
flutter doctor
```

## Spec file

```dart
@NitroModule(
  ios:     AppleNativeImpl.swift,
  android: AndroidNativeImpl.kotlin,
  linux:   LinuxNativeImpl.cpp,   // ← add this
)
abstract class MyModule extends HybridObject {
  double compute(double x, double y);
}
```

## Generate bridges

```bash
dart run nitrogen_cli generate
dart run nitrogen_cli link
```

`nitrogen link` patches `linux/CMakeLists.txt`.

## CMake configuration

```cmake
cmake_minimum_required(VERSION 3.14)

set(NITRO_NATIVE "${CMAKE_CURRENT_SOURCE_DIR}/../src/native")
set(GENERATED_CPP "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp")

add_library(my_module SHARED
  "${CMAKE_CURRENT_SOURCE_DIR}/my_module.cpp"
  "${GENERATED_CPP}/my_module.bridge.g.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/../src/dart_api_dl.c"
)

target_include_directories(my_module PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${GENERATED_CPP}"
  "${NITRO_NATIVE}"
)

# Linux: link against libdl (for dlopen) and pthreads.
target_link_libraries(my_module PRIVATE dl pthread)

target_compile_definitions(my_module PUBLIC DART_SHARED_LIB)
set_property(TARGET my_module PROPERTY CXX_STANDARD 17)
```

## Auto-registration

On Linux (GCC/Clang), Nitro uses `__attribute__((constructor))`:

```cpp
// Generated in HybridMyModule.cpp:
__attribute__((constructor))
static void nitro_auto_register() {
    my_module_register_impl(&g_impl);
}
```

This runs automatically when the `.so` is loaded via `DynamicLibrary.open`.

## DynamicLibrary loading

```dart
// Generated in my_module.g.dart:
static DynamicLibrary _loadSupportedLibrary() {
  return NitroRuntime.loadLibForTargets(
    'my_module',
    ios: true, android: true, macos: true,
    windows: true, linux: true,   // ← enabled
    web: false,
  );
}
```

On Linux, this calls `DynamicLibrary.open('libmy_module.so')`.

## Building and running

```bash
flutter run -d linux
# or
flutter build linux
```

## Platform guards in the generated bridge

When only Linux is targeted with C++, the bridge emits a platform guard:

```cpp
#ifdef __linux__
// ... Linux-specific bridge code ...
#endif
```

When both Windows and Linux are targeted:

```cpp
#if defined(_WIN32) || defined(__linux__)
// ... shared desktop bridge code ...
#endif
```

## `nitrogen doctor` checks (Linux)

```
nitrogen doctor

  ✓ Dart 3.4.0
  ✓ Flutter 3.22.0
  ✓ g++ 11.4.0 found at /usr/bin/g++
  ✓ cmake 3.22.1 found at /usr/bin/cmake
  ⚠ ANDROID_NDK_HOME not set — Android targets will fail
  ✓ GTK3 dev headers found
```

## Troubleshooting

**`DynamicLibrary.open` fails: `libmy_module.so: cannot open shared object file`**
→ The `.so` is not on `LD_LIBRARY_PATH`. Flutter handles this automatically; for manual testing, prepend the build output dir: `LD_LIBRARY_PATH=build/linux/x64/release/bundle/lib ./my_app`.

**`undefined reference to 'pthread_create'`**
→ Add `-lpthread` to `target_link_libraries` (shown above).

**`error: 'std::make_unique' is not a member of 'std'` (GCC < 9)**
→ Upgrade to GCC 9+ or add `-std=c++17` to `CMAKE_CXX_FLAGS`.
