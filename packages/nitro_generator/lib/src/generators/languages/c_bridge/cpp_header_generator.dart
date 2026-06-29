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
      // NitroOpt* — packed 2-field structs for nullable primitive transport.
      // Wire: [1 byte hasValue][N bytes value]. Struct size is fixed, so no
      // RecordWriter length prefix is needed. #pragma pack ensures identical
      // layout across MSVC, GCC, and Clang on all target platforms.
      CodeLine('#ifndef NITRO_OPT_DEFINED'),
      CodeLine('#define NITRO_OPT_DEFINED'),
      CodeLine('#pragma pack(push, 1)'),
      CodeLine('typedef struct { uint8_t hasValue; int64_t  value; } NitroOptInt64;'),
      CodeLine('typedef struct { uint8_t hasValue; double   value; } NitroOptFloat64;'),
      CodeLine('typedef struct { uint8_t hasValue; uint8_t  value; } NitroOptBool;'),
      CodeLine('#pragma pack(pop)'),
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
      // Instance lifecycle: Dart calls create_instance on first getInstance(key),
      // native side invokes the registered factory and returns the int64 instanceId.
      // destroy_instance is called from dispose() to release the native impl.
      CodeLine('NITRO_EXPORT int64_t ${libStem}_create_instance(const char* key);'),
      CodeLine('NITRO_EXPORT void ${libStem}_destroy_instance(int64_t instanceId);'),
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
        final isEnumRet = spec.isEnumName(func.returnType.name.replaceFirst('?', ''));
        // instanceId is the first parameter for all bridge functions (Point 13 multi-instance).
        final paramParts = <String>['int64_t instanceId'];
        for (final p in func.params) {
          if (p.type.isFunction) {
            paramParts.add(_callbackParamToC(p, spec));
            continue;
          }
          final isStructParam = spec.isStructName(p.type.name.replaceFirst('?', ''));
          // Nullable primitives: raw byte pointer (matches Swift UnsafeMutablePointer<UInt8>? @_cdecl).
          final paramBase = p.type.name.replaceFirst('?', '');
          // Enum params use int64_t (rawValue).
          final isEnumParam = spec.isEnumName(paramBase);
          String cType;
          if (p.type.isAnyNativeObject) {
            cType = 'int64_t'; // AnyNativeObject / AnyNativeObject? — opaque instance id
          } else if (spec.isCustomTypeName(paramBase)) {
            cType = 'const uint8_t*'; // @NitroCustomType — user-codec byte buffer
          } else if (p.type.name == 'int?' || p.type.name == 'uint64?' || p.type.name == 'double?' || p.type.name == 'bool?' || p.type.name == 'DateTime?') {
            cType = 'const uint8_t*';
          } else {
            cType = isEnumParam ? 'int64_t' : ((isStructParam || p.type.isNativeHandle) ? 'void*' : _typeToC(p.type.name));
          }
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
          // Sync nullable prim returns: uint8_t* pointer (Dart re-interprets as Pointer<NitroOptXxx>).
          final retBase = func.returnType.name.replaceFirst('?', '');
          // @NitroResult: C returns uint8_t* [1B tag][payload].
          // @NitroVariant: C returns uint8_t* [4B len][1B tag][fields].
          final isVariantRet = spec.isVariantName(retBase);
          final isCustomTypeRet = spec.isCustomTypeName(retBase);
          final ret = func.isResult
              ? 'uint8_t*'
              : isVariantRet
              ? 'uint8_t*'
              : func.returnType.isAnyNativeObject
              ? 'int64_t'
              : isCustomTypeRet
              ? 'uint8_t*'
              : func.returnType.name == 'int?'
              ? 'uint8_t*'
              : func.returnType.name == 'uint64?'
              ? 'uint8_t*'
              : func.returnType.name == 'double?'
              ? 'uint8_t*'
              : func.returnType.name == 'bool?'
              ? 'uint8_t*'
              : func.returnType.name == 'DateTime?'
              ? 'uint8_t*'
              : isEnumRet
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
        final bare = prop.type.name.replaceFirst('?', '');
        final isEnumProp = spec.isEnumName(bare);
        // Property: nullable prim / @HybridRecord / @NitroVariant → uint8_t*;
        // enum → int64_t; everything else via _typeToC.
        final String getterRet;
        final String setterParam;
        if (!isEnumProp) {
          final isRecordOrVariantProp =
              prop.type.isRecord || spec.isRecordName(bare) || spec.isVariantName(bare);
          final isCustomTypeProp = spec.isCustomTypeName(bare);
          if (prop.type.isAnyNativeObject) {
            getterRet = 'int64_t'; setterParam = 'int64_t';
          } else if (isCustomTypeProp) {
            getterRet = 'uint8_t*'; setterParam = 'const uint8_t*';
          } else {
            switch (prop.type.name) {
              case 'int?':    getterRet = 'uint8_t*'; setterParam = 'const uint8_t*'; break;
              case 'uint64?': getterRet = 'uint8_t*'; setterParam = 'const uint8_t*'; break;
              case 'double?': getterRet = 'uint8_t*'; setterParam = 'const uint8_t*'; break;
              case 'bool?':   getterRet = 'uint8_t*'; setterParam = 'const uint8_t*'; break;
              default:
                if (isRecordOrVariantProp) {
                  getterRet = 'uint8_t*'; setterParam = 'const uint8_t*';
                } else {
                  getterRet = _typeToC(prop.type.name); setterParam = getterRet;
                }
            }
          }
        } else {
          getterRet = 'int64_t'; setterParam = 'int64_t';
        }
        // S8: property accessors also receive NitroError* out-param; instanceId for dispatch (Point 13).
        if (prop.hasGetter) {
          nodes.add(CodeLine('NITRO_EXPORT $getterRet ${prop.getSymbol}(int64_t instanceId, NitroError* _nitro_err);'));
        }
        if (prop.hasSetter) {
          nodes.add(CodeLine('NITRO_EXPORT void ${prop.setSymbol}(int64_t instanceId, $setterParam value, NitroError* _nitro_err);'));
        }
      }
      nodes.add(const BlankLine());
    }

    // ── Streams ─────────────────────────────────────────────────────────────
    if (spec.streams.isNotEmpty) {
      nodes.add(const CodeLine('// Streams'));
      for (final stream in spec.streams) {
        nodes.add(CodeLine('// Stream<${stream.itemType.name}> ${stream.dartName}'));
        nodes.add(CodeLine('NITRO_EXPORT void ${stream.registerSymbol}(int64_t instanceId, int64_t dart_port);'));
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
      case 'uint64':
        return 'uint64_t';
      case 'DateTime':
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
      case 'AnyNativeObject':
        return 'int64_t';
      default:
        // NitroAnyMap and Map<String, T> both bridge as length-prefixed binary buffers.
        if (dartType == 'NitroAnyMap' || dartType.startsWith('Map<')) return 'uint8_t*';
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
    if (spec.isEnumName(name)) return 'int64_t';
    // @HybridStruct callback params use void* — matches both JNI and Swift paths.
    // The platform bridges cast internally; a typed const T* would conflict across
    // the #ifdef __ANDROID__ / #elif __APPLE__ compile branches.
    if (spec.isStructName(name)) return 'void*';
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
