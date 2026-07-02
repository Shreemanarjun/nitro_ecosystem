import '../../../bridge_spec.dart';
import '../../code_writer.dart';
import '../../generator_metadata.dart';
import '../../record_generator.dart';

/// Generates `*.native.g.h` — the abstract C++ class that the user implements
/// when `@NitroModule(ios: NativeImpl.cpp, android: NativeImpl.cpp)` is used.
///
/// Architecture mirrors React Native Nitro's HybridXxxSpec pattern:
///   - `Hybrid${ClassName}` abstract class with pure-virtual methods
///   - `std::optional<T>` for nullable types (not raw pointers)
///   - `std::function<R(Args...)>` for callbacks (not raw function pointers)
///   - `shared_ptr<Hybrid${ClassName}>` factory for multi-instance support
///   - `NitroRecordWriter` / `NitroRecordReader` for binary codec
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
      CodeLine('// Mirrors RN Nitro\'s HybridXxxSpec pattern — pure-virtual C++ with stdlib types.'),
      CodeLine('// 1. Subclass Hybrid$className and implement all pure-virtual methods.'),
      CodeLine('// 2. Register via ${libStem}_register_factory() (multi-instance) or'),
      CodeLine('//    ${libStem}_register_impl() (single-instance legacy API).'),
      const CodeLine('#pragma once'),
      CodeLine('#ifndef $headerGuard'),
      CodeLine('#define $headerGuard'),
      const BlankLine(),
      const CodeLine('#include <stdint.h>'),
      const CodeLine('#include <stddef.h>'),
      const CodeLine('#include <cstring>'),
      const CodeLine('#include <functional>'),
      const CodeLine('#include <memory>'),
      const CodeLine('#include <optional>'),
      const CodeLine('#include <string>'),
      const CodeLine('#include <stdexcept>'),
      const CodeLine('#include <vector>'),
    ];

    final enumNames = spec.enums.map((e) => e.name).toSet();
    final structNames = spec.structs.map((s) => s.name).toSet();
    final recordNames = spec.recordTypes.map((r) => r.name).toSet();
    // Variants have the same NitroCppBuffer wire type as records — merge into recordNames.
    final variantNames = spec.variants.map((v) => v.name).toSet();
    recordNames.addAll(variantNames);

    if (spec.recordTypes.isNotEmpty || spec.variants.isNotEmpty) {
      nodes.addAll(const [
        CodeLine('#include <variant>'),
      ]);
    }
    nodes.addAll([
      CodeLine('#include "$bridgeHeader"'),
      const BlankLine(),
    ]);

    // NitroCppBuffer — lightweight read-only view (mirrors RN Nitro's ArrayBuffer concept).
    // NitroRecordWriter — binary encoder for @HybridRecord return values.
    // NitroRecordReader — binary decoder for @HybridRecord parameter values.
    nodes.addAll(const [
      CodeLine('/// Lightweight read-only view over a binary payload.'),
      CodeLine('/// For @zeroCopy returns, native code must keep data alive while Dart uses it.'),
      CodeBlock(
        header: 'struct NitroCppBuffer {',
        body: [
          CodeLine('const uint8_t* data;'),
          CodeLine('size_t size;'),
        ],
        footer: '};',
      ),
      BlankLine(),
      CodeLine('/// Binary encoder for @HybridRecord / @NitroVariant return values.'),
      CodeLine('/// Mirrors RN Nitro\'s NitroRecordWriter — build then call toNative().'),
      CodeBlock(
        header: 'struct NitroRecordWriter {',
        body: [
          CodeLine('std::vector<uint8_t> _buf;'),
          CodeLine('NitroRecordWriter() { _buf.reserve(64); }'),
          CodeLine('void writeInt(int64_t v) { _buf.insert(_buf.end(), reinterpret_cast<const uint8_t*>(&v), reinterpret_cast<const uint8_t*>(&v) + 8); }'),
          CodeLine('void writeInt32(int32_t v) { _buf.insert(_buf.end(), reinterpret_cast<const uint8_t*>(&v), reinterpret_cast<const uint8_t*>(&v) + 4); }'),
          CodeLine('void writeDouble(double v) { _buf.insert(_buf.end(), reinterpret_cast<const uint8_t*>(&v), reinterpret_cast<const uint8_t*>(&v) + 8); }'),
          CodeLine('void writeBool(bool v) { _buf.push_back(v ? 1 : 0); }'),
          CodeLine('void writeString(const std::string& s) { int32_t n = (int32_t)s.size(); writeInt32(n); _buf.insert(_buf.end(), s.begin(), s.end()); }'),
          CodeLine('/// Returns heap-allocated [4B length][payload]. Caller must ::free().'),
          CodeLine('uint8_t* toNative() const {'),
          CodeLine('    int32_t payloadLen = (int32_t)_buf.size();'),
          CodeLine('    uint8_t* out = (uint8_t*)::malloc(sizeof(int32_t) + (size_t)payloadLen);'),
          CodeLine('    if (!out) return nullptr;'),
          CodeLine('    ::memcpy(out, &payloadLen, sizeof(int32_t));'),
          CodeLine('    if (payloadLen > 0) ::memcpy(out + sizeof(int32_t), _buf.data(), (size_t)payloadLen);'),
          CodeLine('    return out;'),
          CodeLine('}'),
          CodeLine('NitroCppBuffer toBuffer() const { return { _buf.data(), _buf.size() }; }'),
        ],
        footer: '};',
      ),
      BlankLine(),
    ]);

    // @HybridRecord C++ structs with bounds-checked decoder (§3.3)
    final cppRecords = RecordGenerator.generateCpp(spec);
    if (cppRecords.isNotEmpty) nodes.add(CodeSnippet(cppRecords));

    // @NitroVariant C++ structs and std::variant<> typedefs
    final cppVariants = _generateCppVariants(spec);
    if (cppVariants.isNotEmpty) nodes.add(CodeSnippet(cppVariants));

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
    // Two registration modes (mirrors RN Nitro's HybridObjectRegistry):
    //   1. Factory mode (recommended): register_factory() enables multiple instances.
    //      Dart calls create_instance(key) → factory is invoked → shared_ptr stored.
    //   2. Legacy mode: register_impl() registers a single raw-pointer instance.
    //      Kept for backward compatibility; create_instance() returns a fixed id (0).
    //
    // Layout follows the standard mixed C/C++ header pattern:
    //   • Factory typedef (#ifdef __cplusplus — uses C++ types)
    //   • C function declarations (in extern "C" block for C++ consumers)
    //   • C++-only inline typed helper (after extern "C" closing brace)
    nodes.addAll([
      // C++ factory typedef — must be OUTSIDE extern "C" (uses std::function<>)
      const CodeLine('#ifdef __cplusplus'),
      CodeLine('/// Factory function type — mirrors RN Nitro\'s HybridObjectRegistry constructor fn.'),
      CodeLine('/// Takes the instance key (from Dart\'s getInstance(key)) and returns a shared_ptr.'),
      CodeLine('using Hybrid${className}Factory = std::function<std::shared_ptr<Hybrid$className>(const std::string&)>;'),
      const CodeLine('#endif'),
      const BlankLine(),
      // C function declarations — wrapped in extern "C" for C++ consumers.
      // In plain C, this block is just regular declarations (no name mangling).
      const CodeLine('#ifdef __cplusplus'),
      CodeLine('extern "C" {'),
      const CodeLine('#endif'),
      const BlankLine(),
      CodeLine('/// Register a factory function (recommended — enables multiple instances).'),
      CodeLine('/// Called from create_instance() each time Dart requests a new object.'),
      CodeLine('void ${libStem}_register_factory(void* factory_fn_ptr);'),
      const BlankLine(),
      CodeLine('/// Register a single raw-pointer implementation (legacy single-instance API).'),
      CodeLine('/// Use register_factory() instead for new code.'),
      CodeLine('void ${libStem}_register_impl(Hybrid$className* impl);'),
      const BlankLine(),
      CodeLine('/// Return the registered raw-pointer impl, or nullptr (legacy API).'),
      CodeLine('Hybrid$className* ${libStem}_get_impl(void);'),
      const BlankLine(),
      const CodeLine('#ifdef __cplusplus'),
      CodeLine('} // end extern "C"'),
      const BlankLine(),
      CodeLine('/// C++-only typed factory registration — preferred over the C void* variant.'),
      CodeLine('inline void ${libStem}_register_factory_typed(Hybrid${className}Factory factory) {'),
      CodeLine('    ${libStem}_register_factory(static_cast<void*>(&factory));'),
      CodeLine('}'),
      const CodeLine('#endif'),
      const BlankLine(),
      CodeLine('#endif // $headerGuard'),
    ]);

    return CodeFile(nodes).render(indentText: '    ');
  }

  // ── Type helpers (C++ style) ─────────────────────────────────────────────

  /// C++ return type — mirrors RN Nitro's JSIConverter<T> type mapping.
  /// Nullable types use std::optional<T> (zero-cost tagged union, like std::optional).
  /// Records/Lists/Maps return NitroCppBuffer (binary codec — same as RN Nitro's toJSI).
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
    final isNullable = bt.isNullable || bt.name.endsWith('?');
    final base = bt.name.replaceFirst('?', '');
    if (base == 'void') return 'void';
    // Nullable types → std::optional<T> (mirrors RN Nitro JSIConverter<std::optional<T>>)
    if (isNullable) {
      if (base == 'String') return 'std::optional<std::string>';
      if (enumNames.contains(base)) return 'std::optional<$base>';
      if (structNames.contains(base)) return 'std::optional<$base>';
      if (recordNames.contains(base)) return 'NitroCppBuffer'; // nullable record: empty buffer = null
      final prim = _primitiveType(base);
      if (prim != 'void*') return 'std::optional<$prim>';
    }
    if (base == 'String') return 'std::string';
    if (enumNames.contains(base)) return base;
    if (structNames.contains(base)) return base;
    if (recordNames.contains(base)) return 'NitroCppBuffer';
    if (_isTypedData(base)) return 'NitroCppBuffer';
    return _primitiveType(base);
  }

  /// C++ const-ref param type — nullable types use std::optional<T>.
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
    final isNullable = bt.isNullable || bt.name.endsWith('?');
    final base = bt.name.replaceFirst('?', '');
    // Nullable types → std::optional<T> (const ref for non-trivial types)
    if (isNullable) {
      if (base == 'String') return 'const std::optional<std::string>&';
      if (enumNames.contains(base)) return 'std::optional<$base>';
      if (structNames.contains(base)) return 'const std::optional<$base>&';
      if (recordNames.contains(base)) return 'NitroCppBuffer'; // empty = null
      final prim = _primitiveType(base);
      if (prim != 'void*') return 'std::optional<$prim>';
    }
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
  /// Nullable types use std::optional<T>. Callbacks use std::function<R(Args...)>.
  static List<String> _cppMethodParams(
    List<BridgeParam> params,
    Set<String> enumNames,
    Set<String> structNames,
    Set<String> recordNames,
  ) {
    final parts = <String>[];
    for (final p in params) {
      if (p.type.isFunction) {
        // std::function<R(Args...)> mirrors RN Nitro's JSIConverter<std::function<>>
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
      final isNullable = p.type.isNullable || p.type.name.endsWith('?');
      final base = p.type.name.replaceFirst('?', '');
      if (_isTypedData(base)) {
        parts.add('${_typedDataPtr(base)} ${p.name}');
        parts.add('size_t ${p.name}_length');
      } else if (isNullable) {
        // std::optional<T> for nullable params
        if (base == 'String') {
          parts.add('const std::optional<std::string>& ${p.name}');
        } else if (structNames.contains(base)) {
          parts.add('const std::optional<$base>& ${p.name}');
        } else if (enumNames.contains(base)) {
          parts.add('std::optional<$base> ${p.name}');
        } else if (recordNames.contains(base)) {
          parts.add('NitroCppBuffer ${p.name}'); // empty buffer = null
        } else {
          final prim = _primitiveType(base);
          parts.add('${prim != 'void*' ? 'std::optional<$prim>' : 'void*'} ${p.name}');
        }
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
      // Narrow scalar types (added for RN Nitro parity)
      case 'int8':
        return 'int8_t';
      case 'int16':
        return 'int16_t';
      case 'int32':
        return 'int32_t';
      case 'uint8':
        return 'uint8_t';
      case 'uint16':
        return 'uint16_t';
      case 'uint32':
        return 'uint32_t';
      case 'float':
        return 'float';
      case 'intptr':
        return 'intptr_t';
      case 'size':
        return 'size_t';
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

  /// Callback param as std::function<R(Args...)> — mirrors RN Nitro's JSIConverter<std::function<>>.
  /// Caller can safely capture lambdas, unlike raw function pointers.
  static String _cppCallbackParam(BridgeParam param, Set<String> enumNames) {
    final callback = param.type;
    final ret = _cppCallbackType(callback.functionReturnType ?? 'void', enumNames);
    final paramTypes = callback.functionParams.map((p) => _cppCallbackType(p.name, enumNames, bridgeType: p)).join(', ');
    return 'std::function<$ret($paramTypes)> ${param.name}';
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

  /// Generates C++ struct definitions, `std::variant<>` typedefs, and
  /// `nitro_decode_Xxx` / `nitro_encode_Xxx` free functions for every
  /// `@NitroVariant` type in the spec.
  ///
  /// Wire format: `[1B tag 0..N][optional field bytes — NitroRecordReader order]`
  static String _generateCppVariants(BridgeSpec spec) {
    final localVariants = spec.localVariants;
    if (localVariants.isEmpty) return '';

    final enumNames = spec.enums.map((e) => e.name).toSet();
    final s = CodeWriter();

    s.writeln('// @NitroVariant C++ structs and codecs (generated by Nitrogen)');

    for (final variant in localVariants) {
      // ── Case structs ──────────────────────────────────────────────────────
      for (final c in variant.cases) {
        if (c.isUnit) {
          s.writeln('struct ${c.name} {};');
        } else {
          s.writeln('struct ${c.name} {');
          for (final f in c.fields) {
            final cType = _variantFieldCppType(f.dartType, enumNames);
            s.writeln('    $cType ${f.name};');
          }
          s.writeln('};');
        }
      }
      s.writeln();

      // ── std::variant<> typedef ────────────────────────────────────────────
      final caseNames = variant.cases.map((c) => c.name).join(', ');
      s.writeln('using ${variant.name} = std::variant<$caseNames>;');
      s.writeln();

      // ── nitro_decode_Xxx ──────────────────────────────────────────────────
      s.writeln('inline ${variant.name} nitro_decode_${variant.name}(NitroCppBuffer buf) {');
      s.writeln('    const uint8_t* ptr = buf.data;');
      s.writeln('    if (!ptr || buf.size < 1) throw std::runtime_error("${variant.name}: empty buffer");');
      s.writeln('    int8_t tag = static_cast<int8_t>(*ptr++);');
      s.writeln('    switch (tag) {');
      for (var i = 0; i < variant.cases.length; i++) {
        final c = variant.cases[i];
        s.writeln('    case $i: {');
        if (c.isUnit) {
          s.writeln('        return ${c.name}{};');
        } else {
          // Read fields in order (same as Dart RecordReader — no length prefix for variants)
          for (final f in c.fields) {
            final readExpr = _variantFieldCppRead(f.dartType, enumNames);
            s.writeln('        auto ${f.name} = $readExpr;');
          }
          final args = c.fields.map((f) => '.${f.name} = ${f.name}').join(', ');
          s.writeln('        return ${c.name}{$args};');
        }
        s.writeln('    }');
      }
      s.writeln('    default: throw std::runtime_error("${variant.name}: unknown tag");');
      s.writeln('    }');
      s.writeln('}');
      s.writeln();

      // ── nitro_encode_Xxx ──────────────────────────────────────────────────
      s.writeln('// Note: nitro_encode_${variant.name} returns heap-allocated bytes.');
      s.writeln('// Caller must free with ::free(). Prefer returning NitroCppBuffer from C++ impl');
      s.writeln('// and calling nitro_encode_${variant.name}() before returning to Dart.');
      s.writeln('inline std::pair<uint8_t*, size_t> nitro_encode_${variant.name}(const ${variant.name}& v) {');
      s.writeln('    std::vector<uint8_t> buf;');
      s.writeln('    buf.reserve(16);');
      s.writeln('    std::visit([&](auto&& c) {');
      s.writeln('        using T = std::decay_t<decltype(c)>;');
      for (var i = 0; i < variant.cases.length; i++) {
        final c = variant.cases[i];
        s.writeln('        if constexpr (std::is_same_v<T, ${c.name}>) {');
        s.writeln('            buf.push_back($i); // tag');
        for (final f in c.fields) {
          final writeStmts = _variantFieldCppWrite(f.dartType, 'c.${f.name}', enumNames);
          for (final stmt in writeStmts) {
            s.writeln('            $stmt');
          }
        }
        s.writeln('        }');
      }
      s.writeln('    }, v);');
      s.writeln('    uint8_t* out = static_cast<uint8_t*>(::malloc(buf.size()));');
      s.writeln('    ::memcpy(out, buf.data(), buf.size());');
      s.writeln('    return {out, buf.size()};');
      s.writeln('}');
      s.writeln();
    }

    return s.toString();
  }

  static String _variantFieldCppType(String dartType, Set<String> enumNames) {
    final base = dartType.replaceFirst('?', '');
    if (base == 'String') return 'std::string';
    if (base == 'bool') return 'bool';
    if (base == 'double') return 'double';
    if (base == 'int') return 'int64_t';
    if (enumNames.contains(base)) return 'int64_t'; // enum raw value
    return 'int64_t'; // fallback
  }

  static String _variantFieldCppRead(String dartType, Set<String> enumNames) {
    final base = dartType.replaceFirst('?', '');
    if (base == 'int') return '*reinterpret_cast<const int64_t*>(ptr), ptr += 8';
    if (base == 'double') return '*reinterpret_cast<const double*>(ptr), ptr += 8';
    if (base == 'bool') return 'static_cast<bool>(*ptr++), 0';
    if (enumNames.contains(base)) return '*reinterpret_cast<const int64_t*>(ptr), ptr += 8';
    return '*reinterpret_cast<const int64_t*>(ptr), ptr += 8';
  }

  static List<String> _variantFieldCppWrite(String dartType, String expr, Set<String> enumNames) {
    final base = dartType.replaceFirst('?', '');
    if (base == 'bool') {
      return ['buf.push_back($expr ? 1 : 0);'];
    }
    if (base == 'int' || base == 'double' || enumNames.contains(base)) {
      return [
        '{ auto _v = $expr; buf.insert(buf.end(), reinterpret_cast<const uint8_t*>(&_v), reinterpret_cast<const uint8_t*>(&_v) + 8); }',
      ];
    }
    return ['{ auto _v = $expr; buf.insert(buf.end(), reinterpret_cast<const uint8_t*>(&_v), reinterpret_cast<const uint8_t*>(&_v) + 8); }'];
  }
}
