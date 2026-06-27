# Nitrogen — AI Skills Reference

> **Purpose:** This file is the single source of truth for any AI assistant helping a developer use the Nitrogen ecosystem. Read it before writing spec files, generating bridges, or running CLI commands.
>
> **Ground truth sources:** `packages/nitro_annotations/lib/src/annotations.dart`, `packages/nitrogen_cli/README.md`, `NITRO_ECOSYSTEM_PLAN.md`, `nitro_type_coverage/lib/src/nitro_type_coverage.native.dart`.

---

## Table of Contents

1. [Ecosystem Overview](#1-ecosystem-overview)
2. [Writing Spec Files](#2-writing-spec-files)
   - [File conventions](#21-file-conventions)
   - [Module declaration](#22-module-declaration)
   - [Supported types — complete reference](#23-supported-types--complete-reference)
   - [Annotations — complete reference](#24-annotations--complete-reference)
3. [Type Mapping Across Languages](#3-type-mapping-across-languages)
4. [CLI Reference](#4-cli-reference)
5. [Generation Workflow](#5-generation-workflow)
6. [Native Implementation Guide](#6-native-implementation-guide)
   - [Swift (iOS / macOS)](#61-swift-ios--macos)
   - [Kotlin (Android)](#62-kotlin-android)
   - [C++ (all platforms)](#63-c-all-platforms)
7. [Validation Errors & Warnings](#7-validation-errors--warnings)
8. [Platform File Sync](#8-platform-file-sync)
9. [Worked Examples](#9-worked-examples)
10. [Common Mistakes](#10-common-mistakes)

---

## 1. Ecosystem Overview

Nitrogen is a **zero-overhead FFI bridge generator** for Flutter. You write one `.native.dart` spec file per module; the generator produces type-safe native code for every target platform.

### Packages

| Package | Role | Where to add |
|---|---|---|
| `nitro` | Runtime: base classes, FFI helpers, `NativeHandle`, `NitroResultValue` | `dependencies:` |
| `nitro_annotations` | Annotations only (re-exported by `nitro`) | implicit via `nitro` |
| `nitro_generator` | `build_runner` code generator | `dev_dependencies:` |
| `nitrogen_cli` | CLI: `init`, `generate`, `link`, `doctor`, … | `dart pub global activate nitrogen_cli` |

### Three implementation paths

| `NativeImpl` value | What is generated | Best for |
|---|---|---|
| `NativeImpl.swift` | Swift `@_cdecl` bridge | iOS/macOS platform APIs |
| `NativeImpl.kotlin` | Kotlin JNI bridge | Android platform APIs |
| `NativeImpl.cpp` | Abstract C++ virtual interface, no JNI | Pure logic, shared C++ libs |

---

## 2. Writing Spec Files

### 2.1 File conventions

```
lib/src/<name>.native.dart     ← spec file (you write this)
lib/src/<name>.g.dart          ← generated (never edit)
```

Every spec file follows this exact template:

```dart
import 'dart:typed_data';           // only if TypedData types are used
import 'package:nitro/nitro.dart';
part '<name>.g.dart';

// --- Type declarations (enums, structs, records, variants) go here ---

// --- Module declaration goes here ---
```

### 2.2 Module declaration

```dart
@NitroModule(
  lib: 'my_plugin',               // used as C symbol prefix, e.g. my_plugin_add
  ios: NativeImpl.swift,          // required if targeting iOS
  android: NativeImpl.kotlin,     // required if targeting Android
  macos: NativeImpl.swift,        // required if targeting macOS (use swift or cpp, NOT kotlin)
  windows: NativeImpl.cpp,        // optional
  linux: NativeImpl.cpp,          // optional
)
abstract class MyPlugin extends HybridObject {
  static final MyPlugin instance = _MyPluginImpl();  // always required

  // method declarations …
}
```

**Rules:**
- Class must be `abstract` and extend `HybridObject`.
- `static final instance` line is always required — it wires the generated `_MyPluginImpl`.
- `lib` value becomes the C symbol prefix. Use snake_case. Must be unique across all specs in the plugin.
- `macos: NativeImpl.kotlin` is **invalid** — Kotlin is not a macOS language. Use `swift` or `cpp`.
- Omitting a platform (no key) means the generator skips that platform entirely.

### 2.3 Supported types — complete reference

#### Scalars

| Dart type | Notes |
|---|---|
| `int` | 64-bit signed |
| `double` | 64-bit float |
| `bool` | Mapped to `Int8` at C boundary |
| `String` | UTF-8; pointer + length in C |
| `void` | Return only |

#### Nullable scalars

Append `?` to any scalar. Wire uses `NitroNullable` binary encoding (not null-pointer):

```dart
int?    double?    bool?    String?
```

#### TypedData — all 10 variants

```dart
Uint8List    Int8List     Int16List    Int32List
Uint16List   Uint32List   Float32List  Float64List
Int64List    Uint64List
```

All pass as `pointer + size_t length` in C. Add `@zeroCopy` for zero-copy path (no allocation):

```dart
@zeroCopy
Uint8List processBuffer(Uint8List input);
```

#### Collections

```dart
List<int>              // via @HybridRecord JSON codec
List<double>
List<String>
List<@HybridRecord>    // nested binary encode
Map<String, V>         // V = any scalar or @HybridRecord; key must be String
```

Lists and Maps only work as fields inside `@HybridRecord` types, or as `Future<List<T>>` async return types using the JSON codec path.

#### Custom types

```dart
@HybridStruct()    // zero-copy C struct — primitives only
@HybridEnum()      // enum → int64_t at C boundary
@HybridRecord()    // compact binary-encoded complex type
@NitroVariant()    // sealed discriminated union
NativeHandle<T>    // raw opaque pointer with auto-release (@NitroOwned)
NitroResultValue<T> // success/error result (@NitroResult)
```

#### Async and stream return types

```dart
Future<T>          // requires @nitroAsync on the method
Stream<T>          // requires @NitroStream on the method
```

### 2.4 Annotations — complete reference

#### `@NitroModule`

```dart
@NitroModule(lib: 'name', ios: NativeImpl.swift, android: NativeImpl.kotlin)
```

Marks an abstract class as a native module. `lib` sets the C symbol prefix.

---

#### `@HybridEnum`

```dart
@HybridEnum(startValue: 0)   // startValue defaults to 0
enum MyStatus { idle, active, error }
```

Maps each case to an `int64_t`. `startValue` sets the first raw value.

---

#### `@HybridStruct`

```dart
@HybridStruct(packed: true)   // packed: true = tightly packed C struct
class Point3D {
  final double x;
  final double y;
  final double z;
  const Point3D({required this.x, required this.y, required this.z});
}
```

**Rules:**
- All fields must be `final`.
- Only primitives (`int`, `double`, `bool`) and other `@HybridStruct` types as fields.
- No `String`, `List`, or `@HybridRecord` fields — use `@HybridRecord` for those.
- Constructor must be `const`.

---

#### `@HybridRecord`

```dart
@HybridRecord()
class UserProfile {
  final String name;
  final int age;
  final double score;
  final bool active;
  final List<String> tags;
  final MyStatus status;       // @HybridEnum field
  final Point3D origin;        // @HybridStruct field (encoded inline)
  final UserProfile? parent;   // nullable record field
  UserProfile({required this.name, required this.age, ...});
}
```

**Wire format:** `[4B payload-length][fields in declaration order, little-endian]`

**Supported field types:** `int`, `double`, `bool`, `String`, nullable of any of these, `List<primitive>`, `List<@HybridRecord>`, `@HybridEnum`, `@HybridStruct` (inline), `@HybridRecord` (nested), `Uint8List`, `Int32List`, `Float64List`, `Map<String, V>`.

**Rules:**
- Constructor does NOT need to be `const`.
- Fields can be `var` (not required to be `final`).
- The codec reads/writes fields in **declaration order** — field order matters for wire compatibility.

---

#### `@NitroVariant`

```dart
@NitroVariant()
sealed class MyEvent { const MyEvent(); }

class EventTap extends MyEvent {
  final int x;
  final int y;
  const EventTap({required this.x, required this.y});
}

class EventScroll extends MyEvent {
  final double delta;
  const EventScroll({required this.delta});
}

class EventIdle extends MyEvent {
  const EventIdle();
}
```

**Wire format:** `[4B total-length][1B tag: 0, 1, 2, …][case fields using @HybridRecord codec]`

**Rules:**
- The sealed base class must have `const MyEvent();` (empty const constructor).
- Each subclass can have fields of any `@HybridRecord`-compatible type.
- Maximum 10 cases (E014 if exceeded).
- Use as parameter or return type in module methods directly — no wrapping needed.
- Protocol methods receive/return the **concrete enum type** (e.g. `TcEvent`), not `Any`.

---

#### `@NitroOwned`

```dart
@NitroOwned()
NativeHandle<Void> acquireBuffer(int size);

// Generic type param:
@NitroOwned()
NativeHandle<MyStruct> createObject(String id);
```

Returns an opaque native pointer wrapped in `NativeHandle<T>`. Dart automatically frees the native memory when the handle is GC'd via a `NativeFinalizer` backed by the generated `${lib}_${methodName}_release` C symbol.

**Rules:**
- Return type must be `NativeHandle<T>`. The `T` is informational — the bridge always passes `void*`.
- The generator emits `${cSymbol}_release(void* handle)` in the global C bridge section.
- On Apple: `free(handle)` (Swift allocates via system malloc).
- On Android: no-op (Kotlin handle is a `jlong`, managed by GC).

---

#### `@NitroResult`

```dart
@NitroResult()
NitroResultValue<double> safeDiv(double a, double b);

@NitroResult()
NitroResultValue<String> validateLabel(String label);

// With async:
@NitroResult()
@nitroAsync
Future<NitroResultValue<UserProfile>> login(String user, String pass);
```

**Wire format:** `[1B tag: 0=ok, 1=err][payload]`
- tag 0: record-codec bytes for `T`
- tag 1: 4B string length + UTF-8 error message

**Dart usage:**
```dart
final result = myModule.safeDiv(10, 0);
switch (result) {
  case NitroOk(:final value): print('Result: $value');
  case NitroErr(:final message): print('Error: $message');
}
```

**Swift (throws protocol):**
```swift
func safeDiv(a: Double, b: Double) throws -> Double {
    guard b != 0 else { throw NSError(domain: "division by zero", code: 0) }
    return a / b
}
```

---

#### `@nitroAsync`

```dart
@nitroAsync
Future<String> fetchData(String url);
```

Offloads the native call to a background thread. The Dart side returns an already-resolved `Future`. Return type must be `Future<T>`.

---

#### `@NitroStream`

```dart
@NitroStream(backpressure: Backpressure.dropLatest)
Stream<SensorData> get sensorStream;

@NitroStream(backpressure: Backpressure.block)
Stream<String> get logStream;

@NitroStream(backpressure: Backpressure.batch, batchMaxSize: 16)
Stream<int> get dataStream;
```

**Backpressure strategies:**

| Strategy | Behaviour when consumer is behind |
|---|---|
| `Backpressure.dropLatest` | Discard the newest item (default) |
| `Backpressure.dropOldest` | Discard the oldest buffered item |
| `Backpressure.block` | Block the native emitter thread until Dart consumes |
| `Backpressure.batch` | Accumulate up to `batchMaxSize` items; emit as a batch |

Supported stream item types: `int`, `double`, `bool`, `String`, `Uint8List`, `@HybridEnum`, `@HybridStruct`, `@HybridRecord`.

---

#### `@zeroCopy`

```dart
@zeroCopy
Uint8List processImage(Uint8List pixels);
```

Enables zero-copy path for `TypedData` returns. The native side returns a `malloc`-owned buffer; Dart attaches a `NativeFinalizer` to free it without copying. Do NOT use `@zeroCopy` on params — only on returns.

---

## 3. Type Mapping Across Languages

### Dart → Swift

| Dart | Swift (protocol) | Swift (C @_cdecl) |
|---|---|---|
| `int` | `Int64` | `Int64` |
| `double` | `Double` | `Double` |
| `bool` | `Bool` | `Int8` (0/1) |
| `String` | `String` | `UnsafePointer<CChar>?` |
| `void` | — | `Void` |
| `int?` | `Int64?` | `uint8_t*` (NitroNullableInt) |
| `double?` | `Double?` | `uint8_t*` (NitroNullableDouble) |
| `bool?` | `Bool?` | `uint8_t*` (NitroNullableBool) |
| `String?` | `String?` | `UnsafePointer<CChar>?` |
| `Uint8List` | `Data` | `uint8_t*` + `Int64 length` |
| `@HybridStruct T` | `T` | `void*` |
| `@HybridEnum T` | `T` | `Int64` |
| `@HybridRecord T` | `T` (NitroEncodable) | `uint8_t*` |
| `@NitroVariant T` | `T` (enum with fromReader) | `uint8_t*` |
| `NativeHandle<T>` | `UnsafeMutableRawPointer?` | `void*` |
| `NitroResultValue<T>` | `throws -> T` | `uint8_t*` |
| `Future<T>` | `async throws -> T` | via Dart port |
| `Stream<T>` | `AnyPublisher<T, Never>` (Combine) | `void` emitter |

### Dart → Kotlin

| Dart | Kotlin (interface) | JNI type |
|---|---|---|
| `int` | `Long` | `jlong` |
| `double` | `Double` | `jdouble` |
| `bool` | `Boolean` | `jboolean` |
| `String` | `String` | `jstring` |
| `void` | `Unit` | `void` |
| `int?` | `Long?` | `jbyteArray` (NitroNullableInt) |
| `double?` | `Double?` | `jbyteArray` |
| `bool?` | `Boolean?` | `jbyteArray` |
| `Uint8List` | `ByteArray` | `jbyteArray` |
| `@HybridStruct T` | `TStruct` | `jbyteArray` |
| `@HybridEnum T` | `T` | `jlong` |
| `@HybridRecord T` | `T` | `jbyteArray` |
| `@NitroVariant T` | `T` (sealed) | `jbyteArray` |
| `NativeHandle<T>` | `Long` | `jlong` |
| `NitroResultValue<T>` | throws `Exception` | `jbyteArray` |
| `Future<T>` | `suspend : T` | Kotlin coroutine |
| `Stream<T>` | `Flow<T>` | Kotlin Flow |

### Dart → C++ (interface only)

| Dart | C++ |
|---|---|
| `int` | `int64_t` |
| `double` | `double` |
| `bool` | `bool` |
| `String` | `const std::string&` (param) / `std::string` (return) |
| `int?` | `int64_t` (nullable stripped) |
| `Uint8List` | `const std::vector<uint8_t>& data, size_t length` |
| `@HybridStruct T` | `const T& t` (param) / `T` (return) |
| `@HybridEnum T` | `T` |
| `@HybridRecord T` | `NitroCppBuffer` |
| `@NitroVariant T` | `NitroCppBuffer` |
| `NativeHandle<T>` | `void*` |

---

## 4. CLI Reference

Install once:
```sh
dart pub global activate nitrogen_cli
export PATH="$PATH:$HOME/.pub-cache/bin"   # add to ~/.zshrc or ~/.bashrc
```

### `nitrogen init`

Scaffold a new plugin from scratch.

```sh
nitrogen init                                           # interactive TUI
nitrogen init --name my_plugin                          # named, TUI progress
nitrogen init --no-ui --name my_plugin                  # headless / CI
nitrogen init --no-ui --name my_plugin \
              --org com.example \
              --platforms android,ios,macos,windows,linux
```

| Flag | Default | Description |
|---|---|---|
| `--name`, `-n` | — | Plugin name (required for `--no-ui`) |
| `--org` | `com.example` | Organisation identifier (Android/iOS) |
| `--dir`, `-d` | `.` | Parent directory to create plugin in |
| `--platforms`, `-p` | `android,ios,macos,windows,linux` | Comma-separated target platforms |
| `--no-ui` | `false` | Headless output (requires `--name`) |

### `nitrogen generate`

Generate all bridges from `*.native.dart` specs.

```sh
nitrogen generate                  # TUI output
nitrogen generate --no-ui          # CI / headless
nitrogen generate --no-ui --fail-on-warn   # exit 2 if warnings present
```

| Flag | Default | Description |
|---|---|---|
| `--no-ui` | `false` | Headless `[nitro]`-prefixed output |
| `--fail-on-warn` | `false` | Exit code 2 on spec warnings |

**Exit codes:** `0` = success, `1` = generation error, `2` = warnings + `--fail-on-warn`.

**CI example:**
```yaml
- name: Generate bridges
  run: nitrogen generate --no-ui --fail-on-warn
```

### `nitrogen link`

Wire native build files to generated code (CMake, Podspec, `.clangd`, plugin registrars).

```sh
nitrogen link           # TUI with confirmation
nitrogen link --yes     # skip confirmation
nitrogen link --no-ui   # headless (implies --yes)
```

| Flag | Default | Description |
|---|---|---|
| `--yes`, `-y` | `false` | Skip confirmation prompt |
| `--no-ui` | `false` | Headless output |

Run `link` once after `init` and again whenever you add a new spec file.

### `nitrogen doctor`

Health-check every layer of the native build. Read-only.

```sh
nitrogen doctor           # TUI
nitrogen doctor --no-ui   # CI / headless (exit 1 on errors)
```

| Flag | Default | Description |
|---|---|---|
| `--no-ui` | `false` | Plain-text `[nitro:ok]` / `[nitro:warn]` / `[nitro:error]` output |

**CI example:**
```yaml
- name: Nitrogen health check
  run: nitrogen doctor --no-ui
```

### `nitrogen watch`

Re-generate on every spec file change (250ms debounce).

```sh
nitrogen watch           # streaming TUI
nitrogen watch --no-ui   # headless
```

### `nitrogen clean`

Delete all generated files and build cache.

```sh
nitrogen clean           # TUI
nitrogen clean --no-ui   # headless
```

### `nitrogen migrate`

Migrate CocoaPods plugin to Swift Package Manager (Flutter 3.41+ nested layout).

```sh
nitrogen migrate              # interactive
nitrogen migrate --dry-run    # preview without writing
nitrogen migrate --no-backup  # skip backup
nitrogen migrate --no-ui      # headless
```

### `nitrogen update`

Self-update the CLI to the latest pub.dev release.

```sh
nitrogen update           # TUI
nitrogen update --no-ui   # headless
```

### `nitrogen open`

Open the spec file in your editor.

```sh
nitrogen open
```

---

## 5. Generation Workflow

The canonical workflow for a new plugin:

```sh
# 1. Scaffold
nitrogen init --name my_plugin --org com.example --platforms android,ios,macos

# 2. Edit the spec
#    lib/src/my_plugin.native.dart — define your API here

# 3. Generate bridges
nitrogen generate

# 4. Wire the build system
nitrogen link

# 5. Write native implementations
#    ios/Classes/MyPluginImpl.swift
#    android/src/main/kotlin/.../MyPluginImpl.kt
#    (or src/HybridMyPlugin.cpp for NativeImpl.cpp)

# 6. Health check
nitrogen doctor

# 7. Ongoing — re-generate after spec changes
nitrogen generate
# (link is only needed when you add a new spec file)
```

### After every `generate` (Apple platforms only)

`build_runner` writes to `lib/src/generated/`. The CocoaPods build reads from `ios/Classes/` and `macos/Classes/`. These must be kept in sync **manually** (or via `run_tests.sh` if you have an integration test plugin):

```sh
BASE=path/to/my_plugin
GEN="$BASE/lib/src/generated"

# Swift bridge
cp "$GEN/swift/my_plugin.bridge.g.swift" "$BASE/ios/Classes/"
cp "$GEN/swift/my_plugin.bridge.g.swift" "$BASE/macos/Classes/"

# ObjC++ bridge (contains _release symbols and the C wrapper functions)
cp "$GEN/cpp/my_plugin.bridge.g.cpp" "$BASE/ios/Classes/my_plugin.bridge.g.mm"
cp "$GEN/cpp/my_plugin.bridge.g.cpp" "$BASE/macos/Classes/my_plugin.bridge.g.mm"
cp "$GEN/cpp/my_plugin.bridge.g.h"   "$BASE/ios/Classes/"
cp "$GEN/cpp/my_plugin.bridge.g.h"   "$BASE/macos/Classes/"
```

`nitrogen generate` performs this sync automatically. If you use `dart run build_runner build` directly, you must sync manually.

---

## 6. Native Implementation Guide

### 6.1 Swift (iOS / macOS)

The generator produces a protocol. Conform to it in your `*Impl.swift`:

```swift
// ios/Classes/MyPluginImpl.swift
import Foundation

public class MyPluginImpl: MyPluginProtocol {

    // Scalar sync
    public func echoInt(value: Int64) -> Int64 { value }
    public func echoString(value: String) -> String { value }

    // Nullable — use Swift optional directly
    public func echoNullableInt(value: Int64?) -> Int64? { value }

    // @HybridStruct — use the generated Swift struct
    public func echoPoint(value: TcPoint) -> TcPoint { value }

    // @HybridRecord — NitroEncodable protocol
    public func echoConfig(value: TcConfig) -> TcConfig { value }

    // @nitroAsync — regular func (bridge dispatches to background thread)
    public func asyncInt(value: Int64) -> Int64 { value }

    // @NitroStream — NOT a property; the bridge registers/releases the stream
    // (no method body needed here; stream emitting is done via publish/emit helpers)

    // @NitroResult — throws instead of returning NitroResultValue
    public func safeDiv(a: Double, b: Double) throws -> Double {
        guard b != 0 else { throw NSError(domain: "division by zero", code: 0) }
        return a / b
    }

    // @NitroVariant — concrete enum type (not Any)
    public func echoEvent(event: TcEvent) -> TcEvent { event }

    // @NitroOwned — returns UnsafeMutableRawPointer? (NOT NativeHandle<T>)
    public func acquireBuffer(size: Int64) -> UnsafeMutableRawPointer? {
        UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    }

    // Exception from native
    public func throwNative(message: String) {
        throw NSError(domain: "NitroError", code: 0,
                      userInfo: [NSLocalizedDescriptionKey: message])
    }
}
```

**Key rules for Swift implementations:**
- `@NitroResult` methods use `throws -> T`, **not** `-> NitroResultValue<T>`.
- `@NitroOwned` methods return `UnsafeMutableRawPointer?`, **not** `NativeHandle<T>`.
- `@NitroVariant` params/returns use the concrete sealed type (e.g. `TcEvent`), **not** `Any`.
- `@nitroAsync` methods are regular (non-async) Swift functions; the bridge handles threading.
- Do NOT add `async` to methods that use `@nitroAsync` — only to methods that use `Future` + `@NitroStream`.

### 6.2 Kotlin (Android)

The generator produces an interface. Implement it in your `*Impl.kt`:

```kotlin
// android/src/main/kotlin/.../MyPluginImpl.kt
package com.example.my_plugin

class MyPluginImpl : MyPluginInterface {

    override fun echoInt(value: Long): Long = value
    override fun echoString(value: String): String = value

    // Nullable — Kotlin nullable directly
    override fun echoNullableInt(value: Long?): Long? = value

    // @HybridStruct — generated data class
    override fun echoPoint(value: TcPointStruct): TcPointStruct = value

    // @nitroAsync — suspend fun
    override suspend fun asyncInt(value: Long): Long = value

    // @NitroResult — throw exception; bridge encodes as NitroErr
    override fun safeDiv(a: Double, b: Double): Double {
        if (b == 0.0) throw Exception("division by zero")
        return a / b
    }

    // @NitroVariant — sealed class
    override fun echoEvent(event: TcEvent): TcEvent = event

    // @NitroOwned — return a Long handle (opaque; do NOT free in Kotlin; GC manages)
    override fun acquireBuffer(size: Long): Long = size   // or a real ByteBuffer address
}
```

**Key rules for Kotlin implementations:**
- `@nitroAsync` methods are `suspend fun`.
- `@NitroResult` methods throw an `Exception`; the bridge catches and encodes it.
- `@NitroOwned` returns a `Long` (opaque handle; Kotlin GC manages the lifetime).
- `@NitroVariant` param/returns use the concrete sealed class.

### 6.3 C++ (all platforms)

When `NativeImpl.cpp` is used, subclass the generated `Hybrid*` abstract class:

```cpp
// src/HybridMyPlugin.cpp
#include "my_plugin.native.g.h"    // generated abstract interface

class HybridMyPluginImpl : public HybridMyPlugin {
public:
    double add(double a, double b) override { return a + b; }
    std::string greet(const std::string& name) override { return "Hello, " + name; }

    // @NitroStream — emit via generated helper
    void startEmitting() {
        emit_dataStream(42);   // generated by the bridge
    }
};

// Register on library load
static HybridMyPluginImpl g_impl;

__attribute__((constructor))
static void my_plugin_auto_register() {
    my_plugin_register_impl(&g_impl);
}
```

---

## 7. Validation Errors & Warnings

The generator validates specs before writing any file. All errors are reported together.

| Code | Severity | Triggered by |
|---|---|---|
| `E001` | error | Unsupported type: `Map<K,V>` where K ≠ `String`, or `dynamic`, `Object` |
| `E002` | error | `@nitroAsync` on a non-`Future` return type |
| `E003` | error | Duplicate method name in same spec |
| `E004` | error | `@HybridStruct` with `var` (mutable) fields — all must be `final` |
| `E005` | error | `@ZeroCopy` on a non-TypedData field |
| `E006` | error | Circular struct dependency (A → B → A) |
| `E007` | error | Non-nullable named optional param with no default value |
| `E014` | error | `@NitroVariant` with more than 10 cases |
| `INVALID_MACOS_IMPL` | error | `macos: NativeImpl.kotlin` in `@NitroModule` |
| `W001` | warn | Non-nullable named param with no `defaultLiteral` |
| `W002` | warn | Enum-typed optional param with no default |
| `W003` | warn | Struct-typed optional param with no default |
| `W004` | warn | `Stream<T>` return without `@NitroStream` annotation |

Use `--fail-on-warn` to promote warnings to errors in CI.

---

## 8. Platform File Sync

This is the most common source of confusing "symbol not found" or "stale bridge" errors.

### What `nitrogen generate` writes

All generated files go to `lib/src/generated/`. This is the canonical output:

```
lib/src/generated/
├── swift/    *.bridge.g.swift      ← Swift @_cdecl bridge
├── kotlin/   *.bridge.g.kt         ← Kotlin JNI bridge
└── cpp/      *.bridge.g.{h,cpp}    ← C bridge header + ObjC++ bridge
              *.native.g.h          ← Abstract C++ interface (NativeImpl.cpp only)
              test/*.mock.g.h       ← GoogleMock stub (NativeImpl.cpp only)
```

### What CocoaPods reads (Apple platforms)

CocoaPods reads from `ios/Classes/` and `macos/Classes/`. You must sync:

| Source | Destination | When needed |
|---|---|---|
| `generated/swift/*.bridge.g.swift` | `ios/Classes/*.bridge.g.swift` | After every generate |
| `generated/swift/*.bridge.g.swift` | `macos/Classes/*.bridge.g.swift` | After every generate |
| `generated/cpp/*.bridge.g.cpp` | `ios/Classes/*.bridge.g.mm` | After every generate (note `.mm` extension) |
| `generated/cpp/*.bridge.g.cpp` | `macos/Classes/*.bridge.g.mm` | After every generate |
| `generated/cpp/*.bridge.g.h` | `ios/Classes/*.bridge.g.h` | After every generate |
| `generated/cpp/*.bridge.g.h` | `macos/Classes/*.bridge.g.h` | After every generate |

**Why `.mm`?** CocoaPods compiles `.mm` as Objective-C++ (`#import <Foundation/Foundation.h>` etc. in the bridge), which is required for the `@try`/`@catch` ObjC exception handling in the C bridge wrapper functions.

`nitrogen generate` performs this sync automatically. Use `dart run build_runner build` only for faster iteration; remember to sync manually afterward.

### What Android reads

Android reads directly from `lib/src/generated/kotlin/` via `sourceSets` in `android/build.gradle` (wired by `nitrogen link`). No manual sync needed.

### What CMake reads

Windows/Linux CMake reads `lib/src/generated/cpp/` via the generated `.CMakeLists.g.txt` fragment (included by `src/CMakeLists.txt`, wired by `nitrogen link`). No manual sync needed.

---

## 9. Worked Examples

### Example A — Simple plugin (Swift/Kotlin)

```dart
// lib/src/math.native.dart
import 'package:nitro/nitro.dart';
part 'math.g.dart';

@HybridEnum(startValue: 0)
enum RoundMode { floor, round, ceil }

@NitroModule(lib: 'math', ios: NativeImpl.swift, android: NativeImpl.kotlin, macos: NativeImpl.swift)
abstract class Math extends HybridObject {
  static final Math instance = _MathImpl();

  double add(double a, double b);
  double multiply(double a, double b);
  int round(double value, RoundMode mode);

  @nitroAsync
  Future<double> heavyCompute(double input);
}
```

```sh
nitrogen generate && nitrogen link
```

Swift implementation:
```swift
public class MathImpl: MathProtocol {
    public func add(a: Double, b: Double) -> Double { a + b }
    public func multiply(a: Double, b: Double) -> Double { a * b }
    public func round(value: Double, mode: RoundMode) -> Int64 {
        switch mode {
        case .floor: return Int64(Foundation.floor(value))
        case .round: return Int64(Foundation.round(value))
        case .ceil:  return Int64(Foundation.ceil(value))
        }
    }
    public func heavyCompute(input: Double) -> Double {
        // called on background thread by the bridge
        return sqrt(input) * 1_000_000
    }
}
```

---

### Example B — Struct + Stream

```dart
// lib/src/sensor.native.dart
import 'package:nitro/nitro.dart';
part 'sensor.g.dart';

@HybridStruct(packed: true)
class SensorReading {
  final double temperature;
  final double humidity;
  final int timestamp;
  const SensorReading({required this.temperature, required this.humidity, required this.timestamp});
}

@NitroModule(lib: 'sensor', ios: NativeImpl.swift, android: NativeImpl.kotlin, macos: NativeImpl.swift)
abstract class SensorModule extends HybridObject {
  static final SensorModule instance = _SensorModuleImpl();

  SensorReading getLatestReading();

  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<SensorReading> get readings;
}
```

Dart usage:
```dart
// One-shot
final reading = SensorModule.instance.getLatestReading();
print('Temp: ${reading.temperature}');

// Stream
SensorModule.instance.readings.listen((r) {
  print('${r.temperature}°C @ ${r.timestamp}');
});
```

---

### Example C — Variant + Result

```dart
// lib/src/events.native.dart
import 'package:nitro/nitro.dart';
part 'events.g.dart';

@NitroVariant()
sealed class UserAction { const UserAction(); }

class ActionTap extends UserAction {
  final int x;
  final int y;
  const ActionTap({required this.x, required this.y});
}

class ActionSwipe extends UserAction {
  final double velocity;
  const ActionSwipe({required this.velocity});
}

@NitroModule(lib: 'events', ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class EventProcessor extends HybridObject {
  static final EventProcessor instance = _EventProcessorImpl();

  @NitroResult()
  NitroResultValue<String> processAction(UserAction action);
}
```

Dart usage:
```dart
final result = EventProcessor.instance.processAction(ActionTap(x: 10, y: 20));
switch (result) {
  case NitroOk(:final value): print('Processed: $value');
  case NitroErr(:final message): print('Failed: $message');
}
```

---

### Example D — NativeImpl.cpp (shared C++ logic)

```dart
// lib/src/engine.native.dart
import 'package:nitro/nitro.dart';
part 'engine.g.dart';

@NitroModule(lib: 'engine', ios: NativeImpl.cpp, android: NativeImpl.cpp, macos: NativeImpl.cpp)
abstract class Engine extends HybridObject {
  static final Engine instance = _EngineImpl();

  double compute(double input);
  String version();
}
```

```sh
nitrogen generate   # produces engine.native.g.h (abstract C++ class)
nitrogen link       # wires CMake, podspec
```

```cpp
// src/HybridEngine.cpp
#include "engine.native.g.h"
#include <cmath>
#include <string>

class HybridEngineImpl : public HybridEngine {
public:
    double compute(double input) override { return std::sqrt(input) * 1e6; }
    std::string version() override { return "1.0.0"; }
};

static HybridEngineImpl g_engine;

__attribute__((constructor))
static void engine_auto_register() {
    engine_register_impl(&g_engine);
}
```

---

## 10. Common Mistakes

### Wrong return type for `@NitroOwned`

```dart
// WRONG — impl returns UnsafeMutableRawPointer?, not NativeHandle<T>
public func acquireBuffer(size: Int64) -> NativeHandle<Void> { ... }  // ❌

// CORRECT
public func acquireBuffer(size: Int64) -> UnsafeMutableRawPointer? {  // ✅
    return UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
}
```

### Wrong protocol type for `@NitroVariant`

```dart
// WRONG — bridge generates concrete type, not Any
public func echoEvent(event: Any) -> Any { ... }  // ❌

// CORRECT
public func echoEvent(event: TcEvent) -> TcEvent { ... }  // ✅
```

### Wrong protocol for `@NitroResult`

```dart
// WRONG
public func safeDiv(a: Double, b: Double) -> NitroResultValue<Double> { ... }  // ❌

// CORRECT — throws, and the bridge encodes the error
public func safeDiv(a: Double, b: Double) throws -> Double { ... }  // ✅
```

### Using `macos: NativeImpl.kotlin`

```dart
// WRONG — Kotlin is not a macOS language
@NitroModule(lib: 'x', ios: NativeImpl.swift, android: NativeImpl.kotlin, macos: NativeImpl.kotlin)  // ❌

// CORRECT
@NitroModule(lib: 'x', ios: NativeImpl.swift, android: NativeImpl.kotlin, macos: NativeImpl.swift)   // ✅
```

### Forgetting to sync Apple platform files

```sh
# WRONG — running build_runner directly without syncing
dart run build_runner build   # generates lib/src/generated/ but NOT ios/Classes/

# CORRECT
nitrogen generate              # generates AND syncs
# OR, if using build_runner directly:
dart run build_runner build && \
  cp lib/src/generated/swift/*.bridge.g.swift ios/Classes/ && \
  cp lib/src/generated/swift/*.bridge.g.swift macos/Classes/ && \
  cp lib/src/generated/cpp/*.bridge.g.cpp ios/Classes/*.bridge.g.mm && \
  cp lib/src/generated/cpp/*.bridge.g.cpp macos/Classes/*.bridge.g.mm && \
  cp lib/src/generated/cpp/*.bridge.g.h ios/Classes/ && \
  cp lib/src/generated/cpp/*.bridge.g.h macos/Classes/
```

### `@HybridStruct` with mutable fields

```dart
// WRONG
@HybridStruct()
class Point {
  var x: double;   // ❌ var not allowed
}

// CORRECT
@HybridStruct()
class Point {
  final double x;  // ✅ must be final
  const Point({required this.x});
}
```

### `@NitroVariant` base class missing const constructor

```dart
// WRONG
@NitroVariant()
sealed class MyEvent {}   // ❌ missing const constructor

// CORRECT
@NitroVariant()
sealed class MyEvent { const MyEvent(); }  // ✅
```

### Stale `.bridge.g.mm` after generator fix

If you update the generator (`dart pub upgrade`), always re-run `nitrogen generate` — the `.mm` files in `ios/Classes/` and `macos/Classes/` are copies that go stale independently.

### `Stream<T>` without `@NitroStream`

```dart
// WRONG — produces W004 warning, will not be bridged
Stream<double> get dataStream;  // ❌

// CORRECT
@NitroStream(backpressure: Backpressure.dropLatest)
Stream<double> get dataStream;  // ✅
```

---

*Generated by AI from ground-truth source files. Last updated: 2026-06-26.
Update this file whenever new annotations are added to `nitro_annotations` or new CLI commands are added to `nitrogen_cli`.*
