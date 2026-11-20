import '../../../bridge_spec.dart';
import '../dart/entry_point_shared.dart';
import '../../code_writer.dart';
import '../../generator_metadata.dart';
import '../../../map_wire.dart';
import '../../../wire_kind.dart';
import '../../record_generator.dart' show dartWrappedResultRead;
import '../../struct_generator.dart';

part 'web_bridge/web_members.dart';
part 'web_bridge/web_arguments.dart';
part 'web_bridge/web_returns.dart';
part 'web_bridge/web_callbacks.dart';
part 'web_bridge/web_structs.dart';
part 'web_bridge/web_codecs.dart';

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
///
/// This file assembles the library; the emitters are in `web_bridge/`:
/// `web_members.dart` (methods, properties, streams), `web_arguments.dart` and
/// `web_returns.dart` (values in and out of the module heap),
/// `web_callbacks.dart`, `web_structs.dart` (wasm32 struct layout) and
/// `web_codecs.dart` (tuples, maps, nullable variants).
class WebBridgeGenerator {
  static String generate(BridgeSpec spec) {
    if (!spec.targetsWeb) {
      return '${generatedFileHeader('//', sourceUri: spec.sourceUri, sourceHash: spec.sourceHash)}\n'
          '// Web not targeted — no dart:js_interop bridge generated.\n';
    }

    final w = CodeWriter();
    w.raw(generatedFileHeader('//', sourceUri: spec.sourceUri, sourceHash: spec.sourceHash));

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
    // Shared types (and their pure codecs) from other .native.dart files.
    for (final imp in spec.importedSpecs) {
      w.line("import '${imp.uri}';");
    }
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
    emitEntryPointWebStubs(w, spec);
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
    w.line('    if (NitroConfig.instance.effectiveLogLevel == NitroLogLevel.verbose) {');
    w.line("      NitroRuntime.logLifecycle('$className', 'web instance created (key=\$_key, id=\$_instanceId)');");
    w.line('    }');
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
    w.line('    if (NitroConfig.instance.effectiveLogLevel == NitroLogLevel.verbose) {');
    w.line("      NitroRuntime.logLifecycle('$className', 'web instance disposed (key=\$_key)');");
    w.line('    }');
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

  // ══ Methods ═════════════════════════════════════════════════════════════

  // ══ Properties ══════════════════════════════════════════════════════════

  // ══ Streams ═════════════════════════════════════════════════════════════

  // ══ Argument encoding ═══════════════════════════════════════════════════

  // ══ Return decoding ═════════════════════════════════════════════════════

  // ══ Callbacks ═══════════════════════════════════════════════════════════

  // ══ Helper section (module-level, emitted once per file) ═════════════════

  // ── Struct codecs (wasm32 C layout) ───────────────────────────────────────

  // ── Nullable variant encoders ─────────────────────────────────────────────

  // ── Tuple codecs ──────────────────────────────────────────────────────────

  // ── Map codecs ────────────────────────────────────────────────────────────

  // ── Callback helpers ──────────────────────────────────────────────────────

}
