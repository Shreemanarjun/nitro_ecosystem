## 0.5.13

The nitro_webgpu feedback batch ([#15](https://github.com/Shreemanarjun/nitro_ecosystem/issues/15), [#16](https://github.com/Shreemanarjun/nitro_ecosystem/issues/16), [#20](https://github.com/Shreemanarjun/nitro_ecosystem/issues/20)):

- **New: one SPM C++ target per module** ([#15](https://github.com/Shreemanarjun/nitro_ecosystem/issues/15)) — `nitrogen link` now gives every non-main module its own `Sources/<ModuleClass>Cpp/` target holding its `.bridge.g.mm` forwarder, an umbrella header (so the module's Swift bridge can `import <ModuleClass>Cpp` for `@nitroNativeAsync`), and — for Apple-C++ modules — the `HybridXxx.cpp` forwarder plus C bridge header. Each module target depends on the plugin-level `<PluginClass>Cpp` target, which alone compiles `dart_api_dl.c` and owns the shared nitro/dart headers (compiling them per-target caused the duplicate-symbol and ambiguous-clang-module errors the issue reported). Missing `.target(...)` blocks and Swift-target dependencies are INSERTED into an existing nitrogen-generated `Package.swift` idempotently (anchored at the package-level `targets: [` — never the products list); hand-authored manifests are left untouched with the exact blocks to paste printed instead. A repair pass removes module sources previously synced into the plugin-level target, healing existing duplicate-symbol checkouts. Verified end-to-end: the three-spec integration fixture (Swift/Kotlin + all-C++ + mixed) builds green through `flutter build macos` on the new layout.
- **Fixed: `Plugin.kt` is user-owned once created** ([#16](https://github.com/Shreemanarjun/nitro_ecosystem/issues/16)) — `nitrogen init` re-templated an existing `<Class>Plugin.kt` on every run, silently dropping hand-added imports and lifecycle code (e.g. `android.view.Surface` handling); it is now written only when missing, matching the `Impl.kt` guard. (`nitrogen link`'s registration injection was already additive/idempotent — a new test locks hand-added imports surviving repeated links.)
- **Fixed: plain `dart run build_runner build` hung FOREVER on built example dirs** ([#20](https://github.com/Shreemanarjun/nitro_ecosystem/issues/20)) — build_runner's file walk follows the `example/{ios,macos}/.symlinks/plugins/<name>` symlink back to the plugin root and recurses without output or timeout. `nitrogen init`'s build.yaml now ships `targets.$default.sources` excludes (`example/**`, `**/.symlinks/**`, `**/ephemeral/**`) so raw build_runner never walks the cycle; `nitrogen link` adds the block to existing plugins (never clobbering a user-customized `sources:`); `nitrogen doctor` escalates to a warning with the one-line fix when hazard dirs exist and the excludes are missing.

## 0.5.12

- **Ecosystem sync** — Aligned with `nitro_generator` 0.5.12's zero-copy TypedData fixes (missing `release_typed_data_return` definition on the pure-C++ path; Swift struct conversions dropping the synthesized length for `@zeroCopy` fields). No functional changes to this package — see `nitro_generator`'s changelog, and regenerate your plugin to pick them up.

## 0.5.11

Three developer-experience fixes from real desktop plugin bring-up ([#10](https://github.com/Shreemanarjun/nitro_ecosystem/issues/10), [#11](https://github.com/Shreemanarjun/nitro_ecosystem/issues/11), [#12](https://github.com/Shreemanarjun/nitro_ecosystem/issues/12)) — all verified end-to-end against the reporting repo (`nitro_printing`) at its buggy ref, each repaired by a single `nitrogen link` with no manual edits:

- **Fixed: desktop platforms no longer declare `pluginClass` in the plugin pubspec ([#10])** — Windows/Linux Nitro backends are pure FFI; declaring `pluginClass` alongside `ffiPlugin: true` made Flutter classify the plugin as method-channel on desktop and link a nonexistent `<plugin>_plugin` CMake target (`CMake Error: No target`), blocking every consuming app's desktop build. `nitrogen init` now emits `ffiPlugin: true` only for those platforms, `nitrogen link`/`generate` repair existing pubspecs (both block-style and inline `{ ... }` YAML entries; android/ios/macos keep their genuine plugin classes untouched), and `nitrogen doctor` flags the bad combination with the exact failure it causes.
- **Fixed: `nitrogen link` no longer breaks an example app's desktop build when the example is itself a Nitro module ([#11])** — link treated the example's `windows/`/`linux/` CMakeLists (Flutter *app-runner* files) like plugin platform files: it appended a `target_include_directories(${PLUGIN_NAME} …)` block on a target that doesn't exist in runner scope (hard configure error) and, in earlier versions, baked the linking machine's **absolute** nitro-checkout path into `set(NITRO_NATIVE …)` — committed, so every other machine and CI runner failed to configure. Runner CMakeLists (detected by `BINARY_NAME`/`add_executable`) are now left alone entirely, previously injected blocks are stripped on the next link, and stale absolute `NITRO_NATIVE` values in module CMakeLists are rewritten to the portable `${CMAKE_CURRENT_SOURCE_DIR}`-relative form.
- **Fixed: switching to explicit per-platform desktop impls now completes the whole transition ([#12])** — changing a module from `windows/linux: NativeImpl.cpp` to `WindowsNativeImpl.cpp`/`LinuxNativeImpl.cpp` previously wired `NITRO_IMPL_SRC_<lib>` in the platform CMakeLists but left the other two halves undone: the shared `src/HybridXxx.cpp` content was never migrated when the platform stubs already existed on disk (they're auto-created on every link, so they always did), and an *existing* `src/CMakeLists.txt` kept its hardcoded `target_sources(<lib> PRIVATE "HybridXxx.cpp")` line, which silently ignores the variables — the build kept compiling the now-orphaned shared file while the per-platform files sat empty. One `nitrogen link` now: migrates the shared impl into an *untouched* platform stub (files with real user code are never overwritten; the shared file is left in place — still the fallback for Android and never-opted-in builds — rather than deleted), and retrofits the `if(DEFINED NITRO_IMPL_SRC_<lib>) … else() … endif()` guard onto pre-separation `src/CMakeLists.txt` files (all three historical shapes: `if(NOT ANDROID)`-wrapped, bare `target_sources`, and inline-in-`add_library`). The guard's else-branch preserves the old behavior byte-for-byte for projects that never opt in. Also hardened the implicit-separation detector per the issue's note: a comments-only platform file (stub marker deleted, no actual code) no longer reads as an opt-in.
- Covered by 19 new tests (`link_command_test.dart`).

## 0.5.10

- **Ecosystem sync** — Aligned with `nitro_generator` 0.5.10's desktop C-bridge fixes ([#9](https://github.com/Shreemanarjun/nitro_ecosystem/issues/9)). See `nitro_generator`'s changelog for the generator-side dispatch fixes; the entries below are `nitrogen_cli`'s own, in the same release.
- **Fixed: `windows/CMakeLists.txt` never actually compiled `windows/src/HybridXxx.cpp`** — for a module targeting both `windows: NativeImpl.cpp` and `linux: NativeImpl.cpp`, `windows/CMakeLists.txt` delegates to the shared `src/CMakeLists.txt` via `add_subdirectory(../src)`, which only ever built the *shared* `src/HybridXxx.cpp` — the separate `windows/src/HybridXxx.cpp` stub `nitrogen link` already created sat on disk, fully implemented or not, silently uncompiled. `linux/CMakeLists.txt` had no per-platform stub at all; Linux always shared `src/HybridXxx.cpp` with Windows (or with Android, if Android was also C++).
- **Added: genuine per-platform separation for Windows/Linux desktop C++ implementations** — a module can now have Windows and Linux diverge into their own independently-editable `windows/src/HybridXxx.cpp` / `linux/src/HybridXxx.cpp`, wired via a new `NITRO_IMPL_SRC_<lib>` CMake variable that `windows/CMakeLists.txt`/`linux/CMakeLists.txt` set before `add_subdirectory(../src)`, read by `src/CMakeLists.txt`'s `target_sources` call. This is **not automatic** just because a module targets `NativeImpl.cpp` on both platforms — some plugins genuinely want one shared file (the logic really is identical across desktop platforms); others want Windows and Linux to diverge (different threading primitives, platform intrinsics). Two independent, either-is-sufficient ways to opt in, both gated by `hasCustomPlatformImpl`/the new `requestsSeparateWindowsImpl`/`requestsSeparateLinuxImpl` analyzer getters:
  - **Implicit / gradual**: write real code directly into the auto-created `windows/src/`or `linux/src/` starter stub (detected by the absence of the stub's `TODO: implement all pure-virtual methods` marker) — no annotation change needed.
  - **Explicit / immediate**: spell that platform's implementation using its *specific* marker type — `windows: WindowsNativeImpl.cpp` / `linux: LinuxNativeImpl.cpp` — rather than the generic `NativeImpl.cpp` shorthand. Both forms are `identical()` at the Dart type level (see `nitro_annotations`); this reads the distinction from the annotation's *source text*, which only this link-time analyzer sees. The first time this fires, any existing content in the shared `src/HybridXxx.cpp` is migrated into the new platform-specific file (adjusting the relative include path) rather than starting from an empty stub — activating separation this way is a location change, not a behavior change.
- **Fixed: `PlatformTargetAnalyzer`'s `@NitroModule` annotation extraction silently truncated on the first `)` inside the annotation body, including one inside an ordinary parenthesized code comment** — e.g. `// (see the docs)` sitting between two annotation params. The old extractor used a `[^)]+` regex with no nesting awareness; found by self-inflicted repro while writing a doc comment for the feature above, which made *every* getter on the class (not just the new ones) silently return `false` against the real annotation file it was tested against. Replaced with proper balanced-paren scanning.
- **Added: `nitrogen link`/`nitrogen generate` now generate a correct `android/consumer-rules.pro`** for any Kotlin-on-Android module, plus wire `consumerProguardFiles "consumer-rules.pro"` into `defaultConfig` if a plugin's `build.gradle` doesn't already have it (a generated file that's never applied to a consuming app's release build is a silent no-op). Root cause, found via a real R8 full-mode crash in a production Nitro Android plugin: a plain `-keep class X { *; }` protects a JNI-called method from removal/renaming, but **not** the parameter/return types referenced in its signature — for methods JNI calls by exact signature via `GetStaticMethodID` (every `_call` trampoline, several of which take many `long`/data-class params for suspend methods), an altered parameter type produces a `VerifyError` at the exact call site ("... Long (Low Half)") rather than a normal link failure. `includedescriptorclasses` is ProGuard's own documented remedy for exactly this native/JNI-called-method scenario, not a nitro-specific workaround. The generated block is idempotent and additive (marker-delimited), so a plugin author's own rules for unrelated dependencies always survive. Verified end-to-end, not just via unit tests: built real R8-minified release APKs for two plugins and ran them on a device — one exercising the exact suspend-function trampolines the original crash implicated (camera open + async device enumeration), with zero `VerifyError`s and the affected calls completing normally.
- Covered by 22 new tests across `link_command_test.dart` — including one that found and fixed a further real bug in the `consumerProguardFiles` insertion itself, which corrupted a valid single-line `defaultConfig { minSdk = 24 }` block by splicing an inserted statement onto the rest of that line.

## 0.5.9

- **Ecosystem sync** — Aligned with `nitro_generator` 0.5.9's `@nitroNativeAsync` error-propagation fix. No functional changes to this package — see `nitro_generator`'s changelog, and regenerate your plugin to pick it up.

## 0.5.8

- **Ecosystem sync** — Aligned with `nitro_generator` 0.5.8's `@nitroNativeAsync` fixes (`Map<String,V>`/`NitroAnyMap` params on Kotlin and Swift, bare `@HybridStruct` returns on Kotlin, and `NitroAnyMap` support on Swift). No functional changes to this package — see `nitro_generator`'s changelog, and regenerate your plugin to pick it up.

## 0.5.7

- **Doc fix** — Corrected stale "~930 µs / ~146 µs" async overhead figures in this README with real measured numbers (macOS: `@nitroAsync` ~28 µs, `@nitroNativeAsync` ~27 µs, both near method-channel parity). No functional changes to this package.
- **Ecosystem sync** — Aligned with `nitro_generator` 0.5.7's callback `NativeCallable` leak fix — see its changelog, and regenerate your plugin to pick it up.

## 0.5.6

- **Fixed: `nitrogen generate` could hang forever with zero output or error** — once `example/`'s iOS/macOS/Windows/Linux platforms have been built at least once, standard CocoaPods/Flutter tooling leaves `example/{ios,macos}/.symlinks/plugins/<name>` (and equivalents) pointing straight back to the plugin root. `build_runner`'s initial file-discovery walk follows symlinks with no cycle detection, so it recurses forever — `<root> -> example -> ios -> .symlinks -> <root> -> ...` — burning 100% CPU with no error, no timeout, and no log output (confirmed via a stack sample of a hung process: 100% of time inside `dart:io`'s `AsyncDirectoryLister`). `nitrogen generate` now removes these known-safe-to-delete ephemeral directories before every `build_runner` invocation (they always regenerate from `flutter pub get`/`pod install`), so this can no longer happen through the documented workflow.
- **Added: `nitrogen doctor` now flags this hazard** for anyone running `dart run build_runner build`/`watch` directly (bypassing `nitrogen generate`, which isn't protected by the fix above) — reports which ephemeral dirs are present with guidance to delete them if a direct build_runner invocation ever hangs.
- **Ecosystem sync** — Aligned with the 0.5.6 release. `nitro_generator`'s JNI global-reference leak fix (Android zero-copy stream events aborting the process after ~25 minutes of continuous streaming) is entirely in its generated C++ bridge — see its changelog, and regenerate your plugin to pick it up.

## 0.5.5

- **Fixed: `nitrogen link` broke Linux/Windows FFI-plugin CMake configure** — for shared-src FFI plugins (`add_subdirectory(../src)`), link appended `target_include_directories(${PLUGIN_NAME} …)` where no `${PLUGIN_NAME}` target exists — a hard CMake configure error. The block is now skipped for shared-src plugins (the library target in `src/CMakeLists.txt` already carries the include dirs) and removed on re-link if an earlier version added it.
- **Fixed: multi-spec shared-src plugins never exposed their registrant header, breaking Linux/Windows example builds** — a plugin that both shares `src/` for its Nitro module libraries AND builds its own separate `<pkg>_plugin` registrant target (e.g. a package bundling several `@NitroModule` specs) never got `target_include_directories(${PLUGIN_NAME} INTERFACE ".../include")`, so the app's auto-generated `generated_plugin_registrant.cc` failed with `fatal error: 'pkg/pkg_plugin.h' file not found` (Linux) / `error C1083: Cannot open include file` (Windows). Link now detects this shape (`add_library(${PLUGIN_NAME} ...)` alongside the shared `add_subdirectory(../src)`) and adds the missing INTERFACE include dir, without disturbing any other include directories already declared on that target. Verified with a real `cmake` configure (stubbed Flutter/GTK deps) in both the broken and fixed states, and end-to-end against a real multi-spec plugin (broken → `doctor` reports it → `link` fixes it → `doctor` confirms it).
- **Added: `nitrogen doctor` now detects the multi-spec registrant include-dir issue above** — reports `Registrant include/ dir not exposed on ${PLUGIN_NAME}` with a `Run: nitrogen link` hint on Windows/Linux sections when applicable, so a broken plugin is caught before the example app fails to build.
- **Fixed: `src/Hybrid<Module>.cpp` stub never registered on Windows** — the auto-register `#if` guard omitted `_WIN32` for `windows: NativeImpl.cpp` modules (the MSVC branch was unreachably nested inside the Linux guard), so the impl silently never registered. `ModuleInfo` now carries `windowsIsCpp` and the guard includes `defined(_WIN32)`.

## 0.5.4

- **Fixed: Multi-spec C++ plugin — `NitroOptInt64` typedef conflict in generated C++ bridge headers** — `cpp_record_generator.dart` now excludes the built-in library record types (`NitroOptInt64`, `NitroOptFloat64`, `NitroOptBool`, `NitroNullableInt`, `NitroNullableDouble`, `NitrNullableBool`) from C++ forward declarations and struct definitions. These types are already defined as anonymous C typedefs in the generated `bridge.g.h`; emitting a named `struct NitroOptInt64;` in the same compilation unit caused a hard compiler error (`definition of type 'NitroOptInt64' conflicts with typedef of the same name`).
- **Fixed: Multi-spec Swift plugin — `NitroRecordWriter` not found in scope for `NativeImpl.cpp` bridges** — `swift_record_generator.dart` now skips library record type struct definitions when `emitBoilerplate: false` (the `NativeImpl.cpp` bridge path). Previously, `NitroNullableInt` and friends were emitted in the cpp bridge file even without the preamble, causing `'NitroNullableInt' is ambiguous for type lookup` errors when multiple bridge files compiled into the same Swift module.
- **Fixed: Multi-spec macOS — Static initialization order fiasco (SIOF) crash on startup** — `cpp_direct_emitter.dart` now generates Meyers' Singleton wrapper functions (`_g_instances()`, `_g_instances_mtx()`, `_g_next_instance_id()`, `_g_factory()`) for all C++ registry globals. The previous static global variables could be accessed by `__attribute__((constructor))` callbacks before the globals were initialized, manifesting as a `std::__next_prime` overflow/abort on macOS.
- **Fixed: Multi-spec SPM — C++ bridge files copied before preamble-defining Swift bridge** — `_syncSwiftBridgesToSpmSources` in `link_command.dart` now sorts bridge files so that those containing `public protocol NitroEncodable` (the shared preamble) are placed first. The first file is copied verbatim; subsequent files have the preamble stripped. This ensures `NitroRecordWriter` and related types are always defined before they are referenced in the same Swift module.
- **Tests: 55 new per-spec integration tests** in `integration_test.dart` verifying generator output for all three native-spec combinations: `testing_project` (Swift/Kotlin), `testing_cpp` (NativeImpl.cpp all platforms), and `testing_mixed` (Swift iOS / Kotlin Android / C++ macOS). Covers Dart binding symbols, C bridge signatures, Swift protocol declarations, Kotlin interface signatures, `native.g.h` abstract class, `impl.g.cpp` editable starter, and SPM file placement.
- **Integration: 25/25 device integration tests pass on macOS** across all 3 specs — `add`, `getGreeting`, `multiply`, `pi`, `isEven`, `tryDivide` (nullable int return), `platform`, `optionalFlag` (nullable bool), `optionalValue` (nullable double).

## 0.5.3

- **Fixed: Multi-spec plugin — `symbol not found: nitro_<spec>_init_dart_api_dl` crash (root cause)** — The stale-forwarder cleanup loop in `_syncCppModuleSourcesToSpm` was deleting `${lib}.bridge.g.mm` for every module where `isAppleCpp=false`, including modules that use `ios: NativeImpl.swift` alongside `windows: WindowsNativeImpl.cpp`. Because the bridge mm is required for ALL modules on Apple to compile `${lib}_init_dart_api_dl` into the SPM binary (even for Swift-backed modules), this deletion caused a runtime symbol-not-found crash. The stale cleanup now only removes the `HybridXxx.cpp` impl forwarder, never the bridge forwarder.
- **Tests: 4 new regression tests** in `link_command_test.dart` verifying that (1) `bridge.g.mm` is created for a Swift-on-iOS/C++-on-Windows module, (2) it is not deleted by the stale cleanup, (3) the `HybridXxx.cpp` impl forwarder is correctly removed for Swift-on-Apple modules, and (4) all three bridge mm forwarders are present for a full 3-spec plugin (the nitro_view scenario).
- **Integration tests: 35 tests** added to `nitro_view/example/integration_test/multi_spec_bridge_test.dart` exercising real FFI calls across all 3 specs (`NitroSystem`, `NitroUI`, `NitroView`) on iOS, Android, and macOS. Includes a cross-spec group as a definitive regression guard for the symbol-not-found crash. Added `ACCESS_NETWORK_STATE` and `VIBRATE` permissions to the Android example manifest.

## 0.5.2

- **Fixed: Multi-spec Swift plugin — `invalid redeclaration` persists after every `nitrogen generate` / `nitrogen link`** — `_copySwiftBridgesToClasses` and `_syncSwiftBridgesToSpmSources` in the link step always copied bridge files without preamble-stripping, overwriting any correctly-stripped copies. The fix moves preamble-stripping into these two functions (sorted alphabetically; first file keeps the full preamble, subsequent files have it removed) and relocates `stripSharedSwiftPreamble` to `utils.dart` so it is shared by both the generate and link code paths. Standalone `nitrogen link` now also produces correctly-stripped bridge files.
- **Fixed: Multi-spec plugin — `symbol not found: nitro_<spec>_init_dart_api_dl` crash when 2nd/3rd spec uses Swift on iOS/macOS but C++ on Windows/Linux** — `_syncCppModuleSourcesToSpm` created per-module `${lib}.bridge.g.mm` SPM forwarders only for modules where `isCpp=true AND isAppleCpp=true`. Modules with `ios: NativeImpl.swift, windows: WindowsNativeImpl.cpp` had `isCpp=true` (triggering the stale-cleanup loop) but `isAppleCpp=false` (triggering deletion of the bridge mm). The bridge mm is required for ALL modules on Apple to compile `${lib}_init_dart_api_dl` into the SPM binary; the stale cleanup now only removes the impl forwarder (`HybridXxx.cpp`), never the bridge forwarder (`${lib}.bridge.g.mm`).

## 0.5.1

- **Fixed: Multi-spec Swift plugin — runtime `symbol not found` crash** — `_syncCppModuleSourcesToSpm` now creates a `${lib}.bridge.g.mm` forwarder in the SPM `<PluginName>Cpp` target for every non-plugin Swift module. Previously only C++ modules got per-module wrappers; the `allCppModules.isEmpty` guard skipped all per-module work for pure-Swift plugins, so 2nd and 3rd specs (e.g. `nitro_ui`, `nitro_system`) were never compiled into the binary. Result: `dlsym('nitro_ui_init_dart_api_dl'): symbol not found` crash on first use. Applies to both iOS and macOS SPM targets.
- **Fixed: Multi-spec Swift plugin — `invalid redeclaration` compile error** — `_syncSwiftBridgesToClasses` now strips the shared public-type preamble (`NitroEncodable`, `NitroNullableInt`, `NitroRecordWriter`, etc.) from the 2nd and subsequent bridge `.swift` files before writing them to `ios/Classes/`, `macos/Classes/`, and SPM `Sources/<ClassName>/` directories. All bridge files compile into the same Swift module; duplicate `public` declarations cause a Swift compiler `invalid redeclaration` error. The first file (alphabetically) retains the full preamble; later files keep only their file-private string helpers and spec-specific protocol/registry/stubs.
- **New: `stripSharedSwiftPreamble(String content)`** — Exported top-level function implementing the preamble-stripping logic, enabling direct unit testing without filesystem scaffolding.

## 0.5.0

- **Ecosystem sync** — Aligned with `nitro`, `nitro_annotations`, and `nitro_generator` 0.5.0.

## 0.4.6

- **Ecosystem sync** — Aligned with `nitro`, `nitro_annotations`, and `nitro_generator` 0.4.6.

## 0.4.5

- **Ecosystem sync** — Aligned with `nitro`, `nitro_annotations`, and `nitro_generator` 0.4.5.

## 0.4.4

- **Ecosystem sync** — Aligned with `nitro`, `nitro_annotations`, and `nitro_generator` 0.4.4.

## 0.4.3

- **New: `nitrogen generate --no-ui`** — Headless plain-text output mode with no ANSI colours, auto-enabled when stdout is not a TTY (great for CI pipelines and scripts).
- **New: `nitrogen generate --fail-on-warn`** — Exits with code 2 if `build_runner` emits any `[WARNING]` lines, so CI catches generation warnings as failures.
- **New: `nitrogen generate --verbose` / `-v`** — Prints a per-phase timing breakdown (e.g. "resolve: 120ms, codegen: 340ms") at the end of generation.
- **New: `nitrogen clean` command** — Deletes all Nitrogen-generated files (`*.g.dart`, `*.bridge.g.*`, `*.native.g.h`, etc.) and the `build_runner` cache in one command.
- **New: `--no-ui` headless mode for all commands** — Every command (`init`, `generate`, `clean`, `link`, `doctor`, `migrate`, `update`, `watch`, `open`) now supports `--no-ui`. Output is plain text prefixed with `[nitro]`, `[nitro:warn]`, or `[nitro:error]`; auto-enabled when stdout is not a TTY.
- **TUI: Animated NITRO logo** — The dashboard now displays a large block-art "NITRO" logo with rocket animation at the top of the main content area, pulsing between cyan and magenta in sync with the header.
- **TUI: Improved credits** — Credits updated to "Inspired by Nitro — @mrousavy" with clickable links; added a row for Shreeman Arjun with X and GitHub links.
- **CLI: Nitro credit in `--version` and `--help`** — `nitrogen --version` now prints the Nitro inspiration line; `nitrogen --help` description includes the @mrousavy attribution.
- **Fixed: Doctor false positives on `FlutterFramework/Package.swift`** — `detectSpmStatus` was picking up `ios/FlutterFramework/Package.swift` (the Flutter SDK's SPM manifest, symlinked by CocoaPods) before the plugin's own `ios/<name>/Package.swift`. The scanner now skips directories whose name is not a valid Dart package identifier (lowercase snake_case), eliminating false-positive SPM errors on real-world plugins.
- **Fixed: SPM `Package.swift` missing FlutterFramework dependency** — `nitrogen link` now patches older plugin `Package.swift` files to add the `FlutterFramework` target dependency if it is missing, preventing SPM build failures after upgrading Flutter.
- **Fixed: ANSI escape codes in headless `build_runner` output** — `runStreamingInspected` strips ANSI sequences from subprocess output when running in `--no-ui` mode, so log files stay clean.

## 0.4.2

- **Fixed: Apple C++ forwarder incorrectly deleted** — `link_command.dart` now uses a safe default: forwarders are kept when no spec file exists for a library. Previously any lib not in `platformCppLibs` was deleted, removing valid Apple forwarders from plugins without a local spec.
- **Fixed: Pure-Swift plugin files not copied to SPM target** — `_syncSwiftPluginToSpm` is now called for plugins with no C/C++ content before the early `continue`, ensuring Swift plugin files reach `Sources/<className>/` when building with SPM.
- **Fixed: SPM sync crash for macOS-only plugins** — `_syncSwiftPluginToSpm` now returns early when the target directory doesn't exist, preventing a `PathNotFoundException` for platforms that have no SPM layout.
- **Fixed: Scaffold generated double "Plugin" suffix** — `scaffold_templates.dart` was generating `Swift${pascal}Plugin.swift`; corrected to `Swift${pascal}.swift` to match the expected filename.
- **Ecosystem sync** — Aligned with `nitro`, `nitro_annotations`, and `nitro_generator` 0.4.2.

## 0.4.1

- **Fixed: SPM Package.swift invalid header search paths** — Removed external paths (`../../lib/src/generated/cpp`, `../../.symlinks/plugins/nitro/src/native`) from SPM Swift target configuration. The Swift target accesses types through its `${className}Cpp` dependency via `publicHeadersPath: "include"`.
- **Fixed: Swift plugin not found under SPM** — Added `_syncSwiftPluginToSpm()` which copies `*Plugin.swift` and `*Impl.swift` from `Classes/` to `Sources/<className>/`, ensuring `GeneratedPluginRegistrant.m` can find the Swift plugin class when building with SPM.
- **Fixed: Mixed Apple platform linking** — `nitrogen link` now correctly handles modules with different implementations per Apple platform (e.g. `ios: NativeImpl.swift` + `macos: NativeImpl.cpp`). iOS and macOS `Plugin.swift` registration and `HybridXxx.cpp` forwarders are managed independently per platform.
- **Fixed: Portable `dart_api_dl` header** — `dart_api_dl.h` is now written from the resolved pub-cache path rather than a relative `.symlinks` path, making it stable across both CocoaPods and SPM build trees and on CI machines.
- **Fixed: Release-mode `nitro.h` export macros** — `createSharedHeaders` and `nitrogen doctor` now validate that `NITRO_EXPORT` is present in `nitro.h`, fixing linker errors in archive/release builds.
- **Fixed: Android multi-module stabilization** — `nitrogen init` and `nitrogen link` CMake templates no longer produce duplicate library targets in multi-module projects; `build.gradle` source-set configuration avoids AGP 8.x routing issues.
- **Refactored: Template extraction** — All inline string templates moved from command files into `lib/templates/` (`forwarder_templates.dart`, `podspec_templates.dart`, `cpp_stubs.dart`, `swift_templates.dart`, `cmake_templates.dart`, `native_headers.dart`, `scaffold_templates.dart`). Command files now contain only logic.
- **Fixed: Lint warnings in generated and test code** — Removed underscore-prefixed local identifiers (`_scaffoldSpm`, `_scaffoldMacosSpm`) and unused variables from test files; `no_leading_underscores_for_local_identifiers` warnings eliminated.

## 0.4.0

- **New: Mixed Apple platform support** — `nitrogen link` now correctly handles modules with different implementation languages per Apple platform (e.g. `ios: NativeImpl.swift` + `macos: NativeImpl.cpp`). iOS `Plugin.swift` registration and macOS `Plugin.swift` registration are managed independently, and `HybridXxx.cpp` forwarders are only written for the platform that actually uses C++.
- **SPM and CocoaPods** — Both build systems are fully supported. SPM targets (`Sources/<PluginCpp>/`) and CocoaPods targets (`ios/Classes/`, `macos/Classes/`) are wired automatically by `nitrogen link`. `nitrogen doctor` validates both layouts.
- **Fixed: `bridge.g.mm` always written** — `bridge.g.mm` is now written unconditionally (relative `#include` path), so plugins build correctly even when `nitrogen link` is run before `nitrogen generate`.
- **Fixed: `nitrogen link` no longer deletes the main plugin bridge** when the module lib name matches the plugin name.
- **Fixed: `nitrogen generate` / `nitrogen watch` no longer hang** when `build_runner` is already running.

## 0.3.4

- **Fixed: `createSharedHeaders` now populates SPM Cpp target include dirs** — Previously, `createSharedHeaders` only wrote `nitro.h` and Dart API headers to `src/`, `ios/Classes/`, and `macos/Classes/`. Plugins using the nested Flutter 3.41+ SPM layout (`{platform}/<plugin>/Sources/<ClassName>Cpp/include/`) were left without those headers until `linkPodspec` ran. `createSharedHeaders` now scans for any existing `*Cpp/include/` directories under `ios/<plugin>/Sources/` and `macos/<plugin>/Sources/` and writes `nitro.h` plus copies all `dart_api*.h` headers into them.

## 0.3.3

- **Fixed: `linkPodspec` operation order causing re-added stale Swift bridges** — `_cleanStaleSwiftBridges` was called before `syncBridgeFiles`, so any stale `.bridge.g.swift` copies deleted from `ios/Classes/` were immediately re-added by the subsequent `syncBridgeFiles` call. The order is now `syncBridgeFiles` first, then `_cleanStaleSwiftBridges`, ensuring stale copies are permanently removed.
- **Fixed: `syncBridgeFiles` missing stale Swift bridge deletion for C++ modules** — Previously, `syncBridgeFiles` skipped Swift bridges for `NativeImpl.cpp`/`AppleNativeImpl.cpp` modules but never deleted any stale copies that already existed in `Classes/` or `Sources/<ClassName>/`. It now explicitly deletes those stale files, preventing "Invalid redeclaration" compile errors in projects upgrading from earlier layouts.
- **Fixed: `syncBridgeFiles` SPM layout support** — The function previously returned early when `ios/Classes/` was missing, so the `ios/Sources/<ClassName>/` target (used by SPM-enabled plugins) never received Swift bridge copies. It now checks both layouts independently and copies to whichever target directories exist.
- **Fixed: `_syncCppModuleSourcesToSpm` spurious files when no C++ modules present** — When `moduleInfos` contained no `isCpp` modules, the function still wrote `dart_api_dl.c` and the main plugin forwarder into `ios/Sources/<PluginCpp>/` because the guard was placed after those writes. It now returns early if `allCppModules` is empty, leaving the SPM directory untouched.
- **Improved: Test coverage** — All 339 tests pass. Added and corrected assertions in `utils_test.dart` and `link_command_test.dart` covering: stale Swift bridge deletion for C++ modules in both `ios/Classes/` and `macos/Classes/`, SPM-layout Swift bridge copying, `linkPodspec` operation order, and `_syncCppModuleSourcesToSpm` no-op behaviour.

## 0.3.2

- **Fixed: Swift bridge duplicate compilation ("Invalid redeclaration")** — Generated `.bridge.g.swift` files are now compiled directly from `lib/src/generated/swift/` via the podspec `source_files` pattern. `nitrogen generate` and `nitrogen link` no longer copy these files into `ios/Classes/` or `macos/Classes/`; instead, they delete any stale copies that were left from earlier versions. This eliminates the "Invalid redeclaration" Swift compiler error that occurred when both locations were compiled.
- **Fixed: Android "Unresolved reference: XxxJniBridge" in AGP 8.x** — The generated `build.gradle` template in `nitrogen init` and the benchmark project no longer include `java.srcDirs += "...lib/src/generated/kotlin"`. In AGP 8.x that line routes `.kt` files through the Java compiler path, making Kotlin-only constructs unresolvable. `kotlin.srcDirs` alone is sufficient and correct.
- **Improved: `nitrogen doctor` AGP 8.x diagnostic** — The Android section now detects `java.srcDirs` pointing at `generated/kotlin` and reports an actionable error: `java.srcDirs includes generated/kotlin — causes "Unresolved reference: XxxJniBridge" in AGP 8.x`, with a hint to remove the line and use `kotlin.srcDirs` only.
- **Improved: `nitrogen doctor` mixed-platform module detection** — Generated-files checks now use platform-specific helpers (`_isAndroidKotlinModule` / `_isAppleSwiftModule`) instead of the broad `isCppModule` guard. This correctly handles mixed modules such as `windows: WindowsNativeImpl.cpp, android: NativeImpl.kotlin`: the `.bridge.g.kt` check is no longer skipped just because another platform uses C++.
- **Improved: `nitrogen link` podspec `source_files`** — `linkPodspec()` and `linkMacosPodspec()` now append `'../lib/src/generated/swift/**/*.swift'` to the podspec `source_files` pattern so Swift bridges are compiled without manual copying.
- **Improved: Test coverage** — 14 new tests across `doctor_command_test.dart`, `link_command_test.dart`, and `utils_test.dart` covering: `java.srcDirs` error detection, `sourceSets` missing error, android:cpp `.bridge.g.kt` skip, mixed-module `.bridge.g.kt` check, apple:cpp `.bridge.g.swift` skip, partial-Swift `.bridge.g.swift` check, podspec `source_files` injection, stale Swift bridge cleanup, and AGP 8.x regression guard.

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
