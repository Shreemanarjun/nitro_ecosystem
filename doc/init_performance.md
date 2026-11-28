# Module initialization: cost and how to keep startup fast

Measured 2026-11-28 on an Apple M1 Pro (MacBookPro18,3). macOS ran as a profile build; Android ran on an arm64 API 34 emulator, also as a profile build. Each launch is a fresh process. Every figure is the median of 8 launches.

## What initialization does

A module costs nothing until Dart first reads `MyModule.instance`: the generated `static final` field is lazy. That first read builds the module in this order:

1. Open the library: `DynamicLibrary.process()` on iOS and macOS, `DynamicLibrary.open('lib<lib>.so')` on Android.
2. Call `<lib>_init_dart_api_dl`.
3. Check the ABI version and the bridge checksum. Each check runs a `providesSymbol` and then a lookup.
4. Look up the struct proxies' release functions.
5. Call `<lib>_create_instance`. For Kotlin, this crosses into the JniBridge, which calls your factory. For Swift and C++, it creates the registry slot.

Method symbols are looked up lazily, on each method's first call.

Android has extra work before any Dart code runs. When the plugin class loads, it calls `System.loadLibrary` for each module's `.so`. Then `onAttachedToEngine` calls `registerFactory` for each Kotlin module, which loads the JniBridge class and caches the JNI method IDs.

## Results

### macOS (Swift and C++)

| Module | Constructor | First sync call | First async call | Warm sync | Warm async |
|---|---|---|---|---|---|
| Swift (3 methods) | 47 µs | 2.1 µs | 104 µs | 28 ns | 34 µs |
| C++ | 49 µs | 2.2 µs | 60 µs | 24 ns | 5.9 µs |
| Swift (64 methods) | 36 µs | 6.1 µs | 128 µs | 30 ns | 35 µs |

These rows are for a module that is not the first one touched. The first module also pays about 30–60 µs of one-time cost for the whole process.

The constructor breaks down as follows:
- `init_dart_api_dl`: 5.8 µs
- 2 × `providesSymbol`: 2 µs
- ABI and checksum checks: 2 µs
- `create_instance`: under 1 µs

Resolving one symbol costs about 0.85 µs. Looking up every symbol of the 64-method module would take 66 µs, but lookups are lazy, so startup never pays that.

### Android (Kotlin and C++)

Before Dart runs:

| Step | Cost per module |
|---|---|
| `System.loadLibrary` | 0.5–1.1 ms |
| JniBridge class loading | 0.12–0.35 ms |
| `registerFactory` (JNI ID caching) | 0.19–0.54 ms |

For the five-module test plugin, this adds up to 5–7 ms before the first frame. The app's whole cold start (`am start` TotalTime) is about 850 ms on the emulator.

From Dart, for a module that is not the first one touched:

| Module | Constructor | First async call | Warm sync | Warm async |
|---|---|---|---|---|
| Kotlin | 290–450 µs | 1.25–1.6 ms | 0.94–1.0 µs | 540–570 µs |
| C++ | 640 µs (includes the `dlopen`, see below) | 169 µs | 31 ns | 170 µs |

The first Kotlin async call in the process takes up to 5.6–9.9 ms. It attaches the worker thread to the JVM and starts Kotlin coroutines.

Method count barely matters. Caching 71 JNI method IDs costs about 70 µs more than caching 5.

## Changes made from these numbers

- **Android C++ modules no longer load at startup** (nitrogen link). A C++ module's library has no JNI exports, so `System.loadLibrary` only moved its `dlopen` before the first frame. Dart now opens it on first use: about 0.45 ms on the constructor instead of a median 0.7 ms at startup, and nothing if the app never uses the module. The library's static constructors, where a C++ impl registers itself, still run before `create_instance`.
  - Exception: if any of the plugin's own C/C++ sources define `JNI_OnLoad`, `JNIEXPORT` or `RegisterNatives`, link keeps every library loaded at start. ART resolves `external` functions only in libraries that `System.loadLibrary` loaded; nitro_webgpu's present library is one such case.
- **The worker pool grows on demand** (nitro). It used to start 4 threads per library on the first async call. Now it starts a thread only when queued work finds no idle one, up to the same cap of 4. First async call results:
  - macOS: 25% faster, for example C++ 81 → 60 µs.
  - Android C++: 495 → 169 µs, and 1.4 ms → 270 µs when it is the process's first async call.
  - Warm C++ async on macOS: 8.6 → 5.9 µs.

## How to keep startup fast

1. **Don't read `.instance` during startup.** The module stays free until then. Touch it where the feature is used, or after the first frame.
2. **On Android, every Kotlin module costs about 1–1.5 ms before the first frame** (library load, class loading, `registerFactory`). Merge small Kotlin specs that are always used together into one spec.
3. **Use C++ for hot paths on Android.** A sync call costs about 30 ns instead of 0.95 µs through JNI. A first async call costs 0.17 ms instead of 1.3–1.6 ms.
4. **Warm a latency-critical async path once after the first frame.** On Kotlin, the first async call pays for the JVM thread attach and the coroutine start. A no-op call after `addPostFrameCallback` moves that cost off the user's first tap.
5. **Method count doesn't affect startup.** Symbols resolve lazily, so a 64-method module starts as fast as a 3-method one.

## Several specs in one plugin

Five specs with different targets live in one plugin and work on macOS, the iOS simulator and the Android emulator:
- Swift on Apple, Kotlin on Android
- C++ everywhere
- Swift on iOS, Kotlin on Android, C++ on macOS
- a 64-method spec
- the scaffold's own spec

Each module returns its own values, including 200 concurrent async calls across the modules.

Problems found and fixed:

- **Only the first Kotlin module saw the Activity.** The scaffold's `ActivityWatcher` forwarded to one JniBridge, and link never added the others, so `activity` was null in every other Kotlin module. Link now forwards `onActivityAttached` and `onActivityDetached` to every Kotlin module, in both the `ActivityWatcher` and the `ActivityAware` forms. A negative control (removing the forwarding) makes the test fail.
- **The same type name declared in two specs failed late.** Dart reported `ambiguous_export` and Swift reported "'X' is ambiguous for type lookup". `nitrogen generate` now stops early, and `nitrogen doctor` reports an error that names both files and points to the fix: declare the type once in a type-only `.native.dart` and import it. With that fix, Swift, Kotlin and C++ modules all return the one shared type on all three platforms.

Still open:

- **Removing or renaming a spec leaves references behind.** These stay in the Kotlin plugin (import, `registerFactory`, `loadLibrary`), the Swift plugins (`Registry.register`), the CMake target and the SwiftPM sources, and the next Android or Apple build fails. Remove them by hand until link prunes modules that no longer exist.
- **Link guesses Swift implementation class names inconsistently.** It writes `<Module>ModuleImpl` for added specs and `<Module>Impl` for the scaffold's spec.
- **Each spec is its own `.so` on Android.** Building one library per plugin would save about 0.5 ms per extra Kotlin module at startup, but the generator and CMake layout would have to change.
- **iOS was not measured in profile mode.** The simulator runs only debug builds, and no phone was cabled. macOS uses the same Swift bridge.

## Reproducing

The scripts are in `benchmark/tool/init/`:
- `bench_main.dart` is the example app's `main`.
- `collector.py` is the host collector, on port 8765.
- `summarize.py` prints the medians.
- `android_run.sh` runs N cold launches with `adb`.

The fixture is a fresh `nitrogen init` plugin named `nitro_init_bench` with these specs:
- `ib_swift`: Swift/Kotlin, with `ping`, `point`, `pingAsync`
- `ib_cpp`: C++ everywhere
- `ib_mixed`: Swift on iOS, Kotlin on Android, C++ on macOS
- `ib_wide`: the same plus 64 more methods

Each launch asks the collector for a mode and a rotation, so every module is the first one touched equally often.
- `plain` mode times the constructor, first calls and warm calls.
- `breakdown` mode runs the constructor's steps by hand against the raw library.

The macOS app needs `com.apple.security.network.client`. The Android app needs `INTERNET` and `usesCleartextTraffic`; it reaches the host at `10.0.2.2`.
