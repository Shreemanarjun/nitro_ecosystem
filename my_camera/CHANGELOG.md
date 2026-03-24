## 0.0.2

- **New: `coloredFrames` stream** — added a `Stream<CameraFrame>` that emits 640×480 frames cycling through RGB colors at ~30 fps. Implemented with `Flow` on Android and `PassthroughSubject` + `Timer` on iOS.
- **Fix: smoke test** — `MyCamera.instance` test now gracefully skips instead of failing when the native library is not available in host unit test environments (e.g. CI).
- Expanded `smoke_test.dart` with additional pure-Dart `CameraFrame` field assertions.

## 0.0.1

* Initial release.
