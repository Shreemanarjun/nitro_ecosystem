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
      // MSVC deprecates the POSIX strdup name; _strdup is identical. The
      // struct codecs below strdup String fields, so the shim lives here too.
      const CodeLine('#if defined(_MSC_VER) && !defined(strdup)'),
      const CodeLine('#define strdup _strdup'),
      const CodeLine('#endif'),
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
          CodeLine('void writeInt8(int8_t v) { _buf.push_back(static_cast<uint8_t>(v)); }'),
          CodeLine('void writeDouble(double v) { _buf.insert(_buf.end(), reinterpret_cast<const uint8_t*>(&v), reinterpret_cast<const uint8_t*>(&v) + 8); }'),
          CodeLine('void writeBool(bool v) { _buf.push_back(v ? 1 : 0); }'),
          CodeLine('void writeString(const std::string& s) { int32_t n = (int32_t)s.size(); writeInt32(n); _buf.insert(_buf.end(), s.begin(), s.end()); }'),
          CodeLine('void writeBytes(const uint8_t* data, size_t n) { if (data && n) _buf.insert(_buf.end(), data, data + n); }'),
          CodeLine('/// Returns heap-allocated [4B length][payload]. Caller must ::free().'),
          CodeLine('uint8_t* toNative() const {'),
          CodeLine('    int32_t payloadLen = (int32_t)_buf.size();'),
          CodeLine('    uint8_t* out = (uint8_t*)::malloc(sizeof(int32_t) + (size_t)payloadLen);'),
          CodeLine('    if (!out) return nullptr;'),
          CodeLine('    ::memcpy(out, &payloadLen, sizeof(int32_t));'),
          CodeLine('    if (payloadLen > 0) ::memcpy(out + sizeof(int32_t), _buf.data(), (size_t)payloadLen);'),
          CodeLine('    return out;'),
          CodeLine('}'),
          CodeLine('/// Non-owning view of the payload (no length prefix). Valid while this writer lives.'),
          CodeLine('NitroCppBuffer toBuffer() const { return { _buf.data(), _buf.size() }; }'),
          CodeLine('/// Heap-allocated [4B length][payload] wrapped in a buffer whose size'),
          CodeLine('/// includes the prefix. Use as the return value of record/variant methods:'),
          CodeLine('/// ownership transfers to Dart (Dart frees it after decoding).'),
          CodeLine('NitroCppBuffer toNativeBuffer() const { return { toNative(), sizeof(int32_t) + _buf.size() }; }'),
        ],
        footer: '};',
      ),
      BlankLine(),
    ]);

    // Bounds-checked reader — required by struct codecs, records, and variants.
    final needsReader = spec.recordTypes.isNotEmpty || spec.variants.isNotEmpty || spec.structs.isNotEmpty;
    if (needsReader) {
      nodes.add(CodeSnippet(cppRecordReaderDefinition));
      nodes.add(const BlankLine());
    }

    // @HybridStruct free-function codecs (structs are plain C typedefs — no members).
    final structCodecs = generateCppStructCodecs(spec);
    if (structCodecs.isNotEmpty) nodes.add(CodeSnippet(structCodecs));

    // @HybridRecord C++ structs with bounds-checked decoder (§3.3) + encoder.
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
        // Nullable-aware: `double?` getter returns std::optional<double> — the
        // bridge encodes std::nullopt as the null wire value (NitroOpt blob).
        final cppType = _cppReturnType(prop.type, enumNames, structNames, recordNames);
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
        // Nullable-aware: Stream<int?> emits std::optional<int64_t> — the bridge
        // posts kNull for std::nullopt. Record/variant items are NitroCppBuffer
        // payload views (no length prefix); the bridge copies before posting.
        final itemCpp = _cppReturnType(stream.itemType, enumNames, structNames, recordNames);
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

  /// Public alias of [_cppReturnType] for other generators (bridge dispatch,
  /// impl starter, mocks) so all C++ artifacts share ONE type mapping.
  static String cppReturnTypeFor(
    BridgeType bt,
    Set<String> enumNames,
    Set<String> structNames,
    Set<String> recordNames,
  ) => _cppReturnType(bt, enumNames, structNames, recordNames);

  /// Public alias of [_cppMethodParams] — full impl-facing parameter list.
  static List<String> cppMethodParamsFor(
    List<BridgeParam> params,
    Set<String> enumNames,
    Set<String> structNames,
    Set<String> recordNames,
  ) => _cppMethodParams(params, enumNames, structNames, recordNames);

  /// Public alias of [_cppParamType] — impl-facing type of a single param.
  static String cppParamTypeFor(
    BridgeType bt,
    Set<String> enumNames,
    Set<String> structNames,
    Set<String> recordNames,
  ) => _cppParamType(bt, enumNames, structNames, recordNames);

  /// C++ return type — mirrors RN Nitro's `JSIConverter<T>` type mapping.
  /// Nullable types use `std::optional<T>` (zero-cost tagged union, like std::optional).
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

  /// C++ const-ref param type — nullable types use `std::optional<T>`.
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

  /// Build the full parameter list for a method signature.
  /// TypedData types expand to two params: pointer + length.
  /// Nullable types use `std::optional<T>`. Callbacks use `std::function<R(Args...)>`.
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
        parts.add(cppCallbackParam(p, enumNames, structNames, recordNames));
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
      case 'int64':
        return 'int64_t';
      case 'uint64':
        return 'uint64_t';
      // DateTime bridges as int64 milliseconds-since-epoch (L11).
      case 'DateTime':
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

  /// Callback param as `std::function<R(Args...)>` — mirrors RN Nitro's `JSIConverter<std::function<>>`.
  /// Caller can safely capture lambdas, unlike raw function pointers.
  ///
  /// These are the IMPL-FACING types; the bridge (`cpp_bridge_generator.dart`)
  /// wraps the raw Dart NativeCallable ABI (everything routed through Int64
  /// GP registers, doubles as raw bits, strings as malloc'd Utf8 pointers)
  /// into these clean signatures. Keep both sides in sync.
  static String cppCallbackParam(
    BridgeParam param,
    Set<String> enumNames,
    Set<String> structNames,
    Set<String> recordNames,
  ) {
    final callback = param.type;
    final ret = cppCallbackReturnType(callback.functionReturnType ?? 'void', enumNames);
    final paramTypes = callback.functionParams.map((p) => cppCallbackParamType(p.name, enumNames, structNames, recordNames, bridgeType: p)).join(', ');
    return 'std::function<$ret($paramTypes)> ${param.name}';
  }

  /// Return type of a callback as seen by the C++ impl.
  static String cppCallbackReturnType(String dartType, Set<String> enumNames) {
    final base = dartType.replaceFirst('?', '');
    if (base == 'void') return 'void';
    if (enumNames.contains(base)) return base;
    if (base == 'bool') return 'bool';
    if (base == 'String') return 'std::string';
    return _primitiveType(base);
  }

  /// Parameter type of a callback as seen by the C++ impl.
  static String cppCallbackParamType(
    String dartType,
    Set<String> enumNames,
    Set<String> structNames,
    Set<String> recordNames, {
    BridgeType? bridgeType,
  }) {
    if (bridgeType?.isPointer == true) {
      final inner = bridgeType!.pointerInnerType;
      if (inner == null || inner == 'Void' || inner == 'void') return 'void*';
      if (inner == 'Utf8' || inner == 'Char') return 'char*';
      final prim = _primitiveType(inner.replaceFirst('?', ''));
      return prim == 'void*' ? 'void*' : '$prim*';
    }
    final base = dartType.replaceFirst('?', '');
    if (base == 'void') return 'void';
    if (enumNames.contains(base)) return base;
    if (structNames.contains(base)) return 'const $base&';
    if (recordNames.contains(base)) return 'NitroCppBuffer';
    if (base == 'bool') return 'bool';
    if (base == 'String') return 'const std::string&';
    return _primitiveType(base);
  }

  /// Generates C++ struct definitions, `std::variant<>` typedefs, and
  /// `nitro_decode_Xxx` / `nitro_encode_Xxx` free functions for every
  /// `@NitroVariant` type in the spec.
  ///
  /// Wire format mirrors the Dart `<V>VariantExt.writeFields` exactly:
  /// `[1B tag 0..N][fields in declaration order]` where each nullable field is
  /// preceded by a 1-byte presence flag (1 = present), enum fields are written
  /// as their case INDEX (not nativeValue — matches Dart `enum.index`), record
  /// fields are written inline via `writeFields`, and `List<prim>` fields are
  /// `[4B count][items]`.
  static String _generateCppVariants(BridgeSpec spec) {
    final localVariants = spec.localVariants;
    if (localVariants.isEmpty) return '';

    final enumNames = spec.enums.map((e) => e.name).toSet();
    final s = CodeWriter();

    s.writeln('// @NitroVariant C++ structs and codecs (generated by Nitrogen)');

    // ── Enum index helpers (variant enum fields use Dart's enum.index) ──────
    final variantEnums = <String>{};
    for (final variant in localVariants) {
      for (final c in variant.cases) {
        for (final f in c.fields) {
          final base = f.dartType.replaceFirst('?', '');
          if (enumNames.contains(base)) variantEnums.add(base);
          final item = f.itemTypeName;
          if (item != null && enumNames.contains(item)) variantEnums.add(item);
        }
      }
    }
    for (final enumName in variantEnums) {
      final e = spec.enums.firstWhere((x) => x.name == enumName);
      final values = e.rawValues ?? List<int>.generate(e.values.length, (i) => e.startValue + i);
      final n = values.length;
      final list = values.join(', ');
      s.writeln('// Dart variant fields encode enums by case index (enum.index), not nativeValue.');
      s.writeln('inline $enumName nitro_${enumName}_fromIndex(int64_t i) {');
      s.writeln('    static const int64_t _v[$n] = { $list };');
      s.writeln('    return static_cast<$enumName>((i >= 0 && i < $n) ? _v[i] : _v[0]);');
      s.writeln('}');
      s.writeln('inline int64_t nitro_${enumName}_toIndex($enumName x) {');
      s.writeln('    static const int64_t _v[$n] = { $list };');
      s.writeln('    for (int64_t i = 0; i < $n; i++) { if (_v[i] == (int64_t)x) return i; }');
      s.writeln('    return 0;');
      s.writeln('}');
    }
    if (variantEnums.isNotEmpty) s.writeln();

    for (final variant in localVariants) {
      // ── Case structs ──────────────────────────────────────────────────────
      for (final c in variant.cases) {
        if (c.isUnit) {
          s.writeln('struct ${c.name} {};');
        } else {
          s.writeln('struct ${c.name} {');
          for (final f in c.fields) {
            final cType = _variantFieldCppType(f, enumNames);
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
      s.writeln('/// Decodes a ${variant.name} from a wire payload view (no 4-byte length prefix).');
      s.writeln('inline ${variant.name} nitro_decode_${variant.name}(NitroCppBuffer buf) {');
      s.writeln('    NitroRecordReader _r(buf);');
      s.writeln('    int8_t tag = _r.readInt8();');
      s.writeln('    switch (tag) {');
      for (var i = 0; i < variant.cases.length; i++) {
        final c = variant.cases[i];
        s.writeln('    case $i: {');
        if (c.isUnit) {
          s.writeln('        return ${c.name}{};');
        } else {
          s.writeln('        ${c.name} _c{};');
          for (final f in c.fields) {
            _emitVariantFieldRead(s, f, enumNames, '        ');
          }
          s.writeln('        return _c;');
        }
        s.writeln('    }');
      }
      s.writeln('    default: throw std::runtime_error("${variant.name}: unknown tag");');
      s.writeln('    }');
      s.writeln('}');
      s.writeln();

      // ── nitro_encode_Xxx ──────────────────────────────────────────────────
      s.writeln('/// Appends the wire payload (tag + fields, no length prefix) to [w].');
      s.writeln('inline void nitro_encode_${variant.name}(const ${variant.name}& v, NitroRecordWriter& w) {');
      s.writeln('    std::visit([&w](auto&& c) {');
      s.writeln('        using T = std::decay_t<decltype(c)>;');
      s.writeln('        (void)c;');
      for (var i = 0; i < variant.cases.length; i++) {
        final c = variant.cases[i];
        s.writeln('        if constexpr (std::is_same_v<T, ${c.name}>) {');
        s.writeln('            w.writeInt8($i); // tag');
        for (final f in c.fields) {
          _emitVariantFieldWrite(s, f, 'c.${f.name}', enumNames, '            ');
        }
        s.writeln('        }');
      }
      s.writeln('    }, v);');
      s.writeln('}');
      s.writeln();
      s.writeln('/// Heap-allocated [4B length][payload] block for returning a ${variant.name}');
      s.writeln('/// to Dart (method returns / property getters). Ownership transfers to Dart.');
      s.writeln('inline NitroCppBuffer nitro_${variant.name}_to_native(const ${variant.name}& v) {');
      s.writeln('    NitroRecordWriter _w;');
      s.writeln('    nitro_encode_${variant.name}(v, _w);');
      s.writeln('    return _w.toNativeBuffer();');
      s.writeln('}');
      s.writeln();
    }

    return s.toString();
  }

  static String _variantFieldCppType(BridgeRecordField f, Set<String> enumNames) {
    final base = f.dartType.replaceFirst('?', '');
    String core;
    switch (f.kind) {
      case RecordFieldKind.primitive:
        core = base == 'String'
            ? 'std::string'
            : base == 'bool'
            ? 'bool'
            : base == 'double'
            ? 'double'
            : 'int64_t';
      case RecordFieldKind.enumValue:
        core = enumNames.contains(base) ? base : 'int64_t';
      case RecordFieldKind.recordObject:
      case RecordFieldKind.struct:
        core = base;
      case RecordFieldKind.listPrimitive:
        final item = f.itemTypeName ?? 'int';
        core =
            'std::vector<${item == 'String'
                ? 'std::string'
                : item == 'double'
                ? 'double'
                : item == 'bool'
                ? 'bool'
                : 'int64_t'}>';
      case RecordFieldKind.listEnumValue:
        final item = f.itemTypeName ?? 'int';
        core = 'std::vector<${enumNames.contains(item) ? item : 'int64_t'}>';
      case RecordFieldKind.listRecordObject:
        core = 'std::vector<${f.itemTypeName}>';
      case RecordFieldKind.typedData:
        core = 'std::vector<uint8_t>';
    }
    return f.isNullable ? 'std::optional<$core>' : core;
  }

  /// Emits statements reading one variant field into `_c.<name>`.
  static void _emitVariantFieldRead(
    CodeWriter s,
    BridgeRecordField f,
    Set<String> enumNames,
    String indent,
  ) {
    final base = f.dartType.replaceFirst('?', '');
    String readCore() {
      switch (f.kind) {
        case RecordFieldKind.primitive:
          if (base == 'String') return '_r.readString()';
          if (base == 'bool') return '_r.readBool()';
          if (base == 'double') return '_r.readDouble()';
          return '_r.readInt()';
        case RecordFieldKind.enumValue:
          return enumNames.contains(base) ? 'nitro_${base}_fromIndex(_r.readInt())' : '_r.readInt()';
        case RecordFieldKind.recordObject:
        case RecordFieldKind.struct:
          return '$base::fromReader(_r)';
        default:
          return '';
      }
    }

    switch (f.kind) {
      case RecordFieldKind.primitive:
      case RecordFieldKind.enumValue:
      case RecordFieldKind.recordObject:
      case RecordFieldKind.struct:
        if (f.isNullable) {
          s.writeln('${indent}if (_r.readBool()) { _c.${f.name} = ${readCore()}; }');
        } else {
          s.writeln('${indent}_c.${f.name} = ${readCore()};');
        }
      case RecordFieldKind.listPrimitive:
      case RecordFieldKind.listEnumValue:
      case RecordFieldKind.listRecordObject:
        final item = f.itemTypeName ?? 'int';
        String itemRead;
        if (f.kind == RecordFieldKind.listRecordObject) {
          itemRead = '$item::fromReader(_r)';
        } else if (f.kind == RecordFieldKind.listEnumValue && enumNames.contains(item)) {
          itemRead = 'nitro_${item}_fromIndex(_r.readInt())';
        } else if (item == 'String') {
          itemRead = '_r.readString()';
        } else if (item == 'double') {
          itemRead = '_r.readDouble()';
        } else if (item == 'bool') {
          itemRead = '_r.readBool()';
        } else {
          itemRead = '_r.readInt()';
        }
        final body = '{ int32_t _n = _r.readInt32(); auto& _vec = ${f.isNullable ? '_c.${f.name}.emplace()' : '_c.${f.name}'}; _vec.reserve((size_t)_n); for (int32_t _i = 0; _i < _n; _i++) _vec.push_back($itemRead); }';
        if (f.isNullable) {
          s.writeln('${indent}if (_r.readBool()) $body');
        } else {
          s.writeln('$indent$body');
        }
      case RecordFieldKind.typedData:
        final body = '{ int32_t _n = _r.readInt32(); auto& _vec = ${f.isNullable ? '_c.${f.name}.emplace()' : '_c.${f.name}'}; _vec.resize((size_t)_n); _r.readBytes(_vec.data(), (size_t)_n); }';
        if (f.isNullable) {
          s.writeln('${indent}if (_r.readBool()) $body');
        } else {
          s.writeln('$indent$body');
        }
    }
  }

  /// Emits statements writing one variant field from [expr].
  static void _emitVariantFieldWrite(
    CodeWriter s,
    BridgeRecordField f,
    String expr,
    Set<String> enumNames,
    String indent,
  ) {
    final base = f.dartType.replaceFirst('?', '');
    // For nullable fields, [v] below is the unwrapped value.
    final v = f.isNullable ? '(*$expr)' : expr;
    String writeCore() {
      switch (f.kind) {
        case RecordFieldKind.primitive:
          if (base == 'String') return 'w.writeString($v);';
          if (base == 'bool') return 'w.writeBool($v);';
          if (base == 'double') return 'w.writeDouble($v);';
          return 'w.writeInt($v);';
        case RecordFieldKind.enumValue:
          return enumNames.contains(base) ? 'w.writeInt(nitro_${base}_toIndex($v));' : 'w.writeInt($v);';
        case RecordFieldKind.recordObject:
        case RecordFieldKind.struct:
          return '$v.encodeInto(w);';
        case RecordFieldKind.listPrimitive:
        case RecordFieldKind.listEnumValue:
        case RecordFieldKind.listRecordObject:
          final item = f.itemTypeName ?? 'int';
          String itemWrite;
          if (f.kind == RecordFieldKind.listRecordObject) {
            itemWrite = '_e.encodeInto(w);';
          } else if (f.kind == RecordFieldKind.listEnumValue && enumNames.contains(item)) {
            itemWrite = 'w.writeInt(nitro_${item}_toIndex(_e));';
          } else if (item == 'String') {
            itemWrite = 'w.writeString(_e);';
          } else if (item == 'double') {
            itemWrite = 'w.writeDouble(_e);';
          } else if (item == 'bool') {
            itemWrite = 'w.writeBool(_e);';
          } else {
            itemWrite = 'w.writeInt(_e);';
          }
          return '{ w.writeInt32((int32_t)$v.size()); for (const auto& _e : $v) { $itemWrite } }';
        case RecordFieldKind.typedData:
          return '{ w.writeInt32((int32_t)$v.size()); w.writeBytes($v.data(), $v.size()); }';
      }
    }

    if (f.isNullable) {
      s.writeln('${indent}w.writeBool($expr.has_value());');
      s.writeln('${indent}if ($expr.has_value()) { ${writeCore()} }');
    } else {
      s.writeln('$indent${writeCore()}');
    }
  }
}
