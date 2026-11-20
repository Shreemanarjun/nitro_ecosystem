part of '../cpp_bridge_generator.dart';

// State a C++ implementation's exports share: the instance registry, the
// per-stream subscriber ports and the stream emit functions.

/// Emits the per-stream multi-subscriber port registry shared by the
/// mixed-platform desktop dispatch AND the all-platforms-C++ direct path.
///
/// Kotlin/Swift keep a port per subscription; a single `int64_t` slot here
/// let a second concurrent subscriber overwrite the first, which then
/// received nothing ("multiple subscribers independent" returned []).
void _emitStreamPortRegistry(CodeWriter writer, BridgeSpec spec) {
  if (spec.streams.isEmpty) {
    // Still define the hook destroy_instance calls, or the bridge fails to link.
    writer.line('static void _nitro_release_instance_streams(const void*) {}');
    writer.blankLine();
    return;
  }
  writer.line('#include <algorithm>');
  writer.line('#include <mutex>');
  writer.line('#include <unordered_map>');
  writer.line('#include <vector>');
  writer.blankLine();
  writer.line('// One registry per stream, PARTITIONED BY INSTANCE: a stream belongs to');
  writer.line('// the Hybrid<Class> that emits it, so a subscriber on one instance never');
  writer.line('// receives another instance\'s events (the ports used to be global, so');
  writer.line('// every subscriber saw every instance). Every concurrent Dart subscriber');
  writer.line('// registers its own ReceivePort. Guarded by a mutex — register/release');
  writer.line('// run on the Dart isolate thread while emits may come from any thread.');
  writer.line('struct _NitroStreamPorts {');
  writer.line('    std::mutex mtx;');
  writer.line('    std::unordered_map<const void*, std::vector<int64_t>> byInstance;');
  writer.line('    void add(const void* inst, int64_t p) {');
  writer.line('        std::lock_guard<std::mutex> l(mtx); byInstance[inst].push_back(p);');
  writer.line('    }');
  writer.line('    // Release carries only the port: Dart cancels a subscription without');
  writer.line('    // naming the instance, so drop it wherever it is registered.');
  writer.line('    void remove(int64_t p) {');
  writer.line('        std::lock_guard<std::mutex> l(mtx);');
  writer.line('        for (auto& kv : byInstance) {');
  writer.line('            auto& v = kv.second;');
  writer.line('            v.erase(std::remove(v.begin(), v.end(), p), v.end());');
  writer.line('        }');
  writer.line('    }');
  writer.line('    void dropInstance(const void* inst) {');
  writer.line('        std::lock_guard<std::mutex> l(mtx); byInstance.erase(inst);');
  writer.line('    }');
  writer.line('    std::vector<int64_t> snapshot(const void* inst) {');
  writer.line('        std::lock_guard<std::mutex> l(mtx);');
  writer.line('        auto it = byInstance.find(inst);');
  writer.line('        return it == byInstance.end() ? std::vector<int64_t>() : it->second;');
  writer.line('    }');
  writer.line('};');
  for (final stream in spec.streams) {
    writer.line('static _NitroStreamPorts g_ports_${stream.dartName};');
  }
  writer.blankLine();
  writer.line('// Called by destroy_instance so a disposed instance leaves no subscribers.');
  writer.line('static void _nitro_release_instance_streams(const void* impl) {');
  for (final stream in spec.streams) {
    writer.line('    g_ports_${stream.dartName}.dropInstance(impl);');
  }
  writer.line('}');
  writer.blankLine();
}

/// Emits the multi-instance registry (mirrors RN Nitro's HybridObjectRegistry).
/// Shared by the all-C++ direct path and the mixed-platform desktop/web
/// section, so a plugin that also targets native still gets one
/// `Hybrid<Class>` per instance instead of a single global impl.
void _emitInstanceRegistry(
  CodeWriter writer,
  String libStem,
  String className,
) {
  // ── Multi-instance registry (mirrors RN Nitro's HybridObjectRegistry) ────
  // g_instances maps instanceId → shared_ptr<Hybrid$className>.
  // Factory mode (recommended): register_factory() → create_instance() calls it.
  // Legacy mode: register_impl() wraps raw ptr with no-op deleter at slot 0.
  writer.line('#include <atomic>');
  writer.line('#include <memory>');
  writer.line('#include <mutex>');
  writer.line('#include <unordered_map>');
  writer.blankLine();
  // Meyers' Singleton for the registry — guarantees thread-safe init before
  // first use even when __attribute__((constructor)) fires early.
  writer.line('using Hybrid${className}Factory = std::function<std::shared_ptr<Hybrid$className>(const std::string&)>;');
  writer.line('static std::unordered_map<int64_t, std::shared_ptr<Hybrid$className>>& _g_instances() {');
  writer.line('    static std::unordered_map<int64_t, std::shared_ptr<Hybrid$className>> m;');
  writer.line('    return m;');
  writer.line('}');
  writer.line('static std::mutex& _g_instances_mtx() {');
  writer.line('    static std::mutex m;');
  writer.line('    return m;');
  writer.line('}');
  writer.line('static std::atomic<int64_t>& _g_next_instance_id() {');
  writer.line('    static std::atomic<int64_t> id{1};');
  writer.line('    return id;');
  writer.line('}');
  writer.line('static Hybrid${className}Factory& _g_factory() {');
  writer.line('    static Hybrid${className}Factory f;');
  writer.line('    return f;');
  writer.line('}');
  writer.blankLine();
  // Lock-free direct-mapped cache for resolved (id -> raw impl); the map + mutex
  // stay the source of truth for create/destroy. N slots keep a rotating working
  // set of live instances resident so a loop between them doesn't hit the mutex
  // every call. Indexed by `id & (N-1)`: two live ids that alias mod N evict each
  // other and fall back to the (correct, slower) mutex lookup — widen N for a hot
  // workload rotating between more than ~N instances of one class. alignas(64)
  // avoids false sharing; the pointer is borrowed (the map owns the shared_ptr),
  // the Dart-side NativeFinalizer never destroys an instance mid-call, and slots
  // are invalidated under the mutex so a freed id can't resolve stale.
  writer.line('static constexpr int _kNitroCacheWays = 32;');
  writer.line('struct alignas(64) _NitroInstSlot {');
  writer.line('    std::atomic<int64_t> id{-1};');
  writer.line('    std::atomic<Hybrid$className*> ptr{nullptr};');
  writer.line('};');
  writer.line('static _NitroInstSlot _g_inst_cache[_kNitroCacheWays];');
  writer.line('static Hybrid$className* _nitro_get_instance(int64_t id) {');
  writer.line('    _NitroInstSlot& _slot = _g_inst_cache[(uint64_t)id & (_kNitroCacheWays - 1)];');
  writer.line('    if (_slot.id.load(std::memory_order_acquire) == id) {');
  writer.line('        return _slot.ptr.load(std::memory_order_relaxed);');
  writer.line('    }');
  writer.line('    std::lock_guard<std::mutex> _lk(_g_instances_mtx());');
  writer.line('    auto it = _g_instances().find(id);');
  writer.line('    Hybrid$className* p = (it != _g_instances().end()) ? it->second.get() : nullptr;');
  writer.line('    if (p) {');
  writer.line('        _slot.ptr.store(p, std::memory_order_relaxed);');
  writer.line('        _slot.id.store(id, std::memory_order_release);');
  writer.line('    }');
  writer.line('    return p;');
  writer.line('}');
  writer.line('static void _nitro_invalidate_cache() {');
  writer.line('    for (int _i = 0; _i < _kNitroCacheWays; ++_i) {');
  writer.line('        _g_inst_cache[_i].id.store(-1, std::memory_order_release);');
  writer.line('        _g_inst_cache[_i].ptr.store(nullptr, std::memory_order_relaxed);');
  writer.line('    }');
  writer.line('}');
  writer.blankLine();
  writer.line('// Defined with the stream registries below (which may be emitted after');
  writer.line('// this block): drops every subscriber belonging to one instance.');
  writer.line('static void _nitro_release_instance_streams(const void* impl);');
  writer.blankLine();
  writer.line('extern "C" {');
  writer.line('void ${libStem}_register_factory(void* fn) {');
  writer.line('    _g_factory() = *static_cast<Hybrid${className}Factory*>(fn);');
  writer.line('}');
  writer.line('void ${libStem}_register_impl(Hybrid$className* impl) {');
  writer.line('    std::lock_guard<std::mutex> _lk(_g_instances_mtx());');
  writer.line('    if (impl) _g_instances()[0] = std::shared_ptr<Hybrid$className>(impl, [](Hybrid$className*){});');
  writer.line('    else _g_instances().erase(0);');
  writer.line('    _nitro_invalidate_cache();');
  writer.line('}');
  writer.line('Hybrid$className* ${libStem}_get_impl() {');
  writer.line('    return _nitro_get_instance(0);');
  writer.line('}');
  writer.line('NITRO_EXPORT int64_t ${libStem}_create_instance(const char* key) {');
  writer.line('    if (_g_factory()) {');
  writer.line('        auto inst = _g_factory()(key ? key : "");');
  writer.line('        if (!inst) return -1;');
  writer.line('        std::lock_guard<std::mutex> _lk(_g_instances_mtx());');
  writer.line('        int64_t id = ++_g_next_instance_id();');
  writer.line('        _g_instances()[id] = std::move(inst);');
  writer.line('        return id;');
  writer.line('    }');
  writer.line('      // Legacy: no factory registered — return 0 (single global impl slot)');
  writer.line('    return 0;');
  writer.line('}');
  writer.line('NITRO_EXPORT void ${libStem}_destroy_instance(int64_t instanceId) {');
  writer.line('    // Slot 0 belongs to register_impl (the legacy single impl and the');
  writer.line('    // stream-emitter target), never to a Dart instance. Without this a');
  writer.line('    // plugin that registers no factory hands every instance id 0, and the');
  writer.line('    // first dispose() erases the slot for all of them.');
  writer.line('    if (instanceId == 0) { return; }');
  writer.line('    std::lock_guard<std::mutex> _lk(_g_instances_mtx());');
  writer.line('    auto _it = _g_instances().find(instanceId);');
  writer.line('    if (_it != _g_instances().end()) {');
  writer.line('        _nitro_release_instance_streams(_it->second.get());');
  writer.line('    }');
  writer.line('    _g_instances().erase(instanceId);');
  writer.line('    _nitro_invalidate_cache();');
  writer.line('}');
}

/// Emits the `Hybrid<Class>::emit_*` stream definitions shared by the
/// mixed-platform desktop dispatch AND the all-platforms-C++ direct path
/// (cpp_direct_emitter.dart). Signatures come from CppInterfaceGenerator
/// so the definitions always match the declarations in *.native.g.h.
void _emitCppStreamEmitters(
  CodeWriter writer,
  BridgeSpec spec,
  String className,
  Set<String> enumNames,
  Set<String> structNames,
  Set<String> variantNames,
) {
  for (final stream in spec.streams) {
    final base = bareTypeName(stream.itemType.name);
    final isNullable = stream.itemType.isNullable || stream.itemType.name.endsWith('?');
    final isStruct = structNames.contains(base);
    final isVariantStream = variantNames.contains(base);
    final isRecord = stream.itemType.isRecord || isVariantStream;
    final isEnum = enumNames.contains(base);
    // Signature must match the declaration in native.g.h exactly.
    final itemCpp = CppInterfaceGenerator.cppReturnTypeFor(
      stream.itemType,
      enumNames,
      structNames,
      {...spec.recordTypes.map((r) => r.name), ...variantNames},
    );

    final ports = 'g_ports_${stream.dartName}';
    // `this` is the emitting instance — only its subscribers get the event.
    writer.line('void Hybrid$className::emit_${stream.dartName}($itemCpp item) {');
    writer.line('    auto _ports = $ports.snapshot(this);');
    if (isRecord) {
      // Record/variant items own a heap [4B len][payload] block — if no
      // subscriber is listening, the caller's buffer must still be released.
      writer.line('    if (_ports.empty()) { if (item.data) { free((void*)item.data); } return; }');
    } else {
      writer.line('    if (_ports.empty()) { return; }');
    }

    // Nullable items: post kNull for std::nullopt, else unwrap and fall through.
    // (Nullable records/variants stay NitroCppBuffer — nullptr data means null.)
    if (isNullable && !isRecord) {
      writer.line('    if (!item.has_value()) {');
      writer.line('        Dart_CObject _null_obj;');
      writer.line('        _null_obj.type = Dart_CObject_kNull;');
      writer.line('        for (int64_t _port : _ports) {');
      writer.line('            if (!Dart_PostCObject_DL(_port, &_null_obj)) { $ports.remove(_port); }');
      writer.line('        }');
      writer.line('        return;');
      writer.line('    }');
    }
    final v = (isNullable && !isRecord) ? '(*item)' : 'item';

    if (isRecord) {
      // Record/variant: item is a SELF-DESCRIBING heap [4B len][payload]
      // block — exactly what record.toNativeBuffer() / nitro_Xxx_to_native()
      // return, matching the record RETURN convention. Ownership transfers
      // to Dart: each subscriber's port gets its OWN heap copy (Dart frees
      // each via <lib>_nitro_free), and the caller's block is released here
      // — emit always consumes item. Never pass a non-owning
      // writer.toBuffer() view. (Earlier versions expected a bare payload
      // view and re-wrapped it in a second length prefix; paired with
      // toNativeBuffer() that corrupted every decoded field AND leaked the
      // caller's block.)
      writer.line('    Dart_CObject obj;');
      writer.line('    if (item.data == nullptr) {');
      writer.line('        obj.type = Dart_CObject_kNull;');
      writer.line('        for (int64_t _port : _ports) {');
      writer.line('            if (!Dart_PostCObject_DL(_port, &obj)) { $ports.remove(_port); }');
      writer.line('        }');
      writer.line('        return;');
      writer.line('    }');
      writer.line('    for (int64_t _port : _ports) {');
      writer.line('        uint8_t* _copy = (uint8_t*)malloc(item.size);');
      writer.line('        if (!_copy) { break; }');
      writer.line('        memcpy(_copy, item.data, item.size);');
      writer.line('        obj.type = Dart_CObject_kInt64;');
      writer.line('        obj.value.as_int64 = (intptr_t)_copy;');
      writer.line('        if (!Dart_PostCObject_DL(_port, &obj)) {');
      writer.line('            free(_copy);');
      writer.line('            $ports.remove(_port);');
      writer.line('        }');
      writer.line('    }');
      writer.line('    free((void*)item.data);');
      writer.line('}');
      writer.blankLine();
      continue;
    }

    if (stream.itemType.isTypedData) {
      // Typed-data items: NitroCppBuffer.size is in BYTES. The VM copies the
      // elements during the post; the caller keeps ownership of item.data.
      final esz = switch (base) {
        'Int16List' || 'Uint16List' => 2,
        'Int32List' || 'Uint32List' || 'Float32List' => 4,
        'Int64List' || 'Uint64List' || 'Float64List' => 8,
        _ => 1,
      };
      writer.line('    Dart_CObject obj;');
      if (isNullable) {
        writer.line('    if (item.data == nullptr) { obj.type = Dart_CObject_kNull; } else {');
        _emitTypedDataObj(writer, base, 'item.data', 'item.size / $esz', '        ');
        writer.line('    }');
      } else {
        _emitTypedDataObj(writer, base, 'item.data', 'item.size / $esz', '    ');
      }
      writer.line('    for (int64_t _port : _ports) {');
      writer.line('        if (!Dart_PostCObject_DL(_port, &obj)) { $ports.remove(_port); }');
      writer.line('    }');
      writer.line('}');
      writer.blankLine();
      continue;
    }

    if (isStruct) {
      // Struct items post a malloc'd copy whose ownership transfers to
      // Dart — one fresh copy per subscriber port.
      writer.line('    Dart_CObject obj;');
      writer.line('    for (int64_t _port : _ports) {');
      writer.line('        $base* st_ptr = ($base*)malloc(sizeof($base));');
      writer.line('        if (!st_ptr) { break; }');
      writer.line('        *st_ptr = $v;');
      writer.line('        obj.type = Dart_CObject_kInt64;');
      writer.line('        obj.value.as_int64 = (intptr_t)st_ptr;');
      writer.line('        if (!Dart_PostCObject_DL(_port, &obj)) {');
      writer.line('            free(st_ptr);');
      writer.line('            $ports.remove(_port);');
      writer.line('        }');
      writer.line('    }');
      writer.line('}');
      writer.blankLine();
      continue;
    }

    // Scalar-ish items (int/double/bool/String/enum/DateTime/uint64):
    // Dart_PostCObject_DL copies the value during the call, so the same
    // Dart_CObject can be posted to every subscriber port.
    writer.line('    Dart_CObject obj;');
    switch (base) {
      case 'double':
        writer.line('    obj.type = Dart_CObject_kDouble;');
        writer.line('    obj.value.as_double = $v;');
      case 'int' || 'DateTime':
        writer.line('    obj.type = Dart_CObject_kInt64;');
        writer.line('    obj.value.as_int64 = $v;');
      case 'uint64':
        writer.line('    obj.type = Dart_CObject_kInt64;');
        writer.line('    obj.value.as_int64 = (int64_t)$v;');
      case 'bool':
        // Use kInt64 (0/1) — kBool is unreliable on some Android versions.
        writer.line('    obj.type = Dart_CObject_kInt64;');
        writer.line('    obj.value.as_int64 = $v ? 1 : 0;');
      case 'String':
        writer.line('    obj.type = Dart_CObject_kString;');
        writer.line('    obj.value.as_string = (char*)$v.c_str();');
      case _ when isEnum:
        writer.line('    obj.type = Dart_CObject_kInt64;');
        writer.line('    obj.value.as_int64 = static_cast<int64_t>($v);');
      default:
        writer.line('    obj.type = Dart_CObject_kNull;');
    }
    writer.line('    for (int64_t _port : _ports) {');
    writer.line('        if (!Dart_PostCObject_DL(_port, &obj)) { $ports.remove(_port); }');
    writer.line('    }');
    writer.line('}');
    writer.blankLine();
  }
}
