import '../../../bridge_spec.dart';
import '../../code_writer.dart';
import '../../generator_metadata.dart';
import '../../../map_wire.dart';
import '../../../wire_kind.dart';
import '../../struct_generator.dart';

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
      _emitOverride(w, func.returnType);
      // `async` so a checkDisposed() throw rejects the future instead of
      // blowing up at the call site (matches the FFI emitter).
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
      switch (baseItemType) {
        case 'double':
          itemExpr = 'Int64List.fromList([batch[i]]).buffer.asFloat64List()[0]';
        case 'bool':
          itemExpr = 'batch[i] != 0';
        case _ when spec.isEnumName(baseItemType):
          itemExpr = 'batch[i].to$baseItemType()';
        default:
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
        // ELEMENT count: C multiplies by sizeof(T) to get bytes.
        args.add(p.type.name.endsWith('?') ? '(${p.name}?.length ?? 0).toJS' : '${p.name}.length.toJS');
      }
    }
    if (includeErr) args.add('_err.ptr.toJS');
    return args;
  }

  static bool _paramNeedsArena(BridgeSpec spec, BridgeType t) {
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

  /// The JS argument expression for one parameter, mirroring the C signature.
  static String _jsArgExpr(BridgeSpec spec, BridgeType t, String name, String ownerFn) {
    final base = _bare(t.name);
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
      // Pack takes the arena: a TypedData field stores a pointer.
      return nullable ? '($name == null ? 0 : arena.copyIn(_nitroPackStruct$base(_m, arena, $name))).toJS' : 'arena.copyIn(_nitroPackStruct$base(_m, arena, $name)).toJS';
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
      return nullable ? '($name == null ? 0 : arena.copyIn(_nitroEncodeTuple_$base($name))).toJS' : 'arena.copyIn(_nitroEncodeTuple_$base($name)).toJS';
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
      return nullableItems ? 'RecordWriter.encodeNullableListBytes($name, (w, e) => $write)' : 'RecordWriter.encodeListBytes($name, (w, e) => $write)';
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
      return nullableItems ? 'RecordWriter.encodeNullableListBytes($name, (w, e) => $write)' : 'RecordWriter.encodeListBytes($name, (w, e) => $write)';
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
    final base = _bare(type.name);
    w.line('${indent}final _p = dartI64($resVar);');
    w.line('${indent}try {');
    final i2 = '$indent  ';
    w.line('${i2}final _tag = _m.readBytes(_p, 1)[0];');
    w.line('${i2}if (_tag != 0) {');
    // Explicit type argument: through an untyped callSync/callAsync closure a
    // bare NitroErr infers NitroErr<Object?> and fails callAsync's cast.
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
        _ => spec.isEnumName(base) ? '_r.readInt().to$base()' : (spec.isStructName(base) ? '${base}StructExt.fromReader(_r)' : '${base}RecordExt.fromReader(_r)'),
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
    final rtBase = _bare(rt);
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
    final base = _bare(type.name);
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
        return nullableItems ? 'RecordReader.decodeNullableListBytes($framedVar, (r) => $read)' : 'RecordReader.decodeListBytes($framedVar, (r) => $read)';
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
        return nullableItems ? 'RecordReader.decodeNullableListBytes($framedVar, (r) => $read)' : 'RecordReader.decodeListBytes($framedVar, (r) => $read)';
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
  static String _callbackHelperName(String ownerFn, String paramName) => '_nitroWebCallback_${ownerFn}_$paramName';

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

  // ── Struct codecs (wasm32 C layout) ───────────────────────────────────────

  /// Field names treated as an explicit element-count companion for a
  /// zero-copy TypedData sibling. Mirrors struct_generator.dart — the two must
  /// agree or the web layout drifts from the C typedef.
  static const _kLenFieldNames = {'length', 'size', 'stride', 'bytelength', 'bytelen', 'len'};

  static bool _structNeedsSyntheticLen(BridgeStruct st, String field) {
    for (final c in ['${field}Length', '${field}Size']) {
      if (st.fields.any((f) => f.name == c && f.type.name == 'int')) return false;
    }
    return !st.fields.any((f) => _kLenFieldNames.contains(f.name) && f.type.name == 'int');
  }

  /// (size, align) of one struct field slot on wasm32. Pointers are 4/4;
  /// int64/double are 8/8; bool is 1/1. Null = not representable on web.
  static (int, int)? _fieldSlot(BridgeSpec spec, BridgeType t) {
    final base = _bare(t.name);
    return switch (base) {
      // Every pointer-shaped field is a 4-byte wasm32 slot: TypedData buffers
      // (`uint8_t*`), strings (`const char*`) and NESTED STRUCTS, which the C
      // typedef stores as `Nested*`, not inline.
      'String' => (4, 4),
      _ when t.isTypedData || spec.isStructName(base) => (4, 4),
      _ when spec.isEnumName(base) => (4, 4), // C enum field is int32_t
      'int' || 'uint64' || 'DateTime' || 'double' => (8, 8),
      'bool' => (1, 1),
      _ => null,
    };
  }

  /// Byte offsets for every slot plus the total size. Honours `st.packed`,
  /// which the C emitter turns into `#pragma pack(1)`: packed structs are
  /// tight, unpacked ones follow natural C alignment — each member starts at
  /// a multiple of its own alignment and the struct is rounded up to its
  /// strictest member. A
  /// zero-copy TypedData field occupies TWO slots — the pointer and, unless
  /// the spec declares a companion length field, a synthesized int64 count.
  /// Returns null when any field kind is not representable on web.
  static ({Map<String, int> at, Map<String, int> lenAt, Map<String, int> hasAt, int size})? _structLayout(BridgeSpec spec, BridgeStruct st) {
    final at = <String, int>{};
    final lenAt = <String, int>{};
    final hasAt = <String, int>{};
    var off = 0;
    var maxAlign = 1;
    for (final f in st.fields) {
      final slot = _fieldSlot(spec, f.type);
      if (slot == null) return null;
      final (sz, rawAl) = slot;
      final al = st.packed ? 1 : rawAl;
      off = _alignUp(off, al);
      at[f.name] = off;
      off += sz;
      if (al > maxAlign) maxAlign = al;
      if (f.type.isTypedData && _structNeedsSyntheticLen(st, f.name)) {
        off = _alignUp(off, st.packed ? 1 : 8); // int64_t <name>Length
        lenAt[f.name] = off;
        off += 8;
        if (!st.packed && maxAlign < 8) maxAlign = 8;
      }
      // int8_t <name>HasValue — the presence byte for a nullable scalar/enum.
      // Alignment 1, so no padding of its own, but it shifts everything after.
      if (StructGenerator.needsHasValue(f, spec.structs.map((x) => x.name).toSet())) {
        hasAt[f.name] = off;
        off += 1;
      }
    }
    return (at: at, lenAt: lenAt, hasAt: hasAt, size: _alignUp(off, maxAlign));
  }

  static int _alignUp(int v, int a) => (v + a - 1) & ~(a - 1);

  static void _emitStructCodecs(CodeWriter w, BridgeSpec spec) {
    final used = _usedStructs(spec);
    for (final stName in used) {
      final st = spec.structByName(stName);
      if (st == null) continue;
      final layout = _structLayout(spec, st);

      // Pack (Dart → heap bytes). Takes the arena because a TypedData field
      // stores a POINTER into module memory, not the bytes inline.
      w.line('Uint8List _nitroPackStruct$stName(NitroWasmModule m, WasmArena arena, $stName v) {');
      if (layout == null) {
        w.line("  throw UnsupportedError('$stName: has a field kind with no wasm32 struct layout on web');");
        w.line('}');
        w.blankLine();
        continue;
      }
      w.line('  final out = Uint8List(${layout.size});');
      w.line('  final bd = ByteData.sublistView(out);');
      for (final f in st.fields) {
        final base = _bare(f.type.name);
        final off = layout.at[f.name]!;
        // A nullable scalar/enum carries its value in the normal slot plus a
        // synthesized presence byte; the slot is zeroed when absent.
        final hasOff = layout.hasAt[f.name];
        if (hasOff != null) {
          final zero = base == 'double' || base == 'float' ? '0.0' : '0';
          final payload = switch (base) {
            'bool' => '(v.${f.name}! ? 1 : 0)',
            _ when spec.isEnumName(base) => 'v.${f.name}!.nativeValue',
            _ => 'v.${f.name}!',
          };
          w.line('  bd.setUint8($hasOff, v.${f.name} == null ? 0 : 1);');
          w.line('  ${_structScalarWrite(spec, base, off, 'v.${f.name} == null ? $zero : $payload')}');
          continue;
        }
        switch (base) {
          case _ when f.type.isTypedData:
            final bytes = base == 'Uint8List' ? 'v.${f.name}' : 'v.${f.name}.buffer.asUint8List(v.${f.name}.offsetInBytes, v.${f.name}.lengthInBytes)';
            w.line('  bd.setUint32($off, arena.copyIn($bytes), Endian.little);');
            final lenOff = layout.lenAt[f.name];
            if (lenOff != null) w.line('  setInt64LE(bd, $lenOff, v.${f.name}.length);');
          case 'String':
            final e = f.type.name.endsWith('?') ? "v.${f.name} == null ? 0 : arena.cString(v.${f.name}!)" : 'arena.cString(v.${f.name})';
            w.line('  bd.setUint32($off, $e, Endian.little);');
          case _ when spec.isStructName(base):
            final e = f.type.name.endsWith('?') ? "v.${f.name} == null ? 0 : arena.copyIn(_nitroPackStruct$base(m, arena, v.${f.name}!))" : 'arena.copyIn(_nitroPackStruct$base(m, arena, v.${f.name}))';
            w.line('  bd.setUint32($off, $e, Endian.little);');
          case _ when spec.isEnumName(base):
            w.line('  bd.setInt32($off, v.${f.name}.nativeValue, Endian.little);');
          case 'int' || 'uint64':
            w.line('  setInt64LE(bd, $off, v.${f.name});');
          case 'DateTime':
            w.line('  setInt64LE(bd, $off, v.${f.name}.millisecondsSinceEpoch);');
          case 'double':
            w.line('  bd.setFloat64($off, v.${f.name}, Endian.little);');
          default:
            w.line('  bd.setUint8($off, v.${f.name} ? 1 : 0);');
        }
      }
      w.line('  return out;');
      w.line('}');
      w.blankLine();

      // Read (heap offset → Dart value).
      w.line('$stName _nitroReadStruct$stName(NitroWasmModule m, int ptr) {');
      w.line('  final bd = ByteData.sublistView(m.readBytes(ptr, ${layout.size}));');
      final args = <String>[];
      for (final f in st.fields) {
        final base = _bare(f.type.name);
        final off = layout.at[f.name]!;
        String expr;
        final hasOff = layout.hasAt[f.name];
        if (hasOff != null) {
          final decoded = switch (base) {
            'bool' => 'bd.getUint8($off) != 0',
            _ when spec.isEnumName(base) => 'bd.getInt32($off, Endian.little).to$base()',
            'double' || 'float' => 'bd.getFloat64($off, Endian.little)',
            _ => 'getInt64LE(bd, $off)',
          };
          args.add('${f.name}: bd.getUint8($hasOff) != 0 ? $decoded : null');
          continue;
        }
        switch (base) {
          case _ when f.type.isTypedData:
            final elem = _typedDataElementSizeWeb(base);
            final synthLen = layout.lenAt[f.name];
            final lenExpr = synthLen != null ? 'getInt64LE(bd, $synthLen)' : 'getInt64LE(bd, ${layout.at[_structCompanionLen(st, f.name)!]!})';
            w.line('  final _p${f.name} = bd.getUint32($off, Endian.little);');
            w.line('  final _n${f.name} = $lenExpr;');
            final read = 'm.readBytes(_p${f.name}, _n${f.name} * $elem)';
            expr = base == 'Uint8List' ? '(_p${f.name} == 0 ? Uint8List(0) : $read)' : '(_p${f.name} == 0 ? $base(0) : ${_typedDataViewExpr(base, '_b${f.name}')})';
            if (base != 'Uint8List') {
              w.line('  final _b${f.name} = _p${f.name} == 0 ? Uint8List(0) : $read;');
            }
          case 'String':
            final p = 'bd.getUint32($off, Endian.little)';
            expr = f.type.name.endsWith('?') ? '(() { final _p = $p; return _p == 0 ? null : m.readCString(_p); })()' : "(() { final _p = $p; return _p == 0 ? '' : m.readCString(_p); })()";
          case _ when spec.isStructName(base):
            final p = 'bd.getUint32($off, Endian.little)';
            expr = f.type.name.endsWith('?') ? '(() { final _p = $p; return _p == 0 ? null : _nitroReadStruct$base(m, _p); })()' : '_nitroReadStruct$base(m, $p)';
          case _ when spec.isEnumName(base):
            expr = 'bd.getInt32($off, Endian.little).to$base()';
          case 'int' || 'uint64':
            expr = 'getInt64LE(bd, $off)';
          case 'DateTime':
            expr = 'DateTime.fromMillisecondsSinceEpoch(getInt64LE(bd, $off))';
          case 'double':
            expr = 'bd.getFloat64($off, Endian.little)';
          default:
            expr = 'bd.getUint8($off) != 0';
        }
        args.add('${f.name}: $expr');
      }
      w.line('  return $stName(${args.join(', ')});');
      w.line('}');
      w.blankLine();
    }
  }

  /// The spec-declared companion element-count field for [field], or null.
  static String? _structCompanionLen(BridgeStruct st, String field) {
    for (final c in ['${field}Length', '${field}Size']) {
      if (st.fields.any((f) => f.name == c && f.type.name == 'int')) return c;
    }
    for (final f in st.fields) {
      if (_kLenFieldNames.contains(f.name) && f.type.name == 'int') return f.name;
    }
    return null;
  }

  static String _typedDataViewExpr(String dartType, String bytesVar) => '${_typedDataViewCtor(dartType)}($bytesVar.buffer, $bytesVar.offsetInBytes, $bytesVar.lengthInBytes ~/ ${_typedDataElementSizeWeb(dartType)})';

  static String _typedDataViewCtor(String dartType) => '$dartType.view';

  static Set<String> _usedStructs(BridgeSpec spec) {
    final used = <String>{};
    void addType(BridgeType t) {
      final base = _bare(t.name);
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
    // Transitive: a struct reached only as another struct's field still needs
    // its codec emitted. The set doubles as the cycle guard.
    var frontier = used.toList();
    while (frontier.isNotEmpty) {
      final next = <String>[];
      for (final name in frontier) {
        for (final f in spec.structByName(name)?.fields ?? const <BridgeField>[]) {
          final b = _bare(f.type.name);
          if (spec.isStructName(b) && used.add(b)) next.add(b);
        }
      }
      frontier = next;
    }
    return used;
  }

  static String _structReadCall(BridgeSpec spec, String stName, String ptrVar) => '_nitroReadStruct$stName(_m, $ptrVar)';

  // ── Nullable variant encoders ─────────────────────────────────────────────

  static void _emitVariantNullableEncoders(CodeWriter w, BridgeSpec spec) {
    final used = <String>{};
    void addType(BridgeType t) {
      final base = _bare(t.name);
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
    final base = _bare(f.dartType);
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
    final base = _bare(f.dartType);
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
        // Bound to the VIEW: a shared backing buffer would otherwise be
        // serialised whole (see the struct codec, which already does this).
        final toBytes = base == 'Uint8List' ? expr : '$expr.buffer.asUint8List($expr.offsetInBytes, $expr.lengthInBytes)';
        return 'w.writeBlob($toBytes);';
    }
  }

  // ── Map codecs ────────────────────────────────────────────────────────────

  static void _emitMapCodecs(CodeWriter w, BridgeSpec spec) {
    final mapTypes = <String>{};
    void addType(BridgeType t) {
      final base = _bare(t.name);
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
  /// String-key maps TAG every value (0=null, 1=int64, 2=f64, 3=bool,
  /// 4=string, 5=record/variant blob); int-key maps are tag-less. Record/variant blobs
  /// are `[4B blob_len][framed bytes]` — the framed bytes keep their own
  /// inner 4B length prefix.
  static void _emitMapValueWrite(CodeWriter w, BridgeSpec spec, String valueType, {required bool tagged}) {
    void tag(int t) {
      if (tagged) w.line('    w.writeInt8($t);');
    }

    // Bound to a local: `e.value` is a public getter, which Dart will not
    // promote to non-null after the guard.
    var valueExpr = 'e.value';
    if (valueType.endsWith('?')) {
      w.line('    final _v = e.value;');
      w.line('    if (_v == null) { w.writeInt8(${MapValueWire.nul.tag}); continue; }');
      valueType = valueType.substring(0, valueType.length - 1);
      valueExpr = '_v';
    }
    tag(_wireOf(spec, valueType).tag);
    switch (valueType) {
      case 'int':
        w.line('    w.writeInt($valueExpr);');
      case 'double':
        w.line('    w.writeDouble($valueExpr);');
      case 'bool':
        w.line('    w.writeBool($valueExpr);');
      case 'String':
        w.line('    w.writeString($valueExpr);');
      case final t when spec.isEnumName(t):
        w.line('    w.writeInt($valueExpr.nativeValue);');
      case final t when spec.isRecordName(t) || spec.isVariantName(t):
        w.line('    w.writeBlob(_nitroEncodeFramed((rw) => $valueExpr.writeFields(rw)));');
      default:
        w.line('    w.writeString(jsonEncode($valueExpr));');
    }
  }

  static void _emitMapValueRead(CodeWriter w, BridgeSpec spec, String valueType, {required bool tagged}) {
    if (valueType.endsWith('?')) {
      w.line('    if (r.readInt8() == ${MapValueWire.nul.tag}) { result[key] = null; continue; }');
      valueType = valueType.substring(0, valueType.length - 1);
    } else if (tagged) {
      w.line('    r.readInt8(); // skip the value type tag');
    }
    switch (valueType) {
      case 'int':
        w.line('    final v = r.readInt();');
      case 'double':
        w.line('    final v = r.readDouble();');
      case 'bool':
        w.line('    final v = r.readBool();');
      case 'String':
        w.line('    final v = r.readString();');
      case final t when spec.isEnumName(t):
        w.line('    final v = r.readInt().to$t();');
      case final t when spec.isRecordName(t):
        w.line('    final v = ${t}RecordExt.fromReader(RecordReader.fromFramedBytes(r.readBlob()));');
      case final t when spec.isVariantName(t):
        w.line('    final v = ${t}VariantExt.fromReader(RecordReader.fromFramedBytes(r.readBlob()));');
      default:
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

  /// Strips a TRAILING '?' only. replaceFirst would eat the inner one in
  /// `Map<String, int?>` and silently drop the value's nullability.
  static MapValueWire _wireOf(BridgeSpec spec, String valueType) => mapValueWireOf(
    valueType,
    isEnum: spec.isEnumName,
    isRecord: spec.isRecordName,
    isVariant: spec.isVariantName,
  );

  /// Emits the scalar write for a struct slot, matching the non-nullable
  /// arms below — used by the nullable path, which supplies its own value
  /// expression.
  static String _structScalarWrite(BridgeSpec spec, String base, int off, String value) => switch (base) {
    _ when spec.isEnumName(base) => 'bd.setInt32($off, $value, Endian.little);',
    'int' || 'uint64' || 'int64' || 'DateTime' => 'setInt64LE(bd, $off, $value);',
    'double' || 'float' => 'bd.setFloat64($off, $value, Endian.little);',
    _ => 'bd.setUint8($off, $value);',
  };

  static String _bare(String t) => t.endsWith('?') ? t.substring(0, t.length - 1) : t;

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

    return '${capName(k)}${capName(v)}${v.endsWith('?') ? 'Nullable' : ''}';
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
      case _ when spec.isRecordName(retName) || spec.isVariantName(retName):
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

  static String _freeingStringConv(String jsVar, {required bool nullable}) {
    if (nullable) {
      return '(() { final _p = dartI64($jsVar); if (_p == 0) return null; final _s = _module.readCString(_p); _module.nitroFree(_p); return _s; })()';
    }
    return '(() { final _p = dartI64($jsVar); final _s = _module.readCString(_p); _module.nitroFree(_p); return _s; })()';
  }
}
