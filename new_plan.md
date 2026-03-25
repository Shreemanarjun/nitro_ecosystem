
 ---
  Performance

  🔴 High impact

  1.
 - [x] JNI IDs fetched on every call (no caching)   FindClass,
       GetMethodID, GetFieldID, and GetObjectClass are called inside
       every generated function. These traverse the classloader chain
       and are expensive. All IDs should be cached in    static
       jclass/static jmethodID/static jfieldID globals, populated once
       in JNI_OnLoad or lazily on first call with a null-check guard.

 x2.

 - [x] runBlocking serializes async Android calls   Each callAsync
       blocks one Dart isolate-pool thread while the Kotlin coroutine
       runs. With a default pool of 2–4 threads, concurrent async calls
       queue. A   CompletableFuture/ReceivePort-based handoff where the
       Kotlin coroutine posts the result back via
       Dart_PostInteger/Dart_PostCObject would keep threads free.

  3.

 - [x] nitro_report_jni_exception re-fetches method IDs on every
       exception   GetMethodID(cls_class, "getName", ...) and
       GetMethodID(FindClass("java/lang/Throwable"), "getMessage", ...)
       run every time an exception is reported. These should be cached
       globals   set once at init time.

  🟡 Moderate impact

  4. FindClass("...") inside unpack_*_to_jni on every struct pass
  Every call to unpack_SomeStruct_to_jni does env->FindClass(...) + env->GetMethodID(cls, "<init>", ...). Should cache the jclass and jmethodID as statics.

  5. Non-zero-copy TypedData always malloc+copies
  NewFloatArray + SetFloatArrayRegion allocates and copies on every call. If the Dart side owns the buffer for the duration of the call, a NewDirectByteBuffer path (zero-copy) should
  be offered for params too, not just fields.

  6. NitroRuntime.checkError does a native lookup on every return
  Even when no error occurred, _get_error / _clear_error are called after every function. A sentinel return value (e.g. hasError flag baked into the return struct) would skip the
  round-trip in the common case.

  7. Generator's inner loops call spec.structs.any(...) / spec.enums.any(...) O(n×m) times
  Inside loops over params/fields, each type lookup is a linear scan of the struct/enum list. Pre-building Set<String> name tables once at the top of generate() would make each lookup
  O(1).

  🟢 Minor

 - [x] _streamJobs map is not thread-safe   Kotlin's mutableMapOf is not thread-safe. Concurrent register/release calls from different
       coroutines (e.g. two streams firing at the same time) can corrupt
       the map. Should be   java.util.concurrent.ConcurrentHashMap.

 - [x] ByteArrayOutputStream always freshly allocated per encode
       RecordWriter creates a new stream for every encode call. For
       small records this allocation dominates. Pre-sizing or pool-based
       reuse would help hot-path serialisation.

  ---
  Developer Experience

  🔴 High impact

  10. Silent fallthrough in _jniSigType for unknown types
  An unrecognised Dart type silently maps to Ljava/lang/Object;, producing a method that always returns null at runtime with no error at gen-time. Should throw a descriptive StateError
   naming the type and the field/param.

  11. LOGE("Method not found") carries no context
  When GetStaticMethodID returns null, the log just says "Method not found". The generated log line should include the method name and JNI signature so the bug is diagnosable without
  attaching a debugger.

  12. No stale-generation detection
  If generator version is bumped but generated files are not re-run, the mismatch is silent. Emitting a // nitro_generator: 0.2.1 comment in every output file lets a validator or lint
  rule detect drift.

  13. withArena wraps async call body — potential use-after-free
  For async functions with arena params, the arena closes when the outer withArena callback returns, but the inner await NitroRuntime.callAsync(...) hasn't completed yet. Any
  arena-allocated memory (strings, struct pointers) captured by the native call may already be freed by the time the call executes. The arena lifetime needs to extend to cover the
  await.

  🟡 Moderate impact

  14. Coroutine imports emitted unconditionally in Kotlin
  import kotlinx.coroutines.* and runBlocking are always emitted even when the spec has no async functions or streams. Conditional import emission reduces compile scope and avoids
  unused-import warnings.

  15. No null-safety for TypedData fields in pack/unpack
  If a Kotlin ByteBuffer field is null, GetDirectBufferAddress returns null. The C++ side assigns the null pointer to the struct field with no check, causing a silent null-deref later.
   Generated code should emit a null guard and call nitro_report_error.

  16. No zero-copy support for TypedData return values
  @zeroCopy works for struct fields and (as of 0.2.0) parameters, but a function that returns a TypedData still has to copy via GetByteArrayRegion. The @zeroCopy annotation should be
  extensible to return types.

  17. callAsync forces a raw Pointer cast on the Dart side
  NitroRuntime.callAsync returns dynamic; every call site casts result as Pointer<Uint8>. A typed callAsync<T> + structured result envelope would remove the cast and make the generated
   code self-documenting.

  🟢 Minor / Polish

  18. Generated files have no spec-path attribution
  If you have 10 modules it's not obvious which .native.dart produced a given .bridge.g.cpp. Adding // Generated from: camera_module.native.dart at the top aids navigation.

  19. checkDisposed() called on every method
  Minor per-call overhead. A @pragma('vm:prefer-inline') annotation and an assert variant for debug builds could make this zero-cost in release.

  20. spec_extractor.dart makes multiple AST passes
  Annotations, streams, properties, and functions are extracted in separate loops over the same element list. A single-pass visitor would be faster for large specs. 