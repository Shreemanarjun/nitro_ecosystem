part of '../dart_ffi_generator.dart';

/// Emits the `_${spec.dartClassName}Impl` class header, constructor,
/// field declarations, and dispose()/callbackCache logic.
void _emitImplClassSetup(CodeWriter writer, BridgeSpec spec) {
  // ── Impl class ──────────────────────────────────────────────────────────
  final libStem = spec.lib.replaceAll('-', '_');
  final checksum = bridgeSpecChecksum(spec);
  writer.line(
    'class _${spec.dartClassName}Impl extends ${spec.dartClassName} {',
  );
  writer.line('  final DynamicLibrary _dylib;');
  // String-key registry: getInstance('key') returns the same cached instance.
  // instanceId is assigned by the native side on first access via create_instance.
  // WEAK references: an instance that all callers drop can be GC'd (the entry's
  // target goes null), so keyed/multi-instance modules don't leak — a strong
  // map would pin every instance for the process lifetime. dispose() removes
  // the entry eagerly; the finalizer below cleans up a dropped-without-dispose
  // instance's native memory.
  writer.line('  static final _instances = <String, WeakReference<_${spec.dartClassName}Impl>>{};');
  writer.blankLine();
  // GC safety net: if an instance becomes unreachable without dispose() being
  // called, destroy the native instance + free the per-call error slot. The
  // token is a record capturing only the instanceId, key, error-slot pointer,
  // and the (already-resolved) destroy closure — NOT `this` — so it never keeps
  // the instance alive. dispose() detaches it so the two paths can't both run
  // (no double-free).
  //
  // It does NOT close the callback NativeCallables (see _nativeCallbackCache) —
  // only dispose() can. The token can't hold the cache: a NativeCallable wraps a
  // user closure that may capture `this`, so capturing the cache here could pin
  // the instance and stop the finalizer ever running. Therefore an instance that
  // registers callbacks MUST be disposed; relying on GC leaks the callback
  // trampolines (and, for `.listener` callbacks, their ports).
  writer.line(
    '  static final _instanceFinalizer = Finalizer<({int id, String key, Pointer<NitroErrorFfi> err, void Function(int) destroy})>((t) {',
  );
  // A finalizer must never throw an uncaught async error — swallow any failure
  // (best-effort GC cleanup) and always free the error slot.
  writer.line('    try {');
  writer.line('      t.destroy(t.id);');
  writer.line("      NitroRuntime.releaseLib('${spec.lib}');");
  writer.line('      if (_instances[t.key]?.target == null) _instances.remove(t.key);');
  writer.line('    } catch (_) {');
  writer.line('    } finally {');
  writer.line('      calloc.free(t.err);');
  writer.line('    }');
  writer.line('  });');
  writer.line('  final String _instanceKey;');
  writer.line('  late final int _instanceId;');
  // S8: pre-allocated error slot — shared across all sync calls on this instance.
  // One allocation per module, zero allocation per call.
  // calloc, NOT malloc: the slot must start zeroed (hasError = 0). A native
  // bridge path that forgets to write the out-param would otherwise leave Dart
  // reading garbage — nonzero hasError with wild char* fields segfaults inside
  // throwIfOutParamError (seen on the Windows/Linux mixed-spec desktop bridge).
  writer.line('  final Pointer<NitroErrorFfi> _nitroErr = calloc<NitroErrorFfi>();');
  final hasCallbacks = _hasFunctionTypeParams(spec);
  if (hasCallbacks) {
    // One NativeCallable slot per "methodName.paramName", replaced (not
    // accumulated) on every re-registration — see _emitCallbackHelpers.
    writer.line('  final Map<String, NativeCallable<dynamic>> _nativeCallbackCache = {};');
  }
  final hasZeroCopyTypedDataReturn = spec.functions.any((f) => f.zeroCopyReturn && f.returnType.isTypedData);
  if (hasZeroCopyTypedDataReturn) {
    writer.line(
      // NativeFinalizerFunction is typedef NativeFunction<Void Function(Pointer<Void>)>,
      // so lookup<NativeFinalizerFunction> is correct — NOT NativeFunction<NativeFinalizerFunction>.
      "  late final Pointer<NativeFinalizerFunction> _typedDataReturnFinalizer = _dylib.lookup<NativeFinalizerFunction>('${libStem}_release_typed_data_return').cast();",
    );
  }
  // Frees NATIVE-owned memory (strings, record/variant blobs, struct copies,
  // posted async results, stream items) with the module's own C-runtime free.
  // package:ffi's malloc.free is CoTaskMemFree on Windows — calling it on a
  // pointer the native side produced with malloc/strdup corrupts the heap.
  // Native memory must always be released by the allocator that produced it.
  writer.line(
    "  late final void Function(Pointer<Void>) _nitroFreePtr = _dylib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('${libStem}_nitro_free', isLeaf: true);",
  );
  writer.line('  void _nitroFree(Pointer<NativeType> ptr) => _nitroFreePtr(ptr.cast());');
  // Same symbol as a raw function pointer, for NativeFinalizer-based owners
  // (LazyRecordList) that outlive the decoding call.
  writer.line(
    "  late final Pointer<NativeFinalizerFunction> _nitroFreeFinalizer = _dylib.lookup<NativeFinalizerFunction>('${libStem}_nitro_free').cast();",
  );
  // The reverse direction: values Dart produces that NATIVE code frees with
  // C-runtime free() — String/record/variant callback returns. They must be
  // allocated by the module's C-runtime malloc, not package:ffi's allocators
  // (CoTaskMemAlloc on Windows).
  writer.line(
    "  late final Pointer<Void> Function(int) _nitroAllocPtr = _dylib.lookupFunction<Pointer<Void> Function(IntPtr), Pointer<Void> Function(int)>('${libStem}_nitro_alloc', isLeaf: true);",
  );
  if (spec.functions.any(spec.bridgeAsync) || spec.streams.isNotEmpty) {
    // Ack for the per-library batcher: native-async completions and
    // coalesced batch streams both flush on it.
    writer.line("  late final void Function(int) _nitroAckPtr = _dylib.lookupFunction<Void Function(Int64), void Function(int)>('${libStem}_nitro_ack', isLeaf: true);");
  }
  if (spec.functions.any(spec.bridgeAsync)) {
    // Shared completion port for @nitroNativeAsync (see NitroCompletionBatch):
    // one message per burst instead of one per call.
    writer.line("  late final int Function(int) _nitroBindPtr = _dylib.lookupFunction<Int64 Function(Int64), int Function(int)>('${libStem}_nitro_bind', isLeaf: true);");
    // Single-in-flight completion spin (issue #57): arm the slot, then busy-poll
    // it. Opt-in via NitroConfig.nativeAsyncSpinUs; the batch no-ops otherwise.
    writer.line("  late final int Function(int) _nitroArmPtr = _dylib.lookupFunction<Int32 Function(Int64), int Function(int)>('${libStem}_nitro_arm', isLeaf: true);");
    writer.line("  late final void Function(int) _nitroDisarmPtr = _dylib.lookupFunction<Void Function(Int64), void Function(int)>('${libStem}_nitro_disarm', isLeaf: true);");
    writer.line("  late final int Function(int, Pointer<Uint8>, int) _nitroPollPtr = _dylib.lookupFunction<Int32 Function(Int64, Pointer<Uint8>, Int32), int Function(int, Pointer<Uint8>, int)>('${libStem}_nitro_poll', isLeaf: true);");
    writer.line('  late final NitroCompletionBatch _nitroBatch = NitroCompletionBatch(bind: _nitroBindPtr, ack: _nitroAckPtr, arm: _nitroArmPtr, disarm: _nitroDisarmPtr, poll: _nitroPollPtr);');
  }
  writer.line('  late final NitroNativeAllocator _nitroNativeAllocator = NitroNativeAllocator(_nitroAllocPtr, _nitroFreePtr);');
  writer.blankLine();
  writer.line('  static DynamicLibrary _loadSupportedLibrary() {');
  // PX19: Guard against dart:ffi usage on web at runtime.
  // dart:ffi types (DynamicLibrary, Pointer, calloc, etc.) are not available
  // on web — nitro.dart exports ffi_stub.dart instead. This assertion helps
  // catch misconfiguration where the FFI impl is instantiated on web instead
  // of the web bridge from *.web.bridge.g.dart.
  if (spec.targetsWeb) {
    writer.line('    assert(');
    writer.line("      !const bool.fromEnvironment('dart.library.js_interop'),");
    writer.line(
      "      '${spec.lib}: dart:ffi is unavailable on web. "
      "Instantiate the web bridge via create${spec.dartClassName}WebInstance() "
      "from the generated *.web.bridge.g.dart file instead.',",
    );
    writer.line('    );');
  }
  writer.line("    return NitroRuntime.loadLibForTargets('${spec.lib}',");
  writer.line('      ios: ${spec.targetsIos},');
  writer.line('      android: ${spec.targetsAndroid},');
  writer.line('      macos: ${spec.targetsMacos},');
  writer.line('      windows: ${spec.targetsWindows},');
  writer.line('      linux: ${spec.targetsLinux},');
  writer.line('      web: ${spec.targetsWeb},');
  writer.line('    );');
  writer.line('  }');
  writer.blankLine();
  // Factory: returns cached instance for the given key, or creates a new one.
  // On first access: calls create_instance(key) → native assigns instanceId.
  writer.line('  factory _${spec.dartClassName}Impl([String key = \'default\']) {');
  writer.line('    final cached = _instances[key]?.target;');
  writer.line('    if (cached != null) return cached;');
  writer.line('    return _${spec.dartClassName}Impl._init(key);');
  writer.line('  }');
  writer.blankLine();
  writer.line(
    '  _${spec.dartClassName}Impl._init(this._instanceKey) : _dylib = _loadSupportedLibrary() {',
  );
  // Lifecycle timing and messages exist only at verbose: instances are cheap to
  // create, and Dart builds a message before logLifecycle can drop it.
  writer.line("    final initSw = NitroConfig.instance.effectiveLogLevel == NitroLogLevel.verbose ? (Stopwatch()..start()) : null;");
  // Finding 10: TypedData lengths use the `Size` FFI type (= size_t), which
  // is 4 bytes on 32-bit and 8 bytes on 64-bit — no platform-width mismatch.
  // We emit a soft debug-mode note (not a failure) if running on 32-bit so
  // developers know the platform width, but the bridge is fully compatible.
  writer.line("    assert(sizeOf<IntPtr>() >= 4, '${spec.lib}: unsupported pointer width \${sizeOf<IntPtr>()}B');");
  writer.line(
    "    final initFunc = _dylib.lookupFunction<IntPtr Function(Pointer<Void>), int Function(Pointer<Void>)>('${libStem}_init_dart_api_dl');",
  );
  writer.line('    final initCode = initFunc(NativeApi.initializeApiDLData);');
  writer.line('    if (initCode != 0) {');
  writer.line("      throw StateError('${spec.lib}: Dart API DL initialization failed with code \$initCode.');");
  writer.line('    }');
  // Finding 6: use providesSymbol() to give a clear actionable error if the plugin
  // was compiled against an older Nitro that lacks the version/checksum symbols.
  writer.line("    if (!_dylib.providesSymbol('${libStem}_nitro_abi_version')) {");
  writer.line("      throw StateError('${spec.lib}: missing ${libStem}_nitro_abi_version — plugin must be rebuilt against the current Nitro version.');");
  writer.line('    }');
  writer.line(
    "    NitroRuntime.checkAbiVersion('${spec.lib}', () => _dylib.lookupFunction<Uint32 Function(), int Function()>('${libStem}_nitro_abi_version')());",
  );
  writer.line("    if (!_dylib.providesSymbol('${libStem}_nitro_bridge_checksum')) {");
  writer.line("      throw StateError('${spec.lib}: missing ${libStem}_nitro_bridge_checksum — plugin must be rebuilt against the current Nitro version.');");
  writer.line('    }');
  writer.line(
    "    NitroRuntime.checkLinkChecksum('${spec.lib}', '$checksum', () => _dylib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('${libStem}_nitro_bridge_checksum')().toDartString());",
  );
  // Initialise NativeFinalizer for every struct proxy this spec owns (a
  // proxy's _init is private to its library; imported structs stream eagerly).
  // Each proxy looks up its generated release C-symbol from _dylib.
  for (final st in spec.localStructs) {
    writer.line('    ${st.name}Proxy._init(_dylib);');
  }
  // Ask native side to create an impl for this key and return the assigned instanceId.
  // The pointer is accessed lazily on first use — _dylib is already set at this point.
  // calloc on both ends (allocate + free) — zero-initialized as defense in
  // depth for the native key buffer. Functionally equivalent to malloc here:
  // package:ffi's malloc.free/calloc.free both resolve to the same underlying
  // free (CoTaskMemFree on Windows, libc free() elsewhere) regardless of which
  // allocator produced the pointer, so this is a style choice, not a bug fix.
  writer.line('    final _keyPtr = _instanceKey.toNitroUtf8(allocator: calloc);');
  writer.line('    try {');
  writer.line('      _instanceId = _createInstancePtr(_keyPtr);');
  writer.line('      if (_instanceId < 0) {');
  writer.line("        throw StateError('${spec.lib}: failed to create native instance for key \"\$_instanceKey\".');");
  writer.line('      }');
  writer.line('    } finally {');
  writer.line('      calloc.free(_keyPtr);');
  writer.line('    }');
  writer.line('    NitroInstanceRegistry.register(_instanceId, this);');
  writer.line('    _instances[_instanceKey] = WeakReference(this);');
  writer.line('    _instanceFinalizer.attach(this, (id: _instanceId, key: _instanceKey, err: _nitroErr, destroy: _destroyInstancePtr), detach: this);');
  writer.line('    if (initSw != null) {');
  writer.line("      NitroRuntime.logLifecycle('init(${spec.lib})', 'initialized in \${initSw.elapsedMicroseconds} µs (instanceId=\$_instanceId)');");
  writer.line('    }');
  writer.line('  }');
  writer.blankLine();

  // ── Instance lifecycle pointers ─────────────────────────────────────────
  // create_instance(key) → int64: asks native to invoke the factory for this key
  //   and return the assigned instanceId. Called once per unique key in _init().
  // destroy_instance(id): called from dispose() to release the native impl.
  writer.line(
    "  late final int Function(Pointer<Utf8>) _createInstancePtr = _dylib.lookupFunction<Int64 Function(Pointer<Utf8>), int Function(Pointer<Utf8>)>('${libStem}_create_instance');",
  );
  writer.line(
    "  late final void Function(int) _destroyInstancePtr = _dylib.lookupFunction<Void Function(Int64), void Function(int)>('${libStem}_destroy_instance');",
  );

  // ── Method pointers ─────────────────────────────────────────────────────
  for (final func in spec.functions) {
    final nativeType = _toNativeType(func, spec);
    final dartType = _toDartType(func, spec);
    // isLeaf: true skips the Dart VM safepoint transition on every call —
    // valid for any sync bridge function whose C++ body never calls back into
    // Dart.  Candidates: explicitly "Fast"-suffixed methods AND any sync
    // method whose params/return are plain FFI scalars (no arena allocation).
    final isLeaf = _isLeafCandidate(func, spec);
    if (isLeaf) {
      writer.line(
        "  late final $dartType _${func.dartName}Ptr = _dylib.lookup<NativeFunction<$nativeType>>('${spec.nativeSymbol(func)}').asFunction<$dartType>(isLeaf: true);",
      );
    } else {
      writer.line(
        "  late final $dartType _${func.dartName}Ptr = _dylib.lookupFunction<$nativeType, $dartType>('${spec.nativeSymbol(func)}');",
      );
    }
    // @NitroOwned: emit a release function pointer and a NativeFinalizer.
    if (func.isOwned && func.returnType.isNativeHandle) {
      writer.line(
        "  late final void Function(Pointer<Void>) _${func.dartName}ReleaseFn = _dylib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('${func.cSymbol}_release');",
      );
      writer.line(
        "  late final NativeFinalizer _${func.dartName}Finalizer = NativeFinalizer(_dylib.lookup<NativeFunction<Void Function(Pointer<Void>)>>('${func.cSymbol}_release').cast());",
      );
    }
  }

  // ── Property pointers ───────────────────────────────────────────────────
  for (final prop in spec.properties) {
    final ffiType = _typeToFFI(prop.type, spec);
    final dartType = _typeToDartFFI(prop.type, spec);
    final cap = _cap(prop.dartName);
    // Property accessors are always synchronous and their C++ bodies never
    // call back into Dart, so primitive-typed accessors qualify for isLeaf.
    final isLeafProp = _isPrimitiveType(prop.type, spec);
    // S8: property accessors also receive the NitroError* out-param; instanceId for dispatch (Point 13).
    if (prop.hasGetter) {
      if (isLeafProp) {
        writer.line(
          "  late final $dartType Function(int, Pointer<NitroErrorFfi>) _get${cap}Ptr = _dylib.lookup<NativeFunction<$ffiType Function(Int64, Pointer<NitroErrorFfi>)>>('${prop.getSymbol}').asFunction<$dartType Function(int, Pointer<NitroErrorFfi>)>(isLeaf: true);",
        );
      } else {
        writer.line(
          "  late final $dartType Function(int, Pointer<NitroErrorFfi>) _get${cap}Ptr = _dylib.lookupFunction<$ffiType Function(Int64, Pointer<NitroErrorFfi>), $dartType Function(int, Pointer<NitroErrorFfi>)>('${prop.getSymbol}');",
        );
      }
    }
    if (prop.hasSetter) {
      if (isLeafProp) {
        writer.line(
          "  late final void Function(int, $dartType, Pointer<NitroErrorFfi>) _set${cap}Ptr = _dylib.lookup<NativeFunction<Void Function(Int64, $ffiType, Pointer<NitroErrorFfi>)>>('${prop.setSymbol}').asFunction<void Function(int, $dartType, Pointer<NitroErrorFfi>)>(isLeaf: true);",
        );
      } else {
        writer.line(
          "  late final void Function(int, $dartType, Pointer<NitroErrorFfi>) _set${cap}Ptr = _dylib.lookupFunction<Void Function(Int64, $ffiType, Pointer<NitroErrorFfi>), void Function(int, $dartType, Pointer<NitroErrorFfi>)>('${prop.setSymbol}');",
        );
      }
    }
  }

  // ── Stream register/release pointers ────────────────────────────────────
  for (final stream in spec.streams) {
    final cap = _cap(stream.dartName);
    // register takes (instanceId, dartPort); release only needs (dartPort).
    writer.line(
      "  late final void Function(int, int) _register${cap}Ptr = _dylib.lookupFunction<Void Function(Int64, Int64), void Function(int, int)>('${stream.registerSymbol}');",
    );
    writer.line(
      "  late final void Function(int) _release${cap}Ptr = _dylib.lookupFunction<Void Function(Int64), void Function(int)>('${stream.releaseSymbol}');",
    );
  }

  // ── Error handling pointers (Cached to avoid dlsym on every check) ──────
  writer.line('  // ignore: unused_field');
  writer.line(
    "  late final Pointer<NitroErrorFfi> Function() _getErrorPtr = _dylib.lookupFunction<Pointer<NitroErrorFfi> Function(), Pointer<NitroErrorFfi> Function()>('${libStem}_get_error');",
  );
  writer.line('  // ignore: unused_field');
  writer.line(
    "  late final void Function() _clearErrorPtr = _dylib.lookupFunction<Void Function(), void Function()>('${libStem}_clear_error');",
  );
  // Only emit the native-pointer variants when there are regular callAsync
  // functions that need them. isNativeAsync functions use openNativeAsync
  // which doesn't require these pointers.
  final hasCallAsync = spec.functions.any((f) => f.isAsync && !spec.bridgeAsync(f));
  if (hasCallAsync) {
    writer.line('  // ignore: unused_field');
    writer.line(
      "  late final Pointer<NativeFunction<Pointer<NitroErrorFfi> Function()>> _getErrorNativePtr = _dylib.lookup('${libStem}_get_error');",
    );
    writer.line('  // ignore: unused_field');
    writer.line(
      "  late final Pointer<NativeFunction<Void Function()>> _clearErrorNativePtr = _dylib.lookup('${libStem}_clear_error');",
    );
  }
  writer.blankLine();

  // ── dispose() override ───────────────────────────────────────────────────
  writer.line('  @override');
  writer.line('  void dispose() {');
  writer.line('    if (isDisposed) return;');
  // Detach the GC finalizer: this explicit dispose does the same cleanup, so
  // the finalizer must not also run (would double-free the native instance +
  // error slot).
  writer.line('    _instanceFinalizer.detach(this);');
  writer.line('    if (NitroConfig.instance.effectiveLogLevel == NitroLogLevel.verbose) {');
  writer.line("      NitroRuntime.logLifecycle('dispose(${spec.lib})', 'disposing (instanceId=\$_instanceId)');");
  writer.line('    }');
  // Tell native to release this instance's impl before any local cleanup.
  writer.line('    _destroyInstancePtr(_instanceId);');
  // Finding 5: decrement the library ref count; closes the dylib when last instance disposes.
  writer.line("    NitroRuntime.releaseLib('${spec.lib}');");
  // Remove from registry so future getInstance(key) creates a fresh instance.
  writer.line('    _instances.remove(_instanceKey);');
  writer.line('    NitroInstanceRegistry.unregister(_instanceId, this);');
  if (hasCallbacks) {
    writer.line('    for (final callback in _nativeCallbackCache.values) {');
    writer.line('      callback.close();');
    writer.line('    }');
    writer.line('    _nativeCallbackCache.clear();');
  }
  writer.line('    calloc.free(_nitroErr); // S8: free pre-allocated error slot');
  writer.line(
    '    super.dispose(); // sets isDisposed = true, calls onDestroy()',
  );
  writer.line("    NitroRuntime.logLifecycle('dispose(${spec.lib})', 'disposed');");
  writer.line('  }');
  writer.blankLine();

  // ── asAnyNativeObject getter ──────────────────────────────────────────────
  // Exposes this impl as an opaque AnyNativeObject reference. Other plugins
  // can pass it across the bridge without knowing the concrete type — same as
  // RN Nitro's AnyHybridObject / jsi::Object reference semantics.
  writer.line('  /// Opaque reference to this native impl — pass to other plugins via AnyNativeObject.');
  writer.line('  AnyNativeObject get asAnyNativeObject => AnyNativeObject(_instanceId);');
  writer.blankLine();

  if (hasCallbacks) {
    _emitCallbackHelpers(writer, spec);
  }
}

// ── Native-assets (@Native) impl setup ─────────────────────────────────────
// Perf lever 1: when `native_assets: true` (opt-in) AND the module is an
// all-C++ scalar-only shape, resolve the C symbols via top-level `@Native`
// externals bound to the hook-built code asset instead of a runtime
// `DynamicLibrary.open`/`process` + `lookupFunction`. This is the only form
// that works on Android (RTLD_LOCAL hides the symbols from `lookupFunction`).
//
// Call sites are UNCHANGED: the method bodies still call `_fooPtr(...)`, which
// now resolves to a top-level `@Native` function of the same name. Only the
// DECLARATIONS move (instance field → top-level external); the class is still
// opened here and closed by [_emitStreamImpls], exactly like
// [_emitImplClassSetup].

/// True when [spec] can use the native-assets (@Native) path: opt-in, all-C++,
/// non-web, and every shape in [_nativeAssetsIneligibility]'s allow-set.
bool _nativeAssetsEligible(BridgeSpec spec) =>
    spec.useNativeAssets && _nativeAssetsIneligibility(spec) == null;

/// Null if eligible; else the first disqualifying construct (for the N6
/// generated-file fallback note). The @Native path shares marshalling with the
/// `_dylib` path (only symbol resolution differs), so any shape `_dylib` encodes
/// is emittable: scalars (incl. nullable `int`/`double`/`bool`/`uint64`/
/// `DateTime`), `String`, enum, struct, record, variant, anyMap, AnyNativeObject,
/// NativeHandle params, TypedData, callback params. Excluded: @NitroOwned returns
/// and non-TypedData @zeroCopy returns.
String? _nativeAssetsIneligibility(BridgeSpec spec) {
  // null = this type is fine; a string = why it isn't.
  String? bad(BridgeType t, String where) {
    if (t.isRecord ||
        t.isFunction || // callback param → NativeCallable (runtime, no _dylib)
        t.isTypedData || // lever 2: static @Native external for the hot entrypoint
        t.isAnyMap ||
        t.isAnyNativeObject || // opaque int64 instance id
        t.isNativeHandle) { // opaque raw pointer (leaf-safe)
      return null;
    }
    final base = bareTypeName(t.name);
    if (spec.isStructName(base) || spec.isEnumName(base) || spec.isVariantName(base)) return null;
    if (base == 'String') return null; // incl. String?
    // Scalars incl. their nullable forms (arena-packed NitroOpt*, non-leaf).
    if (const {'int', 'double', 'bool', 'uint64', 'DateTime'}.contains(base)) return null;
    return "$where has unsupported type '${t.name}' (stays on the _dylib path)";
  }

  for (final f in spec.functions) {
    // @NitroOwned handles still excluded (NativeHandle wrapper + finalizer).
    if (f.isOwned) return "method '${f.dartName}' returns an @NitroOwned handle";
    // @zeroCopy TypedData RETURNS are supported (release via Native.addressOf,
    // the `_typedDataReturnFinalizer`); a non-TypedData @zeroCopy return is not.
    if (f.zeroCopyReturn && !f.returnType.isTypedData) {
      return "method '${f.dartName}' has a non-TypedData @zeroCopy return";
    }
    // @NitroResult's wire return is a Pointer<Uint8> tag buffer — validate its
    // INNER value type, not the NitroResult wrapper.
    final ret = f.isResult ? _nitroResultInnerType(f.returnType) : f.returnType;
    if (bareTypeName(ret.name) != 'void') {
      final r = bad(ret, "method '${f.dartName}' return");
      if (r != null) return r;
    }
    for (final p in f.params) {
      final r = bad(p.type, "method '${f.dartName}' param '${p.name}'");
      if (r != null) return r;
    }
  }
  for (final p in spec.properties) {
    final r = bad(p.type, "property '${p.dartName}'");
    if (r != null) return r;
  }
  return null;
}

/// Splits a Dart type-argument list on TOP-LEVEL commas only, so a nested
/// generic / function type (e.g. `Pointer<NativeFunction<Int64 Function(Int64,
/// Int64)>>`) stays one element. Returns [] for an empty string.
List<String> _splitTopLevelCommas(String s) {
  if (s.isEmpty) return const [];
  final out = <String>[];
  var depth = 0, start = 0;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c == '<' || c == '(' || c == '[') {
      depth++;
    } else if (c == '>' || c == ')' || c == ']') {
      depth--;
    } else if (c == ',' && depth == 0) {
      out.add(s.substring(start, i).trim());
      start = i + 1;
    }
  }
  out.add(s.substring(start).trim());
  return out;
}

void _emitNativeAssetsImplSetup(CodeWriter writer, BridgeSpec spec) {
  final libStem = spec.lib.replaceAll('-', '_');
  final checksum = bridgeSpecChecksum(spec);
  // Code-asset id the hook's CBuilder produces: package:<pkg>/<libStem>.
  final assetId = 'package:${spec.assetPackage ?? spec.lib}/$libStem';
  // Native-async (@nitroNativeAsync / native-dispatched @nitroAsync) needs the
  // completion-batch externals + Dart DL API init for Dart_PostCObject.
  final hasAsync = spec.functions.any(spec.bridgeAsync);
  // Callbacks (function-type params) → one NativeCallable per param, cached.
  final hasCallbacks = _hasFunctionTypeParams(spec);
  // Streams need the per-stream register/release externals + ack + DL-API init
  // (the coalescer posts items via Dart_PostCObject).
  final hasStreams = spec.streams.isNotEmpty;
  final needsDlInit = hasAsync || hasStreams;
  // Plain isolate-pool @nitroAsync (callAsync) uses the get/clear error symbols
  // as native pointers (portable across the pool isolate).
  final hasCallAsync = spec.functions.any((f) => f.isAsync && !spec.bridgeAsync(f) && !f.isFireAndForget);
  // @zeroCopy TypedData returns are freed by a NativeFinalizer backed by the
  // module's <lib>_release_typed_data_return symbol.
  final hasZcTdReturn = spec.functions.any((f) => f.zeroCopyReturn && f.returnType.isTypedData);
  String native(String type, String symbol, {bool leaf = false}) =>
      "@Native<$type>(symbol: '$symbol', assetId: '$assetId'${leaf ? ', isLeaf: true' : ''})";

  // ── Top-level module symbols (outside the class) ──────────────────────────
  writer.line('// Native-assets code asset symbols (built by hook/build.dart) — resolved');
  writer.line('// statically via @Native, which is what makes this work on Android.');
  writer.line(native('Void Function(Pointer<Void>)', '${libStem}_nitro_free', leaf: true));
  writer.line('external void _nitroFreePtr(Pointer<Void> _p);');
  writer.line(native('Pointer<Void> Function(IntPtr)', '${libStem}_nitro_alloc', leaf: true));
  writer.line('external Pointer<Void> _nitroAllocPtr(int _n);');
  writer.line(native('Uint32 Function()', '${libStem}_nitro_abi_version'));
  writer.line('external int _nitroAbiVersionPtr();');
  writer.line(native('Pointer<Utf8> Function()', '${libStem}_nitro_bridge_checksum'));
  writer.line('external Pointer<Utf8> _nitroBridgeChecksumPtr();');
  writer.line(native('Int64 Function(Pointer<Utf8>)', '${libStem}_create_instance'));
  writer.line('external int _createInstancePtr(Pointer<Utf8> _key);');
  writer.line(native('Void Function(Int64)', '${libStem}_destroy_instance'));
  writer.line('external void _destroyInstancePtr(int _id);');
  if (hasZcTdReturn) {
    writer.line(native('Void Function(Pointer<Void>)', '${libStem}_release_typed_data_return', leaf: true));
    writer.line('external void _releaseTypedDataReturnPtr(Pointer<Void> _p);');
  }

  // Method externals — same names the bodies call (_<name>Ptr).
  for (final func in spec.functions) {
    final nt = _toNativeType(func, spec);
    final dt = _toDartType(func, spec); // "<ret> Function(<csv params>)"
    final cut = dt.indexOf(' Function(');
    final retDart = dt.substring(0, cut);
    final paramsStr = dt.substring(cut + ' Function('.length, dt.length - 1);
    // Depth-aware split: a callback param's own type (e.g.
    // Pointer<NativeFunction<Int64 Function(Int64, Int64)>>) contains commas
    // that must NOT split the outer param list.
    final paramTypes = _splitTopLevelCommas(paramsStr);
    final decl = [for (var k = 0; k < paramTypes.length; k++) '${paramTypes[k]} _a$k'].join(', ');
    writer.line(native(nt, spec.nativeSymbol(func), leaf: _isLeafCandidate(func, spec)));
    writer.line('external $retDart _${func.dartName}Ptr($decl);');
  }
  // Property externals.
  for (final prop in spec.properties) {
    final ffiType = _typeToFFI(prop.type, spec);
    final dartType = _typeToDartFFI(prop.type, spec);
    final cap = _cap(prop.dartName);
    final leaf = _isPrimitiveType(prop.type, spec);
    if (prop.hasGetter) {
      writer.line(native('$ffiType Function(Int64, Pointer<NitroErrorFfi>)', prop.getSymbol!, leaf: leaf));
      writer.line('external $dartType _get${cap}Ptr(int _id, Pointer<NitroErrorFfi> _err);');
    }
    if (prop.hasSetter) {
      writer.line(native('Void Function(Int64, $ffiType, Pointer<NitroErrorFfi>)', prop.setSymbol!, leaf: leaf));
      writer.line('external void _set${cap}Ptr(int _id, $dartType _v, Pointer<NitroErrorFfi> _err);');
    }
  }
  // DL-API init + ack are shared by native-async AND coalesced streams.
  if (needsDlInit) {
    writer.line(native('IntPtr Function(Pointer<Void>)', '${libStem}_init_dart_api_dl'));
    writer.line('external int _initDartApiDlPtr(Pointer<Void> _data);');
    writer.line(native('Void Function(Int64)', '${libStem}_nitro_ack', leaf: true));
    writer.line('external void _nitroAckPtr(int _p);');
  }
  // Completion-batch externals for the native-async path only.
  if (hasAsync) {
    writer.line(native('Int64 Function(Int64)', '${libStem}_nitro_bind', leaf: true));
    writer.line('external int _nitroBindPtr(int _p);');
    writer.line(native('Int32 Function(Int64)', '${libStem}_nitro_arm', leaf: true));
    writer.line('external int _nitroArmPtr(int _id);');
    writer.line(native('Void Function(Int64)', '${libStem}_nitro_disarm', leaf: true));
    writer.line('external void _nitroDisarmPtr(int _id);');
    writer.line(native('Int32 Function(Int64, Pointer<Uint8>, Int32)', '${libStem}_nitro_poll', leaf: true));
    writer.line('external int _nitroPollPtr(int _id, Pointer<Uint8> _out, int _giveUp);');
  }
  // Per-stream register/release externals (register takes instanceId+port;
  // release takes port). The coalescer wires them in _emitStreamImpls.
  for (final stream in spec.streams) {
    final cap = _cap(stream.dartName);
    writer.line(native('Void Function(Int64, Int64)', stream.registerSymbol, leaf: true));
    writer.line('external void _register${cap}Ptr(int _id, int _port);');
    writer.line(native('Void Function(Int64)', stream.releaseSymbol, leaf: true));
    writer.line('external void _release${cap}Ptr(int _port);');
  }
  // Imported-struct stream items free each decoded item through this module's
  // generated per-struct release symbol (dart_stream_emitter references it).
  for (final item in {
    for (final s in spec.streams)
      if (spec.isStructName(bareTypeName(s.itemType.name)) && !spec.localStructs.any((l) => l.name == bareTypeName(s.itemType.name))) bareTypeName(s.itemType.name),
  }) {
    writer.line(native('Void Function(Pointer<Void>)', '${libStem}_release_$item', leaf: true));
    writer.line('external void _release${item}StructPtr(Pointer<Void> _p);');
  }
  // get/clear error externals for the isolate-pool callAsync path (their
  // addresses are passed to the pool isolate via Native.addressOf below).
  if (hasCallAsync) {
    writer.line(native('Pointer<NitroErrorFfi> Function()', '${libStem}_get_error'));
    writer.line('external Pointer<NitroErrorFfi> _getErrorPtr();');
    writer.line(native('Void Function()', '${libStem}_clear_error'));
    writer.line('external void _clearErrorPtr();');
  }
  writer.blankLine();

  // ── Impl class (no _dylib; symbols resolved by the externals above) ───────
  writer.line('class _${spec.dartClassName}Impl extends ${spec.dartClassName} {');
  writer.line('  static final _instances = <String, WeakReference<_${spec.dartClassName}Impl>>{};');
  // GC safety net — same contract as the _dylib path, minus releaseLib (no
  // dylib is opened under native-assets; the code asset lives for the process).
  writer.line('  static final _instanceFinalizer = Finalizer<({int id, String key, Pointer<NitroErrorFfi> err, void Function(int) destroy})>((t) {');
  writer.line('    try {');
  writer.line('      t.destroy(t.id);');
  writer.line('      if (_instances[t.key]?.target == null) _instances.remove(t.key);');
  writer.line('    } catch (_) {');
  writer.line('    } finally {');
  writer.line('      calloc.free(t.err);');
  writer.line('    }');
  writer.line('  });');
  writer.line('  final String _instanceKey;');
  writer.line('  late final int _instanceId;');
  writer.line('  final Pointer<NitroErrorFfi> _nitroErr = calloc<NitroErrorFfi>();');
  writer.line('  void _nitroFree(Pointer<NativeType> ptr) => _nitroFreePtr(ptr.cast());');
  writer.line('  // ignore: unused_field');
  writer.line('  late final NitroNativeAllocator _nitroNativeAllocator = NitroNativeAllocator(_nitroAllocPtr, _nitroFreePtr);');
  // Raw free pointer for NativeFinalizer-based owners (LazyRecordList, zero-copy
  // typed-data). Native.addressOf gives the C function pointer of the @Native
  // external — the native-assets equivalent of _dylib.lookup<...>.
  writer.line('  // ignore: unused_field');
  writer.line('  late final Pointer<NativeFinalizerFunction> _nitroFreeFinalizer = Native.addressOf<NativeFunction<Void Function(Pointer<Void>)>>(_nitroFreePtr).cast();');
  if (hasZcTdReturn) {
    writer.line('  // ignore: unused_field');
    writer.line('  late final Pointer<NativeFinalizerFunction> _typedDataReturnFinalizer = Native.addressOf<NativeFunction<Void Function(Pointer<Void>)>>(_releaseTypedDataReturnPtr).cast();');
  }
  if (hasCallbacks) {
    // One NativeCallable slot per "methodName.paramName", replaced (not
    // accumulated) on every re-registration — see _emitCallbackHelpers.
    writer.line('  final Map<String, NativeCallable<dynamic>> _nativeCallbackCache = {};');
  }
  if (hasCallAsync) {
    // Raw error-symbol pointers passed to the pool isolate by callAsync.
    writer.line('  late final Pointer<NativeFunction<Pointer<NitroErrorFfi> Function()>> _getErrorNativePtr = Native.addressOf<NativeFunction<Pointer<NitroErrorFfi> Function()>>(_getErrorPtr);');
    writer.line('  late final Pointer<NativeFunction<Void Function()>> _clearErrorNativePtr = Native.addressOf<NativeFunction<Void Function()>>(_clearErrorPtr);');
  }
  if (hasAsync) {
    writer.line('  late final NitroCompletionBatch _nitroBatch = NitroCompletionBatch(bind: _nitroBindPtr, ack: _nitroAckPtr, arm: _nitroArmPtr, disarm: _nitroDisarmPtr, poll: _nitroPollPtr);');
  }
  writer.blankLine();
  writer.line('  factory _${spec.dartClassName}Impl([String key = \'default\']) {');
  writer.line('    final cached = _instances[key]?.target;');
  writer.line('    if (cached != null) return cached;');
  writer.line('    return _${spec.dartClassName}Impl._init(key);');
  writer.line('  }');
  writer.blankLine();
  writer.line('  _${spec.dartClassName}Impl._init(this._instanceKey) {');
  writer.line("    final initSw = NitroConfig.instance.effectiveLogLevel == NitroLogLevel.verbose ? (Stopwatch()..start()) : null;");
  writer.line("    assert(sizeOf<IntPtr>() >= 4, '${spec.lib}: unsupported pointer width \${sizeOf<IntPtr>()}B');");
  if (needsDlInit) {
    writer.line('    final _initCode = _initDartApiDlPtr(NativeApi.initializeApiDLData);');
    writer.line("    if (_initCode != 0) { throw StateError('${spec.lib}: Dart API DL initialization failed with code \$_initCode.'); }");
  }
  writer.line("    NitroRuntime.checkAbiVersion('${spec.lib}', () => _nitroAbiVersionPtr());");
  writer.line("    NitroRuntime.checkLinkChecksum('${spec.lib}', '$checksum', () => _nitroBridgeChecksumPtr().toDartString());");
  // Zero-copy struct proxies bind their release symbol via Native.addressOf.
  for (final st in spec.localStructs) {
    writer.line('    ${st.name}Proxy._init();');
  }
  writer.line('    final _keyPtr = _instanceKey.toNitroUtf8(allocator: calloc);');
  writer.line('    try {');
  writer.line('      _instanceId = _createInstancePtr(_keyPtr);');
  writer.line('      if (_instanceId < 0) {');
  writer.line("        throw StateError('${spec.lib}: failed to create native instance for key \"\$_instanceKey\".');");
  writer.line('      }');
  writer.line('    } finally {');
  writer.line('      calloc.free(_keyPtr);');
  writer.line('    }');
  writer.line('    NitroInstanceRegistry.register(_instanceId, this);');
  writer.line('    _instances[_instanceKey] = WeakReference(this);');
  writer.line('    _instanceFinalizer.attach(this, (id: _instanceId, key: _instanceKey, err: _nitroErr, destroy: _destroyInstancePtr), detach: this);');
  writer.line('    if (initSw != null) {');
  writer.line("      NitroRuntime.logLifecycle('init(${spec.lib})', 'initialized in \${initSw.elapsedMicroseconds} µs (instanceId=\$_instanceId)');");
  writer.line('    }');
  writer.line('  }');
  writer.blankLine();
  writer.line('  @override');
  writer.line('  void dispose() {');
  writer.line('    if (isDisposed) return;');
  writer.line('    _instanceFinalizer.detach(this);');
  writer.line('    if (NitroConfig.instance.effectiveLogLevel == NitroLogLevel.verbose) {');
  writer.line("      NitroRuntime.logLifecycle('dispose(${spec.lib})', 'disposing (instanceId=\$_instanceId)');");
  writer.line('    }');
  writer.line('    _destroyInstancePtr(_instanceId);');
  writer.line('    _instances.remove(_instanceKey);');
  writer.line('    NitroInstanceRegistry.unregister(_instanceId, this);');
  if (hasCallbacks) {
    writer.line('    for (final callback in _nativeCallbackCache.values) {');
    writer.line('      callback.close();');
    writer.line('    }');
    writer.line('    _nativeCallbackCache.clear();');
  }
  writer.line('    calloc.free(_nitroErr);');
  writer.line('    super.dispose();');
  writer.line("    NitroRuntime.logLifecycle('dispose(${spec.lib})', 'disposed');");
  writer.line('  }');
  writer.blankLine();
  writer.line('  AnyNativeObject get asAnyNativeObject => AnyNativeObject(_instanceId);');
  writer.blankLine();
  if (hasCallbacks) {
    _emitCallbackHelpers(writer, spec);
  }
  // Class left OPEN — _emitFunctionImpls/_emitPropertyImpls add methods and
  // _emitStreamImpls emits the closing brace (streams.isEmpty here → just `}`).
}

/// Emits a `${ClassName}NativeRef` extension on the abstract class so that
/// callers holding the public type can access [asAnyNativeObject] without casting.
void _emitNativeRefExtension(CodeWriter writer, BridgeSpec spec) {
  writer.line('extension ${spec.dartClassName}NativeRef on ${spec.dartClassName} {');
  writer.line('  AnyNativeObject get asAnyNativeObject => (this as _${spec.dartClassName}Impl).asAnyNativeObject;');
  writer.line('}');
  writer.blankLine();
}
