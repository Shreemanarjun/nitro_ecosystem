import '../../../bridge_spec.dart';
import '../../code_writer.dart';
import '../../generator_metadata.dart';

/// Web bridge generator (0.7.0 pointer-ABI rewrite).
///
/// Emits a `*.web.bridge.g.dart` standalone library for specs that include
/// `web: NativeImpl.wasm`. The generated class drives the SAME C bridge the
/// dart:ffi implementation uses — compiled to WASM by Emscripten — over
/// `dart:js_interop`:
///
///   * every C symbol is called through `NitroWasmModule.call` (the glue maps
///     real names onto the Module object as `_<symbol>`),
///   * the binary wire format is unchanged: framed `[4B len][payload]` blobs
///     are built with the shared `RecordWriter` and copied into the module
///     heap in one bulk write (and read back the same way),
///   * `int64_t` crosses as JS BigInt via `jsI64`/`dartI64` (53-bit fidelity
///     under dart2js),
///   * async/stream completions arrive through the module post callback and
///     the web port registry — mirroring `Dart_PostCObject` exactly,
///   * errors use the same `NitroError` out-param struct, read from linear
///     memory by `WebNitroErrorSlot`.
///
/// Sync borrowed returns (strings, framed blobs) are decoded immediately and
/// NOT freed, mirroring the 0.6.0 borrow contract; posted/async returns are
/// owned and freed via the module's `<lib>_nitro_free`.
class WebBridgeGenerator {
  static String generate(BridgeSpec spec) {
    if (!spec.targetsWeb) {
      return '${generatedFileHeader('//', sourceUri: spec.sourceUri)}\n'
          '// Web not targeted — no dart:js_interop bridge generated.\n';
    }

    final w = CodeWriter();
    w.raw(generatedFileHeader('//', sourceUri: spec.sourceUri));

    final specFile = spec.sourceUri.split('/').last;

    if (spec.isTypeOnly) {
      w.line('// Type-only spec — types come from the spec library;');
      w.line('// nothing to bind on web.');
      return w.toString();
    }

    final className = spec.dartClassName;
    final libStem = spec.lib.replaceAll('-', '_');

    w.line('// ignore_for_file: non_constant_identifier_names, unnecessary_cast, unused_element, unused_field, unused_import, no_leading_underscores_for_local_identifiers, unused_local_variable');
    w.line('/// Web (WASM/js_interop) implementation of [$className]. Reached through');
    w.line('/// the platform shim; never compiled into a native build.');
    w.line('library;');
    w.blankLine();
    w.line("import 'dart:async';");
    w.line("import 'dart:js_interop';");
    w.blankLine();
    w.line('// The web-bridge barrel: always resolves to the WEB runtime (the main');
    w.line('// nitro.dart barrel is conditional and resolves native under the analyzer).');
    w.line("import 'package:nitro/web_bridge.dart';");
    w.blankLine();
    w.line('// The spec library: abstract class + data types + pure codecs (.g.dart part).');
    w.line("import '../../$specFile';");
    w.blankLine();

    // ── Module bootstrap ──────────────────────────────────────────────────
    w.line("const String _libName = '$libStem';");
    final pkg = spec.assetPackage;
    w.line('// The default asset URL is assets/packages/<package>/assets/web/<lib>.js');
    w.line('// (see NitroRuntime.loadWebModule).');
    w.line(pkg != null ? "const String _assetPackage = '$pkg';" : 'const String? _assetPackage = null;');
    w.blankLine();
    w.line('NitroWasmModule get _module => NitroRuntime.webModule(_libName);');
    w.blankLine();
    w.line('/// Loads and instantiates the $libStem WASM module. MUST be awaited before');
    w.line('/// [create${className}Instance] on web. Idempotent. [jsUrl] overrides the');
    w.line('/// default asset URL.');
    w.line('Future<void> ensure${className}Ready({String? jsUrl}) => NitroRuntime.loadWebModule(_libName, jsUrl: jsUrl, assetPackage: _assetPackage).then((_) {});');
    w.blankLine();
    w.line('/// Creates the web (WASM) implementation of [$className]. A distinct [key]');
    w.line('/// creates an independent native instance; the default key returns the');
    w.line('/// shared singleton. Await [ensure${className}Ready] first.');
    w.line("$className create${className}Instance([String key = 'default']) => _${className}WebImpl(key);");
    w.blankLine();

    _emitWebHelpers(w, spec);
    _emitImplClass(w, spec, libStem, className);

    return w.toString();
  }

  // ══ Impl class ══════════════════════════════════════════════════════════

  static void _emitImplClass(CodeWriter w, BridgeSpec spec, String libStem, String className) {
    final checksum = bridgeSpecChecksum(spec);
    w.line('final class _${className}WebImpl extends $className {');
    w.line('  static final Map<String, _${className}WebImpl> _instances = {};');
    w.blankLine();
    w.line("  factory _${className}WebImpl([String key = 'default']) => _instances.putIfAbsent(key, () => _${className}WebImpl._(key));");
    w.blankLine();
    w.line('  _${className}WebImpl._(this._key) {');
    w.line('    _m = _module;');
    w.line('    // One lib reference per instance, balancing the releaseLib in');
    w.line('    // dispose() — mirrors the FFI impl taking a loadLib per instance.');
    w.line('    // Without it the first dispose() dropped the count to zero and');
    w.line('    // evicted the module out from under every remaining instance.');
    w.line('    NitroRuntime.retainLib(_libName);');
    w.line("    NitroRuntime.checkAbiVersion(_libName, () => (_m.call('${libStem}_nitro_abi_version', const []) as JSNumber).toDartInt);");
    w.line("    NitroRuntime.checkLinkChecksum(_libName, '$checksum', () => _m.readCString(dartI64(_m.call('${libStem}_nitro_bridge_checksum', const []))));");
    w.line('    _err = WebNitroErrorSlot.alloc(_m);');
    w.line('    final keyArena = WasmArena(_m);');
    w.line('    try {');
    w.line("      _instanceId = dartI64(_m.call('${libStem}_create_instance', [keyArena.cString(_key).toJS]));");
    w.line('    } finally {');
    w.line('      keyArena.releaseAll();');
    w.line('    }');
    w.line("    NitroRuntime.logLifecycle('$className', 'web instance created (key=\$_key, id=\$_instanceId)');");
    w.line('  }');
    w.blankLine();
    w.line('  final String _key;');
    w.line('  late final NitroWasmModule _m;');
    w.line('  late final WebNitroErrorSlot _err;');
    w.line('  late final int _instanceId;');
    w.blankLine();
    w.line('  // Disposal state lives in HybridObject, NOT in a private field here.');
    w.line('  // A local `_disposed` SHADOWED the base state: dispose() set the copy,');
    w.line('  // `isDisposed` kept reading the base and stayed false forever.');
    w.line('  @override');
    w.line('  void checkDisposed() {');
    w.line('    if (isDisposed) {');
    w.line("      throw StateError('$className (web) was disposed — create a new instance');");
    w.line('    }');
    w.line('  }');
    w.blankLine();
    w.line('  @override');
    w.line('  void dispose() {');
    w.line('    if (isDisposed) return;');
    w.line("    _m.call('${libStem}_destroy_instance', [jsI64(_instanceId)]);");
    w.line('    _err.free();');
    w.line('    _instances.remove(_key);');
    w.line('    NitroRuntime.releaseLib(_libName);');
    w.line("    NitroRuntime.logLifecycle('$className', 'web instance disposed (key=\$_key)');");
    w.line('    // Last: flips isDisposed and runs onDestroy(), matching the FFI impl.');
    w.line('    super.dispose();');
    w.line('  }');
    w.blankLine();
    w.line('  // Legacy two-call error protocol — used by @nitroAsync methods, whose C');
    w.line('  // signature carries no NitroError* out-param.');
    w.line('  void _checkLegacyError() {');
    w.line("    final errPtr = dartI64(_m.call('${libStem}_get_error', const []));");
    w.line('    if (errPtr == 0 || _m.readU8(errPtr) == 0) return;');
    w.line('    final name = _m.readCString(_m.readU32(errPtr + 4));');
    w.line('    final message = _m.readCString(_m.readU32(errPtr + 8));');
    w.line('    final codePtr = _m.readU32(errPtr + 12);');
    w.line('    final stackPtr = _m.readU32(errPtr + 16);');
    w.line('    final code = codePtr != 0 ? _m.readCString(codePtr) : null;');
    w.line('    final stack = stackPtr != 0 ? _m.readCString(stackPtr) : null;');
    w.line("    _m.call('${libStem}_clear_error', const []);");
    w.line('    throw HybridException(name: name, message: message, code: code, stackTrace: stack);');
    w.line('  }');
    w.blankLine();

    for (final func in spec.functions) {
      _emitMethod(w, spec, func);
    }
    for (final prop in spec.properties) {
      _emitProperty(w, spec, prop);
    }
    for (final stream in spec.streams) {
      _emitStream(w, spec, stream);
    }

    w.line('}');
  }

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
  static String _dartTypeFor(BridgeType t) {
    if (t.isPointer) return 'dynamic';
    return t.name;
  }


  /// `NativeHandle<T>` and `Pointer<T>` name different classes per platform —
  /// dart:ffi natively, the web twins here — so `dart analyze`, which resolves
  /// the SPEC natively and this file for web, reports a false invalid_override.
  /// The mismatch is an artefact of analysing one file under the other
  /// platform's resolution; the ignore is scoped to those members only, so a
  /// genuine override break anywhere else still fails the analyzer.
  static void _emitOverride(CodeWriter w, BridgeType returnType) {
    w.line('  @override');
    // The ignore has to sit immediately above the DECLARATION line, which the
    // caller emits next — a comment above `@override` would apply to the
    // annotation instead and leave the error unsuppressed.
    if (returnType.isNativeHandle || returnType.isPointer) {
      w.line('  // ignore: invalid_override');
    }
  }

  static String _dartParams(List<BridgeParam> params) => params.map((p) => '${_dartTypeFor(p.type)} ${p.name}').join(', ');

  // ══ Methods ═════════════════════════════════════════════════════════════

  static void _emitMethod(CodeWriter w, BridgeSpec spec, BridgeFunction func) {
    final params = _dartParams(func.params);
    // @NitroResult widens the declared return to NitroResultValue<T>; the C
    // symbol still returns a pointer to [1B tag][framed payload].
    final rt = func.isResult
        ? 'NitroResultValue<${_dartTypeFor(func.returnType)}>'
        : _dartTypeFor(func.returnType);

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
      _emitOverride(w, func.returnType);
      // `async` so a synchronous throw from checkDisposed() surfaces as a
      // REJECTED future rather than blowing up at the call site — the FFI
      // emitter declares these `async` for the same reason. Callers write
      // `await expectLater(api.asyncX(), throwsA(...))`, which never sees the
      // error if the method throws before returning a Future.
      w.line('  Future<$rt> ${func.dartName}($params) async {');
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
    _emitOverride(w, func.returnType);
    w.line('  $rt ${func.dartName}($params) {');
    w.line('    checkDisposed();');
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

  static void _emitNativeAsyncMethod(CodeWriter w, BridgeSpec spec, BridgeFunction func, String params, String rt) {
    final needsArena = func.params.any((p) => _paramNeedsArena(spec, p.type));
    // Native-async: per-call error slot + dart_port, posted result.
    final callArgs = _buildCallArgs(spec, func.params, includeErr: false, ownerFn: func.dartName);
    _emitOverride(w, func.returnType);
    w.line('  Future<$rt> ${func.dartName}($params) {');
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
  static void _emitNativeAsyncUnpack(CodeWriter w, BridgeSpec spec, BridgeFunction func, String indent) {
    final rt = func.returnType.name;
    final rtBase = rt.replaceFirst('?', '');
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

  // ══ Properties ══════════════════════════════════════════════════════════

  static void _emitProperty(CodeWriter w, BridgeSpec spec, BridgeProperty prop) {
    final rt = _dartTypeFor(prop.type);
    if (prop.hasGetter) {
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

  // ══ Streams ═════════════════════════════════════════════════════════════

  static void _emitStream(CodeWriter w, BridgeSpec spec, BridgeStream stream) {
    final itemType = stream.itemType.name;
    final baseItemType = itemType.replaceFirst('?', '');
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

    if (stream.isBatch && baseItemType == 'String') {
      // kArray of kString → post tag 5 → List<String>.
      w.line('    return NitroRuntime.openStream<List<String>>(');
      w.line('      register: $register,');
      w.line('      unpack: (message) => (message as List).cast<String>(),');
      w.line('      release: $release,');
      w.line('      backpressure: Backpressure.batch,');
      w.line("      debugLabel: '${stream.dartName}',");
      w.line('    ).asyncExpand(Stream.fromIterable);');
    } else if (stream.isBatch && (isRecord || isVariant)) {
      // kTypedData framed batch → post tag 6 → Uint8List [4B len][4B count][items].
      final decode = isRecord ? 'RecordReader.decodeListBytes(batch, (r) => ${baseItemType}RecordExt.fromReader(r))' : 'RecordReader.decodeListBytes(batch, (r) => ${baseItemType}VariantExt.fromReader(r))';
      w.line('    return NitroRuntime.openStream<Uint8List>(');
      w.line('      register: $register,');
      w.line('      unpack: (message) => message as Uint8List,');
      w.line('      release: $release,');
      w.line('      backpressure: Backpressure.batch,');
      w.line("      debugLabel: '${stream.dartName}',");
      w.line('    ).asyncExpand((batch) => Stream.fromIterable($decode));');
    } else if (stream.isBatch) {
      // kArray of kInt64 → post tag 4 → List<int> [count, items...].
      final String itemExpr;
      if (baseItemType == 'double') {
        itemExpr = 'Int64List.fromList([batch[i]]).buffer.asFloat64List()[0]';
      } else if (baseItemType == 'bool') {
        itemExpr = 'batch[i] != 0';
      } else if (spec.isEnumName(baseItemType)) {
        itemExpr = 'batch[i].to$baseItemType()';
      } else {
        itemExpr = 'batch[i]';
      }
      w.line('    return NitroRuntime.openStream<List<int>>(');
      w.line('      register: $register,');
      w.line('      unpack: (message) => (message as List).map((e) => (e as num).toInt()).toList(),');
      w.line('      release: $release,');
      w.line('      backpressure: Backpressure.batch,');
      w.line("      debugLabel: '${stream.dartName}',");
      w.line('    ).asyncExpand((batch) {');
      w.line('      final count = batch[0];');
      w.line('      return Stream.fromIterable([for (var i = 1; i <= count; i++) $itemExpr]);');
      w.line('    });');
    } else {
      final String unpack;
      final nullAction = nullable ? 'return null;' : "throw StateError('Received null event on non-nullable stream ${stream.dartName}');";
      if (isRecord || isVariant) {
        final decode = _framedDecodeExpr(spec, BridgeType(name: baseItemType, isRecord: isRecord), '_framed');
        unpack = '(message) { if (message == null) { $nullAction } final _ptr = (message as num).toInt(); final _framed = _m.readFramed(_ptr); _m.nitroFree(_ptr); return $decode; }';
      } else if (isStruct) {
        unpack = '(message) { if (message == null) { $nullAction } final _ptr = (message as num).toInt(); final _v = ${_structReadCall(spec, baseItemType, '_ptr')}; _m.nitroFree(_ptr); return _v; }';
      } else if (stream.itemType.isAnyNativeObject) {
        unpack = nullable ? '(message) => message == null ? null : AnyNativeObject((message as num).toInt())' : '(message) => AnyNativeObject((message as num).toInt())';
      } else if (spec.isEnumName(baseItemType)) {
        unpack = nullable ? '(message) => message == null ? null : ((message as num).toInt()).to$baseItemType()' : '(message) => ((message as num).toInt()).to$baseItemType()';
      } else if (baseItemType == 'bool') {
        unpack = nullable ? '(message) => message == null ? null : (message as num).toInt() != 0' : '(message) => (message as num).toInt() != 0';
      } else if (baseItemType == 'DateTime') {
        unpack = nullable ? '(message) => message == null ? null : DateTime.fromMillisecondsSinceEpoch((message as num).toInt())' : '(message) => DateTime.fromMillisecondsSinceEpoch((message as num).toInt())';
      } else if (baseItemType == 'int' || baseItemType == 'uint64') {
        unpack = nullable ? '(message) => message == null ? null : (message as num).toInt()' : '(message) => (message as num).toInt()';
      } else if (baseItemType == 'double') {
        unpack = nullable ? '(message) => message == null ? null : (message as num).toDouble()' : '(message) => (message as num).toDouble()';
      } else {
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

  // ══ Argument encoding ═══════════════════════════════════════════════════

  static void _openArena(CodeWriter w, bool needsArena, String indent) {
    if (needsArena) w.line('${indent}return withWasmArena(_m, (arena) {');
  }

  static void _closeArena(CodeWriter w, bool needsArena, String indent) {
    if (needsArena) w.line('$indent});');
  }

  static List<String> _buildCallArgs(BridgeSpec spec, List<BridgeParam> params, {required bool includeErr, required String ownerFn}) {
    final args = <String>['jsI64(_instanceId)'];
    for (final p in params) {
      args.add(_jsArgExpr(spec, p.type, p.name, ownerFn));
      if (p.type.isTypedData) {
        // ELEMENT count, matching the FFI emitter and the C++ signature
        // (`const int32_t* v, size_t v_length`) which multiplies by sizeof to
        // get bytes. Passing lengthInBytes here made the native side read and
        // return sizeof(T)x too much for every element wider than a byte —
        // invisible for Uint8List/Int8List, corrupt for all the rest.
        args.add(p.type.name.endsWith('?') ? '(${p.name}?.length ?? 0).toJS' : '${p.name}.length.toJS');
      }
    }
    if (includeErr) args.add('_err.ptr.toJS');
    return args;
  }

  static bool _paramNeedsArena(BridgeSpec spec, BridgeType t) {
    final base = t.name.replaceFirst('?', '');
    if (base == 'int' || base == 'uint64' || base == 'double' || base == 'bool' || base == 'DateTime') {
      return t.name.endsWith('?'); // nullable prims pack a NitroOpt buffer
    }
    if (spec.isEnumName(base) || t.isAnyNativeObject || t.isNativeHandle || t.isPointer || t.isFunction) return false;
    if (base == 'void') return false;
    if (base == 'int8' || base == 'int16' || base == 'int32' || base == 'uint8' || base == 'uint16' || base == 'uint32' || base == 'float' || base == 'intptr' || base == 'size') return false;
    // Strings, typed data, records, variants, maps, tuples, custom types.
    return true;
  }

  /// The JS argument expression for one parameter, mirroring the C signature.
  static String _jsArgExpr(BridgeSpec spec, BridgeType t, String name, String ownerFn) {
    final base = t.name.replaceFirst('?', '');
    final nullable = t.name.endsWith('?');

    if (t.isFunction) return _callbackArgExpr(spec, t, name, ownerFn);
    // Pointer/NativeHandle params are typed `dynamic` in the override — cast
    // the duck-typed .address back to int so the .toJS extension applies.
    if (t.isNativeHandle || t.isPointer) {
      return t.name.endsWith('?') ? '(($name as dynamic)?.address as int? ?? 0).toJS' : '(($name as dynamic).address as int).toJS';
    }
    if (t.isAnyNativeObject) {
      return nullable ? 'jsI64($name?.instanceId ?? -1)' : 'jsI64($name.instanceId)';
    }
    if (spec.isCustomTypeName(base)) {
      final ct = spec.customTypeByName(base)!;
      return 'arena.copyIn(const ${ct.codecClass}().encodeBytes($name)).toJS';
    }
    if (nullable && (base == 'int' || base == 'uint64' || base == 'DateTime')) {
      final expr = base == 'DateTime' ? '$name?.millisecondsSinceEpoch' : name;
      return 'arena.copyIn(const NitroIntWireCodec().encodeBytes($expr)).toJS';
    }
    if (nullable && base == 'double') {
      return 'arena.copyIn(const NitroDoubleWireCodec().encodeBytes($name)).toJS';
    }
    if (nullable && base == 'bool') {
      return 'arena.copyIn(const NitroBoolWireCodec().encodeBytes($name)).toJS';
    }
    switch (base) {
      case 'int':
      case 'uint64':
        return 'jsI64($name)';
      case 'DateTime':
        return 'jsI64($name.millisecondsSinceEpoch)';
      case 'double':
        return '$name.toJS';
      case 'bool':
        return '($name ? 1 : 0).toJS';
      case 'String':
        return nullable ? '($name == null ? 0 : arena.cString($name)).toJS' : 'arena.cString($name).toJS';
      case 'int8':
      case 'int16':
      case 'int32':
      case 'uint8':
      case 'uint16':
      case 'uint32':
      case 'intptr':
      case 'size':
        return '$name.toJS';
      case 'float':
        return '$name.toJS';
    }
    if (spec.isEnumName(base)) {
      return nullable ? 'jsI64($name == null ? -1 : $name.nativeValue)' : 'jsI64($name.nativeValue)';
    }
    if (t.isTypedData) {
      if (nullable) {
        final bytes = base == 'Uint8List' ? '$name!' : '$name!.buffer.asUint8List($name.offsetInBytes, $name.lengthInBytes)';
        return '($name == null ? 0 : arena.copyIn($bytes)).toJS';
      }
      final bytes = base == 'Uint8List' ? name : '$name.buffer.asUint8List($name.offsetInBytes, $name.lengthInBytes)';
      return 'arena.copyIn($bytes).toJS';
    }
    if (spec.isStructName(base)) {
      return nullable ? '($name == null ? 0 : arena.copyIn(_nitroPackStruct$base($name))).toJS' : 'arena.copyIn(_nitroPackStruct$base($name)).toJS';
    }
    if (spec.isVariantName(base)) {
      final variant = spec.variantByName(base)!;
      final nullTag = variant.cases.indexWhere((c) => c.name.toLowerCase() == 'null');
      if (nullable || nullTag >= 0) {
        return 'arena.copyIn(_nitroEncodeVariantNullable$base($name)).toJS';
      }
      return 'arena.copyIn(_nitroEncodeFramed((w) => $name.writeFields(w))).toJS';
    }
    if (t.isAnyMap || base == 'NitroAnyMap') {
      return nullable ? '($name == null ? 0 : arena.copyIn(_nitroEncodeFramed($name.writeTo))).toJS' : 'arena.copyIn(_nitroEncodeFramed($name.writeTo)).toJS';
    }
    if (t.isTuple) {
      // A nullable tuple passes 0 for "absent" like every other framed param;
      // the encoder itself declares the non-null record type.
      return nullable
          ? '($name == null ? 0 : arena.copyIn(_nitroEncodeTuple_$base($name))).toJS'
          : 'arena.copyIn(_nitroEncodeTuple_$base($name)).toJS';
    }
    if (t.isMap) {
      final suffix = _mapHelperSuffix(spec, base);
      return nullable ? '($name == null ? 0 : arena.copyIn(_nitroEncodeMapBytes$suffix($name))).toJS' : 'arena.copyIn(_nitroEncodeMapBytes$suffix($name)).toJS';
    }
    if (t.isRecord || spec.isRecordName(base)) {
      const libraryRecords = {'NitroNullableInt', 'NitroNullableDouble', 'NitroNullableBool'};
      final writeCall = libraryRecords.contains(base) || spec.isRecordName(base) || spec.isStructName(base) ? '$name.writeFields' : '$name.writeFields';
      if (t.recordListItemType != null) {
        // A nullable LIST passes 0 (nullptr) for "absent" — the C++ bridge
        // unpacks that into an empty buffer and the decode side maps it back
        // to null. Without the guard the encoders receive a `List<T>?` where
        // they declare `List<T>`.
        // No `!` on the encode side: the ternary already promotes $name to
        // non-null, so an assertion here is dead code the analyzer flags.
        final encode = 'arena.copyIn(${_encodeRecordListExpr(spec, t, name)})';
        return nullable ? '($name == null ? 0 : $encode).toJS' : '$encode.toJS';
      }
      return nullable ? '($name == null ? 0 : arena.copyIn(_nitroEncodeFramed((w) => $name.writeFields(w)))).toJS' : 'arena.copyIn(_nitroEncodeFramed((w) => $writeCall(w))).toJS';
    }
    // Fallback: framed record-style value.
    return 'arena.copyIn(_nitroEncodeFramed((w) => $name.writeFields(w))).toJS';
  }

  static String _encodeRecordListExpr(BridgeSpec spec, BridgeType t, String name) {
    final item = t.recordListItemType!;
    // Nullable ITEMS carry a presence flag per entry: [4B count][1B has][item?].
    // Only enum and variant lists can have nullable items today (see
    // spec_extractor) — a plain encode here drops the flag and desynchronises
    // the reader by one byte per item.
    final nullableItems = t.recordListItemIsNullable;
    if (t.isEnumList) {
      final write = 'w.writeInt(e.nativeValue)';
      return nullableItems
          ? 'RecordWriter.encodeNullableListBytes($name, (w, e) => $write)'
          : 'RecordWriter.encodeListBytes($name, (w, e) => $write)';
    }
    if (t.recordListItemIsPrimitive) {
      final writeCall = switch (item) {
        'int' => 'w.writeInt(e)',
        'double' => 'w.writeDouble(e)',
        'bool' => 'w.writeBool(e)',
        'String' => 'w.writeString(e)',
        _ => 'w.writeInt(e)',
      };
      // Primitive list ARGUMENTS are indexed, same as record lists — Kotlin and
      // Swift both skip an 8-byte-per-item offset table when reading a
      // primitive list param, and the native Dart twin encodes with
      // encodeIndexedPrimitiveList. Note the asymmetry is deliberate: primitive
      // list RETURNS are plain on every backend, so the decode side stays
      // decodeListBytes.
      return 'RecordWriter.encodeIndexedListBytes($name, (w, e) => $writeCall)';
    }
    if (spec.isVariantName(item)) {
      const write = 'e.writeFields(w)';
      return nullableItems
          ? 'RecordWriter.encodeNullableListBytes($name, (w, e) => $write)'
          : 'RecordWriter.encodeListBytes($name, (w, e) => $write)';
    }
    // True @HybridRecord lists are indexed in BOTH directions —
    // [4B count][8B×n offsets][item bytes] — matching the native Dart encoder
    // (dart_record_ffi_helpers.dart) and the Kotlin/Swift emitters. The decode
    // side already expects the offset table; encoding plain here made the
    // receiver read item bytes as offsets.
    //
    // C++ is not in that list on purpose: its bridge forwards lists as an
    // opaque [4B len][payload] blob and never parses them, so a hand-written
    // C++ impl must read/write the offset table itself.
    return 'RecordWriter.encodeIndexedListBytes($name, (w, e) => e.writeFields(w))';
  }

  // ══ Return decoding ═════════════════════════════════════════════════════

  /// Web twin of the FFI `_emitResultDecode`. Same wire format —
  /// `[1B tag: 0=ok, 1=err][framed payload]` — read out of the module heap
  /// instead of off a pointer. The buffer is malloc'd by native, so it is
  /// freed on both branches.
  static void _emitResultDecode(
    CodeWriter w,
    BridgeSpec spec,
    BridgeType type,
    String resVar,
    String indent,
  ) {
    final base = type.name.replaceFirst('?', '');
    w.line('${indent}final _p = dartI64($resVar);');
    w.line('${indent}try {');
    final i2 = '$indent  ';
    w.line('${i2}final _tag = _m.readBytes(_p, 1)[0];');
    w.line('${i2}if (_tag != 0) {');
    // Explicit type argument, not a bare `NitroErr(...)`. The enclosing method
    // signature gives the native emitter's inference enough context, but here
    // the value flows through an untyped closure into callSync/callAsync —
    // Dart then infers NitroErr<Object?>, and callAsync's `as T` blew up with
    // "NitroErr<Object?> is not a subtype of NitroResultValue<double>".
    w.line('$i2  return NitroErr<${type.name}>(RecordReader.fromFramedBytes(_m.readFramed(_p + 1)).readString());');
    w.line('$i2}');
    if (type.isRecord) {
      final decode = _framedDecodeExpr(spec, type, '_m.readFramed(_p + 1)');
      w.line('${i2}return NitroOk($decode);');
    } else {
      w.line('${i2}final _r = RecordReader.fromFramedBytes(_m.readFramed(_p + 1));');
      final valueExpr = switch (base) {
        'int' || 'uint64' => '_r.readInt()',
        'double' || 'float' => '_r.readDouble()',
        'bool' => '_r.readBool()',
        'String' => '_r.readString()',
        _ => spec.isEnumName(base)
            ? '_r.readInt().to$base()'
            : (spec.isStructName(base) ? '${base}StructExt.fromReader(_r)' : '${base}RecordExt.fromReader(_r)'),
      };
      w.line('${i2}return NitroOk($valueExpr);');
    }
    w.line('$indent} finally {');
    w.line('$indent  _m.nitroFree(_p);');
    w.line('$indent}');
  }

  static void _emitReturnDecode(
    CodeWriter w,
    BridgeSpec spec,
    BridgeType type,
    String resVar,
    String indent, {
    required bool borrowed,
    required bool zeroCopy,
    BridgeFunction? func,
  }) {
    // @NitroResult: the C symbol returns [1B tag: 0=ok, 1=err][framed payload].
    // Errors travel in the tag, not the error slot, so this decode replaces the
    // ordinary return path entirely.
    if (func?.isResult ?? false) {
      _emitResultDecode(w, spec, type, resVar, indent);
      return;
    }
    final rt = type.name;
    final rtBase = rt.replaceFirst('?', '');
    final nullable = rt.endsWith('?');

    if (rt == 'void') {
      w.line('${indent}return;');
      return;
    }
    switch (rtBase) {
      case 'int':
      case 'uint64':
      case 'DateTime':
        if (nullable) {
          _decodeNullablePrim(w, spec, rtBase, resVar, indent, borrowed);
          return;
        }
        if (rtBase == 'DateTime') {
          w.line('${indent}return DateTime.fromMillisecondsSinceEpoch(dartI64($resVar));');
        } else {
          w.line('${indent}return dartI64($resVar);');
        }
        return;
      case 'double':
        if (nullable) {
          _decodeNullablePrim(w, spec, 'double', resVar, indent, borrowed);
          return;
        }
        w.line('${indent}return ($resVar as JSNumber).toDartDouble;');
        return;
      case 'bool':
        if (nullable) {
          _decodeNullablePrim(w, spec, 'bool', resVar, indent, borrowed);
          return;
        }
        w.line('${indent}return ($resVar as JSNumber).toDartInt != 0;');
        return;
      case 'String':
        // Sync string returns are borrowed (per-thread scratch); async owned.
        if (nullable) {
          w.line('${indent}final _p = dartI64($resVar);');
          w.line('${indent}if (_p == 0) return null;');
          w.line('${indent}final _s = _m.readCString(_p);');
          if (!borrowed) w.line('${indent}_m.nitroFree(_p);');
          w.line('${indent}return _s;');
        } else {
          if (borrowed) {
            w.line('${indent}return _m.readCString(dartI64($resVar));');
          } else {
            w.line('${indent}final _p = dartI64($resVar);');
            w.line('${indent}final _s = _m.readCString(_p);');
            w.line('${indent}_m.nitroFree(_p);');
            w.line('${indent}return _s;');
          }
        }
        return;
      case 'int8':
      case 'int16':
      case 'int32':
      case 'uint8':
      case 'uint16':
      case 'uint32':
      case 'intptr':
      case 'size':
        w.line('${indent}return ($resVar as JSNumber).toDartInt;');
        return;
      case 'float':
        w.line('${indent}return ($resVar as JSNumber).toDartDouble;');
        return;
    }
    if (spec.isEnumName(rtBase)) {
      if (nullable) {
        w.line('${indent}final _v = dartI64($resVar);');
        w.line('${indent}return _v == -1 ? null : _v.to$rtBase();');
      } else {
        w.line('${indent}return dartI64($resVar).to$rtBase();');
      }
      return;
    }
    if (type.isAnyNativeObject || rtBase == 'AnyNativeObject') {
      if (nullable) {
        w.line('${indent}final _id = dartI64($resVar);');
        w.line('${indent}return _id == -1 ? null : AnyNativeObject(_id);');
      } else {
        w.line('${indent}return AnyNativeObject(dartI64($resVar));');
      }
      return;
    }
    if (type.isNativeHandle) {
      final tp = type.nativeHandleTypeParam ?? 'Void';
      w.line('${indent}final _addr = dartI64($resVar);');
      if (nullable) w.line('${indent}if (_addr == 0) return null;');
      w.line('${indent}final _handle = NativeHandle<$tp>.fromAddress(_addr);');
      if (func != null && func.isOwned) {
        w.line("${indent}_handle.attachReleaseCallback((addr) => _m.call('${func.cSymbol}_release', [addr.toJS]));");
      }
      w.line('${indent}return _handle;');
      return;
    }
    if (type.isTypedData) {
      // Wire: [8B byteLength][data] — owned (freed after copy). zeroCopy:
      // [8B byteLength][8B dataAddress] — snapshot then release.
      w.line('${indent}final _ptr = dartI64($resVar);');
      if (nullable) w.line('${indent}if (_ptr == 0) return null;');
      w.line('${indent}final _byteLen = _m.readI64(_ptr);');
      if (zeroCopy) {
        w.line('${indent}final _dataAddr = _m.readI64(_ptr + 8);');
        w.line('${indent}final _bytes = _m.readBytes(_dataAddr, _byteLen);');
        w.line("${indent}_m.call('${spec.lib.replaceAll('-', '_')}_release_typed_data_return', [_ptr.toJS]);");
      } else {
        w.line('${indent}final _bytes = _m.readBytes(_ptr + 8, _byteLen);');
        w.line('${indent}_m.nitroFree(_ptr);');
      }
      w.line('${indent}return ${_typedDataFromBytes(rtBase, '_bytes')};');
      return;
    }
    if (spec.isStructName(rtBase)) {
      // Sync struct returns are owned heap structs with a release fn.
      w.line('${indent}final _ptr = dartI64($resVar);');
      if (nullable) w.line('${indent}if (_ptr == 0) return null;');
      w.line('${indent}final _v = ${_structReadCall(spec, rtBase, '_ptr')};');
      w.line("${indent}_m.call('${spec.lib.replaceAll('-', '_')}_release_$rtBase', [_ptr.toJS]);");
      w.line('${indent}return _v;');
      return;
    }
    if (spec.isCustomTypeName(rtBase)) {
      // Custom-type returns are owned on both sync and async paths (the FFI
      // decode frees them with _nitroFree).
      final ct = spec.customTypeByName(rtBase)!;
      w.line('${indent}final _ptr = dartI64($resVar);');
      if (nullable) w.line('${indent}if (_ptr == 0) return null;');
      w.line('${indent}final _bytes = _m.readBytes(_ptr, const ${ct.codecClass}().encodedSize);');
      w.line('${indent}_m.nitroFree(_ptr);');
      final bang = nullable ? '' : '!';
      w.line('${indent}return const ${ct.codecClass}().decodeBytes(_bytes)$bang;');
      return;
    }
    // Framed blobs (records, variants, maps, AnyMap, tuples, lists) are OWNED
    // on both sync and async paths — the impl mallocs them and the FFI decode
    // frees them; only C strings and nullable-prim scratch are borrowed.
    w.line('${indent}final _ptr = dartI64($resVar);');
    if (nullable) w.line('${indent}if (_ptr == 0) return null;');
    w.line('${indent}final _framed = _m.readFramed(_ptr);');
    w.line('${indent}_m.nitroFree(_ptr);');
    w.line('${indent}return ${_framedDecodeExpr(spec, type, '_framed')};');
  }

  static void _decodeNullablePrim(CodeWriter w, BridgeSpec spec, String base, String resVar, String indent, bool borrowed) {
    // C returns uint8_t* to the packed NitroOpt* layout (borrowed on sync).
    final codec = base == 'double' ? 'NitroDoubleWireCodec' : (base == 'bool' ? 'NitroBoolWireCodec' : 'NitroIntWireCodec');
    final size = base == 'bool' ? 2 : 9;
    w.line('${indent}final _p = dartI64($resVar);');
    w.line('${indent}if (_p == 0) return null;');
    w.line('${indent}final _bytes = _m.readBytes(_p, $size);');
    if (!borrowed) w.line('${indent}_m.nitroFree(_p);');
    if (base == 'DateTime') {
      w.line('${indent}final _ms = const NitroIntWireCodec().decodeBytes(_bytes);');
      w.line('${indent}return _ms != null ? DateTime.fromMillisecondsSinceEpoch(_ms) : null;');
    } else {
      w.line('${indent}return const $codec().decodeBytes(_bytes);');
    }
  }

  /// Decode expression for a framed byte buffer (after the bulk copy).
  static String _framedDecodeExpr(BridgeSpec spec, BridgeType type, String framedVar) {
    final base = type.name.replaceFirst('?', '');
    if (type.isAnyMap || base == 'NitroAnyMap') {
      return 'NitroAnyMap.readFrom(RecordReader.fromFramedBytes($framedVar))';
    }
    if (type.isTuple) {
      return '_nitroDecodeTuple_$base($framedVar)';
    }
    if (type.isMap) {
      return '_nitroDecodeMapBytes${_mapHelperSuffix(spec, base)}($framedVar)';
    }
    if (type.recordListItemType != null) {
      final item = type.recordListItemType!;
      // Mirrors the encode side: nullable items carry a per-entry presence
      // flag, so they need the nullable reader or every item after the first
      // shifts by a byte.
      final nullableItems = type.recordListItemIsNullable;
      if (type.isEnumList) {
        final read = 'r.readInt().to$item()';
        return nullableItems
            ? 'RecordReader.decodeNullableListBytes($framedVar, (r) => $read)'
            : 'RecordReader.decodeListBytes($framedVar, (r) => $read)';
      }
      if (type.recordListItemIsPrimitive) {
        final readCall = switch (item) {
          'int' => 'r.readInt()',
          'double' => 'r.readDouble()',
          'bool' => 'r.readBool()',
          'String' => 'r.readString()',
          _ => 'r.readInt()',
        };
        return 'RecordReader.decodeListBytes($framedVar, (r) => $readCall)';
      }
      if (spec.isVariantName(item)) {
        final read = '${item}VariantExt.fromReader(r)';
        return nullableItems
            ? 'RecordReader.decodeNullableListBytes($framedVar, (r) => $read)'
            : 'RecordReader.decodeListBytes($framedVar, (r) => $read)';
      }
      // Indexed record lists ([4B count][offset table][items]) are produced by
      // encodeIndexedList on native returns; web decodes them eagerly.
      return 'RecordReader.decodeIndexedListBytes($framedVar, (r) => ${item}RecordExt.fromReader(r))';
    }
    if (spec.isVariantName(base)) {
      return '${base}VariantExt.fromReader(RecordReader.fromFramedBytes($framedVar))';
    }
    const libraryRecords = {'NitroNullableInt', 'NitroNullableDouble', 'NitroNullableBool'};
    if (libraryRecords.contains(base)) {
      return '$base.fromReader(RecordReader.fromFramedBytes($framedVar))';
    }
    // Records (and struct-shaped records).
    return '${base}RecordExt.fromReader(RecordReader.fromFramedBytes($framedVar))';
  }

  static String _typedDataFromBytes(String dartType, String bytesVar) {
    if (dartType == 'Uint8List') return bytesVar;
    final viewCtor = switch (dartType) {
      'Int8List' => 'Int8List.view',
      'Int16List' => 'Int16List.view',
      'Uint16List' => 'Uint16List.view',
      'Int32List' => 'Int32List.view',
      'Uint32List' => 'Uint32List.view',
      'Int64List' => 'Int64List.view',
      'Uint64List' => 'Uint64List.view',
      'Float32List' => 'Float32List.view',
      'Float64List' => 'Float64List.view',
      _ => 'Uint8List.view',
    };
    return '$viewCtor($bytesVar.buffer, $bytesVar.offsetInBytes, $bytesVar.lengthInBytes ~/ ${_typedDataElementSizeWeb(dartType)})';
  }

  static int _typedDataElementSizeWeb(String dartType) => switch (dartType) {
    'Uint8List' || 'Int8List' => 1,
    'Int16List' || 'Uint16List' => 2,
    'Int32List' || 'Uint32List' || 'Float32List' => 4,
    _ => 8,
  };

  // ══ Callbacks ═══════════════════════════════════════════════════════════

  /// Emscripten signature letter for one callback C type (wasm32: pointers
  /// and small ints are i32 → 'i'; int64 → 'j'; double → 'd'; float → 'f').
  static String _sigLetter(BridgeSpec spec, BridgeType t) {
    final base = t.name.replaceFirst('?', '');
    if (t.isPointer || t.isNativeHandle || base == 'String') return 'i';
    if (spec.isEnumName(base)) return 'j';
    if (spec.isStructName(base) || spec.isRecordName(base) || spec.isVariantName(base) || t.isMap || t.isAnyMap) return 'i';
    return switch (base) {
      'int' || 'uint64' || 'DateTime' => 'j',
      'double' => 'd',
      'float' => 'f',
      'bool' || 'int8' || 'int16' || 'int32' || 'uint8' || 'uint16' || 'uint32' || 'intptr' || 'size' => 'i',
      'void' => 'v',
      _ => 'i',
    };
  }

  /// A callback parameter: register a Dart closure in the module function
  /// table (cached per parameter slot; replaced closures release their table
  /// entry on the next microtask, mirroring the native deferredClose).
  static String _callbackArgExpr(BridgeSpec spec, BridgeType t, String name, String ownerFn) {
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
  static String _callbackHelperName(String ownerFn, String paramName) =>
      '_nitroWebCallback_${ownerFn}_$paramName';

  // ══ Helper section (module-level, emitted once per file) ═════════════════

  static void _emitWebHelpers(CodeWriter w, BridgeSpec spec) {
    w.line('// ── Wire helpers (web) ──────────────────────────────────────────────────');
    w.blankLine();
    w.line('Uint8List _nitroEncodeFramed(void Function(RecordWriter w) write) {');
    w.line('  final w = RecordWriter();');
    w.line('  write(w);');
    w.line('  return w.takeFramedBytes();');
    w.line('}');
    w.blankLine();

    _emitStructCodecs(w, spec);
    _emitVariantNullableEncoders(w, spec);
    _emitTupleCodecs(w, spec);
    _emitMapCodecs(w, spec);
    _emitCallbackHelpers(w, spec);
  }

  // ── Struct packed codecs ──────────────────────────────────────────────────

  /// wasm32 packed layout for a @HybridStruct: matches the C `#pragma pack(1)`
  /// typedef compiled by emcc (pointers are 4-byte u32 slots).
  static void _emitStructCodecs(CodeWriter w, BridgeSpec spec) {
    final used = _usedStructs(spec);
    for (final stName in used) {
      final st = spec.structByName(stName);
      if (st == null) continue;

      // Pack (Dart → heap bytes). String fields are not supported in struct
      // params on web yet (they need arena-scoped char* slots).
      w.line('Uint8List _nitroPackStruct$stName($stName v) {');
      final size = _structByteSize(spec, st);
      if (size == null) {
        w.line("  throw UnsupportedError('$stName: struct fields beyond prim/enum are not yet supported on web');");
        w.line('}');
        w.blankLine();
        continue;
      }
      w.line('  final out = Uint8List($size);');
      w.line('  final bd = ByteData.sublistView(out);');
      var off = 0;
      for (final f in st.fields) {
        final base = f.type.name.replaceFirst('?', '');
        if (spec.isEnumName(base)) {
          w.line('  setInt64LE(bd, $off, v.${f.name}.nativeValue);');
          off += 8;
        } else if (base == 'int' || base == 'uint64' || base == 'DateTime') {
          w.line('  setInt64LE(bd, $off, ${base == 'DateTime' ? 'v.${f.name}.millisecondsSinceEpoch' : 'v.${f.name}'});');
          off += 8;
        } else if (base == 'double') {
          w.line('  bd.setFloat64($off, v.${f.name}, Endian.little);');
          off += 8;
        } else if (base == 'bool') {
          w.line('  bd.setUint8($off, v.${f.name} ? 1 : 0);');
          off += 1;
        }
      }
      w.line('  return out;');
      w.line('}');
      w.blankLine();

      // Read (heap offset → Dart value).
      w.line('$stName _nitroReadStruct$stName(NitroWasmModule m, int ptr) {');
      w.line('  final bd = ByteData.sublistView(m.readBytes(ptr, $size));');
      final args = <String>[];
      off = 0;
      for (final f in st.fields) {
        final base = f.type.name.replaceFirst('?', '');
        String expr;
        if (spec.isEnumName(base)) {
          expr = 'getInt64LE(bd, $off).to$base()';
          off += 8;
        } else if (base == 'int' || base == 'uint64') {
          expr = 'getInt64LE(bd, $off)';
          off += 8;
        } else if (base == 'DateTime') {
          expr = 'DateTime.fromMillisecondsSinceEpoch(getInt64LE(bd, $off))';
          off += 8;
        } else if (base == 'double') {
          expr = 'bd.getFloat64($off, Endian.little)';
          off += 8;
        } else {
          expr = 'bd.getUint8($off) != 0';
          off += 1;
        }
        args.add('${f.name}: $expr');
      }
      w.line('  return $stName(${args.join(', ')});');
      w.line('}');
      w.blankLine();
    }
  }

  /// Byte size of the packed wasm32 struct, or null when a field kind is not
  /// yet supported on web (strings, typed data, nested structs).
  static int? _structByteSize(BridgeSpec spec, BridgeStruct st) {
    var size = 0;
    for (final f in st.fields) {
      final base = f.type.name.replaceFirst('?', '');
      if (spec.isEnumName(base) || base == 'int' || base == 'uint64' || base == 'double' || base == 'DateTime') {
        size += 8;
      } else if (base == 'bool') {
        size += 1;
      } else {
        return null;
      }
    }
    return size;
  }

  static Set<String> _usedStructs(BridgeSpec spec) {
    final used = <String>{};
    void addType(BridgeType t) {
      final base = t.name.replaceFirst('?', '');
      if (spec.isStructName(base)) used.add(base);
    }

    for (final f in spec.functions) {
      addType(f.returnType);
      for (final p in f.params) {
        addType(p.type);
      }
    }
    for (final p in spec.properties) {
      addType(p.type);
    }
    for (final s in spec.streams) {
      addType(s.itemType);
    }
    return used;
  }

  static String _structReadCall(BridgeSpec spec, String stName, String ptrVar) => '_nitroReadStruct$stName(_m, $ptrVar)';

  // ── Nullable variant encoders ─────────────────────────────────────────────

  static void _emitVariantNullableEncoders(CodeWriter w, BridgeSpec spec) {
    final used = <String>{};
    void addType(BridgeType t) {
      final base = t.name.replaceFirst('?', '');
      if (spec.isVariantName(base) && (t.name.endsWith('?') || (spec.variantByName(base)!.cases.any((c) => c.name.toLowerCase() == 'null')))) {
        used.add(base);
      }
    }

    for (final f in spec.functions) {
      addType(f.returnType);
      for (final p in f.params) {
        addType(p.type);
      }
    }
    for (final p in spec.properties) {
      addType(p.type);
    }

    for (final name in used) {
      final variant = spec.variantByName(name)!;
      final nullTag = variant.cases.indexWhere((c) => c.name.toLowerCase() == 'null');
      w.line('Uint8List _nitroEncodeVariantNullable$name($name? value) {');
      w.line('  final w = RecordWriter();');
      if (nullTag >= 0) {
        w.line('  if (value == null) {');
        w.line('    w.writeInt8($nullTag);');
        w.line('  } else {');
        w.line('    value.writeFields(w);');
        w.line('  }');
      } else {
        w.line("  if (value == null) { throw ArgumentError('$name has no null case'); }");
        w.line('  value.writeFields(w);');
      }
      w.line('  return w.takeFramedBytes();');
      w.line('}');
      w.blankLine();
    }
  }

  // ── Tuple codecs ──────────────────────────────────────────────────────────

  static void _emitTupleCodecs(CodeWriter w, BridgeSpec spec) {
    final tuples = spec.localRecordTypes.where((r) => r.isTuple).toList();
    for (final rt in tuples) {
      final fieldTypes = rt.fields
          .map((f) {
            if (f.isNullable) return '${f.dartType.replaceFirst("?", "")}?';
            return f.dartType;
          })
          .join(', ');
      final tupleType = '($fieldTypes)';

      w.line('$tupleType _nitroDecodeTuple_${rt.name}(Uint8List framed) {');
      w.line('  final r = RecordReader.fromFramedBytes(framed);');
      final reads = rt.fields.map((f) => _tupleFieldReadExpr(spec, f)).join(', ');
      w.line('  return ($reads);');
      w.line('}');
      w.blankLine();

      w.line('Uint8List _nitroEncodeTuple_${rt.name}($tupleType v) {');
      w.line('  final w = RecordWriter();');
      for (var i = 0; i < rt.fields.length; i++) {
        _emitTupleFieldWrite(w, spec, rt.fields[i], i + 1);
      }
      w.line('  return w.takeFramedBytes();');
      w.line('}');
      w.blankLine();
    }
  }

  static String _tupleFieldReadExpr(BridgeSpec spec, BridgeRecordField f) {
    final base = f.dartType.replaceFirst('?', '');
    String inner;
    switch (f.kind) {
      case RecordFieldKind.primitive:
        inner = switch (base) {
          'int' => 'r.readInt()',
          'double' => 'r.readDouble()',
          'bool' => 'r.readBool()',
          'String' => 'r.readString()',
          'Uint8List' => 'r.readBlob()',
          _ => 'r.readInt()',
        };
      case RecordFieldKind.enumValue:
        inner = 'r.readInt().to$base()';
      case RecordFieldKind.recordObject || RecordFieldKind.struct:
        inner = '${base}RecordExt.fromReader(r)';
      case RecordFieldKind.listPrimitive:
        final item = f.itemTypeName ?? 'int';
        final read = switch (item) {
          'int' => 'r.readInt()',
          'double' => 'r.readDouble()',
          'bool' => 'r.readBool()',
          'String' => 'r.readString()',
          _ => 'r.readInt()',
        };
        inner = 'List.generate(r.readInt32(), (_) => $read)';
      case RecordFieldKind.listEnumValue:
        inner = 'List.generate(r.readInt32(), (_) => r.readInt().to${f.itemTypeName}())';
      case RecordFieldKind.listRecordObject:
        inner = 'List.generate(r.readInt32(), (_) => ${f.itemTypeName}RecordExt.fromReader(r))';
      case RecordFieldKind.typedData:
        inner = base == 'Uint8List' ? 'r.readBlob()' : '$base.view(r.readBlob().buffer)';
    }
    if (f.isNullable) return 'r.readNullTag() ? null : $inner';
    return inner;
  }

  static void _emitTupleFieldWrite(CodeWriter w, BridgeSpec spec, BridgeRecordField f, int index) {
    final accessor = 'v.\$$index';
    final base = f.dartType.replaceFirst('?', '');
    if (f.isNullable) {
      w.line('  w.writeNullTag($accessor == null);');
      w.line('  if ($accessor != null) {');
      w.line('    ${_tupleFieldWriteStmt(spec, f, '$accessor!', base)}');
      w.line('  }');
      return;
    }
    w.line('  ${_tupleFieldWriteStmt(spec, f, accessor, base)}');
  }

  static String _tupleFieldWriteStmt(BridgeSpec spec, BridgeRecordField f, String expr, String base) {
    switch (f.kind) {
      case RecordFieldKind.primitive:
        return switch (base) {
          'int' => 'w.writeInt($expr);',
          'double' => 'w.writeDouble($expr);',
          'bool' => 'w.writeBool($expr);',
          'String' => 'w.writeString($expr);',
          'Uint8List' => 'w.writeBlob($expr);',
          _ => 'w.writeInt($expr);',
        };
      case RecordFieldKind.enumValue:
        return 'w.writeInt($expr.nativeValue);';
      case RecordFieldKind.recordObject || RecordFieldKind.struct:
        return '$expr.writeFields(w);';
      case RecordFieldKind.listPrimitive:
        final item = f.itemTypeName ?? 'int';
        final writeCall = switch (item) {
          'int' => 'w.writeInt(e)',
          'double' => 'w.writeDouble(e)',
          'bool' => 'w.writeBool(e)',
          'String' => 'w.writeString(e)',
          _ => 'w.writeInt(e)',
        };
        return 'w.writeInt32($expr.length); for (final e in $expr) { $writeCall; }';
      case RecordFieldKind.listEnumValue:
        return 'w.writeInt32($expr.length); for (final e in $expr) { w.writeInt(e.nativeValue); }';
      case RecordFieldKind.listRecordObject:
        return 'w.writeInt32($expr.length); for (final e in $expr) { e.writeFields(w); }';
      case RecordFieldKind.typedData:
        final toBytes = base == 'Uint8List' ? expr : '$expr.buffer.asUint8List()';
        return 'w.writeBlob($toBytes);';
    }
  }

  // ── Map codecs ────────────────────────────────────────────────────────────

  static void _emitMapCodecs(CodeWriter w, BridgeSpec spec) {
    final mapTypes = <String>{};
    void addType(BridgeType t) {
      final base = t.name.replaceFirst('?', '');
      if (t.isMap && !t.isAnyMap) mapTypes.add(base);
    }

    for (final f in spec.functions) {
      addType(f.returnType);
      for (final p in f.params) {
        addType(p.type);
      }
    }
    for (final p in spec.properties) {
      addType(p.type);
    }

    for (final mapType in mapTypes) {
      final (keyType, valueType) = _mapKeyValue(mapType);
      final suffix = _mapHelperSuffix(spec, mapType);
      final isIntKey = keyType != 'String';
      final keyIsEnum = spec.isEnumName(keyType);

      // ── Encode ──
      w.line('Uint8List _nitroEncodeMapBytes$suffix($mapType m) {');
      w.line('  final w = RecordWriter();');
      w.line('  w.writeInt32(m.length);');
      w.line('  for (final e in m.entries) {');
      if (!isIntKey) {
        w.line('    w.writeString(e.key);');
      } else if (keyIsEnum) {
        w.line('    ${_intKeyWrite(spec, keyType, 'e.key.nativeValue')}');
      } else {
        w.line('    ${_intKeyWrite(spec, keyType, 'e.key')}');
      }
      // String-key maps tag every value; int-key maps are tag-less.
      _emitMapValueWrite(w, spec, valueType, tagged: !isIntKey);
      w.line('  }');
      w.line('  return w.takeFramedBytes();');
      w.line('}');
      w.blankLine();

      // ── Decode ──
      w.line('$mapType _nitroDecodeMapBytes$suffix(Uint8List framed) {');
      w.line('  final r = RecordReader.fromFramedBytes(framed);');
      w.line('  final count = r.readInt32();');
      w.line('  final result = <$keyType, $valueType>{};');
      w.line('  for (var i = 0; i < count; i++) {');
      if (!isIntKey) {
        w.line('    final key = r.readString();');
      } else if (keyIsEnum) {
        w.line('    final key = ${_intKeyRead(spec, keyType)}.to$keyType();');
      } else {
        w.line('    final key = ${_intKeyRead(spec, keyType)};');
      }
      _emitMapValueRead(w, spec, valueType, tagged: !isIntKey);
      w.line('    result[key] = v;');
      w.line('  }');
      w.line('  return result;');
      w.line('}');
      w.blankLine();
    }
  }

  /// Map value wire, mirroring the native helpers exactly.
  ///
  /// String-key maps TAG every value (1=int64, 2=f64, 3=bool, 4=string,
  /// 5=record/variant blob); int-key maps are tag-less. Record/variant blobs
  /// are `[4B blob_len][framed bytes]` — the framed bytes keep their own
  /// inner 4B length prefix.
  static void _emitMapValueWrite(CodeWriter w, BridgeSpec spec, String valueType, {required bool tagged}) {
    void tag(int t) {
      if (tagged) w.line('    w.writeInt8($t);');
    }

    if (valueType == 'int') {
      tag(1);
      w.line('    w.writeInt(e.value);');
    } else if (valueType == 'double') {
      tag(2);
      w.line('    w.writeDouble(e.value);');
    } else if (valueType == 'bool') {
      tag(3);
      w.line('    w.writeBool(e.value);');
    } else if (valueType == 'String') {
      tag(4);
      w.line('    w.writeString(e.value);');
    } else if (spec.isEnumName(valueType)) {
      tag(1);
      w.line('    w.writeInt(e.value.nativeValue);');
    } else if (spec.isRecordName(valueType) || spec.isVariantName(valueType)) {
      tag(5);
      w.line('    w.writeBlob(_nitroEncodeFramed((rw) => e.value.writeFields(rw)));');
    } else {
      tag(4);
      w.line('    w.writeString(jsonEncode(e.value));');
    }
  }

  static void _emitMapValueRead(CodeWriter w, BridgeSpec spec, String valueType, {required bool tagged}) {
    if (tagged) w.line('    r.readInt8(); // skip the value type tag');
    if (valueType == 'int') {
      w.line('    final v = r.readInt();');
    } else if (valueType == 'double') {
      w.line('    final v = r.readDouble();');
    } else if (valueType == 'bool') {
      w.line('    final v = r.readBool();');
    } else if (valueType == 'String') {
      w.line('    final v = r.readString();');
    } else if (spec.isEnumName(valueType)) {
      w.line('    final v = r.readInt().to$valueType();');
    } else if (spec.isRecordName(valueType)) {
      w.line('    final v = ${valueType}RecordExt.fromReader(RecordReader.fromFramedBytes(r.readBlob()));');
    } else if (spec.isVariantName(valueType)) {
      w.line('    final v = ${valueType}VariantExt.fromReader(RecordReader.fromFramedBytes(r.readBlob()));');
    } else {
      w.line('    final v = jsonDecode(r.readString()) as $valueType;');
    }
  }

  static String _intKeyWrite(BridgeSpec spec, String keyType, String expr) {
    final size = _intKeyByteSizeWeb(spec, keyType);
    return switch (size) {
      1 => 'w.writeInt8($expr);',
      4 => 'w.writeInt32($expr);',
      _ => 'w.writeInt($expr);',
    };
  }

  static String _intKeyRead(BridgeSpec spec, String keyType) {
    final size = _intKeyByteSizeWeb(spec, keyType);
    return switch (size) {
      1 => 'r.readInt8()',
      4 => 'r.readInt32()',
      _ => 'r.readInt()',
    };
  }

  static int _intKeyByteSizeWeb(BridgeSpec spec, String keyType) {
    if (spec.isEnumName(keyType)) return 8;
    return switch (keyType) {
      'int8' || 'uint8' => 1,
      'int16' || 'uint16' => 2,
      'int32' || 'uint32' => 4,
      _ => 8,
    };
  }

  static (String, String) _mapKeyValue(String mapTypeName) {
    final lt = mapTypeName.indexOf('<');
    final gt = mapTypeName.lastIndexOf('>');
    if (lt < 0 || gt < 0) return ('String', 'dynamic');
    final inner = mapTypeName.substring(lt + 1, gt);
    final comma = inner.indexOf(',');
    if (comma < 0) return ('String', 'dynamic');
    return (inner.substring(0, comma).trim(), inner.substring(comma + 1).trim());
  }

  static String _mapHelperSuffix(BridgeSpec spec, String mapTypeName) {
    final (k, v) = _mapKeyValue(mapTypeName);
    String capName(String s) {
      final cleaned = s.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
      return cleaned.isEmpty ? 'Dynamic' : cleaned[0].toUpperCase() + cleaned.substring(1);
    }

    return '${capName(k)}${capName(v)}';
  }

  // ── Callback helpers ──────────────────────────────────────────────────────

  static void _emitCallbackHelpers(CodeWriter w, BridgeSpec spec) {
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

  static void _emitOneCallbackHelper(CodeWriter w, BridgeSpec spec, BridgeParam p, String ownerFn) {
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
      final base = t.name.replaceFirst('?', '');
      final nullable = t.name.endsWith('?');
      String conv;
      if (base == 'int' || base == 'uint64') {
        conv = 'dartI64(a$i)';
      } else if (base == 'DateTime') {
        conv = 'DateTime.fromMillisecondsSinceEpoch(dartI64(a$i))';
      } else if (base == 'double' || base == 'float') {
        conv = '(a$i! as JSNumber).toDartDouble';
      } else if (base == 'bool') {
        conv = '(a$i! as JSNumber).toDartInt != 0';
      } else if (base == 'String') {
        // char* — borrowed for the duration of the call; malloc'd by the
        // bridge and freed by Dart on native, so mirror: read then free.
        conv = nullable ? _freeingStringConv('a$i', nullable: true) : _freeingStringConv('a$i', nullable: false);
      } else if (spec.isEnumName(base)) {
        conv = 'dartI64(a$i).to$base()';
      } else if (spec.isStructName(base)) {
        conv = '(() { final _p = dartI64(a$i); final _v = _nitroReadStruct$base(_module, _p); _module.nitroFree(_p); return _v; })()';
      } else if (spec.isRecordName(base) || spec.isVariantName(base) || t.isMap || t.isAnyMap) {
        final decode = _framedDecodeExpr(spec, t, '_framed');
        final nullPart = nullable ? 'if (_p == 0) return null; ' : '';
        conv = '(() { final _p = dartI64(a$i); ${nullPart}final _framed = _module.readFramed(_p); _module.nitroFree(_p); return $decode; })()';
      } else {
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
    if (retName == 'void') {
      retConv = '';
    } else if (retName == 'int' || retName == 'uint64') {
      retConv = 'return jsI64(_r);';
    } else if (retName == 'double') {
      retConv = 'return _r.toJS;';
    } else if (retName == 'bool') {
      retConv = 'return (_r ? 1 : 0).toJS;';
    } else if (retName == 'String') {
      // The bridge frees callback string returns with the module free — copy
      // into a nitro_alloc'd buffer.
      retConv = 'return _module.nitroAllocCString(_r).toJS;';
    } else if (retName == 'DateTime') {
      retConv = 'return jsI64(_r.millisecondsSinceEpoch);';
    } else if (spec.isEnumName(retName)) {
      retConv = 'return jsI64(_r.nativeValue);';
    } else if (spec.isRecordName(retName) || spec.isVariantName(retName)) {
      // Framed blob, same shape as a record return: encode into a module
      // allocation and hand back the pointer. The bridge frees it with the
      // module free after reading, mirroring the native contract.
      retConv = 'return _module.nitroAllocBytes(_nitroEncodeFramed((w) => _r.writeFields(w))).toJS;';
    } else {
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

  static String _freeingStringConv(String jsVar, {required bool nullable}) {
    if (nullable) {
      return '(() { final _p = dartI64($jsVar); if (_p == 0) return null; final _s = _module.readCString(_p); _module.nitroFree(_p); return _s; })()';
    }
    return '(() { final _p = dartI64($jsVar); final _s = _module.readCString(_p); _module.nitroFree(_p); return _s; })()';
  }
}
