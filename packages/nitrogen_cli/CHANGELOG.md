## 0.3.1
- **Improved: Ecosystem Sync** — Synchronized to version 0.3.1.
- **New: macOS `nitrogen link` step** — `linkMacosPodspec()` now wires `macos/$plugin.podspec` with the correct `s.platform = :osx, '10.15'`, `HEADER_SEARCH_PATHS`, `swift_version`, `DEFINES_MODULE`, `dart_api_dl.c` forwarder, and per-module C++ impl forwarders in `macos/Classes/`. The new step appears in the link progress view at index 3.
- **Improved: macOS `nitrogen link` auto-fixes** — `linkMacosSwiftPlugin()` now automatically creates a default `${ClassName}Plugin.swift` if missing and injects the required `Registry.register()` calls. It also handles implementation naming fallbacks (e.g. `BenchmarkImpl`).
- **Improved: `nitrogen link` podspec auto-dependency** — `linkPodspec()` and `linkMacosPodspec()` now automatically inject `s.dependency 'nitro'` if it's missing, ensuring the 1.5 µs FFI bridge headers are always visible to the compiler.
- **Fixed: `nitrogen link` symlink corruption** — Hardened `linkMacosSwiftPlugin()` and `linkSwiftPlugin()` to use `followLinks: false` and filter out `.symlinks/` directories, preventing recursive modification of external packages in the `pub_cache`.
- **New: macOS Swift plugin wiring** — `linkMacosSwiftPlugin()` injects `NitroModules` bridge registration calls into `macos/*Plugin.swift`, mirroring the existing iOS `linkSwiftPlugin()`. Both iOS and macOS Swift wiring now run in a single link step that marks done if either platform directory is present.
- **New: macOS `nitrogen doctor` section** — A dedicated `macOS` doctor section checks podspec `HEADER_SEARCH_PATHS`, C++17 flag, `dart_api_dl.c`, `nitro.h`, `NITRO_EXPORT` macro, stale `.bridge.g.cpp` presence, `.bridge.g.mm` bridges, `.native.g.h` header sync, and Swift plugin registration — parallel to the existing iOS section.
- **Improved: `nitrogen doctor` platform diagnostics** — Added explicit checks for `s.dependency 'nitro'` in both iOS and macOS podspecs, providing better DX for troubleshooting native linkage issues.
- **New: macOS pubspec check** — `nitrogen doctor` now validates the `macos:` platform block in `pubspec.yaml`, checking for `pluginClass` or `ffiPlugin: true`.
- **Fixed: `isCppModule()` detection for macOS-only and mixed-platform specs** — The old implementation required two occurrences of `NativeImpl.cpp` in the annotation string, so `macos: NativeImpl.cpp` alone (or `ios: NativeImpl.cpp, macos: NativeImpl.cpp` with no Android) was falsely classified as non-cpp. Now uses a platform-arg regex `\b(?:ios|android|macos)\s*:\s*NativeImpl\.cpp\b` — any platform being cpp marks the module as cpp.
- **Fixed: `_discoverCppLibs()` same two-occurrence bug** — The internal bridge-sync utility had identical broken logic; stale `.bridge.g.swift` files were not cleaned from `ios/Classes/` or `macos/Classes/` for macOS-only cpp specs. Fixed with the same platform-arg regex.
- **New: `syncBridgeFiles(platform:)` parameter** — `syncBridgeFiles` now accepts an optional `platform` parameter ('ios' or 'macos', default 'ios') so macOS bridge files are correctly synced to `macos/Classes/` with the same Swift-exclusion and `.cpp` → `.mm` rename logic.
- **New: `nitro.h` copied to `macos/Classes/`** — `createSharedHeaders()` now writes `nitro.h` into `macos/Classes/` when that directory exists, in addition to `ios/Classes/`.
- **Fixed: `dashboard_test` Watch description assertion** — the TUI right-panel column truncates long strings; test now checks the visible prefix `'Run the Nitro gen'` instead of the full description.
- **Improved: Test coverage** — 30+ new edge-case tests across `link_command_test.dart`, `doctor_command_test.dart`, and `utils_test.dart`: multi-line/comment-above annotation parsing, macOS-only `discoverModuleInfos`, tri-platform specs, `linkMacosPodspec` no-op/insertion/idempotency, `linkMacosSwiftPlugin` injection/deduplication/no-op, `syncBridgeFiles(platform: 'macos')` variants, macOS doctor section states, and macOS pubspec check variants.

## 0.3.0

- **Fixed: PascalCase derivation for filenames with underscores** — `discoverModuleInfos` now uses a robust `_toPascalCase` helper with empty-segment guards. This prevents `RangeError` exceptions when processing filenames with consecutive underscores (e.g., `my__module.native.dart`).
- **Improved: Ecosystem Sync**: Synchronized the Nitro ecosystem to version 0.3.0.

## 0.2.4

- **Fixed: iOS build failure for NativeImpl.cpp modules** — Three issues that blocked `NativeImpl.cpp` modules from linking on iOS have been resolved:
  - `linkPodspec` now creates `ios/Classes/Hybrid<Lib>.cpp` forwarders for C++ module impl files. On Android each module is its own `.so`; on iOS everything is one binary — the impl must be compiled in `ios/Classes/`.
  - `syncBridgeFiles` now auto-discovers NativeImpl.cpp modules by reading `.native.dart` specs and skips copying their `.bridge.g.swift` to `ios/Classes/`. The C++ bridge calls `g_impl` directly; the `@_cdecl("_call_*")` stubs in the Swift file are never called and their names clash with the non-cpp Swift bridge, causing a duplicate-symbol linker error.
  - `ensureIosPackageSwift` + new `_syncCppModuleSourcesToSpm` syncs the `.bridge.g.mm` and `Hybrid<Lib>.cpp` forwarders into the SPM `Sources/<Main>Cpp/` target, and copies only the C-compatible `.bridge.g.h` into `include/` (never `.native.g.h`, which uses C++ types that break the CocoaPods umbrella header).
- **New: NativeImpl.cpp Direct C++ Support** — All CLI commands now fully support `@NitroModule(ios: NativeImpl.cpp, android: NativeImpl.cpp)` modules:
  - `nitrogen generate`: syncs `.native.g.h` headers to `ios/Classes/`; skips "Not applicable" Swift placeholder files; shows a tailored next-steps hint for cpp modules.
  - `nitrogen link`: skips Swift bridge registration and Kotlin `JniBridge.register` steps for all-cpp plugins; adds `generated/cpp/test/` to `.clangd` for GoogleMock IDE support.
  - `nitrogen doctor`: new **NativeImpl.cpp Direct Implementation** section checks whether `${lib}_register_impl()` is wired up in `src/` and whether `.clangd` includes the test directory; Android/iOS sections show `ℹ info` (not errors) for checks irrelevant to cpp modules.
- **Improved: `nitrogen doctor` — cpp-aware Android/iOS sections**:
  - Android: when all specs use `NativeImpl.cpp`, Kotlin JNI bridge checks are shown as info.
  - iOS: Registry.register check skipped for all-cpp plugins; checks for `.native.g.h` headers in `ios/Classes/` instead; `.bridge.g.mm` warning suppressed.
  - Generated files: `.bridge.g.kt`/`.bridge.g.swift` shown as `ℹ info` (placeholder) for cpp modules; `.native.g.h`, `.mock.g.h`, `.test.g.cpp` checked as required outputs.
- **New: `isCppModule()` + `ModuleInfo`** — `link_command.dart` exports `isCppModule(File)` (detects two `NativeImpl.cpp` occurrences in annotation) and `ModuleInfo` (carries `isCpp` flag). Legacy `discoverModules()` preserved for compatibility.
- **Improved: Test Coverage** — 28 new tests covering `isCppModule` edge cases, `discoverModuleInfos` with mixed cpp/kotlin projects, doctor Android/iOS cpp sections, NativeImpl.cpp doctor section (register_impl check, clangd check).

## 0.2.3

- **Automated Native Healing**: Commands now proactively fix common native build errors.
  - `nitrogen link` and `nitrogen generate` automatically scan your C++ source files and strip redundant `#include "*.bridge.g.cpp"` directives that previously caused duplicate symbol errors in Xcode.
  - Added a dedicated `cleanRedundantIncludes` utility to the CLI core for robust source cleanup.
- **Native Visibility Synchronization**:
  - The CLI now maintains a canonical `nitro.h` with `NITRO_EXPORT` visibility macros for cross-platform FFI compatibility.
  - `nitrogen link`, `nitrogen generate`, and `nitrogen init` all strictly enforce that your project's `nitro.h` is up to date, automatically repairing it if it's outdated or corrupted.
- **Enhanced `nitrogen doctor` Diagnostics**:
  - New check for redundant bridge includes in `src/`.
  - New check for `NITRO_EXPORT` visibility macros in `nitro.h`.
  - Improved `HEADER_SEARCH_PATHS` validation in iOS podspecs to ensure all generated code is discoverable.
- **Improved Code Generation**: Fixed an issue in `nitro_generator` where large `Uint8List` buffers were incorrectly passed as `Array<UInt8>` instead of `Data` in some Swift bridge signatures.
- **Dependency Sync**: Synchronized the Nitro ecosystem to version 0.2.3.

## 0.2.2

- Standardized on Nitrogen 0.2.2 ecosystem versions.

## 0.2.1
- **New Watch Mode**: Added the `nitrogen watch` command to handle continuous code generation. This feature includes an automatic **iOS Bridge Sync** that copies and renames generated C++/Swift bridges to `ios/Classes` on every successful build. This ensures that your iOS project always has the latest generated bridge files without manual intervention.
- **Better TUI Experience**: Overhauled the Nitro Dashboard with a new multi-project sidebar, improved focus management (using **[Tab]**), and consistent ESC-based navigation.
- **New: Multi-Project Discovery**: Automatically detects and switches between multiple Nitrogen modules in a monorepo.
- **Improved: Enhanced Doctor**: Expanded `nitrogen doctor` to verify system compiler toolchains (Clang, Xcode, NDK, Java) and validate plugin registration.
- **Performance**: Optimized Android and JNI bridge performance with static caching and persistent thread pools.
- **Improved: TUI Navigation & Error Handling** — Standardized "ESC back" and "ESC exit" navigation logic across all views. Implemented a centered, high-visibility error UI for all command failures (e.g., missing `pubspec.yaml`, network/process errors).
- **Improved: JNI Performance** — All `FindClass`, `GetStaticMethodID`, `GetFieldID`, and `GetMethodID` calls are now cached as static globals and initialized once in `JNI_OnLoad`, eliminating per-call classloader traversal.
- **Improved: Android Async Throughput** — Kotlin bridge async methods now delegate to a `newCachedThreadPool` executor instead of calling `runBlocking` directly.
- **Improved: Generator O(1) Type Lookups** — `KotlinGenerator` and `CppBridgeGenerator` now pre-build type name tables once per generation, reducing lookup complexity from O(n) to O(1).
- **Improved: Process Feedback** — `ProcessView` now uses visual cues (red borders) and explicit status text when a long-running process fails.
- **Fixed: Arena Use-After-Free in Async FFI Bridges** — Generated code now uses `Arena()` directly with `try/finally` to ensure the arena lives until after the async native call completes.
- **Fixed: Typed `callAsync<T>` Removes Raw Pointer Casts** — Generated Dart now uses the typed form `callAsync<T>(...)`, eliminating unsafe `as` casts.
- **Fixed: Null Safety for JNI Pack** — Added null guards for zero-copy `ByteBuffer` fields in `pack_*_from_jni` helpers.
- **Fixed: `nitrogen doctor` Unmodifiable List Error** — Resolved a runtime exception by ensuring diagnostic lists are growable.
- **Fixed: `nitrogen exit` command** — Properly terminates the application from the menu.
- **Refactored Link Logic**: Decoupled core linking logic (CMake, Podspec, Swift/Kotlin plugins, `.clangd`) from the TUI-specific `LinkView`. All linking tasks are now top-level, testable functions that support a `baseDir` parameter for programmatic execution in monorepos or test environments.
- **Improved: iOS Podspec Wiring**: Updated `linkPodspec` to automatically enforce **Swift 5.9** and **iOS 13.0** as minimums, ensuring compatibility with the latest Nitrogen generated code.
- **Fixed: PathNotFoundException in Tests**: Updated `getAllProjects` to accept an optional `baseDir`, eliminating reliance on the process-global `Directory.current` and fixing parallel test execution failures.
- **Improved Test Coverage**: Added a comprehensive test suite for CLI command registration, module discovery, and path resolution.


## 0.2.0

- **New: High-Performance Binary Codec Integration** — All generated bridges now default to the compact binary protocol for `@HybridRecord` types, matching the updates in `package:nitro` 0.2.0.
- **Improved: `nitrogen doctor` Reliability** — Fixed a runtime exception ("Unsupported operation: Cannot add to an unmodifiable list") when running checks on `pubspec.yaml`, generated files, and build system wiring.
- **Improved: `nitrogen generate` Stability** — Updated the generator backbone to remove unreferenced helper methods and redundant type lookups in Swift bridges.
- **Improved: Linter Integration** — Updated analysis options to prefer wider page widths (220) and cleaner formatting for generated code across all packages.
- **Dependency Sync**: Synchronized core ecosystem versions to 0.2.0 across `nitro`, `nitro_generator`, and `nitrogen_cli`.

## 0.1.13

- **Full Zero-Copy TypedData Support**:
  - Fixed JNI bridging for `@HybridStruct` (descriptors, casts, and byte counts).
  - Added `ZeroCopyBuffer` variants for ALL TypedData types with GC finalizers.
  - `Int64List` and `Uint64List` are now correctly handled in all generators.
- **iOS & Swift Safety**:
  - Renamed bridge files to `.bridge.g.mm` to enable Objective-C++ exception handling.
  - Fixed memory corruption when passing typed lists (`Float32List`, etc.) by using ABI-safe pointers and companion length parameters.
  - Replaced `fatalError` with catchable `NSException.raise` for bridge validation errors.
- **CLI Workflow & Tooling**:
  - `nitrogen generate` now automatically syncs Swift bridges to `ios/Classes/` and runs `pod install`.
  - Added new `nitrogen doctor` checks for iOS project health and FFI plugin configuration.
  - Stale bridge files are now automatically cleaned up during `link`.
- **Generator Enhancements**: Added cyclic dependency detection in structs and support for `@HybridEnum` as struct fields.
- **Testing & Quality**: Added 150+ new tests covering zero-copy TypedData, cyclic dependencies, and bridge safety. Fixed minor TUI lints and improved CLI feedback.

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
