part of '../dart_ffi_generator.dart';

void _emitNativeAsyncBody(
  CodeWriter writer,
  BridgeFunction func,
  BridgeSpec spec,
  String callArgs,
  bool needsArena,
) {
  final unpack = _nativeAsyncUnpack(func, spec);
  final openType = _nativeAsyncOpenType(func, spec);

  if (needsArena) {
    writer.line('    final arena = Arena();');
    writer.line('    try {');
    writer.line('      return NitroRuntime.openNativeAsync<$openType>(');
    writer.line('        call: (port) => _${func.dartName}Ptr($callArgs, port),');
    writer.line('        unpack: $unpack,');
    writer.line("        methodName: '${func.dartName}',");
    writer.line('      );');
    writer.line('    } finally {');
    writer.line('      arena.releaseAll();');
    writer.line('    }');
  } else {
    final plainCallArgs = func.params
        .map((p) {
          final t = p.type.name;
          if (spec.isEnumName(t)) return '${p.name}.nativeValue';
          if (t == 'bool') return '${p.name} ? 1 : 0';
          if (p.type.isFunction) return _callbackArgExpr(func, p);
          // Optional primitives: NitroNullable binary encoding for zero-collision transport.
          // NOTE: These need an arena; needsArena now includes int?/double?/bool?.
          if (t == 'int?') return 'NitroNullableInt.fromNullable(${p.name}).toNative(arena)';
          if (t == 'double?') return 'NitroNullableDouble.fromNullable(${p.name}).toNative(arena)';
          if (t == 'bool?') return 'NitroNullableBool.fromNullable(${p.name}).toNative(arena)';
          return p.name;
        })
        .join(', ');

    final portSep = plainCallArgs.isEmpty ? '' : ', ';
    writer.line('    return NitroRuntime.openNativeAsync<$openType>(');
    writer.line('      call: (port) => _${func.dartName}Ptr($plainCallArgs${portSep}port),');
    writer.line('      unpack: $unpack,');
    writer.line("      methodName: '${func.dartName}',");
    writer.line('    );');
  }
}

/// The Dart type parameter for openNativeAsync`<T>` for this function.
String _nativeAsyncOpenType(BridgeFunction func, BridgeSpec spec) {
  final rt = func.returnType.name;
  // openNativeAsync<T> returns the unpacked Dart API type. The raw transport
  // shape (kInt64, kDouble, pointer address, etc.) is handled inside `unpack`.
  if (rt == 'void') return 'void';
  return rt;
}

/// Returns the unpack lambda expression for a @NitroNativeAsync method.
///
/// The native side posts via Dart_PostCObject_DL:
///  • primitives (int/double) → kInt64/kDouble → received as int/double
///  • bool                   → kBool          → received as bool
///  • void                   → kNull           → received as null
///  • String                 → kString         → received as Dart String
///  • record/struct/list     → kInt64 (ptr)    → decode from Pointer`<Uint8>`
///  • enum                   → kInt64          → call .toEnumType()
String _nativeAsyncUnpack(BridgeFunction func, BridgeSpec spec) {
  final rt = func.returnType.name;
  final rtBase = rt.replaceFirst('?', '');
  final isNullable = rt.endsWith('?');

  if (rt == 'void') return '(_) {}';

  // bool / bool?
  if (rtBase == 'bool') {
    return isNullable ? '(raw) => (raw as bool?) == null ? null : raw as bool' : '(raw) => raw as bool';
  }

  // String / String?  — native posts kString or kNull
  if (rtBase == 'String') {
    return isNullable ? '(raw) => raw as String?' : '(raw) => raw as String';
  }

  // @HybridRecord  — native posts kInt64 (pointer to binary buffer)
  if (func.returnType.isRecord) {
    final decodeExpr = _decodeRecordExpr(func.returnType, 'rawPtr');
    final isLazy = func.returnType.recordListItemType != null && !func.returnType.recordListItemIsPrimitive;
    if (isNullable) {
      if (isLazy) {
        return '(raw) { final rawPtr = Pointer<Uint8>.fromAddress(raw as int); if (rawPtr == nullptr) return null; return $decodeExpr; }';
      }
      return '(raw) { final rawPtr = Pointer<Uint8>.fromAddress(raw as int); if (rawPtr == nullptr) return null; try { return $decodeExpr; } finally { malloc.free(rawPtr); } }';
    }
    if (isLazy) {
      return '(raw) { final rawPtr = Pointer<Uint8>.fromAddress(raw as int); return $decodeExpr; }';
    }
    return '(raw) { final rawPtr = Pointer<Uint8>.fromAddress(raw as int); try { return $decodeExpr; } finally { malloc.free(rawPtr); } }';
  }

  // @HybridStruct  — native posts kInt64 (pointer to heap struct)
  if (spec.isStructName(rtBase)) {
    if (isNullable) {
      return '(raw) { final ptr = Pointer<${rtBase}Ffi>.fromAddress(raw as int); if (ptr == nullptr) return null; try { return ptr.ref.toDart(); } finally { ptr.ref.freeFields(); malloc.free(ptr); } }';
    }
    return '(raw) { final ptr = Pointer<${rtBase}Ffi>.fromAddress(raw as int); try { return ptr.ref.toDart(); } finally { ptr.ref.freeFields(); malloc.free(ptr); } }';
  }

  // @HybridEnum  — native posts kInt64 rawValue
  if (spec.isEnumName(rtBase)) {
    return isNullable ? '(raw) { final v = raw as int; return v == -1 ? null : v.to$rtBase(); }' : '(raw) => (raw as int).to$rtBase()';
  }

  // int / int?  — native posts kInt64; sentinel Int64.min = null
  if (rtBase == 'int') {
    return isNullable ? '(raw) { final v = raw as int; return v == -9223372036854775808 ? null : v; }' : '(raw) => raw as int';
  }

  // double / double?  — native posts kDouble; sentinel NaN = null
  if (rtBase == 'double') {
    return isNullable ? '(raw) { final v = raw as double; return v.isNaN ? null : v; }' : '(raw) => raw as double';
  }

  // Fallthrough: unknown type — cast directly (should not normally occur).
  return '(raw) => raw as $rt';
}

// S8: always-on error check via the pre-allocated out-param slot.
// This replaces the old assert-gated get_error()/clear_error() pattern.
// Errors are now detected in BOTH debug AND release builds.
String _inlineCheckError() {
  return 'NitroRuntime.throwIfOutParamError(_nitroErr);';
}

// ── Unified return decode helper ──────────────────────────────────────────
// Single source of truth for decoding raw FFI results into Dart values.
// Replaces four duplicated if/else chains (sync-arena, sync-no-arena,
// async-arena, async-no-arena). Calls existing _decodeRecordExpr /
// _emitTypedDataDecodeReturn so emitted code is byte-for-byte identical.
void _emitReturnDecode(
  CodeWriter writer,
  BridgeType returnType,
  String resVar,
  String indent,
  BridgeSpec spec, {
  bool zeroCopy = false,
  bool isOwned = false,
  String? dartName,
  String nativeHandleTypeParam = 'Void',
}) {
  final rt = returnType.name;
  final kind = classifyReturn(returnType, spec);
  final base = returnType.baseName;

  switch (kind) {
    case ReturnKind.voidType:
      return;
    case ReturnKind.record:
      final decodeExpr = _decodeRecordExpr(returnType, resVar);
      final isLazy = returnType.recordListItemType != null && !returnType.recordListItemIsPrimitive;
      // Nullable @HybridRecord: C returns nullptr when Kotlin returns null ByteArray?.
      final isNullableRecord = returnType.isNullable || returnType.name.endsWith('?');
      if (isNullableRecord) {
        writer.line('${indent}if ($resVar == nullptr) return null;');
      }
      if (isLazy) {
        writer.line('${indent}return $decodeExpr;');
      } else {
        writer.line('${indent}final $rt decoded;');
        writer.line('${indent}try {');
        writer.line('$indent  decoded = $decodeExpr;');
        writer.line('$indent} finally {');
        writer.line('$indent  malloc.free($resVar);');
        writer.line('$indent}');
        writer.line('${indent}return decoded;');
      }
    case ReturnKind.typedData:
      _emitTypedDataDecodeReturn(writer, returnType, resVar, indent, zeroCopy: zeroCopy);
    case ReturnKind.struct:
      // Nullable struct (T?): null pointer → Dart null.
      // Non-nullable struct: null pointer → StateError (should never happen).
      if (returnType.isNullable || returnType.name.endsWith('?')) {
        writer.line('${indent}if ($resVar == nullptr) return null;');
      } else {
        writer.line('${indent}if ($resVar == nullptr) {');
        writer.line('$indent  throw StateError(\'${dartName ?? rt} returned null\');');
        writer.line('$indent}');
      }
      writer.line('${indent}final structPtr = Pointer<${base}Ffi>.fromAddress($resVar.address);');
      writer.line('${indent}final $base decoded;');
      writer.line('${indent}try {');
      writer.line('$indent  decoded = structPtr.ref.toDart();');
      writer.line('$indent} finally {');
      writer.line('$indent  structPtr.ref.freeFields();');
      writer.line('$indent  malloc.free(structPtr);');
      writer.line('$indent}');
      writer.line('${indent}return decoded;');
    case ReturnKind.nativeHandle:
      if (isOwned && dartName != null) {
        writer.line('${indent}final handle = NativeHandle<$nativeHandleTypeParam>.fromAddress($resVar.address);');
        writer.line('${indent}_${dartName}Finalizer.attach(handle, $resVar.cast(), detach: handle);');
        writer.line("${indent}handle.attachReleaseCallback((addr) { _${dartName}ReleaseFn(Pointer<Void>.fromAddress(addr)); _${dartName}Finalizer.detach(handle); });");
        writer.line('${indent}return handle;');
      } else {
        writer.line('${indent}return NativeHandle<$nativeHandleTypeParam>.fromAddress($resVar.address);');
      }
    case ReturnKind.enumType:
      // Nullable enum: -1 sentinel = null; otherwise decode rawValue.
      final isNullableEnum = returnType.isNullable || returnType.name.endsWith('?');
      if (isNullableEnum) {
        writer.line('${indent}return $resVar == -1 ? null : $resVar.to$base();');
      } else {
        writer.line('${indent}return $resVar.to$base();');
      }
    case ReturnKind.boolNonNull:
      writer.line('${indent}return $resVar != 0;');
    case ReturnKind.boolNullable:
      // NitroNullable binary encoding — decode from Pointer<Uint8>
      writer.line('${indent}return NitroNullableBool.fromNative($resVar).nullable;');
    case ReturnKind.stringNonNull:
      writer.line('${indent}return $resVar.toDartStringWithFree();');
    case ReturnKind.stringNullable:
      writer.line('${indent}return $resVar == nullptr ? null : $resVar.toDartStringWithFree();');
    case ReturnKind.intNullable:
      // NitroNullable binary encoding — decode from Pointer<Uint8>
      writer.line('${indent}return NitroNullableInt.fromNative($resVar).nullable;');
    case ReturnKind.doubleNullable:
      // NitroNullable binary encoding — decode from Pointer<Uint8>
      writer.line('${indent}return NitroNullableDouble.fromNative($resVar).nullable;');
    case ReturnKind.variant:
      // @NitroVariant: C returns Pointer<Uint8> = [4B len][1B tag][fields].
      // Dart VariantExt.fromNative reads [4B len] then [tag][fields].
      final vBase = returnType.name.replaceFirst('?', '');
      writer.line('${indent}if ($resVar == nullptr) throw StateError(\'$vBase returned null\');');
      writer.line('${indent}final _variant;');
      writer.line('${indent}try {');
      writer.line('$indent  _variant = ${vBase}VariantExt.fromNative($resVar);');
      writer.line('$indent} finally {');
      writer.line('$indent  malloc.free($resVar);');
      writer.line('$indent}');
      writer.line('${indent}return _variant;');
    case ReturnKind.primitive:
      writer.line('${indent}return $resVar;');
  }
}

/// Variable name used for the raw async result based on return kind.
/// Keeps emitted code readable: `rawPtr` for pointer types, `res` for scalars.
String _asyncResVarName(ReturnKind kind) => switch (kind) {
  ReturnKind.record => 'rawPtr',
  ReturnKind.typedData => 'rawPtr',
  ReturnKind.struct => 'rawPtr',
  _ => 'res',
};

// Kept for callers that already pass an indent; delegates to the S8 form.
String _assertCheckError(String indent) => '$indent${_inlineCheckError()}';

// ── Leaf / isLeaf helpers ─────────────────────────────────────────────────

/// Returns true when [bt] maps to a plain FFI scalar (int, double, bool, or
/// a known enum) — types that require no arena allocation and no Dart heap
/// object creation on the call boundary.
bool _isPrimitiveType(BridgeType bt, BridgeSpec spec) {
  if (bt.isRecord || bt.isTypedData || bt.isPointer || bt.isFunction || bt.isNativeHandle) return false;
  final name = bt.name.replaceFirst('?', '');
  if (name == 'String' || name == 'void') return false;
  if (spec.isStructName(name)) return false;
  // Nullable primitives now use NitroNullable (Pointer<Uint8>) — not scalars.
  if (bt.name == 'int?' || bt.name == 'double?' || bt.name == 'bool?') return false;
  // int, double, bool, and known enums are all FFI scalars.
  return true;
}

/// Returns true when the function pointer should be bound with `isLeaf: true`.
///
/// `isLeaf: true` skips the Dart VM safepoint transition, shaving ~50–200 ns
/// per call.  It is safe when the C++ body never calls back into Dart and the
/// call is expected to be short-lived (no blocking I/O).
///
/// Conditions:
///  • Not async (async calls dispatch to isolates, irrelevant here).
///  • Explicitly named "Fast" — a developer contract that the method is hot.
///  • OR all params and the return type are plain scalars (no arena needed).
bool _isLeafCandidate(BridgeFunction func, BridgeSpec spec) {
  if (func.isAsync || func.isNativeAsync) return false;
  if (func.dartName.endsWith('Fast')) return true;
  final rt = func.returnType;
  if (!_isPrimitiveType(rt, spec) && rt.name != 'void') return false;
  return func.params.every((p) => _isPrimitiveType(p.type, spec));
}
