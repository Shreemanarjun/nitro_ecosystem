## 0.1.8

- `nitrogen link`: fix Android/iOS build failure where `dart_api_dl.c` and `dart_api_dl.h` were not found when `nitro` is installed from pub.dev (e.g. via puro's pub cache) rather than a local monorepo path.
  - `link` now reads `.dart_tool/package_config.json` to resolve the actual installed `nitro` package path (absolute `file://` URI or relative URI).
  - Creates a local `src/dart_api_dl.c` forwarder (`#include "<resolved path>"`) so the Android CMake build never references a path outside the project directory.
  - `ios/Classes/dart_api_dl.c` now chains through `../../src/dart_api_dl.c`, giving both Android CMake and iOS CocoaPods/SPM a single resolution point.
  - Migrates legacy `"${NITRO_NATIVE}/dart_api_dl.c"` entries in existing `CMakeLists.txt` to the new local `"dart_api_dl.c"` form automatically.
  - Updates a stale `NITRO_NATIVE` cmake variable if the path it currently points to no longer contains `dart_api_dl.h`.
- `nitrogen init`: generated `CMakeLists.txt` and `ios/Classes/dart_api_dl.c` now use the same local-forwarder pattern from day one.
- Extracted `resolveNitroNativePath`, `nitroNativePathExists`, and `dartApiDlForwarderContent` as package-level functions for testability; private `_LinkViewState` helpers now delegate to them.
- Added tests covering `resolveNitroNativePath` (file:// URI, relative URI, absent config, fallback), `nitroNativePathExists`, and `dartApiDlForwarderContent`.

## 0.1.7

- `nitrogen init`: `nitro` and `nitro_generator` dependency versions are now resolved automatically from pub.dev at scaffold time instead of being hardcoded.
- Fallback: if pub.dev is unreachable, `flutter pub add nitro` and `flutter pub add --dev nitro_generator` are run in the generated plugin directory so pub resolves the latest compatible versions itself.

## 0.1.6

- Fix `nitrogen doctor` always reporting `ios/Classes/dart_api_dl.cpp missing`: the check now correctly looks for `dart_api_dl.c`, matching what `nitrogen link` actually creates (`.cpp` is deleted by `link` because C++ rejects the `void*`/function-pointer cast inside it).

## 0.1.5

- `nitrogen init` now generates starter `${ClassName}Impl.swift` and `${ClassName}Impl.kt` files so the plugin compiles immediately without any manual steps.
- iOS: switched from `@objc`/`NSObject` to `@_cdecl` C-bridge stubs — Swift structs and Swift-only protocols can now cross the native boundary correctly.
- iOS: `HEADER_SEARCH_PATHS` in podspec now uses `${PODS_ROOT}/../.symlinks/plugins/nitro/src/native` so the path resolves correctly whether `nitro` is a local path dependency or installed from pub.dev.
- iOS: `dart_api_dl` is created as `.c` (not `.cpp`) so the Dart DL API compiles as C; C++ rejects the `void*`/function-pointer cast inside it.
- iOS: `nitrogen init` now creates a `Package.swift` alongside the podspec, enabling Swift Package Manager distribution in addition to CocoaPods.
- iOS: SPM `Sources/` layout uses symlinks into `Classes/` so a single file exists at one location and is shared between both build systems.
- `nitrogen link`: extracted `discoverModuleLibs` and `extractLibNameFromSpec` as package-level functions for testability.
- Added comprehensive `link_command_test.dart` covering lib-name extraction, module discovery, podspec path correctness, and template content validation.

## 0.1.4
- `nitrogen init` always prompts for plugin name via an interactive `PluginNameForm` TUI; the name can no longer be passed as a positional argument.
- Added `NitrogenInitApp` (public) to handle the form → scaffold flow, reusable in both CLI and TUI dashboard.
- TUI dashboard `/init` route updated to use `NitrogenInitApp` instead of a hardcoded `InitView`.
- `ESC` on the plugin name form navigates back to the dashboard (TUI) or is a no-op (CLI).
- Added `pluginName` field to `InitResult` for post-run reporting.
- Added comprehensive tests for `InitResult`, `InitStep`, `InitStepRow`, `PluginNameForm`, and plugin name validation.

## 0.1.3
- Implement String type conversion in the struct generator and add braces to the CLI's plugin name extraction.

## 0.1.2
- Rename generator package folder to `nitro_generator`.
- Update `doctor` and `init` commands with new path references.

## 0.1.1
- Update `nitrogen` package reference to `nitro_generator`.

## 0.1.0
- Initial release with `nocterm` dashboard.
- Integrated `nitrogen init`, `generate`, `link`, `doctor`, and `update`.
