import '../../../../bridge_spec.dart';
import '../../../code_writer.dart';
import 'swift_map_emitter.dart';
import 'swift_type_mapper.dart';

part 'function/swift_sync.dart';
part 'function/swift_async.dart';
part 'function/swift_native_async.dart';
part 'function/swift_returns.dart';
part 'function/swift_arguments.dart';

/// Emits a `@_cdecl` stub for a single [BridgeFunction].
///
/// Handles all dispatch paths:
///   - `@NitroNativeAsync` — Task + Dart_PostCObject_DL
///   - `@nitroAsync` — DispatchSemaphore + Task.detached
///   - sync — direct `Registry.impl?.method(…)` call
///
/// [emit] picks the path; each one lives in `function/`: `swift_sync.dart`,
/// `swift_async.dart`, `swift_native_async.dart`, with the argument
/// conversions in `swift_arguments.dart` and shared return shapes in
/// `swift_returns.dart`.
class SwiftFunctionEmitter {
  static void emit(
    CodeWriter writer,
    BridgeFunction func,
    BridgeSpec spec,
    SwiftTypeMapper mapper,
  ) {
    if (func.lineNumber != null) {
      writer.line('// source: ${spec.sourceUri.split('/').last}:${func.lineNumber}');
    }

    final cRetType = mapper.cdeclReturnType(func);

    final params = func.params
        .expand((p) {
          if (p.type.isFunction) {
            return ['_ ${p.name}: ${mapper.cdeclCallbackType(p.type)}'];
          }
          final t = mapper.cdeclParamType(p.type.name, bridgeType: p.type);
          if (p.type.isTypedData) {
            return ['_ ${p.name}: $t', '_ ${p.name}_length: Int64'];
          }
          return ['_ ${p.name}: $t'];
        })
        .join(', ');

    final stringParams = func.params.where((p) => p.type.name == 'String' || p.type.name == 'String?').toList();
    final typedListParams = func.params.where((p) => p.type.isTypedData).toList();
    final recordListParams = func.params.where((p) => p.type.isRecord && p.type.name.startsWith('List<')).toList();

    final callArgs = _buildCallArgs(func, spec, mapper);

    final isStruct = spec.isStructName(bareTypeName(func.returnType.name));
    final isRecord = spec.isRecordName(bareTypeName(func.returnType.name));
    final isMap = func.returnType.isMap;
    final isAnyMap = func.returnType.isAnyMap;
    final isRecordList = func.returnType.name.startsWith('List<');
    final isBool = mapper.cdeclReturnType(func) == 'Int8';
    final isVoid = func.returnType.name == 'void';
    final isString = bareTypeName(func.returnType.name) == 'String';
    final isTypedDataReturn = func.returnType.isTypedData;
    final isEnumRet = spec.isEnumName(bareTypeName(func.returnType.name));
    final isVariantRet = spec.isVariantName(bareTypeName(func.returnType.name));
    final isCustomTypeReturn = spec.isCustomTypeName(func.returnType.baseName);

    if (func.isNativeAsync) {
      _emitNativeAsync(
        writer,
        func,
        spec,
        mapper,
        params,
        stringParams,
        typedListParams,
        isVoid: func.returnType.name == 'void',
        isRecord: isRecord,
        isRecordList: isRecordList,
        isStruct: isStruct,
        isMap: isMap,
        isAnyMap: isAnyMap,
        isTypedDataReturn: isTypedDataReturn,
        isVariantRet: isVariantRet,
        isCustomTypeReturn: isCustomTypeReturn,
      );
      return;
    }

    writer.line('@_cdecl("_${spec.namespace}_call_${func.dartName}")');
    writer.line('public func _${spec.namespace}_call_${func.dartName}($params) -> $cRetType {');

    _emitParamConversions(writer, stringParams, typedListParams, recordListParams, func);
    SwiftMapEmitter.emitParamDecodes(writer, func, spec);

    if (func.isAsync) {
      _emitAsync(
        writer,
        func,
        spec,
        callArgs,
        mapper,
        isStruct: isStruct,
        isRecord: isRecord,
        isRecordList: isRecordList,
        isBool: isBool,
        isVoid: isVoid,
        isString: isString,
        isTypedDataReturn: isTypedDataReturn,
        isEnumRet: isEnumRet,
        isMap: isMap,
        isAnyMap: isAnyMap,
      );
    } else {
      final syncTarget = func.mainThread ? CodeWriter() : writer;
      _emitSync(
        syncTarget,
        func,
        spec,
        callArgs,
        mapper,
        isStruct: isStruct,
        isRecord: isRecord,
        isRecordList: isRecordList,
        isBool: isBool,
        isVoid: isVoid,
        isString: isString,
        isTypedDataReturn: isTypedDataReturn,
        isEnumRet: isEnumRet,
        isMap: isMap,
        isAnyMap: isAnyMap,
        isVariantRet: isVariantRet,
      );
      if (func.mainThread) {
        // @mainThread sync (issue #19): run the whole dispatch body on the
        // main thread in ONE hop — every return path (guards, encodes) stays
        // inside the closure. _nitroMainSync executes inline when the caller
        // is already the main thread, so there is no self-deadlock; from any
        // other thread the caller blocks until the main queue runs the body.
        writer.line('    return _nitroMainSync { () -> $cRetType in');
        for (final l in syncTarget.toString().trimRight().split('\n')) {
          writer.line(l.isEmpty ? '' : '    $l');
        }
        writer.line('    }');
      }
    }

    writer.line('}');
    writer.blankLine();
  }

  // ── param call-arg mapping ─────────────────────────────────────────────────

  // ── param conversions (top of func body) ─────────────────────────────────

  // ── @NitroNativeAsync ─────────────────────────────────────────────────────

  // ── async (DispatchSemaphore) ─────────────────────────────────────────────

  // ── sync ─────────────────────────────────────────────────────────────────

  // ── @NitroResult encode helper selector ──────────────────────────────────────

  // ── shared return helpers ─────────────────────────────────────────────────

}

/// C symbol prefix of this library (`lib` with dashes as underscores).
String _libStem(BridgeSpec spec) => spec.lib.replaceAll('-', '_');
