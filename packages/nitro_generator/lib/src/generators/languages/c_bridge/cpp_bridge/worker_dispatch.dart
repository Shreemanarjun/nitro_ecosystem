part of '../cpp_bridge_generator.dart';

// Native completion of async work: the per-library completion batch, the
// `<sym>_dispatch` twins that run a sync export on the worker pool, the
// fire-and-forget `<sym>_fnf` exports, stream coalescing and owned-handle
// release exports.

/// Per-library completion batcher instance + its three exports. Emitted
/// right after the DL header so the macro from the bridge header can route
/// every later post site through it (web builds have no ports: skipped).
void _emitCompletionBatch(CodeWriter writer, BridgeSpec spec) {
  final libStem = spec.lib.replaceAll('-', '_');
  if (spec.targetsWeb) writer.line('#ifndef __EMSCRIPTEN__');
  writer.line('#include "nitro_completion_batch.h"');
  writer.line('static NitroCompletionBatch g_nitro_batch_$libStem;');
  writer.line('extern "C" {');
  writer.line('NITRO_EXPORT bool ${libStem}_nitro_post(int64_t port, struct _Dart_CObject* obj) { return g_nitro_batch_$libStem.post(port, obj); }');
  writer.line('NITRO_EXPORT int64_t ${libStem}_nitro_bind(int64_t batchPort) { return g_nitro_batch_$libStem.bind(batchPort); }');
  writer.line('NITRO_EXPORT void ${libStem}_nitro_ack(int64_t batchPort) { g_nitro_batch_$libStem.ack(batchPort); }');
  // Single-in-flight completion spin (issue #57): arm the slot, then Dart
  // busy-polls poll() for a short window instead of parking on the port.
  // arm() returns 1 if this isolate claimed the one shared slot, 0 if another
  // isolate owns it (caller must not spin). disarm() frees a claim whose call
  // threw before dispatching a worker.
  writer.line('NITRO_EXPORT int32_t ${libStem}_nitro_arm(int64_t id) { return g_nitro_batch_$libStem.arm(id) ? 1 : 0; }');
  writer.line('NITRO_EXPORT void ${libStem}_nitro_disarm(int64_t id) { g_nitro_batch_$libStem.disarm(id); }');
  writer.line('NITRO_EXPORT int32_t ${libStem}_nitro_poll(int64_t id, uint8_t* out, int32_t giveUp) { return g_nitro_batch_$libStem.poll(id, out, giveUp); }');
  writer.line('}');
  if (spec.functions.any((f) => spec.dispatchesAsync(f) || spec.fireAndForget(f))) _emitWorkerDispatchInfra(writer, spec, libStem);
  if (spec.targetsWeb) writer.line('#endif');
  writer.blankLine();
}

/// Posts `count` elements at `data` as one Dart typed list of [base]'s
/// element type (the VM copies them during the post). `data` may be null
/// for an empty list.
void _emitTypedDataObj(CodeWriter w, String base, String data, String count, String indent) {
  w.line('${indent}static const uint8_t _nitro_empty[8] = {0};');
  w.line('${indent}obj.type = Dart_CObject_kTypedData;');
  w.line('${indent}obj.value.as_typed_data.type = ${CppBridgeGenerator.typedDataKind(base)};');
  w.line('${indent}obj.value.as_typed_data.length = (intptr_t)($count);');
  w.line('${indent}obj.value.as_typed_data.values = $data ? (const uint8_t*)$data : _nitro_empty;');
}

/// Every stream port is its own batch target in the per-library batcher
/// while registered (see nitro_completion_batch.h): items that arrive while
/// Dart is busy travel in one message. No item is dropped or reordered.
void _emitStreamCoalesce(CodeWriter writer, BridgeSpec spec, String call, [BridgeStream? stream]) {
  final libStem = spec.lib.replaceAll('-', '_');
  final free = stream == null ? null : _streamItemFree(spec, stream, libStem);
  if (spec.targetsWeb) writer.line('#ifndef __EMSCRIPTEN__');
  writer.line(free == null ? '    g_nitro_batch_$libStem.$call(dart_port);' : '    g_nitro_batch_$libStem.$call(dart_port, $free);');
  if (spec.targetsWeb) writer.line('#endif');
}

/// How the batcher frees one undelivered item of [stream], matching what
/// Dart does on delivery: struct items go through the proxy's release
/// function, record/variant/map blobs through `<lib>_nitro_free`. Scalar and
/// string items own nothing (null).
String? _streamItemFree(BridgeSpec spec, BridgeStream stream, String libStem) {
  final base = bareTypeName(stream.itemType.name);
  if (spec.isStructName(base)) return '[](int64_t a) { ${libStem}_release_$base((void*)(intptr_t)a); }';
  if (stream.itemType.isRecord || spec.isVariantName(base)) return '[](int64_t a) { ${libStem}_nitro_free((void*)(intptr_t)a); }';
  return null;
}

/// Worker pool + post helpers behind `<sym>_dispatch` (see
/// [emitCppWorkerDispatch]); emitted inside the same non-web guard.
void _emitWorkerDispatchInfra(CodeWriter writer, BridgeSpec spec, String libStem) {
  writer.line('#include "nitro_worker_pool.h"');
  // Heap-allocated and never destroyed. Its workers are detached and parked on
  // the pool's condition variable; as a static object it was destroyed at
  // exit(), and glibc's pthread_cond_destroy blocks while a thread waits, so a
  // Linux process that had made one async call never exited.
  writer.line('static NitroWorkerPool& g_nitro_pool_$libStem = *new NitroWorkerPool();');
  writer.line('[[maybe_unused]] static void _nitro_post_null(int64_t port) { Dart_CObject o; o.type = Dart_CObject_kNull; Dart_PostCObject_DL(port, &o); }');
  writer.line('[[maybe_unused]] static void _nitro_post_i64(int64_t port, int64_t v) { Dart_CObject o; o.type = Dart_CObject_kInt64; o.value.as_int64 = v; Dart_PostCObject_DL(port, &o); }');
  writer.line('[[maybe_unused]] static void _nitro_post_f64(int64_t port, double v) { Dart_CObject o; o.type = Dart_CObject_kDouble; o.value.as_double = v; Dart_PostCObject_DL(port, &o); }');
  writer.line('[[maybe_unused]] static void _nitro_post_bool(int64_t port, int8_t v) { Dart_CObject o; o.type = Dart_CObject_kBool; o.value.as_bool = v != 0; Dart_PostCObject_DL(port, &o); }');
  writer.line('[[maybe_unused]] static void _nitro_post_ptr(int64_t port, const void* p) { _nitro_post_i64(port, (int64_t)(intptr_t)p); }');
  writer.line('// Owned C string (strdup\'d by the async sync export): posted as kString, then freed.');
  writer.line(
    '[[maybe_unused]] static void _nitro_post_str_owned(int64_t port, char* s) { if (!s) { _nitro_post_null(port); return; } Dart_CObject o; o.type = Dart_CObject_kString; o.value.as_string = s; Dart_PostCObject_DL(port, &o); free(s); }',
  );
  writer.line('// [int32 len][payload] blob → owned copy (empty for null).');
  writer.line(
    '[[maybe_unused]] static std::vector<uint8_t> _nitro_copy_framed(const void* p) { if (!p) return {}; int32_t n = 0; memcpy(&n, p, 4); const uint8_t* b = (const uint8_t*)p; return std::vector<uint8_t>(b, b + 4 + (n < 0 ? 0 : n)); }',
  );
  writer.line('[[maybe_unused]] static std::vector<uint8_t> _nitro_copy_bytes(const void* p, size_t n) { if (!p) return {}; const uint8_t* b = (const uint8_t*)p; return std::vector<uint8_t>(b, b + n); }');
  writer.line('// Moves the thread-local error of the worker into the per-call slot Dart reads.');
  writer.line(
    '[[maybe_unused]] static void _nitro_move_err(NitroError* dst, NitroError* src) { if (!dst || !src) return; dst->hasError = 1; dst->name = src->name; dst->message = src->message; dst->code = src->code; dst->stackTrace = src->stackTrace; src->hasError = 0; src->name = src->message = src->code = src->stackTrace = nullptr; }',
  );
}

/// Fire-and-forget bound: outstanding jobs allowed before a call blocks the
/// caller for pool space (issue #58 backpressure). A hot streaming loop stays
/// well under this; a runaway producer is throttled instead of OOMing.
const int _fnfMaxQueued = 1024;

/// One `<sym>_fnf` export: a `void` `@nitroNativeAsync` (see [BridgeSpec.fireAndForget]).
/// Copies its args, enqueues the sync impl on the pool (bounded) and returns —
/// no dart_port, no post, no error slot. Many calls dispatch concurrently, so a
/// stream of small void calls isn't serialized by the single-in-flight slot.
void _emitFnfFunction(CodeWriter w, BridgeSpec spec, String libStem, BridgeFunction func) {
  final sym = func.cSymbol;
  final pieces = [for (final p in func.params) _dispatchParam(spec, libStem, p)];
  final params = ['int64_t instanceId', for (final x in pieces) ...x.params];
  final args = ['instanceId', for (final x in pieces) ...x.args];
  w.line('NITRO_EXPORT void ${sym}_fnf(${params.join(', ')}) {');
  for (final c in pieces.map((x) => x.copy).nonNulls) {
    w.line(c);
  }
  // Reuse the normal native-async posting <sym>, but with dart_port = 0 so
  // nothing is posted (fire-and-forget: no completion). A fresh error slot per
  // call absorbs any error the impl reports; it's dropped (best-effort — the
  // contract is that fire-and-forget impls don't need to surface errors).
  // block policy (dropOldest=0): under sustained overload the caller waits for
  // pool space rather than dropping work or growing the queue unbounded.
  w.line('    g_nitro_pool_$libStem.enqueueBounded([=]() mutable {');
  w.line('        NitroError _fnf_err = {};');
  w.line('        $sym(${args.join(', ')}, &_fnf_err, 0);');
  for (final r in pieces.map((x) => x.release).nonNulls) {
    w.line(r);
  }
  w.line('    }, $_fnfMaxQueued, 0);');
  w.line('}');
  w.blankLine();
}

/// One `<sym>_dispatch` export (see [emitCppWorkerDispatch]).
void _emitDispatchFunction(CodeWriter w, BridgeSpec spec, String libStem, BridgeFunction func) {
  final sym = func.cSymbol;
  final pieces = [for (final p in func.params) _dispatchParam(spec, libStem, p)];
  final params = ['int64_t instanceId', for (final x in pieces) ...x.params];
  final args = ['instanceId', for (final x in pieces) ...x.args];
  final cRet = CppHeaderGenerator.syncReturnCType(spec, func);
  final post = switch (cRet) {
    'void' => '_nitro_post_null(dart_port);',
    'double' => '_nitro_post_f64(dart_port, _r);',
    'int8_t' || 'bool' => '_nitro_post_bool(dart_port, _r);',
    'char*' || 'const char*' => '_nitro_post_str_owned(dart_port, (char*)_r);',
    'int64_t' => '_nitro_post_i64(dart_port, _r);',
    _ => '_nitro_post_ptr(dart_port, (const void*)_r);',
  };
  w.line('NITRO_EXPORT void ${sym}_dispatch(${params.join(', ')}, NitroError* _nitro_err, int64_t dart_port) {');
  w.line('    if (_nitro_err) { _nitro_err->hasError = 0; }');
  for (final c in pieces.map((x) => x.copy).nonNulls) {
    w.line(c);
  }
  w.line('    g_nitro_pool_$libStem.enqueue([=]() mutable {');
  w.line('        ${libStem}_clear_error();');
  w.line(cRet == 'void' ? '        $sym(${args.join(', ')});' : '        $cRet _r = $sym(${args.join(', ')});');
  for (final r in pieces.map((x) => x.release).nonNulls) {
    w.line(r);
  }
  w.line('        NitroError* _e = ${libStem}_get_error();');
  w.line('        if (_e->hasError) { _nitro_move_err(_nitro_err, _e); _nitro_post_null(dart_port); return; }');
  w.line('        $post');
  w.line('    });');
  w.line('}');
  w.blankLine();
}

/// One parameter of a `<sym>_dispatch` export: its C parameter(s), the copy
/// taken before enqueueing (null = passed by value), the argument(s) the
/// worker hands the sync export, and the release after the call.
({List<String> params, String? copy, List<String> args, String? release}) _dispatchParam(BridgeSpec spec, String libStem, BridgeParam p) {
  final cType = CppHeaderGenerator.cParamType(spec, p);
  final base = bareTypeName(p.type.name);
  final n = p.name;
  final params = ['$cType $n', if (p.type.isTypedData) 'size_t ${n}_length'];
  final framed = p.type.isRecord || p.type.isMap || p.type.isAnyMap || spec.isVariantName(base) || p.type.name.startsWith('List<');
  if (base == 'String') {
    return (params: params, copy: '    std::string _c_$n($n ? $n : ""); const bool _n_$n = $n == nullptr;', args: ['_n_$n ? nullptr : _c_$n.c_str()'], release: null);
  }
  if (p.type.isTypedData) {
    // One padding byte keeps data() non-null for an empty list, so only a
    // null argument reaches the sync export as nullptr.
    final copy = '    std::vector<uint8_t> _c_$n = _nitro_copy_bytes($n, (size_t)${n}_length * sizeof(*$n)); const bool _n_$n = $n == nullptr; _c_$n.push_back(0);';
    return (params: params, copy: copy, args: ['_n_$n ? nullptr : ($cType)_c_$n.data()', '${n}_length'], release: null);
  }
  if (spec.isStructName(base)) {
    return (
      params: params,
      copy: '    $base* _c_$n = nullptr; if ($n) { _c_$n = ($base*)malloc(sizeof($base)); *_c_$n = _nitro_clone_$base(*static_cast<const $base*>($n)); }',
      args: ['(void*)_c_$n'],
      release: '        if (_c_$n) ${libStem}_release_$base(_c_$n);',
    );
  }
  if (p.type.isNullableNitroPrim) {
    final opt = base == 'bool' ? 'NitroOptBool' : (base == 'double' ? 'NitroOptFloat64' : 'NitroOptInt64');
    return (params: params, copy: '    std::vector<uint8_t> _c_$n = _nitro_copy_bytes($n, sizeof($opt));', args: ['_c_$n.empty() ? nullptr : ($cType)_c_$n.data()'], release: null);
  }
  if (framed) {
    return (params: params, copy: '    std::vector<uint8_t> _c_$n = _nitro_copy_framed($n);', args: ['_c_$n.empty() ? nullptr : ($cType)_c_$n.data()'], release: null);
  }
  return (params: params, copy: null, args: [n], release: null); // scalars, enums, handles: by value
}

void _emitOwnedReleaseExports(CodeWriter writer, BridgeSpec spec) {
  // ── @NitroOwned release functions ────────────────────────────────────────────
  // Emitted globally (before platform guards) so the symbol exists on ALL platforms.
  // On Android, the handle is a jlong from Kotlin — Kotlin GC manages lifecycle (no-op).
  // On Apple/Desktop, the handle is from UnsafeMutableRawPointer.allocate (system malloc).
  final ownedFuncs = spec.functions.where((f) => f.isOwned && f.returnType.isNativeHandle).toList();
  if (ownedFuncs.isNotEmpty) {
    writer.line('extern "C" {');
    // Custom release symbols from @NitroOwned(release: '...') — declared
    // here with the handle-pointer signature so this file compiles without
    // including the owning library's header. extern "C" names don't mangle,
    // so the declaration links against the real definition (e.g. webgpu.h's
    // `void wgpuBufferRelease(WGPUBuffer)`). Deduped: several methods may
    // share one release function.
    final customReleases = ownedFuncs.map((f) => f.releaseSymbol).whereType<String>().toSet();
    for (final sym in customReleases) {
      writer.line('void $sym(void* handle);');
    }
    for (final f in ownedFuncs) {
      final custom = f.releaseSymbol;
      if (custom != null) {
        // Handle is owned by a native library — release through its own
        // function (@NitroOwned(release: '$custom')), never free().
        writer.line('NITRO_EXPORT void ${f.cSymbol}_release(void* handle) {');
        writer.line('    if (handle) { $custom(handle); }');
        writer.line('}');
      } else {
        // On all platforms the handle is a real malloc'd pointer:
        //   Android: allocated via sun.misc.Unsafe.allocateMemory (ART calls malloc internally).
        //   Apple:   allocated via UnsafeMutableRawPointer.allocate.
        // Both are freed with free().
        writer.line('NITRO_EXPORT void ${f.cSymbol}_release(void* handle) {');
        writer.line('    if (handle) { free(handle); }');
        writer.line('}');
      }
    }
    writer.line('}');
    writer.blankLine();
  }
}
