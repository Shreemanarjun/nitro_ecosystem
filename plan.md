# flutter_hybrid_objects — build plan

> A Flutter-native equivalent of React Native Nitro Modules.
> Write one `.native.dart` spec file. Get Kotlin + Swift + C++ + Dart FFI — all generated.

---

## Vision

```dart
// Math.native.dart  ← you write this
@HybridObject(ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class Math extends HybridObject {
  double add(double a, double b);
}
```

```bash
dart run build_runner build
```

```
✓  lib/src/Math.g.dart           Dart FFI implementation
✓  android/src/.../Math.g.kt     Kotlin JNI stub + protocol
✓  ios/Classes/Math.g.swift      Swift C-bridge + protocol
✓  src/Math.g.h                  C header (shared contract)
✓  CMakeLists.g.txt              CMake fragment
```

Plugin author fills in `MathImpl.kt` and `MathImpl.swift`.
App developer calls `Math.instance.add(1, 2)`. Done.

---

## Comparison with Nitro Modules

| Concept             | Nitro Modules (RN)              | flutter_hybrid_objects          |
|---------------------|---------------------------------|---------------------------------|
| Spec file           | `Math.nitro.ts`                 | `Math.native.dart`              |
| Spec language       | TypeScript interface            | Dart abstract class             |
| Annotation          | `HybridObject<{ios,android}>`   | `@HybridObject(ios:,android:)`  |
| iOS impl            | Swift                           | Swift                           |
| Android impl        | Kotlin                          | Kotlin                          |
| Bridge              | JSI + C++                       | dart:ffi + JNI + C++            |
| Zero-copy frames    | JSI ArrayBuffer                 | AHardwareBuffer / CVPixelBuffer |
| Streams             | NitroEventEmitter               | `Stream<T>` via SendPort        |
| Code generation     | nitrogen CLI (nitrogen_cli)     | nitro_generator CLI            |
| Runtime package     | react-native-nitro-modules      | nitro                           |

---

## Repository layout

```
flutter_hybrid_objects/
├── packages/
│   ├── nitro/                       # 1. Runtime + annotations  (pub.dev)
│   ├── nitro_generator/             # 2. nitro_generator builder (pub.dev, dev dep)
│   └── nitrogen_cli/                # 3. nitrogen CLI tool       (pub global)
├── example/
│   ├── lib/src/camera.native.dart   # The spec — only file author writes
│   ├── lib/src/generated/           # Generated Dart
│   ├── android/src/.../             # Generated Kotlin
│   └── ios/Classes/                 # Generated Swift
└── docs/
    └── getting_started.md
```

---

## Phase 1 — `nitro` (runtime + annotations)

Every plugin adds this as a regular dependency. Zero codegen required to consume — only to build.

### 1.1 Annotation classes

**File:** `lib/src/annotations.dart`

#### `@HybridObject` — the entry point

```dart
class HybridObject {
  final NativeImpl ios;           // which language implements on iOS
  final NativeImpl android;       // which language implements on Android
  final String?    cSymbolPrefix; // override C prefix (default: snake_case classname)
  final String?    lib;           // override .so/.dylib name (default: lib{classname})

  const HybridObject({
    required this.ios,
    required this.android,
    this.cSymbolPrefix,
    this.lib,
  });
}

enum NativeImpl {
  swift,    // iOS: Swift + @_cdecl C bridge
  kotlin,   // Android: Kotlin + JNI bridge
  cpp,      // Both: shared C++ (advanced)
}
```

#### `@HybridStruct` — a type that crosses the native boundary

```dart
class HybridStruct {
  // Fields named here are Uint8List delivered as zero-copy raw pointer.
  // A Finalizer calls the native unlock symbol when the Dart object is GC'd.
  final List<String> zeroCopy;
  final bool packed;  // no C struct padding, default false

  const HybridStruct({this.zeroCopy = const [], this.packed = false});
}
```

#### `@HybridEnum` — a C-compatible integer enum

```dart
class HybridEnum {
  final int startValue;  // first case value, default 0
  const HybridEnum({this.startValue = 0});
}
```

#### Method modifiers

```dart
// Makes a method async. Return type must be Future<T>.
// Dispatched on HybridRuntime's background isolate pool.
const hybrid_async = _HybridAsync();
class _HybridAsync { const _HybridAsync(); }

// Makes a getter a native stream via SendPort dispatch.
// Only valid on abstract getters returning Stream<T>.
class hybrid_stream {
  final Backpressure backpressure;
  const hybrid_stream({this.backpressure = Backpressure.dropLatest});
}

// Marks a Uint8List param as zero-copy (passed as raw ptr, callee must not retain).
const zero_copy = _ZeroCopy();
class _ZeroCopy { const _ZeroCopy(); }

enum Backpressure {
  dropLatest,   // best for sensors/camera: stale frames are useless
  block,        // block native thread until Dart consumes
  bufferDrop,   // ring buffer; oldest item dropped when full
}
```

**Naming rationale:** `snake_case` modifier annotations (`hybrid_async`, `hybrid_stream`, `zero_copy`) are visually distinct from class-level annotations and avoid collisions with popular packages like `async` or `stream`.

---

### 1.2 Base class

**File:** `lib/src/hybrid_object_base.dart`

```dart
// Every spec abstract class extends this.
// The generator checks for this supertype to confirm the class is a valid spec.
abstract class HybridObject {
  void onMemoryTrim() {}  // Android: onTrimMemory signal
  void onDestroy() {}     // Dart object GC'd — release native resources
}
```

---

### 1.3 Runtime

**File:** `lib/src/hybrid_runtime.dart`

The runtime is called only by generated code. Plugin authors and app developers never call it directly.

| Responsibility           | Mechanism                                                 |
|--------------------------|-----------------------------------------------------------|
| Load shared library      | `DynamicLibrary.open()` Android / `.process()` iOS        |
| Bind FFI symbols         | `lib.lookupFunction<N,D>()` — cached per symbol           |
| Async dispatch           | Isolate pool (1 .. `Platform.numberOfProcessors`)         |
| Stream from native       | `ReceivePort` + native `Dart_PostCObject_DL`              |
| Zero-copy buffer release | `Finalizer<int>` calling native unlock symbol on GC       |
| Error propagation        | Thread-local error string on native; read after FFI call  |
| String marshalling       | Per-call Arena allocator; freed immediately after call    |

**API surface (called by generated code only):**

```dart
class HybridRuntime {
  static DynamicLibrary loadLib(String libName);
  static T    callSync<T>(Function fn, List<Object?> args);
  static Future<T> callAsync<T>(Function fn, List<Object?> args);
  static Stream<T> openStream<T>({
    required void Function(int dartPort) register,
    required T    Function(int rawPtr)   unpack,
    required void Function(int rawPtr)   release,
    required Backpressure                backpressure,
  });
  static Future<void> init({int minIsolates = 1});
  static Future<void> dispose();
}
```

---

### 1.4 FFI utilities

**File:** `lib/src/ffi_utils.dart`

```dart
T withArena<T>(T Function(Arena arena) body);  // arena allocator scope

extension StringToNative on String {
  Pointer<Utf8> toNativeUtf8({Allocator allocator = malloc});
}

extension NativeToString on Pointer<Utf8> {
  String toDartString();
}

class ZeroCopyBuffer {
  final Pointer<Uint8> ptr;
  final int length;
  Uint8List get bytes => ptr.asTypedList(length);
  void release();  // explicit early release before GC
}
```

---

### 1.5 pubspec.yaml

```yaml
name: nitro
description: >
  Runtime and annotations for flutter_hybrid_objects.
  Write a .native.dart spec, get Kotlin + Swift + C++ + FFI generated.
version: 0.1.0

environment:
  sdk: '>=3.3.0 <4.0.0'
  flutter: '>=3.19.0'

dependencies:
  flutter: { sdk: flutter }
  ffi: ^2.1.0

dev_dependencies:
  flutter_test: { sdk: flutter }
  flutter_lints: ^4.0.0

flutter:
  plugin:
    platforms:
      android: { ffiPlugin: true }
      ios:     { ffiPlugin: true }
```

---

## Phase 2 — `nitro_generator` (build_runner generator)

`dev_dependency` only. Never ships in app builds.

### 2.1 build.yaml

```yaml
builders:
  hybrid_object_generator:
    import: 'package:flutter_hybrid_gen/builder.dart'
    builder_factories: ['hybridObjectBuilder']
    build_extensions:
      '.native.dart':
        - '.g.dart'
        - '_bridge.g.kt'
        - '_bridge.g.swift'
        - '_bridge.g.h'
        - '_CMakeLists.g.txt'
    auto_apply: dependents
    build_to: source
    applies_builders: ['source_gen|combining_builder']
```

The trigger is the `.native.dart` extension — exactly like Nitro's `.nitro.ts`. Any file ending in `.native.dart` is a spec. Everything ending in `.g.dart`, `_bridge.g.kt`, etc. is generated output.

---

### 2.2 Internal pipeline

```
Foo.native.dart
      │
      ▼  package:analyzer + source_gen
  LibraryReader
      │  collect all @HybridObject classes
      │  collect all @HybridStruct classes in same library
      │  collect all @HybridEnum enums in same library
      ▼
  SpecExtractor
      │  abstract methods            → BridgeFunction (sync)
      │  @hybrid_async methods       → BridgeFunction (async)
      │  @hybrid_stream getters      → BridgeStream
      │  abstract T getters/setters  → BridgeProperty
      │  method params               → BridgeParam (with type mapping)
      ▼
  BridgeSpec  (language-agnostic AST)
      │
      ▼
  SpecValidator  (fail fast, clear error messages)
      │
      ├──▶  DartFfiGenerator     →  Foo.g.dart
      ├──▶  KotlinGenerator      →  Foo_bridge.g.kt
      ├──▶  SwiftGenerator       →  Foo_bridge.g.swift
      ├──▶  CppHeaderGenerator   →  Foo_bridge.g.h
      └──▶  CMakeGenerator       →  Foo_CMakeLists.g.txt
```

---

### 2.3 SpecExtractor — what it reads

| Dart construct                                          | Extracted as                      |
|---------------------------------------------------------|-----------------------------------|
| `abstract class Foo extends HybridObject`               | `BridgeSpec`                      |
| `@HybridObject(ios: NativeImpl.swift, ...)`             | platform targets + lib name       |
| Abstract method, no modifier                            | `BridgeFunction(isAsync: false)`  |
| Abstract method + `@hybrid_async`                       | `BridgeFunction(isAsync: true)`   |
| Abstract getter returning `Stream<T>` + `@hybrid_stream`| `BridgeStream`                    |
| Abstract getter returning `T` (non-Stream)              | `BridgeProperty(setter: false)`   |
| Abstract field / setter                                 | `BridgeProperty(setter: true)`    |
| Method param annotated `@zero_copy`                     | `BridgeParam(zeroCopy: true)`     |
| `@HybridStruct` class referenced in any signature       | `BridgeStruct`                    |
| `@HybridEnum` enum referenced in any signature          | `BridgeEnum`                      |

---

### 2.4 Type mapping table

| Dart type           | C type          | Kotlin type      | Swift type      |
|---------------------|-----------------|------------------|-----------------|
| `int`               | `int64_t`       | `Long`           | `Int64`         |
| `double`            | `double`        | `Double`         | `Double`        |
| `bool`              | `int8_t`        | `Boolean`        | `Bool`          |
| `String`            | `const char*`   | `String`         | `String`        |
| `Uint8List`         | `uint8_t*`+len  | `ByteArray`      | `Data`          |
| `void`              | `void`          | `Unit`           | `Void`          |
| `@HybridStruct` T   | `void*`         | data class `T`   | `struct T`      |
| `@HybridEnum` E     | `int64_t`       | `enum class E` (Long nativeValue) | `enum E: Int64` |
| `Future<T>`         | callback-based  | `suspend fun`    | `async func`    |
| `Stream<T>`         | SendPort reg.   | `Flow<T>`        | `AsyncStream<T>`|

> **Note on enums:** The bridge layer uses `int64_t`/`Long` (not `int32_t`) so that JNI
> `CallStaticLongMethod` can be used uniformly. Each Kotlin enum exposes `.nativeValue: Long`
> and a `fromNative(Long)` companion function. Dart FFI uses `Int64` for all enum types.

---

### 2.5 BridgeSpec AST

```
BridgeSpec
  ├── dartClassName      "Camera"
  ├── lib                "libcamera"
  ├── namespace          "vc"           (C symbol prefix)
  ├── iosImpl            swift
  ├── androidImpl        kotlin
  ├── sourceUri          String         (for import directives)
  │
  ├── structs[]
  │     ├── name, packed
  │     └── fields[]    { name, type, zeroCopy, nullable }
  │
  ├── enums[]
  │     ├── name, startValue
  │     └── values[]    String
  │
  ├── functions[]
  │     ├── dartName     "capturePhoto"
  │     ├── cSymbol      "vc_capture_photo"
  │     ├── isAsync, thread
  │     ├── returnType   BridgeType
  │     └── params[]    { name, type, zeroCopy, nullable }
  │
  ├── streams[]
  │     ├── dartName         "frames"
  │     ├── registerSymbol   "vc_register_frames_stream"
  │     ├── releaseSymbol    "vc_release_frame"
  │     ├── itemType         BridgeType
  │     └── backpressure     Backpressure
  │
  └── properties[]
        ├── dartName     "zoom"
        ├── type         BridgeType
        ├── getSymbol    "vc_get_zoom"
        ├── setSymbol    "vc_set_zoom"
        ├── hasGetter, hasSetter
```

---

### 2.6 SpecValidator rules

```
ERROR   return type contains List<T> — wrap in @HybridStruct with Uint8List field
ERROR   @HybridStruct field type is not primitive / String / Uint8List / @HybridStruct
ERROR   @hybrid_async method does not return Future<T>
ERROR   @hybrid_stream getter does not return Stream<T>
ERROR   @zero_copy applied to non-Uint8List parameter
ERROR   class does not extend HybridObject base class
ERROR   zeroCopy field name in @HybridStruct does not match any declared field
ERROR   duplicate C symbol names (namespace collision across functions)

WARNING large @HybridStruct returned synchronously — consider @hybrid_async
WARNING sync method marshals multiple Strings — arena allocation per call
WARNING high-frequency @hybrid_stream with String item type — prefer Uint8List
```

---

### 2.7 Generator outputs

#### `DartFfiGenerator` → `Foo.g.dart`

- `typedef` pairs (`Native` + `Dart`) for every C function
- `Struct` subclasses for every `@HybridStruct`
- `_FooImpl` class extending the abstract spec
- Static `Foo.instance` accessor
- Sync functions: arena alloc → FFI call → free → return
- Async functions: `HybridRuntime.callAsync(...)` wrapper
- Stream getters: `HybridRuntime.openStream(...)` with unpack + release lambdas
- Properties: getter/setter calling named C symbols
- `part of` directive referencing the spec file

#### `KotlinGenerator` → `Foo_bridge.g.kt`

- `HybridFooSpec` interface — the contract the plugin author implements
- `FooJniBridge` object with `external fun` JNI declarations
- JNI registration helper for `FlutterPlugin.onAttachedToEngine`
- Kotlin data classes for every `@HybridStruct`
- Kotlin enum classes for every `@HybridEnum`
- Header comment: `// Implement HybridFooSpec in FooImpl.kt`

#### `SwiftGenerator` → `Foo_bridge.g.swift`

- `HybridFooProtocol` — the protocol the plugin author conforms to
- `@_cdecl` C bridge functions for every method and property
- `HybridFooRegistry` singleton holding the `HybridFooProtocol?` impl
- Swift structs for every `@HybridStruct`
- Swift enums for every `@HybridEnum`
- Header comment: `// Implement HybridFooProtocol in FooImpl.swift`

#### `CppHeaderGenerator` → `Foo_bridge.g.h`

- `extern "C"` block with every C function signature
- C struct definitions for every `@HybridStruct`
- C enum definitions for every `@HybridEnum`
- Include guards

#### `CMakeGenerator` → `Foo_CMakeLists.g.txt`

- `add_library(libfoo SHARED ...)` fragment
- `target_link_libraries(...)` with `android` and `log`
- `target_compile_definitions(...)` for min SDK
- `include()` this from the plugin's root `CMakeLists.txt`

---

### 2.8 File naming convention

| File                      | Who writes it  | Notes                            |
|---------------------------|----------------|----------------------------------|
| `Camera.native.dart`      | Plugin author  | Spec — triggers codegen          |
| `Camera.g.dart`           | Generated      | Dart FFI impl — commit to VCS    |
| `Camera_bridge.g.kt`      | Generated      | Kotlin stub — commit to VCS      |
| `Camera_bridge.g.swift`   | Generated      | Swift stub — commit to VCS       |
| `Camera_bridge.g.h`       | Generated      | C header — commit to VCS         |
| `Camera_CMakeLists.g.txt` | Generated      | CMake fragment — commit to VCS   |
| `CameraImpl.kt`           | Plugin author  | Real Kotlin implementation       |
| `CameraImpl.swift`        | Plugin author  | Real Swift implementation        |

Generated files are committed to VCS so app developers without `build_runner` can build normally. Regenerate with `dart run build_runner build --delete-conflicting-outputs`.

---

### 2.9 pubspec.yaml

```yaml
name: nitro_generator
description: build_runner code generator for nitro.
version: 0.1.0

environment:
  sdk: '>=3.3.0 <4.0.0'

dependencies:
  analyzer:   '>=6.4.0 <8.0.0'
  build:       ^2.4.0
  source_gen:  ^1.5.0
  dart_style:  ^2.3.0
  path:        ^1.9.0
  nitro:
    path: ../nitro

dev_dependencies:
  build_runner: ^2.4.0
  test:         ^1.25.0
  lints:        ^4.0.0
```

---

## Phase 3 — `nitrogen_cli` (The CLI)

`dart pub global activate flutter_hybrid_cli`

Identical generator output to `build_runner` but without needing it in `pubspec.yaml`. Useful in CI and for one-off generation.

### 3.1 Commands

```
nitrogen generate
    Runs all generators on every *.native.dart in the project.

flutter_hybrid init <PluginName>
    Scaffolds a new Flutter plugin:
      – pubspec.yaml wired with correct dependencies
      – PluginName.native.dart with a starter spec
      – android/ and ios/ directory structure
      – CMakeLists.txt with include() for generated fragment
      – README with setup instructions

flutter_hybrid doctor
    For each *.native.dart in the project:
      – Checks generated files exist and are up to date
      – Runs validator on the spec
      – Verifies lib names match pubspec ffiPlugin declarations
      – Reports OK / STALE / ERROR per spec file

flutter_hybrid clean
    Deletes all *.g.dart, *_bridge.g.kt, *_bridge.g.swift,
    *_bridge.g.h, *_CMakeLists.g.txt files.
```

### 3.2 pubspec.yaml

```yaml
name: flutter_hybrid_cli
description: CLI for flutter_hybrid_objects. Scaffold, generate, and doctor.
version: 0.1.0

environment:
  sdk: '>=3.3.0 <4.0.0'

dependencies:
  args:  ^2.5.0
  path:  ^1.9.0
  nitro_generator:
    path: ../nitrogen

executables:
  nitrogen: nitrogen
```

---

## Phase 4 — Example plugin (camera)

A complete, real camera plugin built with the SDK. Serves as integration test and reference.

### 4.1 What the plugin author writes — 3 files total

```dart
// 1. lib/src/camera.native.dart — the full spec

@HybridStruct(zeroCopy: ['data'])
class CameraFrame {
  final Uint8List data;
  final int width;
  final int height;
  final int stride;
  final int timestampNs;
}

@HybridEnum()
enum FlashMode { off, on, auto, torch }

@HybridObject(ios: NativeImpl.swift, android: NativeImpl.kotlin, lib: 'visioncamera')
abstract class Camera extends HybridObject {
  void start(String deviceId, int width, int height, int fps);
  void stop();

  @hybrid_async
  Future<String> capturePhoto(String outputDir, {int quality = 92});

  @hybrid_stream(backpressure: Backpressure.dropLatest)
  Stream<CameraFrame> get frames;

  double get minZoom;
  double get maxZoom;
  double zoom = 1.0;
  FlashMode flash = FlashMode.off;
}
```

```kotlin
// 2. android/.../CameraImpl.kt
class CameraImpl(context: Context) : HybridCameraSpec {
    // implement generated HybridCameraSpec interface
}
```

```swift
// 3. ios/Classes/CameraImpl.swift
class CameraImpl: HybridCameraProtocol {
    // conform to generated HybridCameraProtocol
}
```

### 4.2 What the app developer writes

```dart
final cam = Camera.instance;
await cam.start('back', 1920, 1080, 30);

cam.frames.listen((frame) {
  // frame.bytes → zero-copy Uint8List view into GPU buffer
  // auto-released when this callback returns
});

final path = await cam.capturePhoto('/tmp/photos');
```

---

## Phase 5 — Testing strategy

### 5.1 Unit tests (no device needed)

| Test target            | What it verifies                                      |
|------------------------|-------------------------------------------------------|
| `SpecExtractor`        | Correct AST from each annotation combination          |
| `SpecValidator`        | Every error and warning rule fires correctly          |
| Generator snapshots    | Generated code matches golden files                   |
| Type mapping           | Every Dart type → correct C / Kotlin / Swift type     |

### 5.2 Integration tests (device / emulator)

| Plugin                  | What it verifies                                      |
|-------------------------|-------------------------------------------------------|
| Math (add, subtract)    | Sync FFI round-trip on Android + iOS                  |
| Echo (String → String)  | String marshalling and arena allocator correctness    |
| Buffer (Uint8List echo) | Zero-copy path, no buffer overflow                    |
| Async (delayed result)  | Isolate pool, Future completion, error propagation    |
| Stream (counter)        | SendPort delivery, backpressure, stream cancel        |
| Camera (full example)   | JNI + AHardwareBuffer + CVPixelBuffer end-to-end      |

---

## Phase 6 — Documentation

```
docs/
├── getting_started.md        5-minute walkthrough: Math.native.dart → working plugin
├── spec_reference.md         Every annotation, field, modifier — full reference
├── type_mapping.md           Dart ↔ C ↔ Kotlin ↔ Swift type table
├── zero_copy.md              AHardwareBuffer + CVPixelBuffer architecture
├── streams.md                SendPort internals, backpressure options explained
├── async.md                  Isolate pool internals, error propagation
├── troubleshooting.md        Common build errors and fixes
└── migrating_from_pigeon.md  Comparison and migration guide from Pigeon
```

---

## Current status (as of 2026-03-23)

| Phase | Status | Notes |
|-------|--------|-------|
| Runtime + annotations (`nitro` package) | ✅ Done | `NitroModule`, `HybridStruct`, `HybridEnum`, `NitroStream`, `NitroAsync`, `Backpressure` |
| `SpecExtractor` + `BridgeSpec` AST | ✅ Done | Extracts functions, properties, streams, structs, enums |
| `nitro_generator` | ✅ Done | JNI Local Frames, direct C++, async/streams |
| `nitrogen link` CLI | ✅ Done | Auto-discovers all modules, wires CMake + Kotlin + Podspec |
| JNI Local Frames | ✅ Done | Systematic PushLocalFrame/PopLocalFrame scoping |
| Isolate Pool 2.0 | ✅ Done | Persistent Result Ports + callId routing (146 µs async) |
| Performance Baseline | ✅ Done | 1.5 µs (Sync) / 8ms (1GB) / 25 TB/s (Unsafe Ptr) |
| JNI name mangling | ✅ Done | Proper `_jniMangle` + `_jniMethodName` per-component utility |
| Example plugin (`my_camera`) | ✅ Done | 3 modules, streams, structs, enums, builds on Android |
| Generator unit tests | ✅ Done | 35 tests covering all generator outputs (no dart:mirrors) |
| `SpecValidator` | ✅ Done | Validates specs, enums, structs, and impl targeting |
| `nitrogen doctor` CLI | ✅ Done | Health-check for generated files, stale detection, wiring |
| Golden-file snapshot tests | ✅ Done | Full coverage for bridge/dart generator output |
| iOS / Android E2E | ✅ Done | Verified on iPhone 17 Pro Max & OnePlus 11 (Release) |

---

## DX improvement roadmap

### Done
- **Multi-module linking** (`nitrogen link`): auto-discovers all `.native.dart` specs, updates CMakeLists.txt, Plugin.kt, and Podspec in one command.
- **Proper JNI mangling** (`_jniMangle` + `_jniMethodName`): escapes underscores in every component (package, class, method). Stream names like `sensor_data` → `emit_1sensor_1data`, not the broken `emit_1sensor_data`.
- **Header/impl type consistency** (`CppHeaderGenerator`): enum-returning functions now declare `int64_t` in the `.h` to match the `.cpp`, eliminating "conflicting types" compiler errors.

### Planned

#### `SpecValidator` (high priority)
Fail early with a clear error before generating anything:
```
ERROR  Camera.native.dart:12 — getStatus() returns DeviceStatus but DeviceStatus is not
       annotated @HybridEnum. Add @HybridEnum() to the enum declaration.

WARNING  Camera.native.dart:20 — Large struct CameraFrame returned synchronously.
         Consider annotating captureFrame() with @NitroAsync.
```

#### `nitrogen doctor` command
```
$ dart run nitrogen_cli doctor
Checking my_camera...
  ✅  my_camera.bridge.g.cpp  — up to date
  ✅  my_camera.bridge.g.kt   — up to date
  ✅  my_camera.bridge.g.h    — up to date
  ❌  my_camera.bridge.g.cpp  — STALE (spec changed 2 commits ago). Run build_runner.

Checking complex...
  ✅  All generated files up to date

Checking verification...
  ✅  All generated files up to date

CMakeLists.txt ............... ✅
android/.../Plugin.kt ........ ✅
ios/my_camera.podspec ........ ✅
```

---

## Delivery order

| Week   | Milestone                                                        |
|--------|------------------------------------------------------------------|
| 1–2    | Runtime + annotations — ✅ done                                  |
| 3–4    | SpecExtractor, BridgeSpec AST — ✅ done                          |
| 5–6    | All generators working on Android — ✅ done                      |
| 7–8    | iOS Swift generator + CMake — ✅ done                            |
| 9–10   | Example plugin (`my_camera`) + `nitrogen link` CLI — ✅ done     |
| 11     | ✅ SpecValidator + `nitrogen doctor` command |
| 12     | ✅ JNI Scoped Frames + Isolate Pool 2.0 + Performance Peak |

---

## Non-goals for v1

- Windows / Linux / macOS desktop (Android + iOS only)
- C++ as primary implementation language (Swift + Kotlin are v1 targets)
- Pigeon-compatible platform channel fallback (pure FFI only)
- Automatic C ABI versioning

---

## Open questions

1. **Struct return size** — return small structs (≤16 bytes) by value across FFI, or always by pointer? By-value is faster; by-pointer is safer for layout differences.

2. **Isolate pool sizing** — fixed pool (e.g. 4 isolates) vs dynamic? Fixed is simpler; dynamic avoids thread explosion on low-core devices.

3. **String encoding** — UTF-8 everywhere, or expose `@utf16` modifier for future Windows support?

4. **Error propagation style** — thread-local error string (Nitro style) vs typed `HybridException` thrown from Dart? Thread-local is simpler to generate; typed exception is more idiomatic Dart.

5. **Generated file location** — next to the spec in `lib/src/`, or always in `lib/src/generated/`? Dedicated subfolder is cleaner but needs a config option.
