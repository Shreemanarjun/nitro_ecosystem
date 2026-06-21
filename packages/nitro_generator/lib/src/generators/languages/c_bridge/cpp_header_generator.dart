import '../../../bridge_spec.dart';
import '../../struct_generator.dart';
import '../../enum_generator.dart';
import '../../code_writer.dart';
import '../../generator_metadata.dart';

class CppHeaderGenerator {
  static String generate(BridgeSpec spec) {
    final nodes = <CodeNode>[
      CodeSnippet(generatedFileHeader('//', sourceUri: spec.sourceUri)),
      const CodeLine('#pragma once'),
      const BlankLine(),
      const CodeLine('#include <stdint.h>'),
      const CodeLine('#include <stdbool.h>'),
      const CodeLine('#include <stdlib.h>'),
      const BlankLine(),
    ];
    // Inline nitro.h content so this header is fully self-contained.
    // Using ifndef guards so it composes cleanly with user-supplied nitro.h copies.
    nodes.addAll(const [
      CodeLine('#ifndef NITRO_EXPORT'),
      CodeLine('#  if defined(_WIN32)'),
      CodeLine('#    define NITRO_EXPORT __declspec(dllexport)'),
      CodeLine('#  else'),
      CodeLine('#    define NITRO_EXPORT __attribute__((visibility("default"))) __attribute__((used))'),
      CodeLine('#  endif'),
      CodeLine('#endif'),
      BlankLine(),
      CodeLine('#ifndef NITRO_ERROR_DEFINED'),
      CodeLine('#define NITRO_ERROR_DEFINED'),
      CodeBlock(
        header: 'typedef struct {',
        body: [
          CodeLine('int8_t hasError;'),
          CodeLine('const char* name;'),
          CodeLine('const char* message;'),
          CodeLine('const char* code;'),
          CodeLine('const char* stackTrace;'),
        ],
        footer: '} NitroError;',
      ),
      CodeLine('#endif'),
      BlankLine(),
    ]);

    // Include headers for types imported from other .native.dart files.
    if (spec.importedTypeFiles.isNotEmpty) {
      for (final inc in spec.importedTypeFiles) {
        nodes.add(CodeLine('#include "$inc"'));
      }
      nodes.add(const BlankLine());
    }

    final cEnums = EnumGenerator.generateCEnums(spec);
    if (cEnums.isNotEmpty) nodes.add(CodeSnippet(cEnums));

    final cStructs = StructGenerator.generateCStructs(spec);
    if (cStructs.isNotEmpty) nodes.add(CodeSnippet(cStructs));

    if (spec.isTypeOnly) {
      return CodeFile(nodes).render();
    }

    nodes.addAll(const [
      CodeLine('#ifdef __cplusplus'),
      CodeLine('extern "C" {'),
      CodeLine('#endif'),
      BlankLine(),
    ]);

    final libStem = spec.lib.replaceAll('-', '_');
    nodes.addAll([
      CodeLine('NITRO_EXPORT uint32_t ${libStem}_nitro_abi_version(void);'),
      CodeLine('NITRO_EXPORT const char* ${libStem}_nitro_bridge_checksum(void);'),
      CodeLine('NITRO_EXPORT intptr_t ${libStem}_init_dart_api_dl(void* data);'),
      CodeLine('NITRO_EXPORT NitroError* ${libStem}_get_error(void);'),
      CodeLine('NITRO_EXPORT void ${libStem}_clear_error(void);'),
      if (spec.functions.any((f) => f.zeroCopyReturn && f.returnType.isTypedData))
        CodeLine('NITRO_EXPORT void ${libStem}_release_typed_data_return(void* ptr);'),
      // @NitroOwned: emit a _release symbol for each owned NativeHandle function.
      // The user implements these to free the native heap allocation.
      for (final f in spec.functions.where((f) => f.isOwned && f.returnType.isNativeHandle))
        CodeLine('/// Release the handle returned by ${f.dartName}(). Called by Dart NativeFinalizer.')
      ,
      for (final f in spec.functions.where((f) => f.isOwned && f.returnType.isNativeHandle))
        CodeLine('NITRO_EXPORT void ${f.cSymbol}_release(void* handle);'),
      const BlankLine(),
      const BlankLine(),
      const BlankLine(),
    ]);

    // ── Methods ─────────────────────────────────────────────────────────────
    if (spec.functions.isNotEmpty) {
      nodes.add(const CodeLine('// Methods'));
      for (final func in spec.functions) {
        final isEnumRet = spec.enums.any(
          (en) => en.name == func.returnType.name.replaceFirst('?', ''),
        );
        final paramParts = <String>[];
        for (final p in func.params) {
          if (p.type.isFunction) {
            paramParts.add(_callbackParamToC(p, spec));
            continue;
          }
          final isStructParam = spec.structs.any(
            (st) => st.name == p.type.name.replaceFirst('?', ''),
          );
          // Nullable bool uses int32_t (jint) to preserve the -1 sentinel for null.
          final isNullableBool = p.type.isNullable && p.type.name.replaceFirst('?', '') == 'bool';
          // Enum params use int64_t (rawValue) — void* cast of -1 (null sentinel) is
          // implementation-defined on AArch64 and may not equal int64_t -1.
          final paramBase = p.type.name.replaceFirst('?', '');
          final isEnumParam = spec.enums.any((en) => en.name == paramBase);
          final cType = isNullableBool
              ? 'int32_t'
              : isEnumParam
              ? 'int64_t'
              : ((isStructParam || p.type.isNativeHandle) ? 'void*' : _typeToC(p.type.name));
          paramParts.add('$cType ${p.name}');
          if (p.type.isTypedData) paramParts.add('int64_t ${p.name}_length');
        }
        // @NitroNativeAsync: C entry point is always void + extra dart_port param.
        if (func.isNativeAsync) {
          paramParts.add('int64_t dart_port');
          final paramStr = paramParts.join(', ');
          nodes.add(CodeLine('NITRO_EXPORT void ${func.cSymbol}($paramStr);'));
        } else {
          // S8: only SYNC functions take NitroError* out-param.
          // @nitroAsync functions use TLS get_error/clear_error — no NitroError* in signature.
          if (!func.isAsync) {
            paramParts.add('NitroError* _nitro_err');
          }
          final ret = isEnumRet
              ? 'int64_t'
              : func.returnType.isTypedData
              ? 'uint8_t*'
              : _typeToC(func.returnType.name);
          final params = paramParts.join(', ');
          nodes.add(CodeLine('NITRO_EXPORT $ret ${func.cSymbol}($params);'));
        }
      }
      nodes.add(const BlankLine());
    }

    // ── Properties ──────────────────────────────────────────────────────────
    if (spec.properties.isNotEmpty) {
      nodes.add(const CodeLine('// Properties'));
      for (final prop in spec.properties) {
        final isEnumProp = spec.enums.any(
          (en) => en.name == prop.type.name.replaceFirst('?', ''),
        );
        final cType = isEnumProp ? 'int64_t' : _typeToC(prop.type.name);
        // S8: property accessors also receive NitroError* out-param.
        if (prop.hasGetter) {
          nodes.add(CodeLine('NITRO_EXPORT $cType ${prop.getSymbol}(NitroError* _nitro_err);'));
        }
        if (prop.hasSetter) {
          nodes.add(CodeLine('NITRO_EXPORT void ${prop.setSymbol}($cType value, NitroError* _nitro_err);'));
        }
      }
      nodes.add(const BlankLine());
    }

    // ── Streams ─────────────────────────────────────────────────────────────
    if (spec.streams.isNotEmpty) {
      nodes.add(const CodeLine('// Streams'));
      for (final stream in spec.streams) {
        nodes.add(CodeLine('// Stream<${stream.itemType.name}> ${stream.dartName}'));
        nodes.add(CodeLine('NITRO_EXPORT void ${stream.registerSymbol}(int64_t dart_port);'));
        nodes.add(CodeLine('NITRO_EXPORT void ${stream.releaseSymbol}(int64_t dart_port);'));
      }
      nodes.add(const BlankLine());
    }

    // ── Struct release functions ────────────────────────────────────────────
    if (spec.structs.isNotEmpty) {
      nodes.add(const CodeLine('// Struct release functions'));
      for (final st in spec.structs) {
        nodes.add(CodeLine('NITRO_EXPORT void ${libStem}_release_${st.name}(void* ptr);'));
      }
      nodes.add(const BlankLine());
    }

    nodes.addAll(const [
      CodeLine('#ifdef __cplusplus'),
      CodeLine('}'),
      CodeLine('#endif'),
    ]);

    return CodeFile(nodes).render();
  }

  static String _typeToC(String dartType) {
    switch (dartType.replaceFirst('?', '')) {
      case 'int':
        return 'int64_t';
      case 'double':
        return 'double';
      case 'bool':
        return 'int8_t';
      case 'String':
        return 'const char*';
      case 'Uint8List':
        return 'uint8_t*';
      case 'Int8List':
        return 'int8_t*';
      case 'Int16List':
        return 'int16_t*';
      case 'Int32List':
        return 'int32_t*';
      case 'Uint16List':
        return 'uint16_t*';
      case 'Uint32List':
        return 'uint32_t*';
      case 'Float32List':
        return 'float*';
      case 'Float64List':
        return 'double*';
      case 'Int64List':
        return 'int64_t*';
      case 'Uint64List':
        return 'uint64_t*';
      case 'void':
        return 'void';
      default:
        return 'void*';
    }
  }

  static String _callbackParamToC(BridgeParam param, BridgeSpec spec) {
    final callback = param.type;
    final ret = _callbackTypeToC(callback.functionReturnType ?? 'void', spec);
    final params = callback.functionParams.map((p) => _callbackTypeToC(p.name, spec, bridgeType: p)).join(', ');
    final paramStr = params.isEmpty ? 'void' : params;
    return '$ret (*${param.name})($paramStr)';
  }

  static String _callbackTypeToC(String dartType, BridgeSpec spec, {BridgeType? bridgeType}) {
    if (bridgeType?.isPointer == true) {
      return _pointerToC(bridgeType!.pointerInnerType);
    }
    final name = dartType.replaceFirst('?', '');
    if (spec.enums.any((en) => en.name == name)) return 'int64_t';
    return _typeToC(name);
  }

  static String _pointerToC(String? innerType) {
    switch (innerType) {
      case 'Uint8':
        return 'uint8_t*';
      case 'Int8':
        return 'int8_t*';
      case 'Int16':
        return 'int16_t*';
      case 'Int32':
        return 'int32_t*';
      case 'Uint16':
        return 'uint16_t*';
      case 'Uint32':
        return 'uint32_t*';
      case 'Float':
        return 'float*';
      case 'Double':
        return 'double*';
      case 'Int64':
        return 'int64_t*';
      case 'Uint64':
        return 'uint64_t*';
      case 'Utf8':
      case 'Char':
        return 'char*';
      case 'Void':
      case 'void':
      case null:
        return 'void*';
      default:
        return 'void*';
    }
  }
}
