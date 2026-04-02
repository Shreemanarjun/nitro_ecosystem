# Changelog
## 0.3.1
### macOS support across the Nitro ecosystem

**Platform targeting** — `@NitroModule` now accepts a `macos` parameter (`NativeImpl.swift` or `NativeImpl.cpp`). Using `NativeImpl.kotlin` on macOS is a validator error (`INVALID_MACOS_IMPL`).

**`nitro_generator`** — `BridgeSpec` gains `macosImpl`, `targetsMacos`, and `targetsAppleCpp` fields. The C++ bridge `#ifdef` guard is now `__APPLE__` (covers both iOS and macOS). `isCppImpl` correctly accounts for macOS.

**`nitrogen link`** — `nitrogen link` now wires the macOS podspec (`linkMacosPodspec`) and macOS Swift plugin (`linkMacosSwiftPlugin`) in a dedicated link step. `nitro.h` is written to `macos/Classes/` alongside `ios/Classes/`.

**`nitrogen doctor`** — A new macOS section checks podspec configuration, C++ headers, bridge files, and Swift plugin registration — on par with the existing iOS checks. The pubspec validator now also inspects the `macos:` platform block.

**Bridge sync** — `syncBridgeFiles` accepts a `platform` parameter so macOS bridge files are correctly copied to `macos/Classes/` with the same `.cpp` → `.mm` rename and Swift-exclusion logic. The `isCppModule()` / `_discoverCppLibs()` detection bug (required two `NativeImpl.cpp` occurrences; broke macOS-only specs) is fixed.


### Zero-copy proxy streaming (`@HybridStruct` + `@NitroStream`)

Generated proxy classes now **extend** the value type instead of only implementing `Finalizable`. Every getter is `@override` and reads lazily from the native heap — no fields are copied until accessed:

```dart
// Generated: BenchmarkBoxProxy extends BenchmarkBox
@override int get color    => _native.ref.color;   // lazy native read
@override double get width  => _native.ref.width;  // lazy native read
@override double get height => _native.ref.height; // lazy native read
```

Because `Proxy <: ValueType`, `Stream<BenchmarkBoxProxy>` satisfies `Stream<BenchmarkBox>` via Dart's covariant generics — no `.map()`, no eager copy, and **no API change** required in consumer code.

### Memory-safe `NativeFinalizer` with generated C release symbols

Each `@HybridStruct` proxy is backed by a generated C function (`${lib}_release_${Struct}`) rather than `malloc.nativeFree`. The finalizer is lazily bound via an idempotent `static void _init(DynamicLibrary dylib)` called once in the impl constructor:

```cpp
// Generated in *.bridge.g.cpp
void benchmark_cpp_release_BenchmarkBox(void* ptr) {
    if (!ptr) return;
    free(ptr);
}
```

### `isLeaf: true` on all sync primitive bindings

All synchronous FFI bindings with primitive-only return types (including property accessors) now use `.asFunction<...>(isLeaf: true)`, skipping the Dart VM safepoint transition (~50–200 ns saved per call on hot paths).

### Indexed lazy decoding for `@HybridRecord` collections

`@HybridRecord` list fields use an **indexed wire format** with an offset table (`[count | int64[count] offsets | blobs...]`), enabling O(1) random item access. The Dart runtime exposes `LazyRecordList<T>` — items are decoded on first access and cached. Kotlin and Swift encode with a `writeIndexedList` helper; the decode path skips the offset table for sequential reads.

### Documentation & benchmark example

- All `benchmark_cpp.native.dart` declarations now have full dartdoc with usage examples.
- `benchmark/README.md` replaced with performance tables, architecture diagram, and zero-copy proxy explanation.
- `packages/nitro/README.md` and top-level `README.md` updated with proxy streaming section and performance comparison table.
- `box_stress_page.dart` `nitroCppStruct` panel now subscribes to `BenchmarkCpp.instance.boxStream`; boxes are rendered via lazy `BenchmarkBoxProxy` field reads directly from native heap.

### Bridge Safety & Memory Hygiene

**JNI Local Reference Management** — Optimized JNI bridge performance by systematically releasing all local references for Strings, Structs, and ByteBuffers. This prevents JNI table overflows and significantly reduces GC pressure during high-throughput operations. Added explicit cleanup in both success and exception paths.

**LazyRecordList Memory Safety** — Transitioned `LazyRecordList` from manual `malloc.free` in `finally` blocks to `NativeFinalizer`-backed cleanup. This ensures that the underlying native buffer remains valid for the entire lifecycle of the Dart object, resolving use-after-free vulnerabilities in asynchronous iteration.

**Struct Deep Release & Integrity** — Reinforced complex type safety by ensuring all `TypedData` fields are eagerly copied during `toDart()` conversion. Added `freeFields()` logic to C++ struct release paths to properly clean up heap-allocated properties (like `char*` strings) before the struct itself is released.

---

## 0.3.0

- Initial workspace setup for the Nitro Modules ecosystem.
- Core packages: `nitro`, `nitro_annotations`, `nitro_generator`.
- CLI tool: `nitrogen_cli`.
- Support for Android and iOS platforms.
- Direct C++ implementation path (`NativeImpl.cpp`) — no JNI or Swift bridge.
- `@HybridStruct`, `@HybridEnum`, `@HybridRecord`, `@NitroStream`, `@nitroAsync` annotations.
- GoogleMock test stubs and CMake fragment generation.
