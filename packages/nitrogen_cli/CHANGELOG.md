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
