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
          if (t == 'bool') return p.name; // Bool FFI type — pass directly
          if (p.type.isFunction) return _callbackArgExpr(func, p);
          // Optional primitives: NitroOpt* packed struct encoding via Arena.
          if (t == 'int?') return 'arena.packInt(${p.name})';
          if (t == 'double?') return 'arena.packDouble(${p.name})';
          if (t == 'bool?') return 'arena.packBool(${p.name})';
          if (t == 'DateTime') return '${p.name}.millisecondsSinceEpoch';
          if (t == 'DateTime?') return 'arena.packInt(${p.name}?.millisecondsSinceEpoch)';
          return p.name;
        })
        .join(', ');
    final allCallArgs = plainCallArgs.isEmpty ? '_instanceId' : '_instanceId, $plainCallArgs';

    writer.line('    return NitroRuntime.openNativeAsync<$openType>(');
    writer.line('      call: (port) => _${func.dartName}Ptr($allCallArgs, port),');
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

  // bool / bool?  — non-null: posts kBool; nullable: posts kInt64 (pointer address to NitroOptBool)
  if (rtBase == 'bool') {
    if (isNullable) {
      return '(raw) { final ptr = Pointer<NitroOptBool>.fromAddress(raw as int); final v = ptr.decoded; malloc.free(ptr); return v; }';
    }
    return '(raw) => raw as bool';
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

  // int / int?  — non-null: posts kInt64 scalar; nullable: posts kInt64 (pointer address to NitroOptInt64)
  if (rtBase == 'int') {
    if (isNullable) {
      return '(raw) { final ptr = Pointer<NitroOptInt64>.fromAddress(raw as int); final v = ptr.decoded; malloc.free(ptr); return v; }';
    }
    return '(raw) => raw as int';
  }

  // double / double?  — non-null: posts kDouble; nullable: posts kInt64 (pointer address to NitroOptFloat64)
  if (rtBase == 'double') {
    if (isNullable) {
      return '(raw) { final ptr = Pointer<NitroOptFloat64>.fromAddress(raw as int); final v = ptr.decoded; malloc.free(ptr); return v; }';
    }
    return '(raw) => raw as double';
  }

  // DateTime / DateTime?  — non-null: posts kInt64 ms; nullable: posts kInt64 (pointer address to NitroOptInt64)
  if (rtBase == 'DateTime') {
    if (isNullable) {
      return '(raw) { final ptr = Pointer<NitroOptInt64>.fromAddress(raw as int); final ms = ptr.decoded; malloc.free(ptr); return ms != null ? DateTime.fromMillisecondsSinceEpoch(ms) : null; }';
    }
    return '(raw) => DateTime.fromMillisecondsSinceEpoch(raw as int)';
  }

  // AnyNativeObject — posts kInt64 instanceId; nullable uses -1 sentinel
  if (rtBase == 'AnyNativeObject' || func.returnType.isAnyNativeObject) {
    return isNullable
        ? '(raw) { final id = raw as int; return id == -1 ? null : AnyNativeObject(id); }'
        : '(raw) => AnyNativeObject(raw as int)';
  }

  // @NitroCustomType — posts kInt64 (pointer to Uint8 buffer)
  if (spec.isCustomTypeName(rtBase)) {
    final ct = spec.customTypeByName(rtBase)!;
    if (isNullable) {
      return '(raw) { final rawPtr = Pointer<Uint8>.fromAddress(raw as int); if (rawPtr == nullptr) return null; try { return const ${ct.codecClass}().decode(rawPtr); } finally { malloc.free(rawPtr); } }';
    }
    return '(raw) { final rawPtr = Pointer<Uint8>.fromAddress(raw as int); try { return const ${ct.codecClass}().decode(rawPtr)!; } finally { malloc.free(rawPtr); } }';
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
  // Set true for @nitroAsync paths: bool is transported as int via callAsync<int>,
  // so emit `!= 0` decode. False for sync: Bool FFI type means resVar is already bool.
  bool asyncBoolAsInt = false,
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
        writer.line('${indent}_${dartName}Finalizer.attach(handle, $resVar.cast(), detach: handle, externalSize: 128);');
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
      // Sync: Bool FFI type → resVar is already Dart bool, return directly.
      // Async: callAsync<int> transports bool as int → need != 0 decode.
      if (asyncBoolAsInt) {
        writer.line('${indent}return $resVar != 0;');
      } else {
        writer.line('${indent}return $resVar;');
      }
    case ReturnKind.boolNullable:
      // res is Pointer<NitroOptBool> (malloc'd) — decode then free.
      writer.line('${indent}final _boolResult = $resVar.decoded; malloc.free($resVar); return _boolResult;');
    case ReturnKind.stringNonNull:
      writer.line('${indent}return $resVar.toDartStringWithFree();');
    case ReturnKind.stringNullable:
      writer.line('${indent}return $resVar == nullptr ? null : $resVar.toDartStringWithFree();');
    case ReturnKind.intNullable:
      // res is Pointer<NitroOptInt64> (malloc'd) — decode then free.
      writer.line('${indent}final _intResult = $resVar.decoded; malloc.free($resVar); return _intResult;');
    case ReturnKind.doubleNullable:
      // res is Pointer<NitroOptFloat64> (malloc'd) — decode then free.
      writer.line('${indent}final _dblResult = $resVar.decoded; malloc.free($resVar); return _dblResult;');
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
    case ReturnKind.dateTime:
      writer.line('${indent}return DateTime.fromMillisecondsSinceEpoch($resVar);');
    case ReturnKind.dateTimeNullable:
      writer.line('${indent}final _msResult = $resVar.decoded; malloc.free($resVar); return _msResult != null ? DateTime.fromMillisecondsSinceEpoch(_msResult) : null;');
    case ReturnKind.anyNativeObject:
      writer.line('${indent}return AnyNativeObject($resVar);');
    case ReturnKind.anyNativeObjectNullable:
      writer.line('${indent}return $resVar == -1 ? null : AnyNativeObject($resVar);');
    case ReturnKind.customType:
      final ctName = base;
      final ct = spec.customTypeByName(ctName)!;
      writer.line('${indent}if ($resVar == nullptr) throw StateError(\'$ctName returned null\');');
      writer.line('${indent}final _ctResult;');
      writer.line('${indent}try {');
      writer.line('$indent  _ctResult = const ${ct.codecClass}().decode($resVar)!;');
      writer.line('$indent} finally {');
      writer.line('$indent  malloc.free($resVar);');
      writer.line('$indent}');
      writer.line('${indent}return _ctResult;');
    case ReturnKind.customTypeNullable:
      final ctNameN = base;
      final ctN = spec.customTypeByName(ctNameN)!;
      writer.line('${indent}if ($resVar == nullptr) return null;');
      writer.line('${indent}final _ctNResult;');
      writer.line('${indent}try {');
      writer.line('$indent  _ctNResult = const ${ctN.codecClass}().decode($resVar);');
      writer.line('$indent} finally {');
      writer.line('$indent  malloc.free($resVar);');
      writer.line('$indent}');
      writer.line('${indent}return _ctNResult;');
    case ReturnKind.uint64:
      // uint64 is represented as Dart int (bits preserved); raw Uint64 FFI value passes through.
      writer.line('${indent}return $resVar;');
    case ReturnKind.uint64Nullable:
      // uint64? reuses NitroOptInt64 struct (same 9-byte layout); int? result = raw bits.
      writer.line('${indent}final _u64Result = $resVar.decoded; malloc.free($resVar); return _u64Result;');
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
  ReturnKind.customType => 'rawPtr',
  ReturnKind.customTypeNullable => 'rawPtr',
  ReturnKind.intNullable => 'optPtr',
  ReturnKind.doubleNullable => 'optPtr',
  ReturnKind.boolNullable => 'optPtr',
  ReturnKind.dateTimeNullable => 'optPtr',
  ReturnKind.uint64Nullable => 'optPtr',
  _ => 'res',
};

// Kept for callers that already pass an indent; delegates to the S8 form.
String _assertCheckError(String indent) => '$indent${_inlineCheckError()}';

// ── Leaf / isLeaf helpers ─────────────────────────────────────────────────

/// Returns true when [bt] maps to a plain FFI scalar (int, double, bool, or
/// a known enum) — types that require no arena allocation and no Dart heap
/// object creation on the call boundary.
///
/// Nullable primitives (int?, double?, bool?) also qualify here because
/// [_isLeafNullableParam] handles them via Struct.create<`NitroOptXxx`>() which
/// allocates on the Dart GC heap rather than the C heap — zero malloc per call.
bool _isPrimitiveType(BridgeType bt, BridgeSpec spec) {
  if (bt.isRecord || bt.isTypedData || bt.isPointer || bt.isFunction || bt.isNativeHandle) return false;
  // Custom types always go as Pointer<Uint8> — not scalar.
  if (spec.isCustomTypeName(bt.baseName)) return false;
  final name = bt.name.replaceFirst('?', '');
  if (name == 'String' || name == 'void') return false;
  if (spec.isStructName(name)) return false;
  // Nullable primitives use Struct.create<NitroOptXxx>() + .address for leaf calls — no C heap alloc.
  // They still count as "primitive-like" for leaf detection purposes.
  // AnyNativeObject — scalar Int64 wire (non-null and nullable both use Int64).
  // int, double, bool, and known enums are all FFI scalars.
  return true;
}

/// Returns true when the param type is a nullable primitive (int?, double?, bool?)
/// that should use Struct.create<NitroOptXxx>() + .address on leaf calls.
bool _isLeafNullableParam(BridgeType bt) =>
    bt.name == 'int?' || bt.name == 'double?' || bt.name == 'bool?' ||
    bt.name == 'uint64?' || bt.name == 'DateTime?';

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

/// Returns true when this function qualifies for the Struct.create optimization:
/// sync, leaf-eligible, and has at least one nullable prim param whose encoding
/// would otherwise require an Arena. These functions use Struct.create<NitroOptXxx>()
/// + .address instead — zero C heap allocation per call.
bool _isLeafStructCreate(BridgeFunction func, BridgeSpec spec) =>
    _isLeafCandidate(func, spec) &&
    func.params.any((p) => _isLeafNullableParam(p.type));

/// Builds Struct.create setup statements and call args for a leaf-struct-create function.
/// Returns (setup: list of `final _lsN = ...` statements, args: call arg expressions).
/// [indent] is prepended to each setup statement.
({List<String> setup, List<String> args}) buildLeafStructCreateArgs(
  List<BridgeParam> params,
  BridgeSpec spec,
  String indent,
) {
  final setup = <String>[];
  final args = <String>[];
  var idx = 0;
  for (final p in params) {
    final t = p.type.name;
    final tBase = t.replaceFirst('?', '');
    if (_isLeafNullableParam(p.type)) {
      final v = '_ls${idx++}_${p.name}';
      if (t == 'int?' || t == 'uint64?') {
        setup.add('${indent}final $v = Struct.create<NitroOptInt64>()..hasValue = ${p.name} != null ? 1 : 0..value = ${p.name} ?? 0;');
      } else if (t == 'DateTime?') {
        setup.add('${indent}final $v = Struct.create<NitroOptInt64>()..hasValue = ${p.name} != null ? 1 : 0..value = ${p.name}?.millisecondsSinceEpoch ?? 0;');
      } else if (t == 'double?') {
        setup.add('${indent}final $v = Struct.create<NitroOptFloat64>()..hasValue = ${p.name} != null ? 1 : 0..value = ${p.name} ?? 0.0;');
      } else if (t == 'bool?') {
        setup.add('${indent}final $v = Struct.create<NitroOptBool>()..hasValue = ${p.name} != null ? 1 : 0..value = ${p.name} == true ? 1 : 0;');
      }
      args.add('$v.address');
    } else if (spec.isEnumName(tBase)) {
      args.add(t.endsWith('?') ? '${p.name} == null ? -1 : ${p.name}.nativeValue' : '${p.name}.nativeValue');
    } else if (t == 'bool') {
      args.add(p.name);
    } else if (t == 'DateTime') {
      args.add('${p.name}.millisecondsSinceEpoch');
    } else if (p.type.isAnyNativeObject) {
      args.add(t.endsWith('?') ? '${p.name}?.instanceId ?? -1' : '${p.name}.instanceId');
    } else {
      args.add(p.name);
    }
  }
  return (setup: setup, args: args);
}

// ── Finding 1: @Native<F> leaf binding helpers ────────────────────────────────

/// Returns the FFI type string for a leaf sync param in @Native<F> declarations.
/// Delegates directly to [_typeToFFI] — nullable prim params already map to
/// Pointer<NitroOptXxx> there.
String _leafParamFfiType(BridgeType bt, BridgeSpec spec) => _typeToFFI(bt, spec);

/// Returns the Dart callable type string for a leaf sync param in @Native<F>
/// declarations.  Delegates to [_typeToDartFFI].
String _leafParamDartType(BridgeType bt, BridgeSpec spec) => _typeToDartFFI(bt, spec);

/// Returns the FFI return type for a @Native leaf function declaration.
String _leafReturnFfiType(BridgeType rt, BridgeSpec spec) => _typeToFFI(rt, spec);

/// Returns the Dart return type for a @Native leaf function declaration.
String _leafReturnDartType(BridgeType rt, BridgeSpec spec) => _typeToDartFFI(rt, spec);

/// Emits top-level `@Native<F>(symbol: ..., isLeaf: true)` external function
/// declarations for all leaf struct-create functions in [spec].
///
/// These allow the Dart AOT compiler to issue a direct C function call (not a
/// function-pointer dispatch) on iOS/macOS where the native library is statically
/// linked and all symbols are already in the process namespace.
///
/// On Android the function-pointer fallback (_${func.dartName}Ptr) is used instead
/// (controlled by `_nitroNativeBindings` in the impl class).
void _emitNativeBindingDeclarations(CodeWriter writer, BridgeSpec spec) {
  final libStem = spec.lib.replaceAll('-', '_');
  final leafFuncs = spec.functions.where((f) => _isLeafStructCreate(f, spec)).toList();
  if (leafFuncs.isEmpty) return;

  writer.line('// ── @Native<F> leaf bindings — AOT-optimized direct C calls ──────────');
  writer.line('// iOS/macOS: resolve via DynamicLibrary.process() (static linking).');
  writer.line('// Android: call ${libStem}_enable_native_bindings() from Kotlin init.');
  for (final func in leafFuncs) {
    // Build FFI type sig: ReturnFFI Function(Int64, [ParamFFIs], Pointer<NitroErrorFfi>)
    final ffiParamList = [
      'Int64',
      ...func.params.map((p) => _leafParamFfiType(p.type, spec)),
      'Pointer<NitroErrorFfi>',
    ].join(', ');
    final ffiReturn = _leafReturnFfiType(func.returnType, spec);
    final ffiSig = '$ffiReturn Function($ffiParamList)';

    // Build Dart external param list with numbered names (_id, _p0, _p1, ..., _err)
    final dartParamParts = <String>['int _id'];
    for (var i = 0; i < func.params.length; i++) {
      dartParamParts.add('${_leafParamDartType(func.params[i].type, spec)} _p$i');
    }
    dartParamParts.add('Pointer<NitroErrorFfi> _err');
    final dartParams = dartParamParts.join(', ');
    final dartReturn = _leafReturnDartType(func.returnType, spec);

    writer.line("@Native<$ffiSig>(symbol: '${func.cSymbol}', isLeaf: true)");
    writer.line('external $dartReturn _n_${func.cSymbol}($dartParams);');
    writer.blankLine();
  }
}

/// Returns the Struct.create expression for a single nullable-prim property setter value.
/// Pass [varName] as the Dart variable to encode (typically 'value').
String buildSingleStructCreateArg(BridgeType type, String varName) {
  final t = type.name;
  if (t == 'int?' || t == 'uint64?') {
    return 'Struct.create<NitroOptInt64>()..hasValue = $varName != null ? 1 : 0..value = $varName ?? 0';
  } else if (t == 'DateTime?') {
    return 'Struct.create<NitroOptInt64>()..hasValue = $varName != null ? 1 : 0..value = $varName?.millisecondsSinceEpoch ?? 0';
  } else if (t == 'double?') {
    return 'Struct.create<NitroOptFloat64>()..hasValue = $varName != null ? 1 : 0..value = $varName ?? 0.0';
  } else {
    return 'Struct.create<NitroOptBool>()..hasValue = $varName != null ? 1 : 0..value = $varName == true ? 1 : 0';
  }
}
