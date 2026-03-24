import '../bridge_spec.dart';
import 'struct_generator.dart';
import 'enum_generator.dart';

class CppHeaderGenerator {
  static String generate(BridgeSpec spec) {
    final s = StringBuffer();
    s.writeln('#pragma once');
    s.writeln();
    s.writeln('#include <stdint.h>');
    s.writeln('#include <stdbool.h>');
    s.writeln('#include <stdlib.h>');
    s.writeln();
    s.writeln('typedef struct {');
    s.writeln('  int8_t hasError;');
    s.writeln('  const char* name;');
    s.writeln('  const char* message;');
    s.writeln('  const char* code;');
    s.writeln('  const char* stackTrace;');
    s.writeln('} NitroError;');
    s.writeln();

    final cEnums = EnumGenerator.generateCEnums(spec);
    if (cEnums.isNotEmpty) s.write(cEnums);

    final cStructs = StructGenerator.generateCStructs(spec);
    if (cStructs.isNotEmpty) s.write(cStructs);

    s.writeln('extern "C" {');
    s.writeln('#endif');
    s.writeln();
    s.writeln('NitroError* NitroGetError(void);');
    s.writeln('void NitroClearError(void);');
    s.writeln();
    s.writeln();

    // ── Methods ─────────────────────────────────────────────────────────────
    if (spec.functions.isNotEmpty) {
      s.writeln('// Methods');
      for (final func in spec.functions) {
        final isEnumRet = spec.enums.any(
          (en) => en.name == func.returnType.name.replaceFirst('?', ''),
        );
        final ret = isEnumRet ? 'int64_t' : _typeToC(func.returnType.name);
        final params = func.params
            .map((p) {
              final isStructParam = spec.structs.any(
                (st) => st.name == p.type.name.replaceFirst('?', ''),
              );
              return '${isStructParam ? 'void*' : _typeToC(p.type.name)} ${p.name}';
            })
            .join(', ');
        final paramStr = params.isEmpty ? 'void' : params;
        s.writeln('$ret ${func.cSymbol}($paramStr);');
      }
      s.writeln();
    }

    // ── Properties ──────────────────────────────────────────────────────────
    if (spec.properties.isNotEmpty) {
      s.writeln('// Properties');
      for (final prop in spec.properties) {
        final isEnumProp = spec.enums.any(
          (en) => en.name == prop.type.name.replaceFirst('?', ''),
        );
        final cType = isEnumProp ? 'int64_t' : _typeToC(prop.type.name);
        if (prop.hasGetter) {
          s.writeln('$cType ${prop.getSymbol}(void);');
        }
        if (prop.hasSetter) {
          s.writeln('void ${prop.setSymbol}($cType value);');
        }
      }
      s.writeln();
    }

    // ── Streams ─────────────────────────────────────────────────────────────
    if (spec.streams.isNotEmpty) {
      s.writeln('// Streams');
      for (final stream in spec.streams) {
        s.writeln('// Stream<${stream.itemType.name}> ${stream.dartName}');
        s.writeln('void ${stream.registerSymbol}(int64_t dart_port);');
        s.writeln('void ${stream.releaseSymbol}(int64_t dart_port);');
      }
      s.writeln();
    }

    s.writeln('#ifdef __cplusplus');
    s.writeln('}');
    s.writeln('#endif');

    return s.toString();
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
}
