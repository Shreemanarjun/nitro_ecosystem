import '../../../bridge_spec.dart';
import '../../code_writer.dart';
import '../../generator_metadata.dart';
import '../../record_generator.dart';

/// Generates `*.native.g.h` — the abstract C++ class that the user implements
/// when `@NitroModule(ios: NativeImpl.cpp, android: NativeImpl.cpp)` is used.
///
/// The user subclasses `Hybrid${ClassName}` and registers their instance via
/// `${lib}_register_impl(&myImpl)` during plugin initialisation.
class CppInterfaceGenerator {
  static String generate(BridgeSpec spec) {
    if (!spec.hasCppImpl) {
      return '// Not applicable: NativeImpl is not cpp for this module.\n';
    }

    final libStem = spec.lib.replaceAll('-', '_');
    final className = spec.dartClassName;
    final headerGuard = '${libStem.toUpperCase()}_NATIVE_G_H';
    final bridgeHeader = '$libStem.bridge.g.h';
    final nodes = <CodeNode>[
      CodeSnippet(generatedFileHeader('//', sourceUri: spec.sourceUri)),
      const CodeLine('//'),
      CodeLine('// Abstract C++ interface for $className.'),
      CodeLine(
        '// Subclass Hybrid$className and register via ${libStem}_register_impl().',
      ),
      const CodeLine('#pragma once'),
      CodeLine('#ifndef $headerGuard'),
      CodeLine('#define $headerGuard'),
      const BlankLine(),
      const CodeLine('#include <stdint.h>'),
      const CodeLine('#include <stddef.h>'),
      const CodeLine('#include <string>'),
      const CodeLine('#include <stdexcept>'),
    ];

    final enumNames = spec.enums.map((e) => e.name).toSet();
    final structNames = spec.structs.map((s) => s.name).toSet();
    final recordNames = spec.recordTypes.map((r) => r.name).toSet();

    if (spec.recordTypes.isNotEmpty) {
      nodes.addAll(const [
        CodeLine('#include <cstring>'),
        CodeLine('#include <optional>'),
        CodeLine('#include <vector>'),
      ]);
    }
    nodes.addAll([
      CodeLine('#include "$bridgeHeader"'),
      const BlankLine(),
    ]);

    // NitroCppBuffer — lightweight view for @HybridRecord payloads and
    // @zeroCopy TypedData returns.
    nodes.addAll(const [
      CodeLine(
        '/// Lightweight read-only view over a binary payload.',
      ),
      CodeLine(
        '/// For @zeroCopy returns, native code must keep data alive while Dart uses it.',
      ),
      CodeBlock(
        header: 'struct NitroCppBuffer {',
        body: [
          CodeLine('const uint8_t* data;'),
          CodeLine('size_t size;'),
        ],
        footer: '};',
      ),
      BlankLine(),
    ]);

    // @HybridRecord C++ structs with bounds-checked decoder (§3.3)
    final cppRecords = RecordGenerator.generateCpp(spec);
    if (cppRecords.isNotEmpty) nodes.add(CodeSnippet(cppRecords));

    // ── Abstract interface class ─────────────────────────────────────────────
    nodes.addAll([
      CodeLine('/// Abstract C++ interface for $className.'),
      const CodeLine(
        '/// 1. Subclass this and implement all pure-virtual methods.',
      ),
      CodeLine(
        '/// 2. Call ${libStem}_register_impl(&myInstance) at startup.',
      ),
      CodeLine('/// 3. Call ${libStem}_register_impl(nullptr) in teardown.'),
      CodeLine('class Hybrid$className {'),
      const CodeLine('public:'),
      CodeLine('    virtual ~Hybrid$className() = default;'),
      const BlankLine(),
    ]);

    // Methods
    if (spec.functions.isNotEmpty) {
      nodes.add(
        const CodeLine(
          '    // ── Methods ──────────────────────────────────────────────────────────',
        ),
      );
      for (final func in spec.functions) {
        if (func.lineNumber != null) {
          nodes.add(
            CodeLine(
              '    // source: ${spec.sourceUri.split('/').last}:${func.lineNumber}',
            ),
          );
        }
        if (func.isNativeAsync) {
          // @NitroNativeAsync: impl returns void and accepts dart_port so it can
          // post the result directly via Dart_PostCObject_DL from any thread.
          final params = _cppMethodParams(func.params, enumNames, structNames, recordNames);
          params.add('int64_t dartPort');
          nodes.add(
            CodeLine('    virtual void ${func.dartName}(${params.join(', ')}) = 0;'),
          );
        } else {
          final retType = _cppReturnType(func.returnType, enumNames, structNames, recordNames);
          final params = _cppMethodParams(func.params, enumNames, structNames, recordNames);
          final paramStr = params.join(', ');
          nodes.add(
            CodeLine('    virtual $retType ${func.dartName}($paramStr) = 0;'),
          );
        }
      }
      nodes.add(const BlankLine());
    }

    // Properties
    if (spec.properties.isNotEmpty) {
      nodes.add(
        const CodeLine(
          '    // ── Properties ───────────────────────────────────────────────────────',
        ),
      );
      for (final prop in spec.properties) {
        final cppType = _cppScalarType(prop.type, enumNames, structNames, recordNames);
        if (prop.hasGetter) {
          nodes.add(
            CodeLine('    virtual $cppType get_${prop.dartName}() const = 0;'),
          );
        }
        if (prop.hasSetter) {
          final paramType = _cppParamType(prop.type, enumNames, structNames, recordNames);
          nodes.add(
            CodeLine(
              '    virtual void set_${prop.dartName}($paramType value) = 0;',
            ),
          );
        }
      }
      nodes.add(const BlankLine());
    }

    // Streams — emit helpers declared inline (implemented in bridge.g.cpp)
    if (spec.streams.isNotEmpty) {
      nodes.addAll(const [
        CodeLine(
          '    // ── Streams ──────────────────────────────────────────────────────────',
        ),
        CodeLine(
          '    // Call the emit_* helpers below to push items to Dart from any thread.',
        ),
      ]);
      for (final stream in spec.streams) {
        final itemCpp = _cppScalarType(stream.itemType, enumNames, structNames, recordNames);
        nodes.add(
          CodeLine('    /// Emit a value on the ${stream.dartName} stream.'),
        );
        nodes.add(CodeLine('    void emit_${stream.dartName}($itemCpp item);'));
      }
      nodes.add(const BlankLine());
    }

    nodes.addAll([
      const CodeLine('protected:'),
      CodeLine('    Hybrid$className() = default;'),
      const CodeLine('};'),
      const BlankLine(),
    ]);

    // ── Registration API ─────────────────────────────────────────────────────
    nodes.addAll([
      const CodeLine('#ifdef __cplusplus'),
      const CodeLine('extern "C" {'),
      const CodeLine('#endif'),
      const BlankLine(),
      const CodeLine(
        '/// Register your C++ implementation. Call once during plugin/app init.',
      ),
      const CodeLine('/// Pass nullptr to unregister (e.g. in teardown).'),
      CodeLine('void ${libStem}_register_impl(Hybrid$className* impl);'),
      const BlankLine(),
      const CodeLine(
        '/// Return the currently registered implementation (may be nullptr).',
      ),
      CodeLine('Hybrid$className* ${libStem}_get_impl(void);'),
      const BlankLine(),
      const CodeLine('#ifdef __cplusplus'),
      const CodeLine('}'),
      const CodeLine('#endif'),
      const BlankLine(),
      CodeLine('#endif // $headerGuard'),
    ]);

    return CodeFile(nodes).render(indentText: '    ');
  }

  // ── Type helpers (C++ style) ─────────────────────────────────────────────

  /// C++ return type. Primitives → scalar; String → std::string;
  /// Struct → by-value; Enum → enum typedef; Record/List/Map and TypedData
  /// returns → NitroCppBuffer.
  static String _cppReturnType(
    BridgeType bt,
    Set<String> enumNames,
    Set<String> structNames,
    Set<String> recordNames,
  ) {
    // NativeHandle<T>: raw opaque pointer, zero codec. Always void*.
    if (bt.isNativeHandle) return 'void*';
    // isRecord covers bare @HybridRecord, List<T>, and Map<K,V> — all bridge
    // as NitroCppBuffer regardless of the name string.
    if (bt.isRecord) return 'NitroCppBuffer';
    if (bt.isPointer) {
      final inner = bt.pointerInnerType;
      if (inner == null) return 'void*';
      final innerBase = inner.replaceFirst('?', '');
      if (innerBase == 'void' || innerBase == 'Void') return 'void*';
      if (innerBase == 'String') return 'std::string*';
      if (enumNames.contains(innerBase)) return '$innerBase*';
      if (structNames.contains(innerBase)) return '$innerBase*';
      if (recordNames.contains(innerBase)) return 'NitroCppBuffer*';
      final prim = _primitiveType(innerBase);
      return prim == 'void*' ? 'void*' : '$prim*';
    }
    final base = bt.name.replaceFirst('?', '');
    if (base == 'void') return 'void';
    if (base == 'String') return 'std::string';
    if (enumNames.contains(base)) return base;
    if (structNames.contains(base)) return base;
    if (recordNames.contains(base)) return 'NitroCppBuffer';
    if (_isTypedData(base)) return 'NitroCppBuffer';
    return _primitiveType(base);
  }

  /// C++ const-ref param type for setters / scalar positions.
  static String _cppParamType(
    BridgeType bt,
    Set<String> enumNames,
    Set<String> structNames,
    Set<String> recordNames,
  ) {
    // NativeHandle<T>: pass raw opaque pointer.
    if (bt.isNativeHandle) return 'void*';
    // isRecord covers bare @HybridRecord, List<T>, and Map<K,V>.
    if (bt.isRecord) return 'NitroCppBuffer';
    if (bt.isPointer) {
      final inner = bt.pointerInnerType;
      if (inner == null) return 'void*';
      final innerBase = inner.replaceFirst('?', '');
      if (innerBase == 'void' || innerBase == 'Void') return 'void*';
      if (innerBase == 'String') return 'std::string*';
      if (enumNames.contains(innerBase)) return '$innerBase*';
      if (structNames.contains(innerBase)) return '$innerBase*';
      if (recordNames.contains(innerBase)) return 'NitroCppBuffer*';
      final prim = _primitiveType(innerBase);
      return prim == 'void*' ? 'void*' : '$prim*';
    }
    final base = bt.name.replaceFirst('?', '');
    if (base == 'String') return 'const std::string&';
    if (enumNames.contains(base)) return base;
    if (structNames.contains(base)) return 'const $base&';
    if (recordNames.contains(base)) return 'NitroCppBuffer';
    if (_isTypedData(base)) return _typedDataPtr(base);
    return _primitiveType(base);
  }

  /// Scalar C++ type (for return types, property types, and stream item types).
  static String _cppScalarType(
    BridgeType bt,
    Set<String> enumNames,
    Set<String> structNames,
    Set<String> recordNames,
  ) {
    // NativeHandle<T>: pass raw opaque pointer.
    if (bt.isNativeHandle) return 'void*';
    // isRecord covers bare @HybridRecord, List<T>, and Map<K,V>.
    if (bt.isRecord) return 'NitroCppBuffer';
    if (bt.isPointer) {
      final inner = bt.pointerInnerType;
      if (inner == null) return 'void*';
      final innerBase = inner.replaceFirst('?', '');
      if (innerBase == 'void' || innerBase == 'Void') return 'void*';
      if (innerBase == 'String') return 'std::string*';
      if (enumNames.contains(innerBase)) return '$innerBase*';
      if (structNames.contains(innerBase)) return '$innerBase*';
      if (recordNames.contains(innerBase)) return 'NitroCppBuffer*';
      final prim = _primitiveType(innerBase);
      return prim == 'void*' ? 'void*' : '$prim*';
    }
    final base = bt.name.replaceFirst('?', '');
    if (base == 'String') return 'std::string';
    if (enumNames.contains(base)) return base;
    if (structNames.contains(base)) return base;
    if (recordNames.contains(base)) return 'NitroCppBuffer';
    return _primitiveType(base);
  }

  /// Build the full parameter list for a method signature.
  /// TypedData types expand to two params: pointer + length.
  static List<String> _cppMethodParams(
    List<BridgeParam> params,
    Set<String> enumNames,
    Set<String> structNames,
    Set<String> recordNames,
  ) {
    final parts = <String>[];
    for (final p in params) {
      if (p.type.isFunction) {
        parts.add(_cppCallbackParam(p, enumNames));
        continue;
      }
      // isRecord covers bare @HybridRecord, List<T>, and Map<K,V>.
      if (p.type.isRecord) {
        parts.add('NitroCppBuffer ${p.name}');
        continue;
      }
      if (p.type.isPointer) {
        final inner = p.type.pointerInnerType;
        if (inner == null) {
          parts.add('void* ${p.name}');
        } else {
          final innerBase = inner.replaceFirst('?', '');
          if (innerBase == 'void' || innerBase == 'Void') {
            parts.add('void* ${p.name}');
          } else if (innerBase == 'String') {
            parts.add('std::string* ${p.name}');
          } else if (enumNames.contains(innerBase)) {
            parts.add('$innerBase* ${p.name}');
          } else if (structNames.contains(innerBase)) {
            parts.add('$innerBase* ${p.name}');
          } else if (recordNames.contains(innerBase)) {
            parts.add('NitroCppBuffer* ${p.name}');
          } else {
            final prim = _primitiveType(innerBase);
            parts.add('${prim == 'void*' ? 'void*' : '$prim*'} ${p.name}');
          }
        }
        continue;
      }
      final base = p.type.name.replaceFirst('?', '');
      if (_isTypedData(base)) {
        parts.add('${_typedDataPtr(base)} ${p.name}');
        parts.add('size_t ${p.name}_length');
      } else if (base == 'String') {
        parts.add('const std::string& ${p.name}');
      } else if (structNames.contains(base)) {
        parts.add('const $base& ${p.name}');
      } else if (enumNames.contains(base)) {
        parts.add('$base ${p.name}');
      } else if (recordNames.contains(base)) {
        parts.add('NitroCppBuffer ${p.name}');
      } else {
        parts.add('${_primitiveType(base)} ${p.name}');
      }
    }
    return parts;
  }

  static bool _isTypedData(String base) {
    const td = {
      'Uint8List',
      'Int8List',
      'Int16List',
      'Int32List',
      'Uint16List',
      'Uint32List',
      'Float32List',
      'Float64List',
      'Int64List',
      'Uint64List',
    };
    return td.contains(base);
  }

  static String _typedDataPtr(String base) {
    switch (base) {
      case 'Uint8List':
        return 'const uint8_t*';
      case 'Int8List':
        return 'const int8_t*';
      case 'Int16List':
        return 'const int16_t*';
      case 'Uint16List':
        return 'const uint16_t*';
      case 'Int32List':
        return 'const int32_t*';
      case 'Uint32List':
        return 'const uint32_t*';
      case 'Float32List':
        return 'const float*';
      case 'Float64List':
        return 'const double*';
      case 'Int64List':
        return 'const int64_t*';
      case 'Uint64List':
        return 'const uint64_t*';
      default:
        return 'const uint8_t*';
    }
  }

  static String _primitiveType(String base) {
    switch (base) {
      // Dart primitive names
      case 'int':
        return 'int64_t';
      case 'double':
        return 'double';
      case 'bool':
        return 'bool';
      // FFI-style inner types used in Pointer<T>
      case 'Uint8':
        return 'uint8_t';
      case 'Int8':
        return 'int8_t';
      case 'Int16':
        return 'int16_t';
      case 'Int32':
        return 'int32_t';
      case 'Uint16':
        return 'uint16_t';
      case 'Uint32':
        return 'uint32_t';
      case 'Float':
        return 'float';
      case 'Double':
        return 'double';
      case 'Int64':
        return 'int64_t';
      case 'Uint64':
        return 'uint64_t';
      default:
        return 'void*';
    }
  }

  static String _cppCallbackParam(BridgeParam param, Set<String> enumNames) {
    final callback = param.type;
    final ret = _cppCallbackType(callback.functionReturnType ?? 'void', enumNames);
    final params = callback.functionParams.map((p) => _cppCallbackType(p.name, enumNames, bridgeType: p)).join(', ');
    final paramStr = params.isEmpty ? 'void' : params;
    return '$ret (*${param.name})($paramStr)';
  }

  static String _cppCallbackType(String dartType, Set<String> enumNames, {BridgeType? bridgeType}) {
    if (bridgeType?.isPointer == true) {
      final inner = bridgeType!.pointerInnerType;
      if (inner == null || inner == 'Void' || inner == 'void') return 'void*';
      if (inner == 'Utf8' || inner == 'Char') return 'char*';
      final prim = _primitiveType(inner.replaceFirst('?', ''));
      return prim == 'void*' ? 'void*' : '$prim*';
    }
    final base = dartType.replaceFirst('?', '');
    if (base == 'void') return 'void';
    if (enumNames.contains(base)) return 'int64_t';
    if (base == 'bool') return 'int8_t';
    if (base == 'String') return 'const char*';
    return _primitiveType(base);
  }
}
