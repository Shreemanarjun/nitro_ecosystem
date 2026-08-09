# Bridge return ownership

How generated bridges hand memory back to Dart, and why. User-facing upgrade
steps are in [migration/0.6.0.md](../migration/0.6.0.md).

## The rule

| Path | Return storage | Dart frees? |
|---|---|---|
| sync method | per-thread slot | no |
| property getter (always sync) | per-thread slot | no |
| `@nitroAsync` | `malloc` | yes |
| `@nitroNativeAsync` | `malloc`, posted | yes |

Sync calls decode immediately after the call returns — a couple of field reads,
no callbacks, no reentry — so a single slot per thread is enough, and a
`malloc`/`free` pair disappears from every call.

`@nitroAsync` cannot use it. `NitroRuntime.callAsync` dispatches through
`Isolate.run`, so the native call runs on a helper isolate thread while Dart
decodes on the main isolate. Thread-local storage there is a *different slot*, so
the value would decode as garbage. Those paths keep their own allocation.

The Dart free site is platform-independent — one `.g.dart` serves the C++, JNI and
Swift bridges — so every native sync path must borrow together. If one platform
still allocates while Dart has stopped freeing, that platform leaks silently.

## Applies to

Nullable primitives (`int?`, `double?`, `bool?`, `DateTime?`, `uint64?`),
`@HybridStruct` returns (the shell only — inner heap fields stay owned and are
released via `freeFields`), and `String` returns.

**Not** `@NitroResult<T>` or `@NitroVariant`: those carry a binary envelope, not a
NUL-terminated string, and `strlen` would truncate them at the first zero byte.

On the Apple path the Swift shim returns memory it allocated, so the C wrapper
copies into the slot and releases the original — otherwise nothing frees it.

## Benchmarks

`benchmark/tool/bench_opt_return.cpp`, `bench_struct_return.cpp`,
`bench_string_return.cpp`, `bench_instance_cache.cpp`.

Build the allocation benchmarks with `-fno-builtin-malloc -fno-builtin-free`.
Without them LLVM elides the non-escaping `malloc`/`free` pair and both sides
measure ~0.2 ns — the allocation under test disappears. In the real bridge the
pointer escapes to Dart across a library boundary, so it cannot be elided.

## Rejected: reusing JNI `byte[]` params

Caching and regrowing a `jbyteArray` to avoid a per-call `NewByteArray` does not
work: the generated Kotlin bridge uses `ByteArray.size` as the payload length, so
an over-capacity buffer silently reports the wrong length — data corruption, not a
crash. Switching to a direct `ByteBuffer` plus an explicit length parameter fixes
that but changes the Kotlin bridge's public shape, breaking every hand-written
impl.

A safe subset exists if this is revisited: payloads whose size is a compile-time
constant (`NitroOpt*`) can use an exact-size cached array per size class, since
the exact-size invariant keeps `.size` correct. It still needs one array per
parameter slot and a plan for releasing global refs on thread exit. Measure with
the JNI harness (`nitro_type_coverage/example/lib/jni_bench.dart`, which reports
ns/call *and* JVM bytes allocated per call) before attempting it.
