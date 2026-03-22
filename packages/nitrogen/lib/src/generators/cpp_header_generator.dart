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
    s.writeln();

    final cEnums = EnumGenerator.generateCEnums(spec);
    if (cEnums.isNotEmpty) s.write(cEnums);

    final cStructs = StructGenerator.generateCStructs(spec);
    if (cStructs.isNotEmpty) s.write(cStructs);

    s.writeln('#ifdef __cplusplus');
    s.writeln('extern "C" {');
    s.writeln('#endif');
    s.writeln();

    // ── Methods ─────────────────────────────────────────────────────────────
    if (spec.functions.isNotEmpty) {
      s.writeln('// Methods');
      for (final func in spec.functions) {
        final ret = _typeToC(func.returnType.name);
        final params = func.params
            .map((p) => '${_typeToC(p.type.name)} ${p.name}')
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
        final cType = _typeToC(prop.type.name);
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
      case 'int': return 'int64_t';
      case 'double': return 'double';
      case 'bool': return 'int8_t';
      case 'String': return 'const char*';
      case 'Uint8List': return 'uint8_t*';
      case 'void': return 'void';
      default: return 'void*';
    }
  }
}
