part of '../web_bridge_generator.dart';

// Dart callbacks on web: a function-table slot per callback, the wasm
// signature letters, and the argument / return conversions.

/// Emscripten signature letter for one callback C type (wasm32: pointers
/// and small ints are i32 → 'i'; int64 → 'j'; double → 'd'; float → 'f').
String _sigLetter(BridgeSpec spec, BridgeType t) {
  final base = _bare(t.name);
  // Exhaustive over WireKind: a new wire category fails to COMPILE here
  // rather than silently defaulting to a pointer slot and producing a
  // callback signature the wasm table rejects at call time.
  return switch (spec.wireKind(t)) {
    WireKind.none => 'v',
    WireKind.float => base == 'float' ? 'f' : 'd',
    WireKind.enumeration => 'j',
    // Only the genuinely 64-bit integers get 'j'; the rest are i32 slots.
    WireKind.integer => switch (base) {
      'int' || 'uint64' || 'DateTime' => 'j',
      _ => 'i',
    },
    // Everything else is an i32 slot on wasm32: bools, and every
    // pointer-shaped payload.
    WireKind.bool_ ||
    WireKind.string ||
    WireKind.typedData ||
    WireKind.pointer ||
    WireKind.struct ||
    WireKind.record ||
    WireKind.variant ||
    WireKind.list ||
    WireKind.map ||
    WireKind.anyMap ||
    WireKind.function ||
    WireKind.handle ||
    WireKind.opaque => 'i',
  };
}

/// A callback parameter: register a Dart closure in the module function
/// table (cached per parameter slot; replaced closures release their table
/// entry on the next microtask, mirroring the native deferredClose).
String _callbackArgExpr(BridgeSpec spec, BridgeType t, String name, String ownerFn) {
  // The helper returns the function-table index as a Dart int; the call
  // argument list is List<JSAny?>, so it needs converting like any other
  // scalar. A bare int here does not compile.
  return '${_callbackHelperName(ownerFn, name)}($name).toJS';
}

/// Callback helpers are keyed by owning method AND parameter name, mirroring
/// the native emitter's `_nativeCallbackOnBoolTransformBoolCb`. Keying on the
/// parameter alone collides when two methods share a callback parameter name
/// with different signatures — the second method then silently reuses the
/// first one's conversion.
String _callbackHelperName(String ownerFn, String paramName) => '_nitroWebCallback_${ownerFn}_$paramName';

void _emitCallbackHelpers(CodeWriter w, BridgeSpec spec) {
  // One helper per distinct callback parameter (keyed by method+param name),
  // caching the function-table slot and releasing the previous one when the
  // callback is replaced.
  final seen = <String>{};
  for (final func in spec.functions) {
    for (final p in func.params) {
      if (!p.type.isFunction) continue;
      // Keyed by method + param: two methods may each take a callback named
      // e.g. `boolCb` with different signatures.
      if (!seen.add('${func.dartName}.${p.name}')) continue;
      _emitOneCallbackHelper(w, spec, p, func.dartName);
    }
  }
}

void _emitOneCallbackHelper(CodeWriter w, BridgeSpec spec, BridgeParam p, String ownerFn) {
  final cb = p.type;
  final cbParams = cb.functionParams;
  final retName = cb.functionReturnType ?? 'void';
  final retType = BridgeType(name: retName);
  final sig = _sigLetter(spec, retType) + cbParams.map((t) => _sigLetter(spec, t)).join();

  // JS-side closure parameter list and Dart-value conversions.
  final jsParams = <String>[];
  final convs = <String>[];
  for (var i = 0; i < cbParams.length; i++) {
    jsParams.add('JSAny? a$i');
    final t = cbParams[i];
    final base = _bare(t.name);
    final nullable = t.name.endsWith('?');
    String conv;
    switch (base) {
      case 'int' || 'uint64':
        conv = 'dartI64(a$i)';
      case 'DateTime':
        conv = 'DateTime.fromMillisecondsSinceEpoch(dartI64(a$i))';
      case 'double' || 'float':
        conv = '(a$i! as JSNumber).toDartDouble';
      case 'bool':
        conv = '(a$i! as JSNumber).toDartInt != 0';
      case 'String':
        // char* — borrowed for the duration of the call; malloc'd by the
        // bridge and freed by Dart on native, so mirror: read then free.
        conv = nullable ? _freeingStringConv('a$i', nullable: true) : _freeingStringConv('a$i', nullable: false);
      case _ when spec.isEnumName(base):
        conv = 'dartI64(a$i).to$base()';
      case _ when spec.isStructName(base):
        conv = '(() { final _p = dartI64(a$i); final _v = _nitroReadStruct$base(_module, _p); _module.nitroFree(_p); return _v; })()';
      case _ when spec.isRecordName(base) || spec.isVariantName(base) || t.isMap || t.isAnyMap:
        final decode = _framedDecodeExpr(spec, t, '_framed');
        final nullPart = nullable ? 'if (_p == 0) return null; ' : '';
        conv = '(() { final _p = dartI64(a$i); ${nullPart}final _framed = _module.readFramed(_p); _module.nitroFree(_p); return $decode; })()';
      default:
        // Anything left over (List<T>, @NitroTuple, Pointer<T>, …) has no web
        // decode. Falling through to a raw address would hand the callback a
        // meaningless int AND leak the buffer, so fail the build the same way
        // the native generator does rather than emit silently-wrong code.
        throw UnsupportedError(
          '${spec.dartClassName}: callback parameter "${p.name}" takes an '
          'argument of type "${t.name}", which the web bridge cannot decode. '
          'Callback arguments on web support int, uint64, double, bool, '
          'String, DateTime, @HybridEnum, @HybridStruct, @HybridRecord, '
          '@NitroVariant, and Map (and their nullable variants).',
        );
    }
    convs.add(conv);
  }

  final String retConv;
  switch (retName) {
    case 'void':
      retConv = '';
    case 'int' || 'uint64':
      retConv = 'return jsI64(_r);';
    case 'double':
      retConv = 'return _r.toJS;';
    case 'bool':
      retConv = 'return (_r ? 1 : 0).toJS;';
    case 'String':
      // The bridge frees callback string returns with the module free — copy
      // into a nitro_alloc'd buffer.
      retConv = 'return _module.nitroAllocCString(_r).toJS;';
    case 'DateTime':
      retConv = 'return jsI64(_r.millisecondsSinceEpoch);';
    case _ when spec.isEnumName(retName):
      retConv = 'return jsI64(_r.nativeValue);';
    case _ when spec.callbackReturnsBlock(retName):
      // Framed blob, same shape as a record return: encode into a module
      // allocation and hand back the pointer. The bridge frees it with the
      // module free after reading, mirroring the native contract.
      retConv = 'return _module.nitroAllocBytes(_nitroEncodeFramed((w) => _r.writeFields(w))).toJS;';
    default:
      // Anything else (AnyNativeObject, Pointer<T>, lists, tuples) has no web
      // encoding. `return jsI64(0)` would hand native a silent zero, so fail
      // the build rather than emit code that misbehaves only on web.
      throw UnsupportedError(
        '${spec.dartClassName}: callback parameter "${p.name}" returns '
        '"$retName", which the web bridge cannot encode. Callback returns on '
        'web support void, int, uint64, double, bool, String, DateTime, '
        '@HybridEnum, @HybridRecord, and @NitroVariant.',
      );
  }

  final hn = _callbackHelperName(ownerFn, p.name);
  w.line('int? ${hn}_slot;');
  w.line('int $hn(${cb.name} cb) {');
  w.line('  final _old = ${hn}_slot;');
  final closureParams = jsParams.join(', ');
  if (retName == 'void') {
    w.line('  void _js($closureParams) {');
    w.line('    cb(${convs.join(', ')});');
    w.line('  }');
  } else {
    w.line('  JSAny? _js($closureParams) {');
    w.line('    final _r = cb(${convs.join(', ')});');
    w.line('    $retConv');
    w.line('  }');
  }
  w.line("  final _slot = _module.addFunction(_js.toJS, '$sig');");
  w.line('  ${hn}_slot = _slot;');
  w.line('  NitroRuntime.deferredCloseWebFunction(_module, _old);');
  w.line('  return _slot;');
  w.line('}');
  w.blankLine();
}

String _freeingStringConv(String jsVar, {required bool nullable}) {
  if (nullable) {
    return '(() { final _p = dartI64($jsVar); if (_p == 0) return null; final _s = _module.readCString(_p); _module.nitroFree(_p); return _s; })()';
  }
  return '(() { final _p = dartI64($jsVar); final _s = _module.readCString(_p); _module.nitroFree(_p); return _s; })()';
}
