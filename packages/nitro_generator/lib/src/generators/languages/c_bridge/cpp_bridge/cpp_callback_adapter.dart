part of '../cpp_bridge_generator.dart';

// Wraps a raw Dart callback pointer into the `std::function` a C++
// implementation receives. Used by both C++ paths (mixed and all-C++).

/// Emits a lambda that adapts a raw Dart NativeCallable function pointer to
/// the impl-facing `std::function<R(Args...)>` signature declared in
/// native.g.h, and returns the call-argument expression.
///
/// The DECLARED C parameter type (from [_callbackParamToC]) is a documented
/// lie shared with the JNI/Swift paths — the true Dart-side ABI routes every
/// scalar through Int64 GP registers (doubles as raw bits, bools as 0/1,
/// enums as nativeValue), flattens expandable structs to one Int64 per field,
/// passes records/variants as malloc'd [4B len][payload] pointers that Dart
/// frees, and returns strings as malloc'd Utf8 pointers that native frees.
/// Mirrors `dart_callback_helpers.dart` — keep in sync.
String _emitDesktopCallbackWrapper(
  CodeWriter writer,
  BridgeSpec spec,
  BridgeParam p,
  Set<String> enumNames,
  Set<String> structNames,
  Set<String> recordNames,
  Set<String> variantNames,
) {
  final callback = p.type;
  final retDart = callback.functionReturnType ?? 'void';
  final retBase = bareTypeName(retDart);

  // A record, variant or struct comes back as a malloc'd `[4B len][payload]`
  // block: a pointer, which is not an int64_t on a 32-bit ABI or on wasm.
  final returnsBlock = structNames.contains(retBase) || recordNames.contains(retBase) || variantNames.contains(retBase);

  // ── True ABI signature ──────────────────────────────────────────────────
  final trueRet = switch (retBase) {
    'void' => 'void',
    'String' => 'const char*',
    _ when returnsBlock => 'uint8_t*',
    _ => 'int64_t', // int, double (bits), bool, enum (nativeValue), DateTime, uint64
  };

  // Emscripten needs the NATURAL types instead. Widening every scalar to
  // int64_t works on native because a reinterpret_cast'd call just reuses
  // the GP register, but wasm type-checks `call_indirect` against the
  // function-table signature — a double-as-bits `j` where the table entry
  // says `d` aborts with "function signature mismatch", which is why web
  // callbacks never fired. Natural types also keep doubles off the
  // int64-bits path entirely: dart2js ints are 53-bit, so a round-trip
  // through one would corrupt most double payloads.
  String trueRetWeb;
  switch (retBase) {
    case 'void':
      trueRetWeb = 'void';
    case 'String':
      trueRetWeb = 'const char*';
    case 'double' || 'float':
      trueRetWeb = 'double';
    case 'bool':
      trueRetWeb = 'int32_t';
    case _ when returnsBlock:
      trueRetWeb = 'uint8_t*';
    default:
      trueRetWeb = 'int64_t'; // int, enum (nativeValue), DateTime, uint64
  }

  final trueParams = <String>[];
  final implParams = <String>[];
  final argConversions = <String>[];
  final rawArgs = <String>[];
  // Parallel Emscripten plan; `implParams` is shared (the impl-facing
  // std::function signature is identical on both).
  final trueParamsWeb = <String>[];
  final argConversionsWeb = <String>[];
  final rawArgsWeb = <String>[];
  var supported = true;

  for (var i = 0; i < callback.functionParams.length; i++) {
    final cp = callback.functionParams[i];
    final base = bareTypeName(cp.name);
    final isNullableCp = cp.name.endsWith('?');
    final implType = CppInterfaceGenerator.cppCallbackParamType(
      cp.name,
      enumNames,
      structNames,
      recordNames.union(variantNames),
      bridgeType: cp,
    );
    implParams.add('$implType _a$i');

    if (isNullableCp && (base == 'int' || base == 'double' || base == 'bool')) {
      // Nullable prims expand to (isNull, valueBits) — not yet mapped to the
      // single-param impl signature. Fall back to the raw pointer.
      supported = false;
      break;
    }
    if (structNames.contains(base)) {
      final st = spec.structs.firstWhere((s) => s.name == base);
      final numericOnly = st.fields.every((f) {
        final fb = bareTypeName(f.type.name);
        return fb == 'int' || fb == 'double' || fb == 'bool';
      });
      if (!numericOnly) {
        supported = false;
        break;
      }
      for (final f in st.fields) {
        final fb = bareTypeName(f.type.name);
        trueParams.add('int64_t');
        if (fb == 'double') {
          argConversions.add('int64_t _b${i}_${f.name}; { double _d = _a$i.${f.name}; memcpy(&_b${i}_${f.name}, &_d, 8); }');
          rawArgs.add('_b${i}_${f.name}');
        } else if (fb == 'bool') {
          rawArgs.add('(_a$i.${f.name} ? (int64_t)1 : (int64_t)0)');
        } else {
          rawArgs.add('(int64_t)_a$i.${f.name}');
        }
      }
      // Web takes the struct as ONE pointer to a malloc'd copy in native
      // layout — the same packed shape the sync struct path already proves
      // out — and Dart frees it with <lib>_nitro_free after reading. A
      // per-field expansion would have to bit-cast the doubles again.
      trueParamsWeb.add('const void*');
      argConversionsWeb.add('void* _sp$i = malloc(sizeof($base)); memcpy(_sp$i, &_a$i, sizeof($base));');
      rawArgsWeb.add('_sp$i');
    } else if (recordNames.contains(base) || variantNames.contains(base) || cp.isRecord) {
      trueParams.add('const uint8_t*');
      // The impl passes a SELF-DESCRIBING heap [4B len][payload] block
      // (record.toNativeBuffer() / nitro_Xxx_to_native) — the same
      // ownership-transfer contract as record returns and stream emits.
      // Pass the address straight through: Dart decodes via fromNative and
      // frees it via <lib>_nitro_free; a {nullptr,0} item reaches Dart as
      // nullptr (null on a nullable callback param). The old copy-and-rewrap
      // added a second length prefix — Dart then read the inner prefix as
      // the variant tag ("Unknown TcEvent tag: 17") — and leaked the
      // impl's block on every invocation.
      rawArgs.add('_a$i.data');
      // Pointers are i32 on wasm32 — already natural, nothing to widen.
      trueParamsWeb.add('const uint8_t*');
      rawArgsWeb.add('_a$i.data');
    } else if (base == 'double') {
      trueParams.add('int64_t');
      argConversions.add('int64_t _b$i; { double _d = _a$i; memcpy(&_b$i, &_d, 8); }');
      rawArgs.add('_b$i');
      trueParamsWeb.add('double');
      rawArgsWeb.add('_a$i');
    } else if (base == 'bool') {
      trueParams.add('int64_t');
      rawArgs.add('(_a$i ? (int64_t)1 : (int64_t)0)');
      trueParamsWeb.add('int32_t');
      rawArgsWeb.add('(_a$i ? 1 : 0)');
    } else if (enumNames.contains(base)) {
      trueParams.add('int64_t');
      rawArgs.add('static_cast<int64_t>(_a$i)');
      trueParamsWeb.add('int64_t');
      rawArgsWeb.add('static_cast<int64_t>(_a$i)');
    } else if (base == 'int' || base == 'DateTime' || base == 'uint64') {
      trueParams.add('int64_t');
      rawArgs.add('(int64_t)_a$i');
      trueParamsWeb.add('int64_t');
      rawArgsWeb.add('(int64_t)_a$i');
    } else if (base == 'String' && !isNullableCp) {
      // Borrowed for the call on native: Dart copies it. On web Dart frees
      // it with the module free, so it gets a copy of its own.
      trueParams.add('const char*');
      rawArgs.add('_a$i.c_str()');
      trueParamsWeb.add('const char*');
      argConversionsWeb.add('char* _s$i = strdup(_a$i.c_str());');
      rawArgsWeb.add('_s$i');
    } else {
      supported = false;
      break;
    }
  }

  if (!supported) {
    // Unmapped shape — pass the raw pointer through; std::function conversion
    // will surface a compile error at the exact site if the shapes disagree.
    return p.name;
  }

  final implRet = CppInterfaceGenerator.cppCallbackReturnType(retDart, enumNames, structNames: structNames);
  final rawName = '_rawfn_${p.name}';
  final fnName = '_fn_${p.name}';
  final implSig = '$implRet(${implParams.map((s) => s.substring(0, s.lastIndexOf(' '))).join(', ')})';

  // Emits one lambda per ABI. Both bind the same `_fn_<name>`, so the
  // _impl->... call site below is identical either way.
  void emitLambda({required bool web}) {
    final ret = web ? trueRetWeb : trueRet;
    final params = web ? trueParamsWeb : trueParams;
    final convs = web ? argConversionsWeb : argConversions;
    final args = web ? rawArgsWeb : rawArgs;
    final trueSig = '$ret (*)(${params.isEmpty ? 'void' : params.join(', ')})';

    writer.line('        auto $rawName = reinterpret_cast<$trueSig>(${p.name});');
    writer.line('        std::function<$implSig> $fnName =');
    writer.line('            [$rawName](${implParams.join(', ')}) -> $implRet {');
    for (final c in convs) {
      writer.line('            $c');
    }
    final callExpr = '$rawName(${args.join(', ')})';
    switch (retBase) {
      case 'void':
        writer.line('            $callExpr;');
      case 'String':
        writer.line('            const char* _rp = $callExpr;');
        writer.line('            std::string _rs = _rp ? std::string(_rp) : std::string();');
        writer.line('            if (_rp) { free((void*)_rp); }');
        writer.line('            return _rs;');
      case 'double':
        if (web) {
          // Already a real double — no bit reinterpretation on this path.
          writer.line('            return $callExpr;');
        } else {
          writer.line('            int64_t _rb = $callExpr;');
          writer.line('            double _rd; memcpy(&_rd, &_rb, 8);');
          writer.line('            return _rd;');
        }
      case 'bool':
        writer.line('            return $callExpr != 0;');
      case _ when enumNames.contains(retBase):
        writer.line('            return static_cast<$retBase>($callExpr);');
      case _ when structNames.contains(retBase):
        // A struct is decoded here and handed over by value; the block Dart
        // allocated is released whether or not the decode throws.
        writer.line('            std::unique_ptr<uint8_t, void (*)(void*)> _rp($callExpr, free);');
        writer.line('            if (!_rp) throw std::runtime_error("${p.name}: the callback returned no $retBase");');
        writer.line('            int32_t _rn; memcpy(&_rn, _rp.get(), 4);');
        writer.line('            NitroRecordReader _rr(_rp.get() + 4, (size_t)_rn);');
        writer.line('            return nitro_${retBase}_fromReader(_rr);');
      default:
        writer.line('            return $callExpr;');
    }
    writer.line('            };');
  }

  writer.line('#ifdef __EMSCRIPTEN__');
  emitLambda(web: true);
  writer.line('#else');
  emitLambda(web: false);
  writer.line('#endif');
  return fnName;
}
