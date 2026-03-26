## 0.2.1

- **New: `NitroCamera` Hybrid Module** — added a comprehensive camera specification (`nitro_camera.native.dart`) covering device enumeration, permissions, capture controls (zoom, focus, flash, HDR, white-balance), zero-copy frame streaming, and high-performance video recording.
- **Improved: Dependency Management** — added `nitro_annotations` path override in `pubspec.yaml` to ensure consistent annotation resolution in the monorepo.

## 0.2.0

- **New: HybridRecord Support** — Migrated internal camera metrics and frame metadata to the new `@HybridRecord` system using the high-performance binary codec.
- **Improved: Stream Performance** — Enhanced `coloredFrames` stream efficiency by leveraging the optimized Nitrogen 0.2.0 runtime.
- **Improved: Project Health** — Synchronized build system configuration (CMake, Kotlin, Swift) with the latest Nitrogen 0.2.0 standards.
- **Dependency Sync**: Updated `nitro` and `nitro_generator` to version 0.2.0.

## 0.0.2

- **New: `coloredFrames` stream** — added a `Stream<CameraFrame>` that emits 640×480 frames cycling through RGB colors at ~30 fps. Implemented with `Flow` on Android and `PassthroughSubject` + `Timer` on iOS.
- **Fix: smoke test** — `MyCamera.instance` test now gracefully skips instead of failing when the native library is not available in host unit test environments (e.g. CI).
- Expanded `smoke_test.dart` with additional pure-Dart `CameraFrame` field assertions.

## 0.0.1

* Initial release.
