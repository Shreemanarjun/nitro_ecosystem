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
// S8: pre-allocated error slot — shared across all sync calls on this instance.
// One allocation per module, zero allocation per call.
writer.line('  final Pointer<NitroErrorFfi> _nitroErr = calloc<NitroErrorFfi>();');
final hasCallbacks = _hasFunctionTypeParams(spec);
if (hasCallbacks) {
  writer.line('  final Map<Object, NativeCallable<dynamic>> _nativeCallbackCache = {};');
}
final hasZeroCopyTypedDataReturn = spec.functions.any((f) => f.zeroCopyReturn && f.returnType.isTypedData);
if (hasZeroCopyTypedDataReturn) {
  writer.line(
    // NativeFinalizerFunction is typedef NativeFunction<Void Function(Pointer<Void>)>,
    // so lookup<NativeFinalizerFunction> is correct — NOT NativeFunction<NativeFinalizerFunction>.
    "  late final Pointer<NativeFinalizerFunction> _typedDataReturnFinalizer = _dylib.lookup<NativeFinalizerFunction>('${libStem}_release_typed_data_return').cast();",
  );
}
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
  writer.line("      '${spec.lib}: dart:ffi is unavailable on web. "
      "Instantiate the web bridge via create${spec.dartClassName}WebInstance() "
      "from the generated *.web.bridge.g.dart file instead.',");
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
writer.line(
  '  _${spec.dartClassName}Impl() : _dylib = _loadSupportedLibrary() {',
);
writer.line("    final initSw = Stopwatch()..start();");
writer.line(
  "    final initFunc = _dylib.lookupFunction<IntPtr Function(Pointer<Void>), int Function(Pointer<Void>)>('${libStem}_init_dart_api_dl');",
);
writer.line('    final initCode = initFunc(NativeApi.initializeApiDLData);');
writer.line('    if (initCode != 0) {');
writer.line("      throw StateError('${spec.lib}: Dart API DL initialization failed with code \$initCode.');");
writer.line('    }');
writer.line(
  "    NitroRuntime.checkAbiVersion('${spec.lib}', () => _dylib.lookupFunction<Uint32 Function(), int Function()>('${libStem}_nitro_abi_version')());",
);
writer.line(
  "    NitroRuntime.checkLinkChecksum('${spec.lib}', '$checksum', () => _dylib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('${libStem}_nitro_bridge_checksum')().toDartString());",
);
// Initialise NativeFinalizer for every struct proxy.
// Each proxy looks up its generated release C-symbol from _dylib.
for (final st in spec.structs) {
  writer.line('    ${st.name}Proxy._init(_dylib);');
}
writer.line('    initSw.stop();');
writer.line("    NitroRuntime.logLifecycle('init(${spec.lib})', 'initialized in \${initSw.elapsedMicroseconds} µs');");
writer.line('  }');
writer.blankLine();

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
      "  late final $dartType _${func.dartName}Ptr = _dylib.lookup<NativeFunction<$nativeType>>('${func.cSymbol}').asFunction<$dartType>(isLeaf: true);",
    );
  } else {
    writer.line(
      "  late final $dartType _${func.dartName}Ptr = _dylib.lookupFunction<$nativeType, $dartType>('${func.cSymbol}');",
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
  // S8: property accessors also receive the NitroError* out-param.
  if (prop.hasGetter) {
    if (isLeafProp) {
      writer.line(
        "  late final $dartType Function(Pointer<NitroErrorFfi>) _get${cap}Ptr = _dylib.lookup<NativeFunction<$ffiType Function(Pointer<NitroErrorFfi>)>>('${prop.getSymbol}').asFunction<$dartType Function(Pointer<NitroErrorFfi>)>(isLeaf: true);",
      );
    } else {
      writer.line(
        "  late final $dartType Function(Pointer<NitroErrorFfi>) _get${cap}Ptr = _dylib.lookupFunction<$ffiType Function(Pointer<NitroErrorFfi>), $dartType Function(Pointer<NitroErrorFfi>)>('${prop.getSymbol}');",
      );
    }
  }
  if (prop.hasSetter) {
    if (isLeafProp) {
      writer.line(
        "  late final void Function($dartType, Pointer<NitroErrorFfi>) _set${cap}Ptr = _dylib.lookup<NativeFunction<Void Function($ffiType, Pointer<NitroErrorFfi>)>>('${prop.setSymbol}').asFunction<void Function($dartType, Pointer<NitroErrorFfi>)>(isLeaf: true);",
      );
    } else {
      writer.line(
        "  late final void Function($dartType, Pointer<NitroErrorFfi>) _set${cap}Ptr = _dylib.lookupFunction<Void Function($ffiType, Pointer<NitroErrorFfi>), void Function($dartType, Pointer<NitroErrorFfi>)>('${prop.setSymbol}');",
      );
    }
  }
}

// ── Stream register/release pointers ────────────────────────────────────
for (final stream in spec.streams) {
  final cap = _cap(stream.dartName);
  writer.line(
    "  late final void Function(int) _register${cap}Ptr = _dylib.lookupFunction<Void Function(Int64), void Function(int)>('${stream.registerSymbol}');",
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
final hasCallAsync = spec.functions.any((f) => f.isAsync && !f.isNativeAsync);
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
writer.line("    NitroRuntime.logLifecycle('dispose(${spec.lib})', 'disposing');");
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

if (hasCallbacks) {
  _emitCallbackHelpers(writer, spec);
}

}
