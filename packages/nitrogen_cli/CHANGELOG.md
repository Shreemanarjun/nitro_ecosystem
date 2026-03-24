## 0.1.16

- **Fix: zero-copy `@HybridStruct` JNI bridging for all TypedData types** — three JNI bugs fixed in `pack_from_jni` / `unpack_to_jni` helpers for struct fields marked `@zeroCopy`:
  1. Wrong JNI field descriptor: used `"Ljava/lang/Object;"` for all typed-data fields; now correctly uses `"Ljava/nio/ByteBuffer;"`.
  2. Wrong C element cast: `GetDirectBufferAddress` (returns `void*`) was assigned without a cast; now emits the correct element pointer cast (`float*`, `int32_t*`, `double*`, etc.) per TypedData type.
  3. Wrong byte count in `NewDirectByteBuffer`: passed element count instead of byte count; now multiplies by `sizeof(T)` for multi-byte element types (e.g. `st->length * sizeof(float)` for Float32List); 1-byte types (Uint8List, Int8List) need no multiplication.
- **New: `ZeroCopyFloat32Buffer` and all typed zero-copy buffer classes** — `ffi_utils.dart` now exports `ZeroCopyInt8Buffer`, `ZeroCopyInt16Buffer`, `ZeroCopyUint16Buffer`, `ZeroCopyInt32Buffer`, `ZeroCopyUint32Buffer`, `ZeroCopyFloat32Buffer`, `ZeroCopyFloat64Buffer`, and `ZeroCopyInt64Buffer`, each with a `Finalizer`-based GC hook. Previously only `ZeroCopyBuffer` (Uint8List) existed.
- **Fix: `BridgeType.isTypedData` now covers `Int64List` and `Uint64List`** — these two types were missing from the `isTypedData` getter, causing them to fall through to the wrong code paths in all generators.
- **`SpecValidator`: cyclic `@HybridStruct` dependency detection** — DFS cycle detection now reports `CYCLIC_STRUCT` errors with the full cycle path and a hint to break the cycle using `@HybridRecord` (heap-allocated, JSON-bridged). Cycles are deduplicated so the same cycle is reported only once.
- **`SpecValidator` + all generators: `@HybridEnum` usable as `@HybridStruct` field type** — enum fields are now valid in structs; in C they map to `int32_t`, in Dart FFI to `@Int32() int`, in Kotlin to `Long`, and in Swift to the enum type name. Conversion uses existing `.nativeValue` / `.toEnumName()` extensions.
- **Tests** — added `nitro_generator/test/zero_copy_typed_test.dart` (83 tests) covering all 10 TypedData types for JNI descriptor correctness, element casts, byte counts, the `sizeof` suffix, and the length-field heuristic; and `nitro_generator/test/spec_validator_expansion_test.dart` (26 tests) covering cyclic struct detection and enum-as-struct-field across all generators.

## 0.1.15

- **Fix: iOS bridge files renamed `.bridge.g.cpp` → `.bridge.g.mm`** — `nitrogen link` now copies bridge files to `ios/Classes/` with a `.mm` extension so Xcode compiles them as Objective-C++. Without this, `__OBJC__` is never defined in pure C++ compilation units, making the `#ifdef __OBJC__ @try/@catch (NSException*)` blocks dead code — native Swift exceptions (e.g. `NSException.raise`) propagate uncaught through the C++ stack and crash the app instead of being caught and re-thrown as Dart errors. Any stale `.bridge.g.cpp` files in `ios/Classes/` are deleted on each `nitrogen link` run.
- **Fix: `NSException.raise` in generated Swift bridge** — `VerificationImpl.throwError` (and equivalents) now raises a catchable `NSException` instead of calling `fatalError`, which is unrecoverable and bypasses the C++ exception barrier entirely.
- **Fix: typed-list (`Float32List` etc.) parameter bridging** — generator now emits a companion `int64_t <name>_length` parameter at every layer (C header, C bridge, Dart FFI type, Dart FFI call args, Swift `@_cdecl` signature, Swift body). The Swift `@_cdecl` function receives `UnsafeMutablePointer<Float>?` (C-ABI compatible) instead of `[Float]` (a Swift struct, not ABI-safe), and reconstructs the array via `UnsafeBufferPointer`. Previously passing a `Float32List` caused immediate memory corruption and crash.
- **`nitrogen doctor`: 3 new iOS checks** — `ios/Classes/nitro.h present`, stale `*.bridge.g.cpp` files detected (error with hint), and `.bridge.g.mm` file count verified (warn if missing after `nitrogen link`).
- **Tests** — added `test/doctor_command_test.dart` (10 tests) and `packages/nitro_generator/test/typed_list_bridge_test.dart` (32+ tests) covering all new generator behaviours and doctor checks.

## 0.1.14

- **Fix: lint — `link_command.dart`** — made private field `_failed` in `_LinkViewState` `final` (it is only initialised and never reassigned).
- **Fix: lint — `link_command_test.dart`** — removed unused local variable `count` from the `placeholder contains only one NITRO_NATIVE line` test.

## 0.1.13

- **`nitrogen generate`: automatic `pod install`** — after `build_runner` succeeds and generated Swift bridges are synced to `ios/Classes/`, the CLI now finds all `Podfile` locations (`ios/`, `example/ios/`, and any `*/ios/`) and runs `pod install` in each. This ensures the Xcode Pods project is always up-to-date after generation — no more stale module errors (`Use of undeclared identifier '…Plugin'`).
- **`nitrogen generate`: sync Swift bridges to `ios/Classes/`** — every `*.bridge.g.swift` generated under `lib/**/generated/swift/` is automatically copied to `ios/Classes/` so CocoaPods always picks up the freshly generated bridge without manual file management.
- **`nitrogen doctor`: iOS FFI plugin check fixed** — the `ios pluginClass` check no longer errors for pure FFI plugins. If `ffiPlugin: true` is present under `ios:` without a `pluginClass`, the check passes with an informational message. An error is only emitted when neither `pluginClass` nor `ffiPlugin: true` is set.
- **`nitrogen link`: next-steps hint updated** — the post-link next-steps now include `cd example/ios && pod install` as a reminder.

## 0.1.12
- Fix static version in `lib/version.dart`
- `nitrogen init`: `src/dart_api_dl.c` and `src/CMakeLists.txt` now resolve the correct pub-cache `nitro` path at scaffold time instead of writing a monorepo placeholder. After pubspec dependencies are installed, `nitrogen init` reads `.dart_tool/package_config.json` (using the same `resolveNitroNativePath` logic as `nitrogen link`) and overwrites both files with the absolute path — so the generated plugin builds immediately without needing a separate `nitrogen link` run.

## 0.1.11

- `nitrogen init`: generated `example/lib/main.dart` now showcases the plugin API with a proper Flutter app — `WidgetsFlutterBinding.ensureInitialized()`, a `StatelessWidget` `MyApp`, try-catch error screen, async `FutureBuilder`, and a reusable `_FeatureCard` widget. Fixes broken template syntax (`const .all(10)`, `.center`) from the previous scaffold.
- Added `docs/swift-type-mapping.md`: comprehensive reference covering the two-layer Swift type system, full Dart → C → `@_cdecl` → protocol type mapping table, memory ownership for String returns, async bridging pattern, Bool conversion, struct returns, and a crash diagnosis guide for `EXC_BAD_ACCESS`.
- Updated `docs/getting-started.md`: added `@_cdecl` bridge type callout in the Supported Types section, Step 6 note reminding plugin authors to use native Swift types in `*Impl.swift`, and an `EXC_BAD_ACCESS` troubleshooting entry.

## 0.1.10

- **Editor Quick Links**: Instantly open your active Nitro project in VS Code or Antigravity via clickable links in the dashboard header or the `nitrogen open` command.
- **Smart Project Discovery**:
  - `generate`, `link`, and `doctor` commands now automatically search for a Nitro project in the current directory and its direct subdirectories. This allows running Nitrogen commands from a parent folder (e.g., right after `init`) without needing to manually `cd`.
  - Dashboard now reflects the active project found in subdirectories.
- **Improved Navigation**: Added visible `‹ Back` buttons to all menu views (Init, Doctor, Link, and Generate) for easier dashboard navigation.
- **UI Stability Fix**:
  - Fixed flickering and layout jumps in the "✨ SUCCESS ✨" pulse animation during generation and initialization.
  - The success status now maintains a stable height, preventing the log view from shifting.
- **TUI Menu Refinement**: Rearranged core commands with **Exit** consistently at the bottom and editor options moved to a cleaner header position.

## 0.1.9

- **TUI Visual Overhaul (Neon Premium Theme)**:
  - New pulsing header logo (cycles between ⚡ Cyan and 🔥 Magenta).
  - Added "by Shreeman Arjun" author attribution to the dashboard.
  - Improved readability with high-contrast color palettes for menus and logs.
- **Mouse & Interactive Features**:
  - Full mouse support: Hover over menu items to highlight them.
  - Click anywhere on a command row to execute it instantly.
  - Clickable footer links for Documentation, Shreeman.dev, and Marc Rousavy.
- **Context-Aware Dashboard**:
  - **Project Bar**: Displays the name and version of the currently active Nitrogen project in the header.
  - **Status Bar**: Added a fixed bottom bar showing Dart version and current Git branch.
- **Enhanced Process Feedback**:
  - Added a pulsing "✨ SUCCESS ✨" animation and green color shift when a generation or initialization completes successfully.
- **Usability Fixes**:
  - Added an explicit **Exit** command to the TUI menu for easy quitting.
  - Standardized menu alignment (labels and descriptions now align vertically in the center).
  - Automatic TUI versioning: the dashboard always displays the actual package version from `pubspec.yaml`.

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
