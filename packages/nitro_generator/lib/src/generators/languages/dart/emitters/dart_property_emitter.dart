part of '../dart_ffi_generator.dart';

/// Emits `@override` getter/setter implementations for all [BridgeProperty]s.
void _emitPropertyImpls(CodeWriter writer, BridgeSpec spec) {
// ── Property implementations ─────────────────────────────────────────────
for (final prop in spec.properties) {
  final cap = _cap(prop.dartName);
  final rt = prop.type.name;
  final isRecordProp = prop.type.isRecord;

  if (prop.hasGetter) {
    writer.line('  @override');
    writer.line('  $rt get ${prop.dartName} {');
    writer.line('    checkDisposed();');
    writer.line("    return NitroRuntime.callSync(() {");
    writer.line('      final res = _get${cap}Ptr(_nitroErr);');
    writer.line(_assertCheckError('      '));
    _emitReturnDecode(writer, prop.type, 'res', '      ', spec);
    writer.line("    }, methodName: 'get ${prop.dartName}');");
    writer.line('  }');
  }

  if (prop.hasSetter) {
    writer.line('  @override');
    if (isRecordProp) {
      // @HybridRecord properties use _encodeRecordParam for full Map/List fidelity.
      final encodeExpr = _encodeRecordParam(prop.type, 'value', 'arena');
      writer.line('  set ${prop.dartName}($rt value) {');
      writer.line('    checkDisposed();');
      writer.line("    NitroRuntime.callSync<void>(() => withArena((arena) { _set${cap}Ptr($encodeExpr, _nitroErr); ${_inlineCheckError()} }), methodName: 'set ${prop.dartName}');");
      writer.line('  }');
    } else {
      // All other types: encodePropertyValue covers String, bool, int?, double?,
      // enum, TypedData, struct — each with correct sentinel and arena handling.
      final encoded = encodePropertyValue(prop.type, spec, 'value', 'arena');
      if (encoded.needsArena) {
        writer.line(
          "  set ${prop.dartName}($rt value) { checkDisposed(); NitroRuntime.callSync<void>(() => withArena((arena) { _set${cap}Ptr(${encoded.expr}, _nitroErr); ${_inlineCheckError()} }), methodName: 'set ${prop.dartName}'); }",
        );
      } else {
        writer.line(
          "  set ${prop.dartName}($rt value) { checkDisposed(); NitroRuntime.callSync<void>(() { _set${cap}Ptr(${encoded.expr}, _nitroErr); ${_inlineCheckError()} }, methodName: 'set ${prop.dartName}'); }",
        );
      }
    }
  }
  writer.blankLine();
}

}
