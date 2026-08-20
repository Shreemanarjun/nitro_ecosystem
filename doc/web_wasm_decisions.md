# Web/WASM support — WS0 spike decision log

Verified by running code (spike A: hand-written C + Dart js_interop harness under
`dart test -p chrome` for **dart2js** and `-c dart2wasm`; spike B: the real
generated `benchmark_cpp.bridge.g.cpp` compiled with em++ 6.0.7, unchanged).

## Module shape & flags

```
em++ <sources> -O3 --no-entry
  -sMODULARIZE=1 -sEXPORT_NAME=create<LibStem>Module
  -sALLOW_MEMORY_GROWTH=1 -sALLOW_TABLE_GROWTH=1
  -sWASM_BIGINT=1 -sENVIRONMENT=web
  -sEXPORTED_RUNTIME_METHODS=addFunction,wasmExports,wasmMemory,HEAPU8
  -sEXPORTED_FUNCTIONS=_malloc,_free
  -o <lib>.js        # → <lib>.js (glue) + <lib>.wasm
```

- Link C++ with **em++** (emcc alone leaves libc++ symbols undefined when a .c
  file is in the mix).
- `NITRO_EXPORT` (`visibility(default) + used`) is sufficient to keep and
  export every bridge symbol — no per-symbol `EXPORTED_FUNCTIONS` list needed.

## Dart-side binding surface

- Bind **`Module._<c_symbol>`** (the glue's `assignWasmExports` maps real names
  onto the Module object). `Module.wasmExports` carries *minified* names at
  -O2/-O3 — never bind it.
- Load: inject a `<script src=<lib>.js>`, then call the global
  `create<LibStem>Module({...})`; it returns a Promise of the Module object.
  The default `locateFile` resolves `<lib>.wasm` relative to the script URL.
- `INCOMING_MODULE_JS_API` default set is enough for browsers; `wasmBinary` is
  pruned by default (only matters for non-browser harnesses).

## int64 boundary

- With `-sWASM_BIGINT` (default in modern emsdk) every `int64_t` param/return
  is a JS **BigInt**. Convert with cached `BigInt()` / `Number()` globals
  (one JS call each).
- Cost measured: i64 call ≈ 2× an f64 call (dart2js 0.06 vs 0.02 µs;
  dart2wasm 0.63 vs 0.31 µs). Acceptable; document 53-bit fidelity (dart2js
  ints are already 53-bit).
- dart2wasm's JS-boundary calls are ~10× dart2js per call — bulk transfers
  amortize this; avoid per-element heap access in hot paths.

## Heap I/O rules (growth-safe, both compilers)

- **Never cache `HEAPU8`** across exported calls: `ALLOW_MEMORY_GROWTH` swaps
  the ArrayBuffer and stale views detach (byteLength 0). Re-read
  `Module.HEAPU8` per operation; the glue refreshes it on growth.
- Write: `HEAPU8.set(bytes.toJS, ptr)` (one JS call, bulk).
- Read: `HEAPU8.slice(ptr, ptr+len).toDart` (slice copies in JS → identical
  copy semantics under dart2js and dart2wasm).
- `ByteData.get/setInt64` **throws on dart2js** — shared codec paths must use
  a two-uint32-halves helper behind
  `const bool.fromEnvironment('dart.library.js_interop')` so each compiler
  tree-shakes the other branch. (`hi * 0x100000000 + lo`: exact on
  dart2wasm/VM, 53-bit on dart2js.)
- Numbers deserialized from JS (postMessage, channels) arrive as `double`
  under dart2wasm — always `(x as num).toInt()`, never `as int`.

## Post callback (Dart_PostCObject replacement)

- `Module.addFunction(dartFn.toJS, 'vjijjd')` → C function pointer; signature
  `void (*)(int64 port, int32 tag, int64 a, int64 b, double d)`.
- Tags: 0=kNull · 1=kInt64/bool/int32 (`a`) · 2=kDouble (`d`) ·
  3=kString (`a`=char*, **borrowed** — decode synchronously) ·
  4=int64 array (`a`=int64* buf, `b`=count, **borrowed** — copy synchronously).
- C posts synchronously while a Dart-initiated call is on the stack; the Dart
  callback decodes immediately and defers delivery via `scheduleMicrotask` —
  re-entrancy verified safe on both compilers.
- The compat shim (`Dart_PostCObject_DL` → `g_nitro_post_fn`) lets every
  generated post call site compile **unchanged**; kInt64 heap-address posts
  keep their transfer-to-Dart semantics (Dart frees via `<lib>_nitro_free`).

## Error protocol

- The C `NitroError` out-param struct is unchanged. wasm32 layout: 20 bytes —
  `hasError` i8 @0, then `name/message/code/stackTrace` as u32 pointers @
  4/8/12/16. strdup'd fields must be freed with the **module's** free
  (`<lib>_nitro_free`), then the slot zeroed.

## C++ constraints on web (single-threaded module)

- `thread_local`, `std::mutex`, the instance registry, `<thread>` headers all
  compile & link without `-pthread`; **constructing a `std::thread` aborts at
  runtime** ("thread constructor failed"). Impls must not spawn threads on web
  (the benchmark impl's coalescer worker thread is the in-repo example).
- Global C++ static initializers run during module instantiation
  (`__wasm_call_ctors`) — impl self-registration via a global static works.
- `Dart_InitializeApiDL` is shimmed to return 0 so generated init paths
  succeed unconditionally.

## Generated-Dart structural constraint (discovered)

Generated `.g.dart` **part files define `Struct` subclasses with `external`
fields** — a hard compile error under dart2js/dart2wasm. Stubbing dart:ffi
cannot fix that, so for `targetsWeb` specs the generator must split outputs:
platform-neutral codec sections stay in the part; Struct representations,
proxies, and `_<Class>Impl` move to a standalone native-only library reached
via a conditional-import platform shim.
