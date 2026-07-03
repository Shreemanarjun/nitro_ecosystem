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

## Automated runs & regression gate

The headless harness (`example/lib/harness/bench_harness.dart`) measures every
bridge tier — raw FFI floor, Nitro leaf/checked/Swift-Kotlin paths,
MethodChannel — plus string, struct, `@nitroAsync` record, and 16–64 MiB
buffer-throughput cases, with warmup + batch timing + median-of-K-samples
methodology.

```sh
# Quick relative-gated run on macOS (default)
tool/bench.sh

# Full run on a connected Android device
tool/bench.sh -d <device-id> --mode full

# Record this machine's numbers as the new baseline
tool/bench.sh --mode full --update-baseline
```

The script regenerates the bridges, drives
`integration_test/benchmark_regression_test.dart` in profile mode, prints a
markdown **analysis** (per-tier overhead, calls-per-frame budget, Δ vs the
recorded baseline, practical guidance, cross-platform matrix), and archives
the JSON report to `benchmark/results/<platform>-<mode>.json`.

### Platform matrix

The same harness runs on all six targets. Cases whose bridge tier doesn't
exist on a platform are auto-skipped and reported as such; the core
Nitro-vs-raw-FFI gates stay mandatory everywhere.

| Platform | How to run | Notes |
|---|---|---|
| macOS | `tool/bench.sh -d macos` | Reference platform; baseline recorded |
| Android | `tool/bench.sh -d <device-id>` | Physical device required for `--profile`; Kotlin/JNI + C++ + channel tiers |
| iOS | `tool/bench.sh -d <device-id>` | Physical device required for `--profile` (simulators only support `--debug`) |
| Windows | `tool/bench.sh -d windows` | C++ tiers + MethodChannel (MSVC plugin); CI: `bench-windows` job |
| Linux | `xvfb-run -a tool/bench.sh -d linux` | C++ tiers + MethodChannel (GTK plugin); CI: `bench-linux` job |
| Web | — | No FFI on web; the in-app dashboard's pure-Dart stub is the only comparison |

On Windows/Linux the "platform bridge" tier is the direct C++ implementation
(there is no Swift/Kotlin); all three Nitro module libraries are built by the
plugin's CMake via the shared `src/` tree and bundled next to the executable.

### The reference workload — provably identical work on every tier

Trivial `add(a, b)` calls measure pure dispatch. For a fair "real work"
comparison the suite also runs **FNV-1a 64-bit** (`hashBuffer(data, rounds)`,
1 KiB × 16 rounds) on every bridge tier:

| Tier | Where the algorithm runs |
|---|---|
| Raw FFI | `fnv1a_hash` C export (`src/nitro_workload.h`) |
| Nitro C++ | `HybridBenchmarkCpp::hashBuffer` — same C routine |
| Nitro platform bridge | Kotlin (Android) / Swift (Apple) / C++ (desktop) — same algorithm, same language as the channel handler |
| MethodChannel | The platform handler — Kotlin / Swift / MSVC C++ / GTK C++ |

FNV-1a was chosen because it is a handful of lines that are trivially
identical in C, C++, Kotlin, Swift, and Dart (64-bit multiplication wraps mod
2^64 in all of them), strictly sequential and CPU-bound (nothing for a smart
compiler to elide), and **self-verifying** — before timing anything, the
harness calls every tier once and asserts all hashes are bit-identical. A
run where any tier disagrees fails outright, so published numbers always
compare the exact same computation.

Pairing matters: on Android the channel handler and the Nitro platform
bridge both run the *Kotlin* implementation — comparing those two isolates
pure bridge cost with the language held constant. `Nitro C++` vs `Raw FFI`
does the same for the C tier.

### Two-level regression gate

| Gate (`NITRO_BENCH_GATE`) | What it enforces | Where to use |
|---|---|---|
| `relative` (default) | Machine-independent invariants: Nitro leaf ≤ 2.5× raw FFI + 1µs budget · Nitro checked ≤ 4× raw FFI + 1.5µs budget · Nitro ≥ 5× faster than MethodChannel | CI on shared runners |
| `all` | The above **plus** absolute µs vs the checked-in `example/assets/baselines/<platform>.json` (±35% tolerance, `NITRO_BENCH_TOLERANCE_PCT`) | Dedicated hardware |
| `none` | Nothing — measure and report only | Exploration |

The invariants are `ratio × rawFFI + absolute overhead budget` because the raw
FFI floor is ~15ns on Apple Silicon — Nitro's healthy fixed dispatch cost
(~0.3µs: instance lookup + error slot) would fail any pure ratio. The gates
only trip on real architectural regressions — a binding losing `isLeaf`, an
accidental allocation, or an async hop in the call path — which each add ≥1µs
on any machine.

### Sample automated run (macOS, Apple M4 Pro, profile, quick mode)

| Case | Median | vs MethodChannel |
|---|---|---|
| Raw FFI (leaf) | 0.014 µs | 1961× faster |
| Nitro C++ (checked) | 0.266 µs | 104× faster |
| Nitro Swift | 0.269 µs | 103× faster |
| Nitro C++ (leaf) | 0.283 µs | 98× faster |
| Nitro zero-copy struct | 0.408 µs | 68× faster |
| Nitro String round-trip | 0.660 µs | 42× faster |
| MethodChannel | 27.6 µs | 1.0× |
| Nitro @nitroAsync + record | 30.2 µs | isolate-hop bound |

| Throughput (16 MiB/op) | MB/s |
|---|---|
| MethodChannel buffer copy | 3,559 |
| Nitro pinned buffer (leaf) | 30,671 |
| Nitro unsafe pointer | ~25,000,000 † |

> † no pinning, no copy — pure dispatch; the payload is never touched.

CI: `.github/workflows/ci_benchmark.yml` runs the relative-gated quick suite
on every push to `main` and publishes the results table to the job summary.

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
