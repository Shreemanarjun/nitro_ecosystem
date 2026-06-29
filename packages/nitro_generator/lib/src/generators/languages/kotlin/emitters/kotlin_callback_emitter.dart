import '../../../../bridge_spec.dart';
import '../../../code_writer.dart';
import 'kotlin_type_mapper.dart';

/// Emits `@JvmStatic external fun _invoke_*` declarations for all
/// callback parameters in the spec.
///
/// One `_invoke_*` method is emitted per unique callback parameter name
/// (de-duplicated across all functions).
class KotlinCallbackEmitter {
  static void emitInvokers(CodeWriter writer, BridgeSpec spec, KotlinTypeMapper mapper) {
    final emitted = <String>{};
    for (final func in spec.functions) {
      for (final p in func.params) {
        if (!p.type.isFunction) continue;
        final nativeName = '_invoke_${p.name}';
        if (emitted.contains(nativeName)) continue;

        final cbParams = p.type.functionParams;
        final paramDecl = StringBuffer('callbackPtr: Long');

        for (var i = 0; i < cbParams.length; i++) {
          final base = cbParams[i].name.replaceFirst('?', '');
          final struct = spec.structs.where((s) => s.name == base).firstOrNull;
          if (struct != null && mapper.isExpandableStruct(struct)) {
            for (final f in struct.fields) {
              paramDecl.write(', arg${i}_${f.name}: Long');
            }
          } else {
            paramDecl.write(', arg$i: ${mapper.callbackParamJni(cbParams[i])}');
          }
        }

        final cbReturnType = p.type.functionReturnType;
        final kotlinReturn = (cbReturnType != null && cbReturnType != 'void') ? ': ${mapper.callbackReturnJniType(cbReturnType)}' : '';

        emitted.add(nativeName);
        writer.line('    @JvmStatic external fun $nativeName($paramDecl)$kotlinReturn');
        // Per-callback release: posts callbackPtr to the Dart release port so
        // Dart can close the NativeCallable. Port was registered by Dart via
        // the NITRO_EXPORT ${libStem}_registerCallbackRelease C function.
        final releaseName = '_release_${p.name}';
        if (emitted.add(releaseName)) {
          writer.line('    @JvmStatic external fun $releaseName(callbackPtr: Long)');
        }
      }
    }
  }
}
