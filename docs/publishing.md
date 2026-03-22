# Publishing a Nitrogen Plugin to pub.dev

This guide walks a plugin author through preparing and publishing a Nitrogen FFI plugin.

---

## Pre-publish checklist

Run through this list before every release:

- [ ] `nitrogen doctor` reports no errors
- [ ] All generated files are committed to version control
- [ ] `dart test` passes (or `flutter test` if you have widget tests)
- [ ] `pubspec.yaml` has a real description, homepage, and repository
- [ ] `CHANGELOG.md` has an entry for the new version
- [ ] `publish_to: none` is removed (or commented out) from `pubspec.yaml`
- [ ] All path dependencies replaced with pub.dev version constraints
- [ ] `dart pub publish --dry-run` passes with no warnings

---

## Step 1 — Commit all generated files

Nitrogen's generated files must be committed. Consumers of your plugin build without
`nitrogen` or `build_runner` installed, so they rely on pre-generated output.

Files to commit:

```
lib/src/my_plugin.g.dart
lib/src/generated/kotlin/my_plugin.bridge.g.kt
lib/src/generated/swift/my_plugin.bridge.g.swift
lib/src/generated/cpp/my_plugin.bridge.g.h
lib/src/generated/cpp/my_plugin.bridge.g.cpp
lib/src/generated/cmake/my_plugin.CMakeLists.g.txt
```

Verify they are all present and not stale:

```sh
nitrogen doctor
```

All lines should show `✔`. If anything shows `MISSING` or `STALE`, regenerate first:

```sh
nitrogen generate
git add lib/src/
git status  # confirm all generated files are staged
```

---

## Step 2 — Prepare pubspec.yaml

Replace the scaffold defaults with real metadata:

```yaml
name: my_sensor
description: >-
  A Flutter FFI plugin for high-speed sensor data via Nitrogen.
  Zero-copy native streaming, synchronous and async calls on Android and iOS.
version: 1.0.0
homepage: https://github.com/you/my_sensor
repository: https://github.com/you/my_sensor
issue_tracker: https://github.com/you/my_sensor/issues

environment:
  sdk: ">=3.3.0 <4.0.0"
  flutter: ">=3.22.0"

dependencies:
  flutter:
    sdk: flutter
  nitro: ^1.0.0          # pub.dev version — NOT a path dependency
  ffi: ^2.1.0
  plugin_platform_interface: ^2.0.2

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^6.0.0
  build_runner: ^2.4.0   # only needed to regenerate; consumers do not need this
  nitrogen: ^1.0.0       # pub.dev version — NOT a path dependency

flutter:
  plugin:
    platforms:
      android:
        ffiPlugin: true
        package: com.example.my_sensor
        pluginClass: MySensorPlugin
      ios:
        ffiPlugin: true
```

Key points:

- `ffiPlugin: true` on both platforms tells Flutter's build system to compile native code. This is required for any Nitrogen plugin.
- `pluginClass` on Android must match the class that implements `FlutterPlugin` and calls `MySensorJniBridge.register(...)`.
- Remove `publish_to: none` — that line blocks publishing.

---

## Step 3 — Write a good CHANGELOG.md

Follow the [Keep a Changelog](https://keepachangelog.com) format:

```markdown
## 1.0.0

Initial release.

- Synchronous `getTemperature()` and `isConnected()` via direct FFI
- Async `readManufacturerId()` dispatched on background isolate
- Zero-copy `readings` stream at 10 Hz via `@NitroStream`
- `mode` and `sampleRate` read/write properties

## 0.1.0

Beta release. API may change.
```

---

## Step 4 — Versioning conventions

Follow semantic versioning. For Nitrogen plugins:

| Change | Version bump |
|---|---|
| Add a new method or property to the spec | minor (`1.0.0` → `1.1.0`) |
| Remove or rename a method or property | **major** (`1.0.0` → `2.0.0`) |
| Change a parameter type or return type | **major** |
| Bug fix in native implementation only | patch (`1.0.0` → `1.0.1`) |
| Update to a new `nitro` runtime version (non-breaking) | patch or minor |

Changing the spec in a breaking way requires regenerating all generated files and bumping
the major version. Inform users in the CHANGELOG with a migration guide.

---

## Step 5 — Dry run

```sh
dart pub publish --dry-run
```

This validates the package without uploading. It checks:
- All required `pubspec.yaml` fields
- No files that will be excluded from the upload that are referenced in code
- SDK and Flutter version constraints are valid
- Package name is available (or you own it)

Common warnings to fix:

| Warning | Fix |
|---|---|
| `publish_to: none` | Remove that line |
| `path` dependency in `dependencies:` | Replace with a version constraint |
| Description is too short | Aim for 60–180 characters |
| No `homepage` or `repository` | Add them |
| Large files included | Add them to `.pubignore` (see below) |

---

## Step 6 — Set up .pubignore

Create `.pubignore` in the plugin root to exclude files that should not be uploaded to pub.dev
(test fixtures, editor configs, CI config, etc.) while still keeping them in git:

```
# .pubignore
.vscode/
.idea/
example/android/.gradle/
example/ios/Pods/
example/ios/.symlinks/
*.iml
coverage/
```

The `example/` directory is intentionally **not** excluded — pub.dev displays it.

---

## Step 7 — Publish

```sh
dart pub publish
```

This will:
1. Show you a list of all files that will be uploaded
2. Ask for confirmation
3. Open a browser for pub.dev authentication (first time only)
4. Upload the package

After publishing, the package is live at `https://pub.dev/packages/my_sensor`.

---

## Step 8 — Post-publish

Tag the release in git:

```sh
git tag v1.0.0
git push origin v1.0.0
```

Create a GitHub release with the CHANGELOG entry as the body.

---

## Subsequent releases

For every new release:

1. Edit `my_sensor.native.dart` if the API changes
2. `nitrogen generate` — regenerate all outputs
3. `nitrogen doctor` — verify everything is consistent
4. Update `pubspec.yaml` version
5. Update `CHANGELOG.md`
6. `dart pub publish --dry-run` — validate
7. `dart pub publish` — upload
8. `git tag vX.Y.Z && git push origin vX.Y.Z`

---

## What pub.dev scores on

pub.dev gives a score out of 160 points. For Nitrogen plugins:

| Category | Tips |
|---|---|
| Pub points (max 130) | Provide `homepage`, `repository`, valid `CHANGELOG.md`, pass `dart analyze` |
| Popularity | Cross-post to Flutter pub.dev community threads |
| Likes | Ask early users to like the package |
| Documentation | Add `///` doc comments on all public methods in `.native.dart`; pub.dev renders them |

The single highest-value action is passing `dart analyze` with zero issues:

```sh
dart analyze
```

---

## Example: full pubspec.yaml for publishing

```yaml
name: my_sensor
description: >-
  Flutter FFI plugin for high-speed sensor streaming. Nitrogen-powered:
  zero-copy native data, async calls, and typed streams on Android and iOS.
version: 1.0.0
homepage: https://github.com/you/my_sensor
repository: https://github.com/you/my_sensor
issue_tracker: https://github.com/you/my_sensor/issues

environment:
  sdk: ">=3.3.0 <4.0.0"
  flutter: ">=3.22.0"

dependencies:
  flutter:
    sdk: flutter
  nitro: ^1.0.0
  ffi: ^2.1.0
  plugin_platform_interface: ^2.0.2

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^6.0.0
  build_runner: ^2.4.0
  nitrogen: ^1.0.0

flutter:
  plugin:
    platforms:
      android:
        ffiPlugin: true
        package: com.example.my_sensor
        pluginClass: MySensorPlugin
      ios:
        ffiPlugin: true
```
