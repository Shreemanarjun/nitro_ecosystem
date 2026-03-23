# Getting Started with Nitrogen

This guide walks you through creating a Nitrogen FFI plugin from scratch — from `nitrogen init` to a working plugin calling native code on Android and iOS.

**Time to complete:** ~30 minutes (excluding build times)

---

## Prerequisites

Before you begin, install and verify the following tools:

| Tool | Required version | Check |
|---|---|---|
| Flutter SDK | 3.22.0+ | `flutter --version` |
| Dart SDK | 3.3.0+ | `dart --version` |
| Android NDK | 26.1+ (r26b) | Android Studio → SDK Manager → SDK Tools → NDK |
| Kotlin | 1.9.0+ | bundled with Android Studio |
| Xcode | 15.0+ | `xcode-select --version` |
| Swift | 5.9+ | `swift --version` |
| iOS Deployment Target | 13.0+ | set in Podfile |
| CMake | 3.18+ | bundled with Android NDK |

---

## Step 1 — Install the Nitrogen CLI

```sh
dart pub global activate --source path packages/nitrogen_cli
```

Add the pub global bin to your shell PATH (one-time):

```sh
# ~/.zshrc or ~/.bashrc
export PATH="$PATH:$HOME/.pub-cache/bin"
```

Verify:

```sh
nitrogen --help
```

You should see:

```
CLI for scaffolding and generating Nitrogen FFI plugins.

Usage: nitrogen <command> [arguments]

Available commands:
  init      Scaffold a new Nitrogen plugin
  generate  Run code generation on all *.native.dart specs
  link      Wire native build files to Nitrogen runtime
  doctor    Check that all generated files and build wiring are correct
```

---

## Step 2 — Scaffold a new plugin

```sh
nitrogen init my_sensor
```

This creates a `my_sensor/` directory with the following structure:

```
my_sensor/
├── pubspec.yaml                              pre-wired with nitro + nitro_generator
├── lib/
│   ├── my_sensor.dart                        barrel export
│   └── src/
│       └── my_sensor.native.dart             starter spec ← EDIT THIS
├── android/
│   ├── build.gradle
│   └── src/main/kotlin/com/example/my_sensor/
│       ├── MySensorPlugin.kt                 Flutter plugin registrar
│       └── MySensorImpl.kt                   ← EDIT THIS (native implementation)
├── ios/
│   ├── my_sensor.podspec                     pre-configured: Swift 5.9, iOS 13, C++17
│   ├── Package.swift                         Swift Package Manager support
│   └── Classes/
│       ├── SwiftMySensorPlugin.swift         Swift plugin registrar
│       ├── MySensorImpl.swift                ← EDIT THIS (native implementation)
│       ├── my_sensor.bridge.g.swift          symlink → generated bridge (after generate)
│       ├── my_sensor.cpp                     C++ forwarder
│       └── dart_api_dl.c                     Dart DL API (compiled as C)
└── src/
    └── CMakeLists.txt                        Android NDK build file
```

**You only ever edit three files:** the spec, the Kotlin impl, and the Swift impl. Everything else is generated or wired automatically.

---

## Step 3 — Write the spec file

Open `lib/src/my_sensor.native.dart` and define your API:

```dart
import 'dart:typed_data';
import 'package:nitro/nitro.dart';

part 'my_sensor.g.dart';  // generated — do not create manually

// Optional: zero-copy data struct
@HybridStruct(zeroCopy: ['payload'])
class SensorReading {
  final Uint8List payload;   // zero-copy — points into native memory
  final int length;          // byte count — auto-detected as length source
  final double temperature;
  final double humidity;
  final int timestampNs;

  SensorReading(this.payload, this.length, this.temperature, this.humidity, this.timestampNs);
}

// Optional: native enum
@HybridEnum(startValue: 0)
enum SensorMode { idle, sampling, calibrating, error }

// Module spec — the public API your plugin exposes
@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class MySensor extends HybridObject {
  static final MySensor instance = _MySensorImpl(NitroRuntime.loadLib('my_sensor'));

  // Synchronous — direct FFI, executes in < 1 microsecond
  double getTemperature();
  bool isConnected();

  // Async — dispatched on a background isolate, returns to main isolate
  @nitroAsync
  Future<String> readManufacturerId();

  // Stream — native events pushed to Dart via Dart_PostCObject (zero overhead)
  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<SensorReading> get readings;

  // Properties — get/set via named C symbols
  SensorMode get mode;
  set mode(SensorMode value);

  double get sampleRate;
  set sampleRate(double hz);
}
```

### Annotation reference

| Annotation | Where | Meaning |
|---|---|---|
| `@NitroModule(ios:, android:)` | class | Marks this as a Nitrogen module spec |
| `@HybridStruct(zeroCopy: [...])` | class | Generates a C struct; listed fields become zero-copy pointers |
| `@HybridEnum(startValue:)` | enum | Maps to a C `int64` enum with a `nativeValue` getter |
| `@nitroAsync` | method | Dispatches call to background isolate; method must return `Future<T>` |
| `@NitroStream(backpressure:)` | getter | Native push stream; getter must return `Stream<T>` |

### Supported types

| Dart | C | Kotlin | Swift |
|---|---|---|---|
| `int` | `int64_t` | `Long` | `Int64` |
| `double` | `double` | `Double` | `Double` |
| `bool` | `int8_t` | `Boolean` | `Bool` |
| `String` | `const char*` | `String` | `String` |
| `Uint8List` | `uint8_t*` | `ByteArray` | `Data` |
| `Future<T>` | — | `suspend fun` | `async throws` |
| `Stream<T>` | SendPort registration | `Flow<T>` | `AnyPublisher<T, Never>` |
| `@HybridEnum` | `int64_t` | `Long` (via `.nativeValue`) | `Int64` |
| `@HybridStruct` | `YourStruct*` | data class | struct |

Nullable variants (`String?`, `int?`) are also accepted.

---

## Step 4 — Generate native code

From the `my_sensor/` directory:

```sh
cd my_sensor
nitrogen generate
```

This produces six files per spec:

```
lib/src/my_sensor.g.dart                              Dart FFI implementation
lib/src/generated/kotlin/my_sensor.bridge.g.kt        Kotlin JNI bridge + HybridMySensorSpec interface
lib/src/generated/swift/my_sensor.bridge.g.swift      Swift @_cdecl bridge + HybridMySensorProtocol
lib/src/generated/cpp/my_sensor.bridge.g.h            C header (extern "C" declarations)
lib/src/generated/cpp/my_sensor.bridge.g.cpp          C++ JNI impl (Android) + Apple bridge (iOS)
lib/src/generated/cmake/my_sensor.CMakeLists.g.txt    CMake fragment for Android
```

**Commit all generated files.** They are stable, deterministic output — consumers of your plugin build without needing `nitrogen` installed.

> Regenerate any time you change the spec:
> ```sh
> nitrogen generate
> ```

---

## Step 5 — Implement the Kotlin side (Android)

Open `android/src/main/kotlin/com/example/my_sensor/MySensorImpl.kt`.

The generated `my_sensor.bridge.g.kt` contains the `HybridMySensorSpec` interface you must implement:

```kotlin
package com.example.my_sensor

import nitro.my_sensor_module.HybridMySensorSpec
import nitro.my_sensor_module.MySensorJniBridge
import nitro.my_sensor_module.SensorReading
import nitro.my_sensor_module.SensorMode
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.delay
import java.nio.ByteBuffer

class MySensorImpl : HybridMySensorSpec {

    // --- Synchronous ---

    override fun getTemperature(): Double = 23.4

    override fun isConnected(): Boolean = true

    // --- Async ---

    override suspend fun readManufacturerId(): String {
        delay(50) // simulate I2C read
        return "ACME-SensorChip-v2"
    }

    // --- Stream ---

    override val readings: Flow<SensorReading> = flow {
        val buf = ByteBuffer.allocateDirect(64)
        while (true) {
            buf.rewind()
            buf.put(byteArrayOf(0x01, 0x02, 0x03, 0x04))
            emit(SensorReading(
                payload = buf,
                length = 4L,
                temperature = 23.4,
                humidity = 58.0,
                timestampNs = System.nanoTime()
            ))
            delay(100) // 10 Hz
        }
    }

    // --- Properties ---

    override var mode: Long = SensorMode.IDLE.nativeValue

    override var sampleRate: Double = 10.0
}
```

Then register it in `MySensorPlugin.kt`:

```kotlin
class MySensorPlugin : FlutterPlugin {
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        MySensorJniBridge.register(MySensorImpl())
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {}
}
```

### Android build requirements

In `android/build.gradle`, confirm:

```groovy
android {
    compileSdk 34
    defaultConfig {
        minSdk 24
        ndk {
            abiFilters 'arm64-v8a', 'x86_64'
        }
    }
    externalNativeBuild {
        cmake {
            path "../../src/CMakeLists.txt"
        }
    }
}

dependencies {
    implementation "org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.0"
}
```

In `android/local.properties` (or your CI environment), set the NDK path:

```properties
ndk.dir=/Users/you/Library/Android/sdk/ndk/26.1.10909125
```

---

## Step 6 — Implement the Swift side (iOS)

Open `ios/Classes/MySensorImpl.swift` (created automatically by `nitrogen init` as a starter).

The generated `my_sensor.bridge.g.swift` contains the `HybridMySensorProtocol` you must implement:

```swift
import Foundation
import Combine

public class MySensorImpl: NSObject, HybridMySensorProtocol {

    // --- Synchronous ---

    public func getTemperature() -> Double { 23.4 }

    public func isConnected() -> Bool { true }

    // --- Async ---

    public func readManufacturerId() async throws -> String {
        try await Task.sleep(nanoseconds: 50_000_000)
        return "ACME-SensorChip-v2"
    }

    // --- Stream ---

    private let readingsSubject = PassthroughSubject<SensorReading, Never>()
    private var timer: Timer?

    public var readings: AnyPublisher<SensorReading, Never> {
        readingsSubject.eraseToAnyPublisher()
    }

    override init() {
        super.init()
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            let reading = SensorReading(
                payload: buf, length: 4,
                temperature: 23.4, humidity: 58.0,
                timestampNs: Int64(Date().timeIntervalSince1970 * 1_000_000_000)
            )
            self?.readingsSubject.send(reading)
        }
    }

    deinit { timer?.invalidate() }

    // --- Properties ---

    public var mode: Int32 = SensorMode.idle.rawValue

    public var sampleRate: Double = 10.0
}
```

Register it in `SwiftMySensorPlugin.swift`:

```swift
public class SwiftMySensorPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        MySensorRegistry.register(MySensorImpl())
    }
}
```

### iOS build requirements

`ios/my_sensor.podspec` is pre-configured by `nitrogen init` and `nitrogen link`:

```ruby
Pod::Spec.new do |s|
  s.name             = 'my_sensor'
  s.version          = '0.0.1'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.9'
  s.source_files     = 'Classes/**/*'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE'               => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY'           => 'libc++',
    'HEADER_SEARCH_PATHS'         => '$(inherited) "${PODS_ROOT}/../.symlinks/plugins/nitro/src/native"'
  }
end
```

> **Why `PODS_ROOT/../.symlinks/...`?** This path resolves correctly whether `nitro` is a local path dependency or installed from pub.dev. CocoaPods creates `.symlinks/plugins/<name>/` automatically for all plugin dependencies.

`ios/Podfile` (in your example or consumer app):

```ruby
platform :ios, '13.0'
```

#### Swift Package Manager (alternative to CocoaPods)

`nitrogen init` also creates `ios/Package.swift` for SPM distribution:

```swift
// swift-tools-version: 5.9
let package = Package(
    name: "my_sensor",
    platforms: [.iOS(.v13)],
    products: [.library(name: "my_sensor", targets: ["my_sensor"])],
    targets: [
        // C/C++ bridge — SPM requires Swift and C++ in separate targets
        .target(name: "MySensorCpp", path: "Sources/MySensorCpp",
            publicHeadersPath: "include",
            cxxSettings: [.unsafeFlags(["-std=c++17",
                "-I../../.symlinks/plugins/nitro/src/native"])]),
        // Swift implementation + generated bridge
        .target(name: "my_sensor", dependencies: ["MySensorCpp"],
            path: "Sources/MySensor"),
    ]
)
```

The `Sources/` directories contain symlinks back into `Classes/` — one file, two build systems.

---

## Step 7 — Wire the Android CMake build

Run `nitrogen link` to ensure `src/CMakeLists.txt` is connected to the generated C++ files:

```sh
nitrogen link
```

The final `src/CMakeLists.txt` should look like:

```cmake
cmake_minimum_required(VERSION 3.18)
project(my_sensor_plugin)

include(../lib/src/generated/cmake/my_sensor.CMakeLists.g.txt)

target_link_libraries(my_sensor log)
```

The generated CMake fragment sets up `add_library`, `target_sources`, and include paths automatically.

---

## Step 8 — Verify everything with `nitrogen doctor`

Before doing a full build, run the doctor command to catch any missing or stale files:

```sh
nitrogen doctor
```

Expected output when everything is wired correctly:

```
Checking my_sensor...
  ✔  lib/src/my_sensor.g.dart
  ✔  lib/src/generated/kotlin/my_sensor.bridge.g.kt
  ✔  lib/src/generated/swift/my_sensor.bridge.g.swift
  ✔  lib/src/generated/cpp/my_sensor.bridge.g.h
  ✔  lib/src/generated/cpp/my_sensor.bridge.g.cpp
  ✔  lib/src/generated/cmake/my_sensor.CMakeLists.g.txt

Checking CMakeLists.txt...
  ✔  add_library(my_sensor) in src/CMakeLists.txt

Checking android Plugin.kt...
  ✔  System.loadLibrary("my_sensor") in Plugin.kt

Checking iOS podspec...
  ✔  HEADER_SEARCH_PATHS in my_sensor.podspec

my_sensor is healthy — all checks passed.
```

Common errors and fixes:

| Error | Fix |
|---|---|
| `MISSING lib/src/my_sensor.g.dart` | Run `nitrogen generate` |
| `STALE lib/src/my_sensor.g.dart` | Run `nitrogen generate` (spec was changed) |
| `MISSING add_library(my_sensor) in CMakeLists.txt` | Run `nitrogen link` |
| `MISSING System.loadLibrary("my_sensor") in Plugin.kt` | Run `nitrogen link` |
| `MISSING HEADER_SEARCH_PATHS in my_sensor.podspec` | Run `nitrogen link` |

---

## Step 9 — Use your plugin from Dart

```dart
import 'package:my_sensor/my_sensor.dart';

// Synchronous — direct FFI
final temp = MySensor.instance.getTemperature(); // 23.4
final connected = MySensor.instance.isConnected(); // true

// Async — background isolate, returns to main isolate
final id = await MySensor.instance.readManufacturerId();
print(id); // "ACME-SensorChip-v2"

// Properties
MySensor.instance.sampleRate = 100.0; // 100 Hz
MySensor.instance.mode = SensorMode.sampling;

// Stream — zero-copy native events
final sub = MySensor.instance.readings.listen((reading) {
  print('temp=${reading.temperature}  humid=${reading.humidity}');
  print('payload: ${reading.payload.length} bytes (zero-copy)');
  print('ts: ${reading.timestampNs} ns');
});

// Cancel (releases native resources)
sub.cancel();
```

---

## Step 10 — Run the build

**Android:**

```sh
cd example
flutter run -d android
```

**iOS:**

```sh
cd example
flutter run -d ios
```

If the build fails, check:

1. `nitrogen doctor` output (Step 8)
2. Android NDK path in `local.properties`
3. `platform :ios, '13.0'` in `Podfile`
4. `System.loadLibrary("my_sensor")` present in `MySensorPlugin.kt`

---

## What to do when you change the spec

Every time you edit `my_sensor.native.dart`:

```sh
# 1. Regenerate
nitrogen generate

# 2. Verify
nitrogen doctor

# 3. Update your native implementations to match the new spec
#    (Kotlin: MySensorImpl.kt, Swift: MySensorImpl.swift)
```

The generator will emit a `// TODO:` comment anywhere it cannot infer the correct expression (for example, a zero-copy length field it could not find automatically). Search for `TODO` in the generated files after regenerating.

---

## Backpressure options for streams

| Option | Behaviour | Use when |
|---|---|---|
| `Backpressure.dropLatest` | Drop newest item if Dart hasn't consumed | Sensors, camera, high-frequency data |
| `Backpressure.block` | Block the native thread until Dart consumes | Low-frequency, must-not-lose events |
| `Backpressure.bufferDrop` | Ring buffer — drop oldest when full | Bursty data with bounded buffering |

---

## Troubleshooting

### `UnsatisfiedLinkError` on Android

- Verify `System.loadLibrary("my_sensor")` is in `MySensorPlugin.kt`
- Verify `src/CMakeLists.txt` has `add_library(my_sensor ...)`
- Run `nitrogen link` to auto-fix both

### `dlopen failed` / symbol not found on iOS

- Run `nitrogen link` — it fixes `HEADER_SEARCH_PATHS`, adds `DEFINES_MODULE`, creates the `dart_api_dl.c` file, and creates the bridge symlink
- Verify `ios/Classes/<plugin>.bridge.g.swift` is a symlink pointing to `../../lib/src/generated/swift/<plugin>.bridge.g.swift`
- Verify `ios/Classes/dart_api_dl.c` exists (not `.cpp`) — C++ rejects the `void*`/function-pointer cast inside it
- If you see `HybridXxxProtocol not found in scope` — the symlink is dangling; run `nitrogen generate` first to create the generated Swift file, then rebuild

### `Method cannot be marked @objc because the type of the parameter cannot be represented in Objective-C`

This is from an old generated bridge. Regenerate with `nitrogen generate` — the new bridge uses `@_cdecl` top-level functions instead of `@objc` static methods.

### Generated files are stale

```sh
nitrogen doctor   # shows which files are stale
nitrogen generate # regenerates all
```

### `pubspec.yaml` example

```yaml
dev_dependencies:
  nitro_generator: ^0.1.0       # code generator
  build_runner: ^2.4.0
```

### `conflicting types` C compiler error

This means the `.h` and `.cpp` disagree on a return type. Regenerate — this was fixed in Nitrogen 0.2+:

```sh
nitrogen generate
```

### Spec validation errors at generation time

Nitrogen validates your spec before generating. Example errors:

```
nitrogen: lib/src/my_sensor.native.dart
  [ERROR] UNKNOWN_RETURN_TYPE: Method 'getData' returns 'Blob' which is not a known type.
          Hint: Supported types: int, double, bool, String, Uint8List, Future<T>, Stream<T>,
          or a @HybridStruct/@HybridEnum declared in this spec.
```

Fix the type in your spec, then regenerate.

---

## Next steps

- **[Publishing to pub.dev](publishing.md)** — prepare your plugin for release, versioning, and the `dart pub publish` flow
- **[Consuming a plugin](consuming.md)** — how app developers add your plugin and use its API
- Read the **[`nitro` runtime docs](../packages/nitro/README.md)** for the full annotation reference
- Read the **[`nitro_generator` generator docs](../packages/nitrogen/README.md)** for spec validator rules and type mapping details
- Study **[`my_camera`](../my_camera/README.md)** as a production-quality reference implementation
- Run `nitrogen doctor` in CI to catch regressions early
