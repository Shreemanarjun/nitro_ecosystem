# 0.5.7

- **Doc fix** — Corrected a stale doc-comment on `@nitroNativeAsync` quoting the long-outdated "~930 µs → ~146 µs" async overhead figures; see `nitro`'s changelog for the corrected, measured numbers. No functional changes to this package.
- **Ecosystem sync** — Aligned with `nitro_generator` 0.5.7's callback `NativeCallable` leak fix — see its changelog, and regenerate your plugin to pick it up.

# 0.5.6

- **Ecosystem sync** — Aligned with the 0.5.6 release. No changes to this package; the 0.5.6 fix (a JNI global-reference leak on Android zero-copy stream events that aborted the process after ~25 minutes of continuous streaming) is entirely in `nitro_generator`'s generated C++ bridge — see its changelog, and regenerate your plugin to pick it up.

# 0.5.5

- **Ecosystem sync** — Aligned with `nitro`, `nitro_generator`, and `nitrogen_cli` 0.5.5. No changes to this package; the 0.5.5 fixes are entirely in the desktop C++ (`NativeImpl.cpp` on Windows/Linux) generator path and the `nitrogen link`/`nitrogen doctor` CLI — see `nitro_generator`'s and `nitrogen_cli`'s changelogs for details.

# 0.5.4

- **Ecosystem sync** — Aligned with `nitro`, `nitro_generator`, and `nitrogen_cli` 0.5.4.

# 0.5.3

- **Ecosystem sync** — Aligned with `nitro`, `nitro_generator`, and `nitrogen_cli` 0.5.3.

# 0.5.2

- **Ecosystem sync** — Aligned with `nitro`, `nitro_generator`, and `nitrogen_cli` 0.5.2.

# 0.5.1

- **Ecosystem sync** — Aligned with `nitro`, `nitro_generator`, and `nitrogen_cli` 0.5.1.

# 0.5.0

- **Ecosystem sync** — Aligned with `nitro`, `nitro_generator`, and `nitrogen_cli` 0.5.0.

# 0.4.6

- **New Annotations** — Added `@NitroVariant`, `@NitroResult`, `@nitroNativeAsync`, `@zeroCopy`, and `@NitroOwned`.

# 0.4.5

- **Ecosystem sync** — Aligned with `nitro`, `nitro_generator`, and `nitrogen_cli` 0.4.5.

# 0.4.4

- **Ecosystem sync** — Aligned with `nitro`, `nitro_generator`, and `nitrogen_cli` 0.4.4.

# 0.4.3

- **Ecosystem sync** — Aligned with `nitro`, `nitro_generator`, and `nitrogen_cli` 0.4.3.

# 0.4.2

- **Ecosystem sync** — Aligned with `nitro`, `nitro_generator`, and `nitrogen_cli` 0.4.2.

# 0.4.1

- **Ecosystem sync** — Aligned with `nitro`, `nitro_generator`, and `nitrogen_cli` 0.4.1.

# 0.4.0

- **Ecosystem sync to 0.4.0** — Aligned with `nitro`, `nitro_generator`, and `nitrogen_cli` 0.4.0.

# 0.3.3

- **Improved: Ecosystem Sync** — Synchronized to version 0.3.3.

# 0.3.2

- **Improved: Ecosystem Sync** — Synchronized to version 0.3.2.

# 0.3.1

- **Improved: Ecosystem Sync** — Synchronized to version 0.3.1.
- **New: `macos` field on `@NitroModule`** — `NitroModule` now accepts an optional `macos` parameter (`NativeImpl?`) for macOS platform targeting. Valid values are `NativeImpl.swift` and `NativeImpl.cpp`; `NativeImpl.kotlin` is rejected by `SpecValidator` with `INVALID_MACOS_IMPL`. Omitting `macos` means no macOS bridge is generated (existing behaviour unchanged).

# 0.3.0

- **Improved: Ecosystem Sync**: Synchronized all Nitro packages to version 0.3.0.
- **New: Optional platform targeting in `@NitroModule`** — `ios` and `android` parameters are now optional (`NativeImpl?`). Omitting a platform means no bridge is generated for it, enabling single-platform modules (iOS-only or Android-only).

# 0.2.3

- **Dependency Sync**: Synchronized the Nitro ecosystem to version 0.2.3.

# 0.2.2

- Standardized annotation class metadata for Nitrogen 0.2.2's stable code generation.

# 0.2.1

- Created `nitro_annotations` package to house all Nitro annotations.
- This allows `nitro_generator` to remain a pure Dart package without transitive Flutter dependencies.
