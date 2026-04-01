# Nitrogen Benchmark Suite

Performance diagnostic engine for the Nitrogen FFI SDK. Measures every layer of the native bridge stack — from raw Dart FFI up through Nitrogen's generated bindings — and visualises the results in a live Flutter dashboard.

---

## What it benchmarks

| Test | Bridge type | Measures |
|---|---|---|
| `add(double, double)` | MethodChannel | Baseline overhead (~30–114 µs) |
| `add(double, double)` | Nitro (Swift/Kotlin) | Platform-bridge dispatch |
| `add(double, double)` | Nitro (C++ direct) | Virtual-dispatch FFI |
| `add(double, double)` | Nitro (Leaf Call) | `isLeaf: true` — skips Dart VM safepoint |
| `add(double, double)` | Raw FFI | Absolute hardware floor |
| `scalePoint(struct, double)` | Nitro (C++ Struct) | Sync zero-copy struct round-trip |
| `computeStats(int)` | Nitro (C++ Async) | `@nitroAsync` Future latency |
| `Uint8List` (1 MB – 1 GB) | All bridges | Throughput · MB/s |
| `boxStream` | Nitro (C++ BoxStream) | Zero-copy struct streaming · frames/s |

---

## Architecture

```
benchmark_cpp.native.dart     ← Nitrogen spec (single source of truth)
        │
        ├── @HybridStruct BenchmarkPoint  (x, y)         packed, zero-copy
        ├── @HybridStruct BenchmarkBox    (color, w, h)  packed, zero-copy stream
        └── @HybridRecord BenchmarkStats  (binary-encoded async return)
```

The generated `benchmark_cpp.g.dart` emits:

- **`BenchmarkPointFfi` / `BenchmarkBoxFfi`** — `dart:ffi Struct` representations
- **`BenchmarkPointProxy` / `BenchmarkBoxProxy`** — zero-copy proxies that *extend* the value type and override every getter to read lazily from the native heap
- **`_BenchmarkCppImpl`** — the hidden FFI impl with `isLeaf: true` on all primitive bindings and `NativeFinalizer`-backed memory management

### Zero-copy proxy pattern

```
C++ emits malloc'd BenchmarkBox* ──► Dart receives Pointer<BenchmarkBoxFfi>
                                              │
                                    BenchmarkBoxProxy(ptr)
                                              │
                               ┌─────────────┴──────────────┐
                               │  extends BenchmarkBox       │
                               │  @override int get color    │
                               │    => _native.ref.color     │  ← lazy read
                               │  @override double get width │
                               │    => _native.ref.width     │  ← lazy read
                               │  @override double get height│
                               │    => _native.ref.height    │  ← lazy read
                               └────────────────────────────┘
                                              │
                               NativeFinalizer →
                               benchmark_cpp_release_BenchmarkBox(ptr)
                               fires on GC — no manual free needed
```

Because `BenchmarkBoxProxy extends BenchmarkBox`, `Stream<BenchmarkBoxProxy>` satisfies `Stream<BenchmarkBox>` via Dart's covariant generics. The stream consumer receives a plain `BenchmarkBox`-typed variable — no API changes needed — but at runtime every field access is a lazy read directly from native heap memory: zero copy, zero allocation.

---

## Results (Release mode)

### iOS — iPhone 17 Pro Max (iOS 26.3, M4 Pro)
Test: 50,000 iterations of `add(1.0, 2.0)`.

| Bridge | Avg latency | vs MethodChannel |
|---|---|---|
| **MethodChannel** | 39.450 µs | 1.0× |
| Nitro Swift/Kotlin | 0.581 µs | 67.9× |
| Nitro C++ direct | 0.524 µs | 75.3× |
| **Nitro Leaf Call** | **0.452 µs** | **87.3×** |
| Raw FFI | 0.444 µs | 88.9× |

### Android — Pixel 6 Pro (Android 14, Tensor G2)

| Bridge | Avg latency | vs MethodChannel |
|---|---|---|
| **MethodChannel** | 114.2 µs | 1.0× |
| Nitro Kotlin | 2.21 µs | 51.7× |
| Nitro C++ direct | 1.96 µs | 58.3× |
| **Nitro Leaf Call** | **1.89 µs** | **60.4×** |
| Raw FFI | 1.81 µs | 63.1× |

### High-bandwidth throughput — 1 GB (iPhone 17 Pro Max)

| Bridge | Time | Throughput |
|---|---|---|
| MethodChannel | ~567 ms | 1,805 MB/s |
| Nitro Swift | ~719 ms | 1,422 MB/s |
| Nitro C++ direct | ~192 ms | 5,326 MB/s |
| **Nitro Leaf Call** | **~108 ms** | **9,455 MB/s** |
| Nitro Unsafe Ptr | ~71 µs | ~14 TB/s † |

> † Unsafe pointer bypasses the 100 ms pinning step, hitting the memory-controller floor.

---

## Running the benchmark

```sh
# From the benchmark/example directory
flutter run --release
```

The app has two tabs:

- **Benchmark** — sequential / simultaneous / one-off tests with charted latency results
- **Stress** — live FPS meters per bridge · high-bandwidth throughput engine · `boxStream` zero-copy struct streaming demo

---

## Package structure

```
benchmark/
├── lib/
│   ├── benchmark.dart                 ← public API export
│   └── src/
│       ├── benchmark_cpp.native.dart  ← Nitrogen spec (edit this)
│       └── benchmark_cpp.g.dart       ← generated — do not edit
├── example/
│   └── lib/
│       ├── benchmark_page.dart              ← sequential/simultaneous tests
│       ├── box_stress_page.dart             ← live stress + boxStream demo
│       └── controllers/
│           ├── benchmark_controller.dart
│           └── visual_benchmark_controller.dart
└── src/                               ← C++ implementation
    └── HybridBenchmarkCpp.cpp
```
