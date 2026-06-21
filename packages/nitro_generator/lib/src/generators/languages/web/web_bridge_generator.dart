import '../../../bridge_spec.dart';
import '../../code_writer.dart';
import '../../enum_generator.dart';
import '../../generator_metadata.dart';
import '../../record_generator.dart';
import '../../struct_generator.dart';

/// PX18 — Web bridge generator.
///
/// Emits a `*.web.bridge.g.dart` file for specs that include
/// `web: NativeImpl.wasm`. The output uses `dart:js_interop` `@JS()`
/// external declarations to call into a compiled Nitro WASM module,
/// and provides a web implementation class that satisfies the same
/// abstract interface as the native FFI implementation.
///
/// ### WASM symbol convention
/// Each C bridge symbol `${lib}_${method}` is exported from the WASM
/// module under the same name. The `@JS('nitro_${lib}_${method}')`
/// annotation maps the Dart external to that global WASM export.
///
/// ### Usage in a web-targeting spec
/// ```dart
/// @NitroModule(
///   ios: NativeImpl.swift,
///   android: NativeImpl.kotlin,
///   web: NativeImpl.wasm,
/// )
/// abstract class Camera extends HybridObject {
///   static Camera _instance = _createPlatformInstance(); // from .g.dart
///   static Camera get instance => _instance;
///   double add(double a, double b);
/// }
/// ```
///
/// The companion `.g.dart` (DartFfiGenerator) emits a
/// `_createPlatformInstance()` function that routes to the web impl when
/// `dart.library.js_interop` is present.
class WebBridgeGenerator {
  static String generate(BridgeSpec spec) {
    // Only emit a web bridge when the spec actually targets web.
    if (!spec.targetsWeb) {
      return '${generatedFileHeader('//', sourceUri: spec.sourceUri)}\n'
          '// Web not targeted — no dart:js_interop bridge generated.\n';
    }

    final writer = CodeWriter();
    writer.raw(generatedFileHeader('//', sourceUri: spec.sourceUri));

    // This is a standalone library (not a part file) because dart:js_interop
    // @JS() declarations must be at library scope, not inside part files.
    writer.line('@JS()');
    writer.line("library nitro_${spec.lib.replaceAll('-', '_')}_web;");
    writer.blankLine();
    writer.line('import \'dart:js_interop\';');
    // dart:convert needed for JSON-encoded Map<String,V> params
    if (spec.functions.any((f) => f.returnType.isMap || f.params.any((p) => p.type.isMap))) {
      writer.line('import \'dart:convert\';');
    }
    writer.blankLine();

    // Import the spec file to get the abstract class and types
    final specFile = spec.sourceUri.split('/').last;
    writer.line("// Import the abstract class and type extensions from the spec.");
    writer.line("// ignore: unused_import");
    writer.line("import '${specFile.replaceAll('.native.dart', '.g.dart')}';");
    writer.blankLine();

    final libStem = spec.lib.replaceAll('-', '_');
    final enumNames = spec.enums.map((e) => e.name).toSet();
    final structNames = spec.structs.map((s) => s.name).toSet();
    final recordNames = spec.recordTypes.map((r) => r.name).toSet();

    // ── Enum + struct extensions (same as FFI generator for type compat) ─────
    final enumExt = EnumGenerator.generateDartExtensions(spec);
    if (enumExt.isNotEmpty) {
      writer.line('// Type extensions (shared with native path)');
      writer.raw(enumExt);
    }
    final structExt = StructGenerator.generateDartExtensions(spec);
    if (structExt.isNotEmpty) writer.raw(structExt);
    final recordExt = RecordGenerator.generateDartExtensions(spec);
    if (recordExt.isNotEmpty) writer.raw(recordExt);

    if (spec.isTypeOnly) return writer.toString();

    // ── @JS() external declarations ──────────────────────────────────────────
    writer.line('// ── @JS() external declarations — map to WASM module exports ─');
    writer.blankLine();

    for (final func in spec.functions) {
      if (func.isNativeAsync) {
        // @NitroNativeAsync on web would require Dart_PostCObject which isn't
        // available in WASM. Emit a throw-stub instead.
        continue;
      }
      // Use func.cSymbol (C snake_case) for the WASM export name.
      // The WASM module exports symbols by their C name, not Dart camelCase.
      // Dart identifier uses the same snake_case name with a _js suffix.
      final jsSym = func.cSymbol; // e.g. 'config_get_settings'
      final jsDartId = '_${jsSym}_js'; // e.g. '_config_get_settings_js'
      if (func.isAsync) {
        // Async functions: WASM calls are synchronous; wrap in Future.
        final jsParams = _jsFuncParams(func.params, enumNames, structNames, recordNames);
        final jsRet = _jsReturnType(func.returnType, enumNames, structNames, recordNames);
        writer.line('@JS(\'$jsSym\')');
        writer.line('external $jsRet $jsDartId($jsParams);');
        writer.blankLine();
      } else {
        final jsParams = _jsFuncParams(func.params, enumNames, structNames, recordNames);
        final jsRet = _jsReturnType(func.returnType, enumNames, structNames, recordNames);
        writer.line('@JS(\'$jsSym\')');
        writer.line('external $jsRet $jsDartId($jsParams);');
        writer.blankLine();
      }
    }

    for (final prop in spec.properties) {
      final jsRet = _jsPropType(prop.type, enumNames, structNames, recordNames);
      if (prop.hasGetter) {
        writer.line('@JS(\'nitro_${libStem}_get_${prop.dartName}\')');
        writer.line('external $jsRet _${libStem}_get_${prop.dartName}_js();');
        writer.blankLine();
      }
      if (prop.hasSetter) {
        final jsParam = _jsPropType(prop.type, enumNames, structNames, recordNames);
        writer.line('@JS(\'nitro_${libStem}_set_${prop.dartName}\')');
        writer.line('external void _${libStem}_set_${prop.dartName}_js($jsParam value);');
        writer.blankLine();
      }
    }

    // ── Web implementation class ─────────────────────────────────────────────
    writer.line('// ── Web implementation (dart:js_interop → WASM) ──────────────');
    writer.blankLine();
    writer.line(
      '/// Web implementation of [${spec.dartClassName}] via `dart:js_interop`.',
    );
    writer.line(
      '/// Do not instantiate directly; use [create${spec.dartClassName}WebInstance].',
    );
    writer.line(
      'final class _${spec.dartClassName}WebImpl extends ${spec.dartClassName} {',
    );
    writer.blankLine();

    // Methods
    for (final func in spec.functions) {
      writer.line('  @override');
      if (func.isNativeAsync) {
        // Emit a throw for NativeAsync on web
        final retType = 'Future<${func.returnType.name}>';
        final params = func.params.map((p) => '${p.type.name} ${p.name}').join(', ');
        writer.line('  $retType ${func.dartName}($params) {');
        writer.line("    throw UnsupportedError('${func.dartName}: @NitroNativeAsync is not supported on web. Use @nitroAsync instead.');");
        writer.line('  }');
      } else if (func.isAsync) {
        final retType = 'Future<${func.returnType.name}>';
        final params = func.params.map((p) => '${p.type.name} ${p.name}').join(', ');
        final callArgs = func.params.map((p) => _dartToJs(p.type, p.name, enumNames)).join(', ');
        // Use cSymbol-derived identifier to match the @JS() external above
        final jsId = '_${func.cSymbol}_js';
        final jsCall = '$jsId($callArgs)';
        writer.line('  $retType ${func.dartName}($params) async {');
        writer.line('    final _result = $jsCall;');
        writer.line('    return ${_jsTodart(func.returnType, '_result', enumNames, structNames, recordNames)};');
        writer.line('  }');
      } else {
        final retType = func.returnType.name;
        final params = func.params.map((p) => '${p.type.name} ${p.name}').join(', ');
        final callArgs = func.params.map((p) => _dartToJs(p.type, p.name, enumNames)).join(', ');
        final jsId = '_${func.cSymbol}_js';
        final jsCall = '$jsId($callArgs)';
        if (retType == 'void') {
          writer.line('  void ${func.dartName}($params) { $jsCall; }');
        } else {
          final conv = _jsTodart(func.returnType, jsCall, enumNames, structNames, recordNames);
          writer.line('  $retType ${func.dartName}($params) => $conv;');
        }
      }
      writer.blankLine();
    }

    // Properties
    for (final prop in spec.properties) {
      final rt = prop.type.name;
      if (prop.hasGetter) {
        writer.line('  @override');
        final jsCall = '_${libStem}_get_${prop.dartName}_js()';
        final conv = _jsTodart(prop.type, jsCall, enumNames, structNames, recordNames);
        writer.line('  $rt get ${prop.dartName} => $conv;');
      }
      if (prop.hasSetter) {
        writer.line('  @override');
        final jsArg = _dartToJs(prop.type, 'value', enumNames);
        writer.line('  set ${prop.dartName}($rt value) { _${libStem}_set_${prop.dartName}_js($jsArg); }');
      }
      writer.blankLine();
    }

    // Streams — not supported on web (no Dart_PostCObject_DL in WASM)
    for (final stream in spec.streams) {
      final itemType = stream.itemType.name;
      writer.line('  @override');
      if (stream.isMethodStyle) {
        writer.line('  Stream<$itemType> ${stream.dartName}() {');
      } else {
        writer.line('  Stream<$itemType> get ${stream.dartName} {');
      }
      writer.line("    throw UnsupportedError('${stream.dartName}: Nitro streams are not supported on web. Use a polling approach or WebSockets instead.');");
      writer.line('  }');
      writer.blankLine();
    }

    writer.line('}');
    writer.blankLine();

    // ── Factory function ─────────────────────────────────────────────────────
    writer.line(
      '/// Creates the web (WASM) implementation of [${spec.dartClassName}].',
    );
    writer.line(
      '/// Import this file conditionally and call this factory when on web:',
    );
    writer.line('///');
    writer.line(
      "/// ```dart",
    );
    writer.line(
      "/// import '${specFile.replaceAll('.native.dart', '.web.bridge.g.dart')}'",
    );
    writer.line(
      "///     if (dart.library.ffi) '${specFile.replaceAll('.native.dart', '.g.dart')}';",
    );
    writer.line("/// ```");
    // Factory: `createNitroXxxWebInstance()` — camelCase factory matching the
    // platform-conditional import pattern used with `_createNativeInstance()`.
    writer.line(
      '${spec.dartClassName} create${spec.dartClassName}WebInstance() =>',
    );
    writer.line('    _${spec.dartClassName}WebImpl();');
    writer.blankLine();
    // Also emit a no-arg constructor note for clarity
    writer.line(
      '// Usage: import this file with `if (dart.library.ffi) xxx.g.dart`',
    );
    writer.line(
      '// and call create${spec.dartClassName}WebInstance() on web targets.',
    );

    return writer.toString();
  }

  // ── Type conversion helpers ─────────────────────────────────────────────

  /// Dart FFI type → JS interop type for @JS() external param/return.
  static String _jsReturnType(BridgeType bt, Set<String> enumNames,
      Set<String> structNames, Set<String> recordNames) {
    if (bt.name == 'void') return 'void';
    if (bt.isFuture) return 'JSAny?'; // async: result posted as JSAny
    return _toJsType(bt, enumNames, structNames, recordNames);
  }

  static String _jsPropType(BridgeType bt, Set<String> enumNames,
      Set<String> structNames, Set<String> recordNames) =>
      _toJsType(bt, enumNames, structNames, recordNames);

  static String _toJsType(BridgeType bt, Set<String> enumNames,
      Set<String> structNames, Set<String> recordNames) {
    final name = bt.name.replaceFirst('?', '');
    switch (name) {
      case 'int': return 'JSNumber';
      case 'double': return 'JSNumber';
      case 'bool': return 'JSBoolean';
      case 'String': return 'JSString';
      case 'void': return 'void';
    }
    if (bt.isTypedData) return 'JSArrayBuffer';
    if (bt.isPointer || bt.isNativeHandle) return 'JSNumber'; // pointer as numeric address
    if (bt.isFunction) return 'JSFunction'; // callback as JS function
    if (enumNames.contains(name)) return 'JSNumber'; // enum as rawValue
    if (structNames.contains(name)) return 'JSObject'; // struct as JS object
    // Map<String,V>: JSON-encoded on native → JS string on web (not binary buffer)
    if (bt.isMap) return 'JSString';
    // @HybridRecord and List<@HybridRecord>: binary-encoded buffer
    if (bt.isRecord || recordNames.contains(name)) return 'JSArrayBuffer';
    return 'JSAny?';
  }

  static String _jsFuncParams(List<BridgeParam> params, Set<String> enumNames,
      Set<String> structNames, Set<String> recordNames) {
    return params.map((p) {
      final t = _toJsType(p.type, enumNames, structNames, recordNames);
      if (p.type.isTypedData) {
        return '$t ${p.name}, JSNumber ${p.name}Length';
      }
      return '$t ${p.name}';
    }).join(', ');
  }

  /// Dart value → JS value for passing to @JS() functions.
  static String _dartToJs(BridgeType bt, String varName, Set<String> enumNames) {
    final name = bt.name.replaceFirst('?', '');
    if (name == 'int' || name == 'double') return '$varName.toJS';
    if (name == 'bool') return '$varName.toJS';
    if (name == 'String') return '$varName.toJS';
    if (bt.isTypedData) return '$varName.buffer.toJS, $varName.lengthInBytes.toJS';
    if (bt.isPointer || bt.isNativeHandle) return '$varName.address.toJS';
    if (bt.isFunction) return '$varName.toJS'; // treated as JS function ref
    if (enumNames.contains(name)) return '$varName.nativeValue.toJS';
    // Map<String,V>: JSON-encode to string, match JSString on JS side
    if (bt.isMap) return 'jsonEncode($varName).toJS';
    // Struct / Record: JSON-encode for web interop
    return 'jsonEncode($varName).toJS';
  }

  /// JS value → Dart value after calling @JS() function.
  static String _jsTodart(BridgeType bt, String expr, Set<String> enumNames,
      Set<String> structNames, Set<String> recordNames) {
    final name = bt.name.replaceFirst('?', '');
    if (name == 'int') return '($expr as JSNumber).toDartInt';
    if (name == 'double') return '($expr as JSNumber).toDartDouble';
    if (name == 'bool') return '($expr as JSBoolean).toDart';
    if (name == 'String') return '($expr as JSString).toDart';
    if (bt.isTypedData) return '($expr as JSArrayBuffer).toDart.asUint8List()';
    if (bt.isPointer || bt.isNativeHandle) {
      return 'Pointer.fromAddress(($expr as JSNumber).toDartInt)';
    }
    if (bt.isMap) {
      // Map<String,V>: JSON-decoded from JSString
      return 'jsonDecode(($expr as JSString).toDart) as Map<String, dynamic>';
    }
    if (enumNames.contains(name)) {
      return '(($expr as JSNumber).toDartInt).to$name()';
    }
    if (structNames.contains(name) || recordNames.contains(name)) {
      return '$name.fromJson(jsonDecode(($expr as JSString).toDart) as Map<String, dynamic>)';
    }
    return '($expr as JSAny?)';
  }
}
