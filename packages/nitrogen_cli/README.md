# nitrogen_cli ⚡

**CLI tool for Nitrogen plugins.** Scaffold, generate, and link Nitrogen FFI plugins from the command line.

---

## Installation

```sh
# From this monorepo (local development):
# In packages/nitrogen_cli:
dart pub global activate --source path .

# Or for users (real package):
# dart pub global activate nitrogen_cli
```

Then add the Dart pub global bin to your `PATH` (one-time setup):

```sh
# Add to ~/.zshrc or ~/.bashrc:
export PATH="$PATH:$HOME/.pub-cache/bin"
```

---

## Commands

### `nitrogen init <PluginName>`

Scaffolds a complete Nitrogen plugin from scratch with optimized native configurations:

```sh
# Create a new plugin named "my_camera"
nitrogen init my_camera
```

**What it creates:**
- Optimized `src/CMakeLists.txt` for Android.
- `ios/Classes/my_camera.cpp` forwarder.
- Pre-configured `ios/my_camera.podspec` (Swift 5.9, iOS 13.0, C++17).
- Starter `lib/src/my_camera.native.dart` spec.
- `pubspec.yaml` pre-wired with `nitro` and `nitrogen`.

### `nitrogen generate`

Scans the current package for `*.native.dart` files and regenerates all outputs.

```sh
# From your plugin root:
nitrogen generate
```

**What it produces (per `*.native.dart` file):**

| Output | Description |
|---|---|
| `lib/src/*.g.dart` | Dart FFI implementation class |
| `lib/src/generated/kotlin/*.kt` | Kotlin JNI bridge + `HybridXxxSpec` interface |
| `lib/src/generated/swift/*.swift` | Swift `@_cdecl` bridge + `HybridXxxProtocol` protocol |
| `lib/src/generated/cpp/*.h` | C header with `extern "C"` declarations |
| `lib/src/generated/cpp/*.cpp` | C++ JNI & Apple bridge implementation |
| `lib/src/generated/cmake/*.txt` | CMake include for Android builds |

### `nitrogen link`

Ensures the native build files (CMake, Podspec) are correctly linked to Nitrogen's generated code. Use this when adding Nitrogen to an existing plugin.

```sh
nitrogen link
```

---

## Complex Specification Example

Nitrogen supports complex types, nested structures, and multiple streams.

```dart
// lib/src/complex.native.dart
import 'package:nitro/nitro.dart';
part 'complex.g.dart';

@HybridEnum(startValue: 0)
enum DeviceStatus { idle, busy, error, fatal }

@HybridStruct(packed: true)
class SensorData {
  final double temperature;
  final double humidity;
  final int lastUpdate;
  const SensorData({required this.temperature, required this.humidity, required this.lastUpdate});
}

@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class ComplexModule extends HybridObject {
  static final ComplexModule instance = _ComplexModuleImpl();

  int calculate(int seed, double factor, bool enabled);
  
  @nitroAsync
  Future<String> fetchMetadata(String url);

  DeviceStatus getStatus();
  void updateSensors(SensorData data);

  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<SensorData> get sensorStream;
}
```

---

## Requirements

| Tool | Minimum |
|---|---|
| Dart SDK | 3.3.0+ |
| Flutter SDK | 3.22.0+ |
| Android NDK | 26.1+ |
| Kotlin | 1.9.0+ |
| iOS Deployment Target | 13.0+ |
| Xcode | 15.0+ |

---

## Related packages

- **[nitro](file:///Users/shreemanarjunsahu/personal/flutter_package/nitro_ecosystem/packages/nitro)** — Runtime (base classes, annotations, helpers)
- **[nitrogen](file:///Users/shreemanarjunsahu/personal/flutter_package/nitro_ecosystem/packages/nitrogen)** — build_runner code generator
