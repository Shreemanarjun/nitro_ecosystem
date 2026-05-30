# Zero-Overhead Flutter: How Nitro Solves FFI and Method Channel Problems

When building Flutter plugins, developers have traditionally chosen between two imperfect options:

1. **Method Channels** — easy to write, but slow. Every call crosses language boundaries through serialization, thread hops, and the async event loop.
2. **Vanilla (manual) FFI** — fast, but dangerous. No serialization overhead, but developers carry the full burden of JNI reflection, memory management, exception handling, and thread lifecycle.

**Nitro** eliminates this choice by code-generating safe, optimized FFI bindings from a single Dart interface declaration. You write the interface spec once; Nitro generates the entire bridge.

---

## Part 1: The Method Channel Problem

A Method Channel call for something as simple as `getStatus()` involves:

```
[Dart Isolate]
   │  1. Encode arguments → StandardMethodCodec (binary serialization)
   ▼
[Dart Event Loop]
   │  2. Yield — the current Dart execution frame suspends, a Future is queued
   ▼
[Flutter BinaryMessenger (C++)]
   │  3. Thread context switch → platform/UI thread
   ▼
[Android JNI / iOS ObjC Runtime]
   │  4. Decode binary payload → native Map/String/Boolean
   │  5. Execute: cameraManager.getStatus()
   │  6. Encode return value → binary bytes
   ▼
[Flutter BinaryMessenger (C++)]
   │  7. Thread context switch → back to Dart Isolate thread
   ▼
[Dart Isolate]
   │  8. Decode binary payload
   │  9. Resume Event Loop, resolve Future
```

**Overhead: ~500,000ns – 5,000,000ns per call.**

This is acceptable for infrequent UI interactions but disqualifies Method Channels from use in high-frequency scenarios: brightness updates during video recording, torch toggling on every animation frame, or reactive state streams.

---

## Part 2: The Vanilla FFI Problem

Dart FFI eliminates serialization and thread hops. The call executes synchronously on the calling thread — 2ns–10ns total. But manual FFI pushes the complexity onto the developer:

| Challenge | What you must do manually |
| :--- | :--- |
| JNI reflection | `env->FindClass` + `env->GetStaticMethodID` on every call, or build your own static caching table |
| Thread attach/detach | `AttachCurrentThread` before any JNI call on non-JVM threads; `DetachCurrentThread` on thread exit (or leak the descriptor) |
| Native exceptions | `@try/@catch` blocks in every C++ method; map NSException/Throwable to Dart return codes |
| Struct marshalling | `malloc` on native heap, copy fields, pass pointer to Dart, call `free()` manually |
| Stream bridging | Write a custom C callback loop and wire it to a `ReceivePort`/`Dart_PostCObject_DL` |
| Symbol resolution | `DynamicLibrary.lookup` for every function, every call — or cache manually |

Each of these is individually solvable, but together they represent thousands of lines of error-prone boilerplate. In practice, vanilla FFI plugins skip most of these optimizations — and then suffer silent crashes, JVM thread leaks, or memory corruption in production.

---

## Part 3: How Nitro Solves It — from One Dart Spec

Nitro’s input is a single annotated Dart abstract class. For `nitro_torch`, that spec lives in `lib/src/nitro_torch.native.dart`:

```dart
@NitroModule(
  ios: NativeImpl.swift,
  android: NativeImpl.kotlin,
  macos: NativeImpl.swift,
)
abstract class NitroTorch extends HybridObject {
  void turnOn();
  void turnOff();
  bool getStatus();
  void toggle();
  void setLevel(int level);
  int? maxLevel();

  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<TorchLevel> onLevelChanged();

  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<TorchState> onTorchStateChanged();
}

@HybridStruct()
class TorchLevel {
  final int level;
  final int maxLevel;
  TorchLevel({required this.level, required this.maxLevel});
}

@HybridEnum()
enum TorchState { on, off }
```

From this spec, Nitro generates the complete bridge: the C header, the C++ shim (with JNI for Android and `@_cdecl` stubs for iOS/macOS), the Kotlin bridge object, the Swift protocol, and the Dart implementation class. The sections below trace exactly what each generated piece does and why it is faster or safer than the manual equivalent.

---

## Part 4: What Nitro Generates — Under the Hood

### 4.1 Pre-Cached Function Pointers (Dart side)

**Problem with vanilla FFI:** `DynamicLibrary.lookup` does a string-search through the shared library’s symbol table. Calling it on every method invocation adds measurable overhead and is a common performance mistake.

**Nitro’s solution:** All function pointers are looked up exactly once, lazily, during the first call. They are stored as `late final` fields on the impl class. Subsequent calls use the already-resolved pointer directly.

From the generated `lib/src/nitro_torch.g.dart`:

```dart
class _NitroTorchImpl extends NitroTorch {
  final DynamicLibrary _dylib;

  _NitroTorchImpl() : _dylib = NitroRuntime.loadLib(‘nitro_torch’) {
    // Initialize Dart API DL once — required for Dart_PostCObject_DL (streams)
    final initFunc = _dylib.lookupFunction<
      IntPtr Function(Pointer<Void>),
      int Function(Pointer<Void>)
    >(‘nitro_torch_init_dart_api_dl’);
    initFunc(NativeApi.initializeApiDLData);

    TorchLevelProxy._init(_dylib); // binds NativeFinalizer to release symbol
  }

  // Resolved once at first access — never looked up again
  late final void Function() _turnOnPtr = _dylib
      .lookup<NativeFunction<Void Function()>>(‘nitro_torch_turn_on’)
      .asFunction<void Function()>(isLeaf: true);

  late final int Function() _getStatusPtr = _dylib
      .lookup<NativeFunction<Int8 Function()>>(‘nitro_torch_get_status’)
      .asFunction<int Function()>(isLeaf: true);

  late final void Function(int) _setLevelPtr = _dylib
      .lookup<NativeFunction<Void Function(Int64)>>(‘nitro_torch_set_level’)
      .asFunction<void Function(int)>(isLeaf: true);
}
```

### 4.2 `isLeaf: true` — Bypassing Isolate State Transitions

**Problem with vanilla FFI:** By default, a Dart FFI call performs a transition that allows the Garbage Collector (GC) to run concurrently and permits the native method to call back into Dart. This transition has real CPU cost (stack frame manipulation, safepoint checks).

**Nitro’s solution:** Every synchronous method that cannot call back into Dart is marked `isLeaf: true`. This instructs the Dart compiler to emit a raw CPU branch instruction instead — 3–4× faster than the standard FFI call overhead.

```dart
// With isLeaf: true — raw branch, no isolate state transition
late final void Function() _turnOnPtr = _dylib
    .lookup<NativeFunction<Void Function()>>(‘nitro_torch_turn_on’)
    .asFunction<void Function()>(isLeaf: true); // ← skips GC safepoint overhead

// Stream registration does NOT use isLeaf — it registers a Dart port (callbacks into Dart)
late final void Function(int) _registerOnLevelChangedPtr = _dylib
    .lookupFunction<Void Function(Int64), void Function(int)>(
      ‘nitro_torch_register_on_level_changed_stream’,
    ); // no isLeaf — correct: this needs to interact with Dart’s port system
```

Nitro determines `isLeaf` eligibility by analyzing the generated spec. Developers get the benefit without having to reason about GC safepoint rules.

### 4.3 Two-Phase JNI Initialization (Android)

**Problem with vanilla FFI:** `JNI_OnLoad` (called at `System.loadLibrary`) runs before the application’s class loader is available. If you try to cache your plugin’s Kotlin bridge class there, `FindClass` returns null — and JNI calls silently fail or crash.

**Nitro’s solution:** Nitro uses a two-phase approach. `JNI_OnLoad` only caches the JDK system classes (`java/lang/Class`, `java/lang/Throwable`) that are always available. Application-level IDs are deferred to an explicit `initialize()` call that Kotlin makes from `NitroTorchJniBridge.register()` with the correct class loader context.

From `lib/src/generated/cpp/nitro_torch.bridge.g.cpp`:

```cpp
static JavaVM* g_jvm = nullptr;
static jclass g_bridgeClass = nullptr;

// Cached method IDs — populated in initialize(), used on every call
static jmethodID g_mid_turnOn_call = nullptr;
static jmethodID g_mid_getStatus_call = nullptr;
static jmethodID g_mid_setLevel_call = nullptr;
static jmethodID g_mid_maxLevel_call = nullptr;
// ... one entry per method in the spec

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* reserved) {
    g_jvm = vm;
    JNIEnv* env = nullptr;
    vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6);

    // PHASE 1: Only cache system classes — always safe here
    jclass cls_class = env->FindClass("java/lang/Class");
    g_exc_getName = env->GetMethodID(cls_class, "getName", "()Ljava/lang/String;");
    jclass throwable_class = env->FindClass("java/lang/Throwable");
    g_exc_getMessage = env->GetMethodID(throwable_class, "getMessage", "()Ljava/lang/String;");

    return JNI_VERSION_1_6;
}

// PHASE 2: Called by Kotlin after register() — app class loader is available
JNIEXPORT void JNICALL Java_nitro_nitro_1torch_1module_NitroTorchJniBridge_initialize(
    JNIEnv* env, jobject thiz, jclass localClass
) {
    g_bridgeClass = (jclass)env->NewGlobalRef(localClass); // promote to GlobalRef

    // Cache all bridge method IDs exactly once
    g_mid_turnOn_call    = env->GetStaticMethodID(g_bridgeClass, "turnOn_call",    "()V");
    g_mid_turnOff_call   = env->GetStaticMethodID(g_bridgeClass, "turnOff_call",   "()V");
    g_mid_getStatus_call = env->GetStaticMethodID(g_bridgeClass, "getStatus_call", "()Z");
    g_mid_setLevel_call  = env->GetStaticMethodID(g_bridgeClass, "setLevel_call",  "(J)V");
    g_mid_maxLevel_call  = env->GetStaticMethodID(g_bridgeClass, "maxLevel_call",  "()J");

    // Also cache TorchLevel struct class, constructor, and field IDs
    jclass local_cls = env->FindClass("nitro/nitro_torch_module/TorchLevel");
    g_cls_TorchLevel   = (jclass)env->NewGlobalRef(local_cls);
    g_ctor_TorchLevel  = env->GetMethodID(g_cls_TorchLevel, "<init>", "(JJ)V");
    g_fid_TorchLevel_level    = env->GetFieldID(g_cls_TorchLevel, "level",    "J");
    g_fid_TorchLevel_maxLevel = env->GetFieldID(g_cls_TorchLevel, "maxLevel", "J");
}
```

After initialization, `nitro_torch_get_status()` pays zero JNI reflection cost:

```cpp
int8_t nitro_torch_get_status(void) {
    JNIEnv* env = GetEnv();
    nitro_torch_clear_error();
    env->PushLocalFrame(16);
    // ← cached global ref + cached method ID, zero FindClass/GetMethodID overhead
    bool res = env->CallStaticBooleanMethod(g_bridgeClass, g_mid_getStatus_call);
    if (env->ExceptionCheck()) {
        nitro_report_jni_exception(env, env->ExceptionOccurred());
        env->PopLocalFrame(nullptr);
        return false;
    }
    env->PopLocalFrame(nullptr);
    return res;
}
```

On the Kotlin side, `NitroTorchJniBridge` is a thin generated dispatcher that routes to the real implementation:

```kotlin
// Generated: NitroTorchJniBridge in nitro_torch.bridge.g.kt
@JvmStatic fun getStatus_call(): Boolean {
    val impl = implementation ?: throw IllegalStateException("NitroTorch not registered")
    return impl.getStatus() // delegates to developer’s NitroTorchImpl
}
```

```kotlin
// Developer-written: NitroTorchImpl.kt
override fun getStatus(): Boolean = isTorchOn // pure Kotlin, no boilerplate
```

Plugin registration wires everything together in three lines:

```kotlin
// NitroTorchPlugin.kt
override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    NitroTorchJniBridge.register(NitroTorchImpl(), binding.applicationContext)
    // register() calls initialize() → triggers Phase 2 JNI caching above
}
```

### 4.4 RAII Thread Auto-Attach (Android)

**Problem with vanilla FFI:** On Android, threads not spawned by the JVM (e.g., Flutter’s Dart Isolate thread) must be manually attached to the JVM before any JNI call and detached on exit. Forgetting `DetachCurrentThread` leaks JVM thread descriptors, eventually crashing the app.

**Nitro’s solution:** A `thread_local` RAII guard is generated. Its destructor fires automatically when the thread exits — no manual tracking needed.

```cpp
struct NitroJniThreadGuard {
    bool attached = false;
    ~NitroJniThreadGuard() {
        // Called automatically when the owning thread exits
        if (attached && g_jvm != nullptr) {
            g_jvm->DetachCurrentThread();
        }
    }
};
static thread_local NitroJniThreadGuard g_thread_guard; // one per thread, zero developer effort

static JNIEnv* GetEnv() {
    JNIEnv* env = nullptr;
    int status = g_jvm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6);
    if (status == JNI_EDETACHED) {
        g_jvm->AttachCurrentThread(&env, nullptr);
        g_thread_guard.attached = true; // destructor will handle detach
    }
    return env;
}
```

### 4.5 Lock-Free `thread_local` Exception Propagation

**Problem with vanilla FFI:** If Kotlin throws a `Throwable` or Swift throws an `NSException`, the exception propagates through C++ with undefined behavior — or the OS kills the thread, taking the entire Flutter app down.

**Nitro’s solution:** Every native call is wrapped in an exception boundary. Errors are captured into a `thread_local` struct (no allocation, no mutex). Dart checks this struct immediately after the FFI call returns — in nanoseconds, with zero heap impact.

C++ bridge (Android path):
```cpp
static thread_local NitroError g_nitro_error = { 0, nullptr, nullptr, nullptr, nullptr };

static void nitro_report_jni_exception(JNIEnv* env, jthrowable ex) {
    env->ExceptionClear(); // must clear before any further JNI calls
    jclass ex_class = env->GetObjectClass(ex);
    jstring j_name = (jstring)env->CallObjectMethod(ex_class, g_exc_getName);
    jstring j_msg  = (jstring)env->CallObjectMethod(ex, g_exc_getMessage);
    nitro_report_error(
        env->GetStringUTFChars(j_name, 0),
        env->GetStringUTFChars(j_msg, 0),
        nullptr, nullptr
    );
    // ... release refs
}
```

C++ bridge (iOS/macOS path) — `@try/@catch` generated for every ObjC method:
```cpp
void nitro_torch_turn_on(void) {
    nitro_torch_clear_error();
#ifdef __OBJC__
    @try {
        _nitro_torch_call_turnOn(); // calls Swift @_cdecl stub
    } @catch (NSException* e) {
        nitro_report_error([e.name UTF8String], [e.reason UTF8String], nullptr, nullptr);
    }
#else
    _nitro_torch_call_turnOn();
#endif
}
```

Dart checks the error state after every FFI call:
```dart
@override
void turnOn() {
  checkDisposed();
  NitroRuntime.callSync<void>(() {
    _turnOnPtr();                                          // isLeaf FFI call
    NitroRuntime.checkError(_getErrorPtr, _clearErrorPtr); // reads thread_local struct
  }, methodName: ‘turnOn’);
}

@override
bool getStatus() {
  checkDisposed();
  return NitroRuntime.callSync(() {
    final res = _getStatusPtr();                           // returns Int8 via CPU register
    NitroRuntime.checkError(_getErrorPtr, _clearErrorPtr);
    return res != 0;
  }, methodName: ‘getStatus’);
}
```

The `NitroError` struct is defined in the C header and read directly by Dart via FFI — no serialization, no allocation:

```c
// nitro_torch.bridge.g.h
typedef struct {
  int8_t      hasError;
  const char* name;
  const char* message;
  const char* code;
  const char* stackTrace;
} NitroError;
```

### 4.6 Zero-Copy Struct Proxies with `NativeFinalizer`

**Problem with vanilla FFI:** Returning a struct from C to Dart requires either copying all fields into a new Dart object (allocation + GC pressure) or handing the developer a raw pointer they must remember to free.

**Nitro’s solution:** Nitro generates a `TorchLevelProxy` that extends `TorchLevel` but overrides every getter to read lazily from the original C-allocated memory. Fields are never copied at construction time. A `NativeFinalizer` backed by the generated C symbol `nitro_torch_release_TorchLevel` frees the memory when the Dart object is garbage-collected.

```dart
// Generated: lib/src/nitro_torch.g.dart

final class TorchLevelFfi extends Struct {
  @Int64() external int level;
  @Int64() external int maxLevel;
}

final class TorchLevelProxy extends TorchLevel implements Finalizable {
  final Pointer<TorchLevelFfi> _native;

  static NativeFinalizer? _finalizer;

  static void _init(DynamicLibrary dylib) {
    _finalizer ??= NativeFinalizer(
      dylib.lookup<NativeFunction<Void Function(Pointer<Void>)>>(
        ‘nitro_torch_release_TorchLevel’,
      ),
    );
  }

  TorchLevelProxy(this._native) : super(level: 0, maxLevel: 0) {
    _finalizer!.attach(this, _native.cast(), detach: this); // GC will free _native
  }

  // All reads are lazy — zero copies from native heap to Dart heap
  @override int get level    => _native.ref.level;
  @override int get maxLevel => _native.ref.maxLevel;

  // Optional: eagerly snapshot and immediately free
  TorchLevel toDartAndRelease() {
    final v = _native.ref.toDart();
    _finalizer?.detach(this);
    malloc.free(_native);
    return v;
  }
}
```

The corresponding C release function (also generated):
```cpp
extern "C" {
void nitro_torch_release_TorchLevel(void* ptr) {
    if (!ptr) return;
    free(ptr);
}
}
```

### 4.7 Native Stream Bridging (Kotlin Flow → Dart Stream / Swift Combine → Dart Stream)

**Problem with vanilla FFI + Method Channels:** EventChannels use an asynchronous queue and require BinaryMessenger serialization for every event. Implementing a reactive stream via vanilla FFI means writing custom C callback loops and manually wiring `Dart_PostCObject_DL`.

**Nitro’s solution:** Nitro bridges native reactive streams directly to Dart `Stream`s via `Dart_PostCObject_DL` and `ReceivePort`. No serialization. No thread hop. Events land in Dart as raw pointer-sized integers.

**Android path — Kotlin Flow → JNI → Dart:**

```kotlin
// Generated: nitro_torch.bridge.g.kt
@JvmStatic external fun emit_onLevelChanged(dartPort: Long, item: TorchLevel): Unit

@JvmStatic fun nitro_torch_register_on_level_changed_stream_call(dartPort: Long) {
    val impl = implementation ?: return
    _streamJobs[Pair("onLevelChanged", dartPort)] =
        CoroutineScope(Dispatchers.Default).launch {
            impl.onLevelChanged.collect { item ->
                emit_onLevelChanged(dartPort, item) // calls C JNI method below
            }
        }
}
```

```cpp
// Generated: nitro_torch.bridge.g.cpp
JNIEXPORT void JNICALL Java_nitro_nitro_1torch_1module_NitroTorchJniBridge_emit_1onLevelChanged(
    JNIEnv* env, jobject thiz, jlong dartPort, jobject item
) {
    TorchLevel* st_ptr = (TorchLevel*)malloc(sizeof(TorchLevel));
    *st_ptr = pack_TorchLevel_from_jni(env, item); // copy JNI object → C struct once

    Dart_CObject obj;
    obj.type = Dart_CObject_kInt64;
    obj.value.as_int64 = (intptr_t)st_ptr; // send raw pointer to Dart
    Dart_PostCObject_DL(dartPort, &obj);   // lock-free, thread-safe event dispatch
}
```

**iOS/macOS path — Swift Combine → C callback → Dart:**

```swift
// Generated: nitro_torch.bridge.g.swift
@_cdecl("_nitro_torch_register_onLevelChanged_stream")
public func _nitro_torch_register_onLevelChanged_stream(
    _ dartPort: Int64,
    _ emitCb: @convention(c) (Int64, UnsafeMutableRawPointer?) -> Void
) {
    NitroTorchRegistry._onLevelChangedCancellables[dartPort] =
        NitroTorchRegistry.impl?.onLevelChanged.sink { item in
            let ptr = UnsafeMutablePointer<_TorchLevelC>.allocate(capacity: 1)
            ptr.initialize(to: _TorchLevelC.fromSwift(item)) // copy Swift struct → C layout once
            emitCb(dartPort, UnsafeMutableRawPointer(ptr))   // raw pointer to C bridge
        }
}
```

**Dart side — receives raw pointer and wraps it in `TorchLevelProxy` (zero additional copies):**

```dart
@override
Stream<TorchLevel> onLevelChanged() {
  checkDisposed();
  return NitroRuntime.openStream<TorchLevelProxy>(
    register: (port) => _registerOnLevelChangedPtr(port),
    unpack: (message) {
      return TorchLevelProxy(
        Pointer<TorchLevelFfi>.fromAddress(message as int), // message IS the C pointer
      );
    },
    release: (port) => _releaseOnLevelChangedPtr(port),
    backpressure: Backpressure.dropLatest,
  );
}
```

The developer implements the Kotlin side with a plain `MutableSharedFlow` — no C awareness required:

```kotlin
// Developer-written: NitroTorchImpl.kt
class NitroTorchImpl : HybridNitroTorchSpec {
    private val _onLevelChanged = MutableSharedFlow<TorchLevel>(extraBufferCapacity = 16)
    override val onLevelChanged: Flow<TorchLevel> = _onLevelChanged

    private val torchCallback = object : CameraManager.TorchCallback() {
        override fun onTorchStrengthLevelChanged(camId: String, newStrengthLevel: Int) {
            CoroutineScope(Dispatchers.Default).launch {
                _onLevelChanged.emit(
                    TorchLevel(level = newStrengthLevel.toLong(), maxLevel = maxLevel())
                )
            }
        }
    }
}
```

---

## Part 5: End-to-End Call Lifecycle Comparison

### Method Channel — `getStatus()`
```
[Dart Isolate]
   │  1. Allocate StandardMethodCodec payload {"method": "getStatus"}
   │  2. Yield — Future queued, current frame suspended
   ▼
[Flutter BinaryMessenger C++ layer]
   │  3. Thread hop → platform/UI thread
   ▼
[Android JNI / iOS ObjC dispatch]
   │  4. Decode binary map → native String "getStatus"
   │  5. Call implementation via method channel handler
   │  6. Encode return value `true` → binary bytes
   ▼
[Flutter BinaryMessenger C++ layer]
   │  7. Thread hop → back to Dart Isolate
   ▼
[Dart Isolate]
   │  8. Decode binary → bool
   │  9. Resume Future
```
**Total: ~500,000ns – 5,000,000ns**

---

### Vanilla FFI — `getStatus()`
```
[Dart Isolate]
   │  1. DynamicLibrary.lookup("nitro_torch_get_status") — string search every call
   │  2. Dart frame transition (GC safepoint, isolate state)
   ▼
[C++ Shim]
   │  3. AttachCurrentThread (if not JVM thread)
   │  4. FindClass("...NitroTorchBridge") — JNI reflection
   │  5. GetMethodID("getStatus_call", "()Z") — JNI reflection
   │  6. CallStaticBooleanMethod — execute
   │     (If Kotlin throws: process crash or undefined behavior)
   ▼
[Dart Isolate]
   │  7. Receive Int8 in CPU register
```
**Total: ~500ns – 50,000ns (dominated by per-call JNI reflection if not manually cached)**

---

### Nitro — `getStatus()`
```
[Dart Isolate]
   │  1. Call pre-resolved function pointer _getStatusPtr (no lookup)
   │  2. Raw CPU branch (isLeaf: true — no GC safepoint, no isolate transition)
   ▼
[C++ Shim]
   │  3. GetEnv() — thread already attached via RAII guard, returns cached env
   │  4. PushLocalFrame(16) — protects JNI local reference table
   │  5. CallStaticBooleanMethod(g_bridgeClass, g_mid_getStatus_call)
   │     ← cached global ref + cached method ID, zero reflection overhead
   │  6. ExceptionCheck — sets thread_local NitroError if needed; PopLocalFrame
   ▼
[Kotlin: NitroTorchJniBridge]
   │  7. getStatus_call() → NitroTorchImpl.getStatus() → return isTorchOn
   ▼
[Dart Isolate]
   │  8. Receive Int8 in CPU register (no thread hop)
   │  9. NitroRuntime.checkError() — reads thread_local NitroError (zero allocation)
   │  10. return res != 0
```
**Total: ~2ns – 10ns**

---

## Summary

| Problem | Method Channel | Vanilla FFI | Nitro |
| :--- | :--- | :--- | :--- |
| **Serialization cost** | Binary encode/decode on every call | None | None |
| **Thread context switch** | 2× per call (to platform + back) | None | None |
| **Async overhead** | Future + Event Loop yield | None | None |
| **JNI reflection** | Managed by Flutter runtime | Manual cache or per-call overhead | Auto two-phase cache in `JNI_OnLoad` + `initialize()`, zero cost after startup |
| **Thread attach/detach (Android)** | Auto-managed | Manual `AttachCurrentThread`/`DetachCurrentThread`, leak risk | RAII `thread_local` guard, auto-detach on thread exit |
| **JNI local ref table** | Flutter managed | Can overflow in hot loops without `PushLocalFrame` | `PushLocalFrame(16)` / `PopLocalFrame` wraps every call |
| **Native exception safety** | `PlatformException` (graceful) | Process crash on unhandled exception | `thread_local` error struct + `@try/@catch` / JNI ExceptionCheck on every call |
| **Struct marshalling** | Serialized as Map | Manual `malloc`/`free`, memory leak risk | Zero-copy `TorchLevelProxy` + `NativeFinalizer` auto-free |
| **Reactive streams** | EventChannel (async queue + serialization) | Manual C callback + `Dart_PostCObject_DL` | Kotlin Flow / Swift Combine → C JNI callback → `Dart_PostCObject_DL` — generated |
| **Developer boilerplate** | Low | Extremely high | Low — one Dart spec generates everything |
| **Latency** | 500µs – 5ms | 500ns – 50µs (without manual JNI caching) | **2ns – 10ns** |

Nitro is a complete replacement for both Method Channels and vanilla FFI. Here is every problem it solves:

**Replaces Method Channels:**
- No binary serialization — arguments and return values travel as raw C types (integers, pointers, enums), never as Maps, JSON, or codec bytes
- No thread hop — calls execute synchronously on the calling thread; no Future is queued, no event loop yield occurs
- No async latency — `getStatus()` returns in ~2ns instead of waiting for a platform dispatcher round-trip
- No `EventChannel` queue — streams are bridged directly from Kotlin Flow / Swift Combine to Dart via `Dart_PostCObject_DL`; each event is a raw pointer, not a serialized payload
- No codec coupling — adding a new method or field requires only changing the Dart spec; no platform-side codec registration or method name string matching

**Replaces vanilla (manual) FFI:**
- No per-call JNI reflection — `FindClass` / `GetStaticMethodID` run exactly once in `initialize()`; every subsequent call uses cached `jmethodID` pointers
- No JNI local reference overflow — `PushLocalFrame(16)` / `PopLocalFrame` wraps every call, bounding the JNI reference table regardless of call frequency
- No manual thread attach/detach — a `thread_local` RAII guard (`NitroJniThreadGuard`) auto-calls `DetachCurrentThread` when any native thread exits, preventing JVM descriptor leaks
- No silent native crashes — `@try/@catch` (iOS/macOS) and `env->ExceptionCheck()` (Android) on every call; exceptions are captured into a `thread_local NitroError` struct and re-thrown in Dart instead of killing the process
- No manual `malloc`/`free` for structs — `TorchLevelProxy` wraps the C pointer and a `NativeFinalizer` backed by `nitro_torch_release_TorchLevel` frees native memory when Dart GCs the proxy
- No forgotten `isLeaf` — Nitro applies `isLeaf: true` to every qualifying synchronous method automatically, eliminating GC safepoint transitions on each FFI call
- No symbol lookup overhead — all function pointers are resolved once as `late final` fields; subsequent calls are direct branches
- No custom `Dart_PostCObject_DL` plumbing — stream bridging (Kotlin Flow → JNI emit → Dart port) is fully generated; developers write a `MutableSharedFlow`, nothing else
- No boilerplate — one Dart abstract class generates the C header, C++ shim, Kotlin bridge object, Swift protocol, and Dart impl class across all platforms
