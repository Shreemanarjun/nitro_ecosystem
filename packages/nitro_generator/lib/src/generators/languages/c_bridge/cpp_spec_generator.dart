import '../../../bridge_spec.dart';
import '../../code_writer.dart';
import '../../generator_metadata.dart';

/// Generates a `{lib}.spec.g.hpp` C++ abstract-class header — analogous to
/// RN Nitro's `HybridXxxSpec.hpp`.
///
/// The generated file is an additional output (does NOT replace existing
/// generators). It produces a pure-virtual C++ interface that can be implemented
/// directly without JNI or Swift bridge overhead.
///
/// Usage: call [generate] and write the result to `{lib}.spec.g.hpp`.
class CppSpecGenerator {
  /// Returns the generated C++ spec header as a string.
  static String generate(BridgeSpec spec) {
    final w = CodeWriter();
    final libStem = spec.lib.replaceAll('-', '_');
    final className = spec.dartClassName;

    // ── File header ───────────────────────────────────────────────────────
    w.raw(generatedFileHeader('//', sourceUri: spec.sourceUri));
    w.line('#pragma once');
    w.blankLine();

    // Standard includes
    for (final inc in const [
      '<cstdint>',
      '<functional>',
      '<memory>',
      '<optional>',
      '<string>',
      '<unordered_map>',
      '<variant>',
      '<vector>',
    ]) {
      w.line('#include $inc');
    }
    w.blankLine();

    // ── Enum forward declarations ─────────────────────────────────────────
    if (spec.localEnums.isNotEmpty) {
      w.line('// Forward declarations for enums defined in this spec.');
      w.line('// (actual definitions come from the C header)');
      for (final e in spec.localEnums) {
        w.line('enum class ${e.name} : int64_t;');
      }
      w.blankLine();
    }

    // ── Namespace ────────────────────────────────────────────────────────
    w.line('namespace nitro {');
    w.blankLine();

    // ── @NitroVariant using aliases ───────────────────────────────────────
    for (final v in spec.localVariants) {
      _emitVariantAlias(w, v, spec);
    }

    // ── Class doc comment ────────────────────────────────────────────────
    w.line('/// Pure-virtual C++ interface for the $className bridge.');
    w.line('/// Implement this to provide a native C++ backend without JNI or Swift overhead.');
    w.line('///');
    w.line('/// Registration (call from your factory):');
    w.line('///   nitro::register_${libStem}(std::make_shared<My${className}Impl>());');
    w.line('///');
    w.line('/// Dart lifecycle:');
    w.line('///   create_instance → onCreate()');
    w.line('///   destroy_instance → onDestroy()');
    w.line('class ${className}Spec {');
    w.line('public:');
    w.line('  virtual ~${className}Spec() = default;');
    w.blankLine();
    w.line('  virtual void onCreate() {}');
    w.line('  virtual void onDestroy() {}');

    // ── Properties ────────────────────────────────────────────────────────
    if (spec.properties.isNotEmpty) {
      w.blankLine();
      w.line('  // ── Properties ──────────────────────────────────────────');
      for (final prop in spec.properties) {
        final cppType = _dartToCpp(prop.type, spec);
        final propName = _capitalize(prop.dartName);
        if (prop.hasGetter) {
          w.line('  virtual $cppType get$propName() = 0;');
        }
        if (prop.hasSetter) {
          w.line('  virtual void set$propName($cppType value) = 0;');
        }
      }
    }

    // ── Methods (streams omitted — no C++ equivalent) ─────────────────────
    final funcs = spec.functions.where((f) => !f.returnType.isStream).toList();
    if (funcs.isNotEmpty) {
      w.blankLine();
      w.line('  // ── Methods ─────────────────────────────────────────────');
      for (final func in funcs) {
        final ret = _dartToCpp(func.returnType, spec);
        final paramStr = func.params
            .map((p) => '${_dartToCpp(p.type, spec)} ${p.name}')
            .join(', ');
        w.line('  virtual $ret ${func.dartName}($paramStr) = 0;');
      }
    }

    w.line('};');
    w.blankLine();

    // ── Registry helpers ─────────────────────────────────────────────────
    w.line('void register_${libStem}(std::shared_ptr<${className}Spec> impl);');
    w.line('std::shared_ptr<${className}Spec> get_${libStem}(int64_t instanceId);');
    w.blankLine();

    w.line('} // namespace nitro');

    return w.toString();
  }

  // ── Variant alias ──────────────────────────────────────────────────────

  static void _emitVariantAlias(
    CodeWriter w,
    BridgeVariant variant,
    BridgeSpec spec,
  ) {
    final caseTypes = variant.cases.map((c) {
      // null case or unit case → std::monostate
      if (c.name.toLowerCase() == 'null' || c.isUnit) return 'std::monostate';
      if (c.fields.length == 1) return _recordFieldToCpp(c.fields[0], spec);
      // Multi-field case — use monostate as a safe fallback (caller embeds
      // full struct definitions separately if needed).
      return 'std::monostate';
    }).join(', ');
    w.line('using ${variant.name} = std::variant<$caseTypes>;');
    w.blankLine();
  }

  static String _recordFieldToCpp(BridgeRecordField f, BridgeSpec spec) {
    final bare = f.dartType.replaceFirst('?', '');
    if (f.isNullable) {
      final inner = _recordFieldToCpp(
        BridgeRecordField(name: f.name, dartType: bare, kind: f.kind, itemTypeName: f.itemTypeName),
        spec,
      );
      return 'std::optional<$inner>';
    }
    switch (f.kind) {
      case RecordFieldKind.primitive:
        return _dartNameToCpp(bare, spec);
      case RecordFieldKind.enumValue:
        return bare;
      case RecordFieldKind.recordObject:
      case RecordFieldKind.struct:
      case RecordFieldKind.listPrimitive:
      case RecordFieldKind.listEnumValue:
      case RecordFieldKind.listRecordObject:
      case RecordFieldKind.typedData:
        return 'std::vector<uint8_t>';
    }
  }

  // ── Type mapper ────────────────────────────────────────────────────────

  /// Converts a [BridgeType] (with its flags) to a C++ type string.
  static String _dartToCpp(BridgeType type, BridgeSpec spec) {
    // Nullable → std::optional<T>
    final isNullable = type.isNullable || type.name.endsWith('?');
    if (isNullable) {
      final inner = _dartNameToCpp(type.baseName, spec);
      return 'std::optional<$inner>';
    }
    // Stream<T> — no C++ equivalent; callers should omit these methods.
    if (type.isStream) return 'void';
    // Future<T> — C++ side is synchronous; unwrap to T.
    if (type.isFuture) return _dartNameToCpp(type.name, spec);
    // std::function for callbacks
    if (type.isFunction) {
      final ret = _dartNameToCpp(type.functionReturnType ?? 'void', spec);
      final params = type.functionParams.map((p) => _dartToCpp(p, spec)).join(', ');
      return 'std::function<$ret($params)>';
    }
    return _dartNameToCpp(type.name, spec);
  }

  /// Converts a Dart type-name string to a C++ type-name string.
  ///
  /// Handles primitives, typed arrays, [List<T>], [Map<K,V>], and spec-registered
  /// enums / structs / records / variants.
  static String _dartNameToCpp(String dartName, BridgeSpec spec) {
    // Strip nullable suffix if caller forgot to unwrap it
    final bare = dartName.endsWith('?') ? dartName.substring(0, dartName.length - 1) : dartName;

    switch (bare) {
      case 'void':        return 'void';
      case 'bool':        return 'bool';
      case 'int':         return 'int64_t';
      case 'int8':        return 'int8_t';
      case 'int16':       return 'int16_t';
      case 'int32':       return 'int32_t';
      case 'uint8':       return 'uint8_t';
      case 'uint16':      return 'uint16_t';
      case 'uint32':      return 'uint32_t';
      case 'uint64':      return 'uint64_t';
      case 'float':       return 'float';
      case 'double':      return 'double';
      case 'String':      return 'std::string';
      case 'DateTime':    return 'int64_t';
      case 'AnyNativeObject': return 'int64_t';
      case 'Uint8List':   return 'std::vector<uint8_t>';
      case 'Int8List':    return 'std::vector<int8_t>';
      case 'Int16List':   return 'std::vector<int16_t>';
      case 'Int32List':   return 'std::vector<int32_t>';
      case 'Uint16List':  return 'std::vector<uint16_t>';
      case 'Uint32List':  return 'std::vector<uint32_t>';
      case 'Float32List': return 'std::vector<float>';
      case 'Float64List': return 'std::vector<double>';
      case 'Int64List':   return 'std::vector<int64_t>';
      case 'Uint64List':  return 'std::vector<uint64_t>';
    }

    // List<T>
    final listM = RegExp(r'^List<(.+)>$').firstMatch(bare);
    if (listM != null) {
      return 'std::vector<${_dartNameToCpp(listM.group(1)!.trim(), spec)}>';
    }

    // Map<K, V>
    final mapM = RegExp(r'^Map<(\w+),\s*(.+)>$').firstMatch(bare);
    if (mapM != null) {
      final key = mapM.group(1)!.trim();
      final val = mapM.group(2)!.trim();
      // Enum keys and integer keys both map to int64_t in C++.
      final cppKey = spec.isEnumName(key) ? 'int64_t' : _dartNameToCpp(key, spec);
      return 'std::unordered_map<$cppKey, ${_dartNameToCpp(val, spec)}>';
    }

    // Spec-registered named types
    if (spec.isEnumName(bare))       return bare;                    // enum class E : int64_t
    if (spec.isStructName(bare))     return bare;                    // struct S
    if (spec.isRecordName(bare))     return 'std::vector<uint8_t>'; // binary codec
    if (spec.isVariantName(bare))    return bare;                    // using alias
    if (spec.isCustomTypeName(bare)) return 'std::vector<uint8_t>'; // user-codec binary

    return 'void*'; // unknown / opaque
  }

  static String _capitalize(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}
