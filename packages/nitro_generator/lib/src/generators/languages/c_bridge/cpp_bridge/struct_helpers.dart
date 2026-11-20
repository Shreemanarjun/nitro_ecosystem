part of '../cpp_bridge_generator.dart';

// @HybridStruct plumbing shared by the JNI, Swift-shim and C++ paths: deep
// copies for returns, null guards for parameters, field releases, and the
// @zeroCopy field bookkeeping.

// ignore: avoid_positional_boolean_parameters
/// `<symbol>_release(void*)` exports for every `@NitroOwned` handle-returning
/// method — the NativeFinalizer target on the Dart side. Shared by the
/// JNI/Swift bridge and the direct C++ bridge (the latter had none, so an
/// owned handle on a C++-only spec failed at symbol lookup).
/// Deep-copy helpers for every @HybridStruct. Dart frees each pointer field
/// of a struct the C++ implementation returns (`freeFields` →
/// `<lib>_nitro_free`), so the bridge must hand back fresh malloc'd copies —
/// never the impl's own storage or the caller's arguments. The shallow
/// `*_ptr = _res` this replaces made Dart free the input arena (glibc aborts).
void _emitStructCloneHelpers(CodeWriter writer, BridgeSpec spec) {
  if (spec.structs.isEmpty) return;
  final names = spec.structs.map((s) => s.name).toSet();
  writer.line('// Deep copies of returned structs: Dart frees every pointer field.');
  for (final st in spec.structs) {
    writer.line('[[maybe_unused]] static ${st.name} _nitro_clone_${st.name}(const ${st.name}& _s);');
  }
  for (final st in spec.structs) {
    writer.line('[[maybe_unused]] static ${st.name} _nitro_clone_${st.name}(const ${st.name}& _s) {');
    writer.line('    ${st.name} _c = _s;');
    for (final f in st.fields) {
      final base = bareTypeName(f.type.name);
      final n = f.name;
      if (base == 'String') {
        writer.line('    _c.$n = _s.$n ? strdup(_s.$n) : nullptr;');
      } else if (f.type.isTypedData) {
        if (f.zeroCopy) continue; // borrowed Dart-pinned view: Dart never frees it
        final len = zeroCopyCompanionField(st, n) ?? '${n}Length';
        writer.line('    if (_s.$n) {');
        writer.line('        size_t _len = (size_t)_s.$len * sizeof(*_s.$n);');
        writer.line('        _c.$n = (decltype(_c.$n))malloc(_len ? _len : 1);');
        writer.line('        if (_len) memcpy(_c.$n, _s.$n, _len);');
        writer.line('    }');
      } else if (names.contains(base)) {
        writer.line('    if (_s.$n) {');
        writer.line('        _c.$n = ($base*)malloc(sizeof($base));');
        writer.line('        *_c.$n = _nitro_clone_$base(*_s.$n);');
        writer.line('    }');
      }
    }
    writer.line('    return _c;');
    writer.line('}');
  }
  writer.blankLine();
}

bool _isNullableStructType(
  BridgeType type,
  Set<String> structNames,
) {
  return (type.isNullable || type.name.endsWith('?')) && structNames.contains(bareTypeName(type.name));
}

/// Emits the heap-field frees inside `<lib>_release_<Struct>` — strings,
/// nested structs, and non-zero-copy typed data.
///
/// Shared by the mixed (JNI/Swift) bridge and the direct C++ bridge. These
/// two emitters were byte-identical copies here, and #40 was a divergence in
/// exactly this function, so they call one implementation (#41).
/// Emits the `NitroCppBuffer` unpack for a `@HybridRecord` / `@NitroVariant`
/// parameter and returns the call-site argument name.
///
/// Both wire shapes are `[4B len][payload]`; a nullable param arrives as
/// nullptr when omitted, so the length prefix must not be dereferenced.
/// Shared by the mixed and direct C++ bridges (#41) — this unpack was an
/// exact copy in both, and a change to the wire format has to land in one
/// place, not two.
String _emitRecordParamUnpack(
  CodeWriter writer,
  BridgeParam p, {
  required bool isNullable,
}) {
  final buf = '_buf_${p.name}';
  if (isNullable) {
    writer.line('        NitroCppBuffer $buf = { nullptr, 0 };');
    writer.line('        if (${p.name} != nullptr) {');
    writer.line('            $buf.data = (const uint8_t*)${p.name} + 4;');
    writer.line('            $buf.size = (size_t)*(int32_t*)${p.name};');
    writer.line('        }');
  } else {
    writer.line('        NitroCppBuffer $buf = { (const uint8_t*)${p.name} + 4, (size_t)*(int32_t*)${p.name} };');
  }
  return buf;
}

void _emitStructFieldReleases(
  CodeWriter writer,
  BridgeStruct st,
  Set<String> structNames,
) {
  bool isNestedStruct(BridgeField f) => structNames.contains(bareTypeName(f.type.name));
  bool isOwnedTypedData(BridgeField f) => f.type.isTypedData && !f.zeroCopy;

  final needsFieldFrees = st.fields.any(
    (f) => f.type.name == 'String' || isNestedStruct(f) || isOwnedTypedData(f),
  );
  if (!needsFieldFrees) return;

  writer.line('    ${st.name}* st_ptr = (${st.name}*)ptr;');
  for (final f in st.fields) {
    if (f.type.name == 'String') {
      // const char* — cast away const for free().
      writer.line('    if (st_ptr->${f.name}) { free((void*)st_ptr->${f.name}); }');
    } else if (isNestedStruct(f) || isOwnedTypedData(f)) {
      writer.line('    if (st_ptr->${f.name}) { free(st_ptr->${f.name}); st_ptr->${f.name} = nullptr; }');
    }
  }
}

void _emitNullableStructParamGuards(
  CodeWriter writer,
  List<BridgeParam> params,
  Set<String> structNames,
  String functionName,
  String returnStatement,
) {
  for (final p in params) {
    if (!_isNullableStructType(p.type, structNames)) continue;
    _emitNullableStructPointerGuard(
      writer,
      paramName: p.name,
      ownerName: functionName,
      returnStatement: returnStatement,
      indent: '    ',
    );
  }
}

void _emitNullableStructPointerGuard(
  CodeWriter writer, {
  required String paramName,
  required String ownerName,
  required String returnStatement,
  required String indent,
}) {
  final blockIndent = indent;
  final bodyIndent = '$indent    ';
  writer.line('${blockIndent}if ($paramName == nullptr) {');
  writer.line('${bodyIndent}nitro_report_error("NullPointerException", "Parameter $paramName for $ownerName cannot be null.", nullptr, nullptr);');
  writer.line('$bodyIndent$returnStatement');
  writer.line('$blockIndent}');
}

bool _isZeroCopy(BridgeStruct st, String fieldName) {
  return st.fields.any((f) => f.name == fieldName && f.zeroCopy);
}

/// Returns the field name used as the element count for a zero-copy field.
///
/// Checks field-specific names first (e.g. pcmLength, pcmSize), then
/// generic length names (stride, size, length, etc.). If nothing is found,
/// returns the synthesized name '${zeroCopyField}Length' — this matches the
/// companion field that [generateCStructs] / [generateDartExtensions] auto-inject
/// when no explicit companion is declared.
String _zeroCopyLenField(BridgeStruct st, String zeroCopyField) {
  final fieldSpecific = ['${zeroCopyField}Length', '${zeroCopyField}Size'];
  for (final c in fieldSpecific) {
    if (st.fields.any((f) => f.name == c && f.type.name == 'int')) return c;
  }
  const generic = ['stride', 'size', 'length', 'len', 'byteLength', 'byteLen'];
  for (final c in generic) {
    if (st.fields.any((f) => f.name == c && f.type.name == 'int')) return c;
  }
  return '${zeroCopyField}Length'; // synthesized — must be auto-injected in struct
}

/// Returns true when [zeroCopyField] has no explicit companion length field
/// in [st]. In that case, the generators inject a synthetic '${field}Length'
/// field into the C struct and populate it from GetDirectBufferCapacity.
bool _zeroCopyNeedsSynthetic(BridgeStruct st, String zeroCopyField) {
  final fieldSpecific = ['${zeroCopyField}Length', '${zeroCopyField}Size'];
  for (final c in fieldSpecific) {
    if (st.fields.any((f) => f.name == c && f.type.name == 'int')) return false;
  }
  const generic = ['stride', 'size', 'length', 'len', 'byteLength', 'byteLen'];
  for (final c in generic) {
    if (st.fields.any((f) => f.name == c && f.type.name == 'int')) return false;
  }
  return true;
}

void _emitZeroCopyTypedDataParam(
  CodeWriter writer,
  BridgeParam param, {
  required String? returnExpr,
}) {
  final name = param.name;
  final elemSize = _typedDataElementSizeExpr(param.type.name);
  final returnStmt = returnExpr == null ? 'return;' : 'return $returnExpr;';
  final allowsNull = param.type.name.endsWith('?');
  final nullPointerCondition = allowsNull ? '$name == nullptr && ${name}_length > 0' : '$name == nullptr';
  final nullBufferCondition = allowsNull ? 'j_$name == nullptr && ${name}_byte_length > 0' : 'j_$name == nullptr';

  writer.line('    if (${name}_length < 0) {');
  writer.line('        nitro_report_error("ArgumentError", "$name: TypedData length cannot be negative", nullptr, nullptr);');
  writer.line('        env->PopLocalFrame(nullptr);');
  writer.line('        $returnStmt');
  writer.line('    }');
  writer.line('    if ($nullPointerCondition) {');
  writer.line('        nitro_report_error("ArgumentError", "$name: TypedData pointer is null for non-empty buffer", nullptr, nullptr);');
  writer.line('        env->PopLocalFrame(nullptr);');
  writer.line('        $returnStmt');
  writer.line('    }');
  writer.line('    if (${name}_length > INT64_MAX / (int64_t)$elemSize) {');
  writer.line('        nitro_report_error("ArgumentError", "$name: TypedData byte length overflow", nullptr, nullptr);');
  writer.line('        env->PopLocalFrame(nullptr);');
  writer.line('        $returnStmt');
  writer.line('    }');
  writer.line('    int64_t ${name}_byte_length = ${name}_length * (int64_t)$elemSize;');
  writer.line('    jobject j_$name = env->NewDirectByteBuffer($name, ${name}_byte_length);');
  writer.line('    if ($nullBufferCondition) {');
  writer.line('        nitro_report_error("ArgumentError", "$name: failed to create direct ByteBuffer", nullptr, nullptr);');
  writer.line('        env->PopLocalFrame(nullptr);');
  writer.line('        $returnStmt');
  writer.line('    }');
}
