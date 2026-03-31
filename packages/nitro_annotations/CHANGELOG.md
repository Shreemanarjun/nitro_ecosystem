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
