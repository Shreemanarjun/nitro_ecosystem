part of '../web_bridge_generator.dart';

// One generated Dart member per spec member: methods (sync, @nitroAsync,
// @nitroNativeAsync), properties and streams of the web implementation class.

/// The Dart type used in @override signatures.
///
/// A raw `Pointer<T>` is a different class on each side — dart:ffi natively,
/// the address-only marker in ffi_stub on web — and the stub deliberately
/// omits most of the pointer API, so overrides type it `dynamic`.
///
/// `NativeHandle<T>` does NOT need that escape hatch: package:nitro's
/// conditional exports resolve both the handle class and the `Void`-style
/// markers to their web twins, so the spec's declared type and the generated
/// override name the same class. Typing it `dynamic` produced an invalid
/// override, since `dynamic` is not a subtype of the declared return.
String _dartTypeFor(BridgeType t) {
  if (t.isPointer) return 'dynamic';
  return t.name;
}

/// `NativeHandle<T>` and `Pointer<T>` name different classes per platform —
/// dart:ffi natively, the web twins here — so `dart analyze`, which resolves
/// the SPEC natively and this file for web, reports a false invalid_override.
/// The mismatch is an artefact of analysing one file under the other
/// platform's resolution; the ignore is scoped to those members only, so a
/// genuine override break anywhere else still fails the analyzer.
void _emitOverride(CodeWriter w, BridgeType returnType, {List<BridgeParam> params = const []}) {
  w.line('  @override');
  // The ignore has to sit immediately above the DECLARATION line, which the
  // caller emits next — a comment above `@override` would apply to the
  // annotation instead and leave the error unsuppressed.
  // Handle/pointer PARAMETERS hit the same artefact (GH #52 made handle
  // params reachable): the spec's NativeHandle is the native class under
  // `dart analyze`, the override's is the web twin.
  final handleParam = params.any((p) => p.type.isNativeHandle || p.type.isPointer);
  if (returnType.isNativeHandle || returnType.isPointer || handleParam) {
    w.line('  // ignore: invalid_override');
  }
}

// Mirrors the FFI emitter's _paramList: named params must stay named or the
// web impl's signature is not a valid override of the spec (Bug: 0.7.1 web).
String _dartParams(List<BridgeParam> params) {
  final positional = params.where((p) => !p.isNamed).map((p) => '${_dartTypeFor(p.type)} ${p.name}').join(', ');
  final named = params.where((p) => p.isNamed).toList();
  if (named.isEmpty) return positional;
  final namedStr = named
      .map((p) {
        if (p.defaultLiteral != null) return '${_dartTypeFor(p.type)} ${p.name} = ${p.defaultLiteral}';
        return '${_dartTypeFor(p.type)} ${p.name}';
      })
      .join(', ');
  final sep = positional.isEmpty ? '' : ', ';
  return '$positional$sep{$namedStr}';
}

void _emitMethod(CodeWriter w, BridgeSpec spec, BridgeFunction func) {
  final params = _dartParams(func.params);
  // @NitroResult widens the declared return to NitroResultValue<T>; the C
  // symbol still returns a pointer to [1B tag][framed payload].
  final rt = func.isResult ? 'NitroResultValue<${_dartTypeFor(func.returnType)}>' : _dartTypeFor(func.returnType);

  if (func.isNativeAsync) {
    _emitNativeAsyncMethod(w, spec, func, params, rt);
    return;
  }

  final needsArena = func.params.any((p) => _paramNeedsArena(spec, p.type));
  final callArgs = _buildCallArgs(spec, func.params, includeErr: !func.isAsync, ownerFn: func.dartName);
  final call = "_m.call('${func.cSymbol}', [${callArgs.join(', ')}])";

  if (func.isAsync) {
    // @nitroAsync on web runs inline (no isolates); the legacy get/clear
    // error protocol matches the C signature (no NitroError* out-param).
    // Async returns are OWNED (malloc'd by native) — decode then free.
    _emitOverride(w, func.returnType, params: func.params);
    // `async` so a checkDisposed() throw rejects the future instead of
    // blowing up at the call site (matches the FFI emitter).
    w.line('  ${func.returnsFutureOr ? 'FutureOr' : 'Future'}<$rt> ${func.dartMember(params)} async {');
    w.line('    checkDisposed();');
    w.line('    return NitroRuntime.callAsync<$rt>(() {');
    _openArena(w, needsArena, '      ');
    final inner = needsArena ? '        ' : '      ';
    w.line('${inner}final _res = $call;');
    w.line('${inner}_checkLegacyError();');
    _emitReturnDecode(w, spec, func.returnType, '_res', inner, borrowed: false, zeroCopy: func.zeroCopyReturn, func: func);
    _closeArena(w, needsArena, '      ');
    w.line("    }, const [], methodName: '${func.dartName}');");
    w.line('  }');
    w.blankLine();
    return;
  }

  // Sync: NitroError* out-param; borrowed framed/string returns.
  _emitOverride(w, func.returnType, params: func.params);
  // inlineFuture: same sync body inside an `async` function (see BridgeFunction).
  // A FutureOr<T> inline method returns the value itself: no async, no Future.
  w.line(func.inlineFuture ? (func.returnsFutureOr ? '  FutureOr<$rt> ${func.dartMember(params)} {' : '  Future<$rt> ${func.dartMember(params)} async {') : '  $rt ${func.dartMember(params)} {');
  w.line('    checkDisposed();');
  if (func.isFast && !func.inlineFuture) {
    // @nitroFast: bare call, as on native — no callSync wrapper; the error
    // slot is read in debug builds only (the assert compiles away in
    // profile/release).
    _openArena(w, needsArena, '    ');
    final fastInner = needsArena ? '      ' : '    ';
    w.line('${fastInner}final _res = $call;');
    w.line('${fastInner}assert(() { NitroRuntime.throwIfOutParamError(_err); return true; }());');
    _emitReturnDecode(w, spec, func.returnType, '_res', fastInner, borrowed: true, zeroCopy: func.zeroCopyReturn, func: func);
    _closeArena(w, needsArena, '    ');
    w.line('  }');
    w.blankLine();
    return;
  }
  w.line('    return NitroRuntime.callSync(() {');
  _openArena(w, needsArena, '      ');
  final inner = needsArena ? '        ' : '      ';
  w.line('${inner}final _res = $call;');
  w.line('${inner}NitroRuntime.throwIfOutParamError(_err);');
  _emitReturnDecode(w, spec, func.returnType, '_res', inner, borrowed: true, zeroCopy: func.zeroCopyReturn, func: func);
  _closeArena(w, needsArena, '      ');
  w.line("    }, methodName: '${func.dartName}');");
  w.line('  }');
  w.blankLine();
}

void _emitNativeAsyncMethod(CodeWriter w, BridgeSpec spec, BridgeFunction func, String params, String rt) {
  final needsArena = func.params.any((p) => _paramNeedsArena(spec, p.type));
  // Native-async: per-call error slot + dart_port, posted result.
  final callArgs = _buildCallArgs(spec, func.params, includeErr: false, ownerFn: func.dartName);
  _emitOverride(w, func.returnType, params: func.params);
  w.line('  ${func.returnsFutureOr ? 'FutureOr' : 'Future'}<$rt> ${func.dartMember(params)} {');
  w.line('    checkDisposed();');
  w.line('    final _slot = WebNitroErrorSlot.alloc(_m);');
  // Named `arena`, not `_arena`: _buildCallArgs emits `arena.cString(...)`
  // / `arena.copyIn(...)` for every param that needs scratch memory, the
  // same identifier the sync path binds via withWasmArena(_m, (arena) {…}).
  if (needsArena) w.line('    final arena = WasmArena(_m);');
  w.line('    return NitroRuntime.openNativeAsync<$rt>(');
  w.line("      call: (dartPort) => _m.call('${func.cSymbol}', [${callArgs.join(', ')}, _slot.ptr.toJS, jsI64(dartPort)]),");
  w.line('      unpack: (raw) {');
  w.line('        _slot.throwIfError();');
  _emitNativeAsyncUnpack(w, spec, func, '        ');
  w.line('      },');
  if (needsArena) {
    w.line('      cleanup: () { _slot.free(); arena.releaseAll(); },');
  } else {
    w.line('      cleanup: _slot.free,');
  }
  w.line("      methodName: '${func.dartName}',");
  w.line('    );');
  w.line('  }');
  w.blankLine();
}

/// Mirrors the FFI `_nativeAsyncUnpack` matrix over heap offsets: posted
/// kInt64 addresses are OWNED (freed via nitro_free after decoding).
void _emitNativeAsyncUnpack(CodeWriter w, BridgeSpec spec, BridgeFunction func, String indent) {
  final rt = func.returnType.name;
  final rtBase = _bare(rt);
  final isNullable = rt.endsWith('?');
  final type = func.returnType;

  void nullGuard() {
    if (isNullable) {
      w.line('${indent}if (raw == null || raw == 0) return null;');
    } else {
      w.line("${indent}if (raw == null) { throw StateError('${func.dartName} (native-async): native posted null for a non-nullable $rt result'); }");
    }
  }

  if (rt == 'void') {
    w.line('${indent}return;');
    return;
  }
  if (rtBase == 'bool' && !isNullable) {
    w.line('${indent}return raw is bool ? raw : (raw as num).toInt() != 0;');
    return;
  }
  if (rtBase == 'String') {
    w.line(isNullable ? '${indent}return raw as String?;' : '${indent}return raw as String;');
    return;
  }
  if (type.isTypedData) {
    // Posted as the list itself, or as the address of its owned
    // `[8B byteLength][data]` block.
    w.line('${indent}if (raw is $rtBase) return raw;');
    nullGuard();
    w.line('${indent}final _ptr = (raw as num).toInt();');
    w.line('${indent}final _byteLen = _m.readI64(_ptr);');
    w.line('${indent}final _bytes = _m.readBytes(_ptr + 8, _byteLen);');
    w.line('${indent}_m.nitroFree(_ptr);');
    w.line('${indent}return ${_typedDataFromBytes(rtBase, '_bytes')};');
    return;
  }
  if ((rtBase == 'int' || rtBase == 'uint64' || rtBase == 'double' || rtBase == 'bool' || rtBase == 'DateTime') && isNullable) {
    // Posted as a pointer to the packed NitroOpt* layout — same bytes the
    // NitroWireCodec reads.
    w.line('${indent}if (raw == null || raw == 0) return null;');
    w.line('${indent}final _ptr = (raw as num).toInt();');
    final codec = rtBase == 'double' ? 'NitroDoubleWireCodec' : (rtBase == 'bool' ? 'NitroBoolWireCodec' : 'NitroIntWireCodec');
    final size = rtBase == 'bool' ? 2 : 9;
    w.line('${indent}final _bytes = _m.readBytes(_ptr, $size);');
    w.line('${indent}_m.nitroFree(_ptr);');
    if (rtBase == 'DateTime') {
      w.line('${indent}final _ms = const NitroIntWireCodec().decodeBytes(_bytes);');
      w.line('${indent}return _ms != null ? DateTime.fromMillisecondsSinceEpoch(_ms) : null;');
    } else {
      w.line('${indent}return const $codec().decodeBytes(_bytes);');
    }
    return;
  }
  if (rtBase == 'int' || rtBase == 'uint64') {
    w.line('${indent}return (raw as num).toInt();');
    return;
  }
  if (rtBase == 'double') {
    w.line('${indent}return (raw as num).toDouble();');
    return;
  }
  if (rtBase == 'DateTime') {
    w.line('${indent}return DateTime.fromMillisecondsSinceEpoch((raw as num).toInt());');
    return;
  }
  if (spec.isEnumName(rtBase)) {
    if (isNullable) {
      w.line('${indent}if (raw == null) return null;');
      w.line('${indent}final _v = (raw as num).toInt();');
      w.line('${indent}return _v == -1 ? null : _v.to$rtBase();');
    } else {
      w.line('${indent}return ((raw as num).toInt()).to$rtBase();');
    }
    return;
  }
  if (type.isAnyNativeObject || rtBase == 'AnyNativeObject') {
    if (isNullable) {
      w.line('${indent}if (raw == null) return null;');
      w.line('${indent}final _id = (raw as num).toInt();');
      w.line('${indent}return _id == -1 ? null : AnyNativeObject(_id);');
    } else {
      w.line('${indent}return AnyNativeObject((raw as num).toInt());');
    }
    return;
  }
  if (type.isNativeHandle) {
    final tp = type.nativeHandleTypeParam ?? 'Void';
    nullGuard();
    w.line('${indent}final _handle = NativeHandle<$tp>.fromAddress((raw as num).toInt());');
    if (func.isOwned) {
      w.line("${indent}_handle.attachReleaseCallback((addr) => _m.call('${func.cSymbol}_release', [addr.toJS]));");
    }
    w.line('${indent}return _handle;');
    return;
  }
  if (spec.isStructName(rtBase)) {
    nullGuard();
    w.line('${indent}final _ptr = (raw as num).toInt();');
    w.line('${indent}final _v = ${_structReadCall(spec, rtBase, '_ptr')};');
    w.line('${indent}_m.nitroFree(_ptr);');
    w.line('${indent}return _v;');
    return;
  }
  if (spec.isCustomTypeName(rtBase)) {
    final ct = spec.customTypeByName(rtBase)!;
    nullGuard();
    w.line('${indent}final _ptr = (raw as num).toInt();');
    w.line('${indent}final _bytes = _m.readBytes(_ptr, const ${ct.codecClass}().encodedSize);');
    w.line('${indent}_m.nitroFree(_ptr);');
    final bang = isNullable ? '' : '!';
    w.line('${indent}return const ${ct.codecClass}().decodeBytes(_bytes)$bang;');
    return;
  }
  // Framed blobs: records, variants, maps, AnyMap, tuples, record lists.
  nullGuard();
  w.line('${indent}final _ptr = (raw as num).toInt();');
  w.line('${indent}final _framed = _m.readFramed(_ptr);');
  w.line('${indent}_m.nitroFree(_ptr);');
  w.line('${indent}return ${_framedDecodeExpr(spec, type, '_framed')};');
}

void _emitProperty(CodeWriter w, BridgeSpec spec, BridgeProperty prop) {
  final rt = _dartTypeFor(prop.type);
  if (prop.hasGetter && prop.getFast) {
    // @nitroFast getter: bare call + debug-only error check, as on native.
    w.line('  @override');
    w.line('  $rt get ${prop.dartName} {');
    w.line('    checkDisposed();');
    w.line("    final _res = _m.call('${prop.getSymbol}', [jsI64(_instanceId), _err.ptr.toJS]);");
    w.line('    assert(() { NitroRuntime.throwIfOutParamError(_err); return true; }());');
    _emitReturnDecode(w, spec, prop.type, '_res', '    ', borrowed: true, zeroCopy: false, func: null);
    w.line('  }');
    w.blankLine();
  } else if (prop.hasGetter) {
    w.line('  @override');
    w.line('  $rt get ${prop.dartName} {');
    w.line('    checkDisposed();');
    w.line('    return NitroRuntime.callSync(() {');
    w.line("      final _res = _m.call('${prop.getSymbol}', [jsI64(_instanceId), _err.ptr.toJS]);");
    w.line('      NitroRuntime.throwIfOutParamError(_err);');
    _emitReturnDecode(w, spec, prop.type, '_res', '      ', borrowed: true, zeroCopy: false, func: null);
    w.line("    }, methodName: '${prop.dartName}');");
    w.line('  }');
    w.blankLine();
  }
  if (prop.hasSetter) {
    final needsArena = _paramNeedsArena(spec, prop.type);
    // Property setters cannot take a callback, so the owner name is only
    // used for uniqueness and never reaches a helper.
    final arg = _jsArgExpr(spec, prop.type, 'value', 'set_${prop.dartName}');
    w.line('  @override');
    w.line('  set ${prop.dartName}($rt value) {');
    w.line('    checkDisposed();');
    if (prop.setFast) {
      // @nitroFast setter: bare call + debug-only error check, as on native.
      // A setter cannot `return withWasmArena(...)`: plain call.
      if (needsArena) w.line('    withWasmArena(_m, (arena) {');
      final fastInner = needsArena ? '      ' : '    ';
      w.line("${fastInner}_m.call('${prop.setSymbol}', [jsI64(_instanceId), $arg, _err.ptr.toJS]);");
      w.line('${fastInner}assert(() { NitroRuntime.throwIfOutParamError(_err); return true; }());');
      if (needsArena) w.line('    });');
      w.line('  }');
      w.blankLine();
      return;
    }
    w.line('    NitroRuntime.callSync(() {');
    _openArena(w, needsArena, '      ');
    final inner = needsArena ? '        ' : '      ';
    w.line("${inner}_m.call('${prop.setSymbol}', [jsI64(_instanceId), $arg, _err.ptr.toJS]);");
    w.line('${inner}NitroRuntime.throwIfOutParamError(_err);');
    _closeArena(w, needsArena, '      ');
    w.line("    }, methodName: '${prop.dartName}=');");
    w.line('  }');
    w.blankLine();
  }
}

void _emitStream(CodeWriter w, BridgeSpec spec, BridgeStream stream) {
  final itemType = stream.itemType.name;
  final baseItemType = _bare(itemType);
  final nullable = stream.itemType.isNullable;
  final q = nullable ? '?' : '';
  final isRecord = stream.itemType.isRecord;
  final isStruct = spec.isStructName(baseItemType);
  final isVariant = spec.isVariantName(baseItemType);
  String streamItemType = baseItemType;
  if (baseItemType == 'uint64') streamItemType = 'int';
  if (stream.itemType.isAnyNativeObject) streamItemType = 'AnyNativeObject';

  final sig = stream.isMethodStyle ? 'Stream<$streamItemType$q> ${stream.dartName}()' : 'Stream<$streamItemType$q> get ${stream.dartName}';

  w.line('  @override');
  w.line('  $sig {');
  w.line('    checkDisposed();');

  final register = "(port) => _m.call('${stream.registerSymbol}', [jsI64(_instanceId), jsI64(port)])";
  final release = "(port) => _m.call('${stream.releaseSymbol}', [jsI64(port)])";

  // Web has no batcher: a batch stream is posted per item, same as the rest.
  {
    final String unpack;
    final nullAction = nullable ? 'return null;' : "throw StateError('Received null event on non-nullable stream ${stream.dartName}');";
    switch (baseItemType) {
      case _ when isRecord || isVariant:
        final decode = _framedDecodeExpr(spec, BridgeType(name: baseItemType, isRecord: isRecord), '_framed');
        unpack = '(message) { if (message == null) { $nullAction } final _ptr = (message as num).toInt(); final _framed = _m.readFramed(_ptr); _m.nitroFree(_ptr); return $decode; }';
      case _ when isStruct:
        unpack = '(message) { if (message == null) { $nullAction } final _ptr = (message as num).toInt(); final _v = ${_structReadCall(spec, baseItemType, '_ptr')}; _m.nitroFree(_ptr); return _v; }';
      case _ when stream.itemType.isAnyNativeObject:
        unpack = nullable ? '(message) => message == null ? null : AnyNativeObject((message as num).toInt())' : '(message) => AnyNativeObject((message as num).toInt())';
      case _ when spec.isEnumName(baseItemType):
        unpack = nullable ? '(message) => message == null ? null : ((message as num).toInt()).to$baseItemType()' : '(message) => ((message as num).toInt()).to$baseItemType()';
      case 'bool':
        unpack = nullable ? '(message) => message == null ? null : (message as num).toInt() != 0' : '(message) => (message as num).toInt() != 0';
      case 'DateTime':
        unpack = nullable ? '(message) => message == null ? null : DateTime.fromMillisecondsSinceEpoch((message as num).toInt())' : '(message) => DateTime.fromMillisecondsSinceEpoch((message as num).toInt())';
      case 'int' || 'uint64':
        unpack = nullable ? '(message) => message == null ? null : (message as num).toInt()' : '(message) => (message as num).toInt()';
      case 'double':
        unpack = nullable ? '(message) => message == null ? null : (message as num).toDouble()' : '(message) => (message as num).toDouble()';
      case _ when stream.itemType.isTypedData:
        // The web shim delivers every typed-data post as raw bytes; copy to
        // an aligned buffer and view it as the declared element type.
        final view = baseItemType == 'Uint8List' ? 'message as Uint8List' : '$baseItemType.sublistView(Uint8List.fromList(message as Uint8List))';
        unpack = '(message) { if (message == null) { $nullAction } return $view; }';
      default:
        unpack = '(message) => message as $baseItemType$q';
    }
    w.line('    return NitroRuntime.openStream<$streamItemType$q>(');
    w.line('      register: $register,');
    w.line('      unpack: $unpack,');
    w.line('      release: $release,');
    w.line('      backpressure: Backpressure.${stream.backpressure.name},');
    w.line("      debugLabel: '${stream.dartName}',");
    w.line('    );');
  }
  w.line('  }');
  w.blankLine();
}

void _openArena(CodeWriter w, bool needsArena, String indent) {
  if (needsArena) w.line('${indent}return withWasmArena(_m, (arena) {');
}

void _closeArena(CodeWriter w, bool needsArena, String indent) {
  if (needsArena) w.line('$indent});');
}

List<String> _buildCallArgs(BridgeSpec spec, List<BridgeParam> params, {required bool includeErr, required String ownerFn}) {
  final args = <String>['jsI64(_instanceId)'];
  for (final p in params) {
    args.add(_jsArgExpr(spec, p.type, p.name, ownerFn));
    if (p.type.isTypedData) {
      // ELEMENT count: C multiplies by sizeof(T) to get bytes.
      args.add(p.type.name.endsWith('?') ? '(${p.name}?.length ?? 0).toJS' : '${p.name}.length.toJS');
    }
  }
  if (includeErr) args.add('_err.ptr.toJS');
  return args;
}

bool _paramNeedsArena(BridgeSpec spec, BridgeType t) {
  final base = _bare(t.name);
  if (base == 'int' || base == 'uint64' || base == 'double' || base == 'bool' || base == 'DateTime') {
    return t.name.endsWith('?'); // nullable prims pack a NitroOpt buffer
  }
  if (spec.isEnumName(base) || t.isAnyNativeObject || t.isNativeHandle || t.isPointer || t.isFunction) return false;
  if (base == 'void') return false;
  if (base == 'int8' || base == 'int16' || base == 'int32' || base == 'uint8' || base == 'uint16' || base == 'uint32' || base == 'float' || base == 'intptr' || base == 'size') return false;
  // Strings, typed data, records, variants, maps, tuples, custom types.
  return true;
}
