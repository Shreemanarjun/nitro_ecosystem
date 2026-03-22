# my_camera 📷

**Reference implementation of a Nitrogen FFI plugin.** `my_camera` demonstrates the full Nitrogen SDK with a real camera-frame streaming pipeline — including zero-copy `CameraFrame` struct delivery at 30 fps, async native calls, and synchronous FFI.

This plugin is part of the [nitro_ecosystem](https://github.com/Shreemanarjun/nitro_ecosystem) monorepo and serves as the integration test and reference for building your own Nitrogen plugins.

---

## What this plugin demonstrates

| Feature | Implementation |
|---|---|
| Synchronous FFI call | `add(double, double) → double` |
| Async native call | `getGreeting(String) → Future<String>` |
| Zero-copy stream | `frames → Stream<CameraFrame>` at ~30fps |
| `@HybridStruct` with zero-copy `Uint8List` | `CameraFrame.data` backed by `DirectByteBuffer` (Android) / `UnsafeMutablePointer<UInt8>` (iOS) |

---

## Requirements

### Build tools

| Tool | Minimum |
|---|---|
| Flutter SDK | 3.22.0+ |
| Dart SDK | 3.3.0+ |
| Android Studio / Gradle | Gradle 8.x + AGP 8.x |
| Android NDK | 26.1+ (r26b) |
| Kotlin | 1.9.0+ |
| Xcode | 15.0+ |
| iOS Deployment Target | 13.0+ |
| Swift | 5.9+ |

### Runtime dependencies (auto-pulled via pubspec)

- `nitro` — Nitrogen runtime (base classes, FFI helpers)
- `ffi` — Dart's `ffi` package for arena allocation
- `kotlinx-coroutines-core` — for Kotlin `Flow` streaming
- Combine framework — for Swift `AnyPublisher` streaming (system framework, no install needed)

---

## Getting started

### 1. Add to your app

```yaml
# pubspec.yaml
dependencies:
  my_camera:
    path: ../my_camera  # or publish to pub.dev
```

### 2. Android — ensure NDK is configured

`android/local.properties`:
```properties
ndk.dir=/Users/you/Library/Android/sdk/ndk/26.1.10909125
```

`android/app/build.gradle`:
```groovy
android {
    compileSdk 34
    defaultConfig {
        minSdk 24
        ndk {
            abiFilters 'arm64-v8a', 'x86_64'
        }
    }
}
```

### 3. iOS — ensure minimum deployment target

`ios/Podfile`:
```ruby
platform :ios, '13.0'
```

---

## Usage

```dart
import 'package:my_camera/my_camera.dart';

// ── Synchronous call ─────────────────────────────────────────────────
final result = MyCamera.instance.add(10, 20); // 30.0 — direct FFI

// ── Async call ───────────────────────────────────────────────────────
final greeting = await MyCamera.instance.getGreeting('Flutter');
print(greeting);
// Android: "Hello Flutter, from Kotlin Coroutines!"
// iOS:     "Hello Flutter, from Swift-land!"

// ── Zero-copy stream at 30fps ────────────────────────────────────────
final subscription = MyCamera.instance.frames.listen((frame) {
  // CameraFrame fields:
  print('${frame.width} × ${frame.height}');       // e.g. 1280 × 720
  print('stride: ${frame.stride}');                // bytes per row (e.g. 5120 for BGRA)
  print('${frame.data.length} bytes');             // stride bytes, zero-copy
  print('ts: ${frame.timestampNs} ns');            // native capture timestamp

  // frame.data is a Uint8List view into native hardware memory.
  // No allocation. No copy. The buffer is valid for the lifetime of this callback.
});

// Cancel the stream (releases native resources)
subscription.cancel();
```

---

## Plugin file structure

```
my_camera/
├── lib/
│   ├── my_camera.dart                        ← public barrel export
│   └── src/
│       ├── my_camera.native.dart             ← spec (author-written) ← EDIT THIS
│       ├── my_camera.g.dart                  ← generated FFI impl
│       └── generated/
│           ├── kotlin/my_camera.bridge.g.kt  ← generated Kotlin JNI bridge
│           └── swift/my_camera.bridge.g.swift← generated Swift bridge
│
├── android/
│   └── src/main/kotlin/.../MyCameraPlugin.kt ← Kotlin implementation ← EDIT THIS
│
├── ios/
│   └── Classes/
│       ├── MyCameraImpl.swift                ← Swift implementation ← EDIT THIS
│       └── SwiftMyCameraPlugin.swift         ← plugin registrar
│
└── example/
    └── lib/main.dart                         ← demo app
```

**You only write 3 files.** Everything else is generated.

---

## Regenerating the generated files

If you change `my_camera.native.dart`, regenerate with:

```sh
# From my_camera/ directory:
dart pub global run nitrogen_cli:nitrogen generate

# Or if you have the CLI activated globally:
nitrogen generate
```

---

## The spec file (`my_camera.native.dart`)

```dart
import 'dart:typed_data';
import 'package:nitro/nitro.dart';

part 'my_camera.g.dart';

@HybridStruct(zeroCopy: ['data'])
class CameraFrame {
  final Uint8List data;       // zero-copy hardware buffer pointer
  final int width;
  final int height;
  final int stride;           // bytes per row (auto-detected as byte-length)
  final int timestampNs;      // capture timestamp in nanoseconds

  CameraFrame(this.data, this.width, this.height, this.stride, this.timestampNs);
}

@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class MyCamera extends HybridObject {
  static final MyCamera instance = _MyCameraImpl(NitroRuntime.loadLib('my_camera'));

  double add(double a, double b);

  @nitroAsync
  Future<String> getGreeting(String name);

  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<CameraFrame> get frames;
}
```

---

## How zero-copy works

```
   Native (Kotlin/Swift)              Dart
   ──────────────────────             ────────────────────────────
   DirectByteBuffer.allocateDirect()  
   ↓ emit CameraFrame via Flow/Publisher
   C++ Dart_PostCObject(dartPort, ptr_address)
                                      NitroRuntime.openStream unpack:
                                      Pointer<_CameraFrameFfi>.fromAddress(rawPtr)
                                        .ref  ← zero alloc
                                        .toDart()
                                          data.asTypedList(stride)  ← zero copy
                                      ↓
                                      CameraFrame delivered to StreamBuilder
```

The `Uint8List` returned as `frame.data` is a direct view into the native `DirectByteBuffer` / `UnsafeMutablePointer<UInt8>`. **No bytes are copied across the FFI boundary.**

---

## Backpressure

At 30fps, frames arrive every ~33ms. If Dart's UI thread is busy, older frames are automatically **dropped** (`Backpressure.dropLatest`) so native memory is never exhausted. Change in the spec:

```dart
@NitroStream(backpressure: Backpressure.dropLatest)  // drop new frame if Dart is busy
@NitroStream(backpressure: Backpressure.block)        // block native thread (not recommended for camera)
@NitroStream(backpressure: Backpressure.bufferDrop)   // ring buffer, drop oldest
```

---

## Running the example app

```sh
cd my_camera/example
flutter run
```

The example shows:
- `10 + 20 = 30.0` — sync result
- `Hello Flutter, from Kotlin/Swift!` — async result  
- `1280 × 720  stride=5120` — live stream feed
- `3600.0 KB (zero-copy)` — data size per frame
- Live nanosecond timestamp ticking at 30fps

---

## License

MIT — see [LICENSE](../LICENSE)
