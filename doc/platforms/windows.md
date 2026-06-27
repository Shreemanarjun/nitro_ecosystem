# Windows Build Guide

Nitro supports Windows via `NativeImpl.cpp` — your module is compiled as a shared DLL and loaded via `DynamicLibrary.open`.

## Prerequisites

| Tool | Minimum version | How to install |
|---|---|---|
| MSVC (Visual C++) | 2019 or later | Visual Studio Build Tools |
| CMake | 3.14+ | `winget install Kitware.CMake` or bundled with VS |
| Flutter | 3.22+ stable | flutter.dev |
| Dart SDK | 3.4+ | bundled with Flutter |

Verify:
```powershell
cl /?          # MSVC
cmake --version
flutter doctor
```

## Spec file

```dart
@NitroModule(
  ios:     AppleNativeImpl.swift,
  android: AndroidNativeImpl.kotlin,
  windows: WindowsNativeImpl.cpp,   // ← add this
)
abstract class MyModule extends HybridObject {
  double compute(double x, double y);
}
```

## Generate bridges

```powershell
dart run nitrogen_cli generate
dart run nitrogen_cli link
```

`nitrogen link` patches `windows/CMakeLists.txt` to compile the generated bridge file.

## CMake configuration

After `nitrogen link`, your `windows/CMakeLists.txt` will contain:

```cmake
cmake_minimum_required(VERSION 3.14)

set(NITRO_NATIVE "${CMAKE_CURRENT_SOURCE_DIR}/../src/native")
set(GENERATED_CPP "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp")

add_library(my_module SHARED
  "${CMAKE_CURRENT_SOURCE_DIR}/my_module.cpp"     # your implementation
  "${GENERATED_CPP}/my_module.bridge.g.cpp"       # generated bridge
  "${CMAKE_CURRENT_SOURCE_DIR}/../src/dart_api_dl.c"
)

target_include_directories(my_module PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${GENERATED_CPP}"
  "${NITRO_NATIVE}"
)

# Windows-specific: no extra system libs needed beyond the CRT.
# MSVC links against the Universal CRT automatically.
target_compile_definitions(my_module PUBLIC DART_SHARED_LIB)
set_target_properties(my_module PROPERTIES
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON
)
```

## MSVC-safe registration stub

`__attribute__((constructor))` is a GCC/Clang extension unavailable on MSVC. Nitro generates a portable alternative for Windows:

```cpp
// Generated in HybridMyModule.cpp (NativeImpl.cpp path):
#if defined(_WIN32)
// MSVC: use a namespace-scope initializer instead of __attribute__((constructor))
static const int _nitro_reg = []() {
    my_module_register_impl(&g_impl);
    return 0;
}();
#else
__attribute__((constructor))
static void nitro_auto_register() {
    my_module_register_impl(&g_impl);
}
#endif
```

## `dart_api_dl.c` on Windows

MSVC requires C files to be compiled as C (not C++). `nitrogen link` emits:

```cmake
set_source_files_properties(
  "${CMAKE_CURRENT_SOURCE_DIR}/../src/dart_api_dl.c"
  PROPERTIES LANGUAGE C
)
```

without which MSVC may refuse to compile `dart_api_dl.c`.

## DynamicLibrary loading

On Windows, Nitro loads `my_module.dll`:

```dart
// Generated automatically in my_module.g.dart:
static DynamicLibrary _loadSupportedLibrary() {
  return NitroRuntime.loadLibForTargets(
    'my_module',
    ios: true, android: true, macos: true,
    windows: true,   // ← enabled
    linux: true, web: false,
  );
}
```

The runtime calls `DynamicLibrary.open('my_module.dll')` on Windows.

## Building and running

```powershell
flutter run -d windows
# or
flutter build windows
```

Flutter's CMake integration builds the DLL automatically as part of the build.

## `nitrogen doctor` checks (Windows)

```
nitrogen doctor

  ✓ Dart 3.4.0
  ✓ Flutter 3.22.0
  ✓ CMake 3.28 found at C:\Program Files\CMake\bin\cmake.exe
  ✓ MSVC 2022 (19.38) found
  ✓ WINDOWSSDKDIR = C:\Program Files (x86)\Windows Kits\10\
  ⚠ ANDROID_NDK_HOME not set — Android targets will fail
```

## Troubleshooting

**LNK2001: unresolved external symbol `Dart_InitializeApiDL`**
→ `dart_api_dl.c` is missing from the CMake target. Re-run `nitrogen link`.

**C2059: syntax error: `__attribute__`**
→ Your bridge was generated for GCC/Clang. Add `MSVC` to the platform list and regenerate.

**`DynamicLibrary.open` throws `OS Error: The specified module could not be found`**
→ The DLL build output directory is not on `PATH`. Flutter handles this automatically via `flutter run`; for manual testing, copy the DLL next to the EXE.
