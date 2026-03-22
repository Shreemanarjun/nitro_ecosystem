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

    // Enums
    final cEnums = EnumGenerator.generateCEnums(spec);
    if (cEnums.isNotEmpty) {
      s.write(cEnums);
    }

    // Structs
    final cStructs = StructGenerator.generateCStructs(spec);
    if (cStructs.isNotEmpty) {
      s.write(cStructs);
    }

    s.writeln('#ifdef __cplusplus');
    s.writeln('extern "C" {');
    s.writeln('#endif');
    s.writeln();

    for (final func in spec.functions) {
      final ret = _typeToC(func.returnType.name);
      final params = func.params.map((p) => '${_typeToC(p.type.name)} ${p.name}').join(', ');
      s.writeln('$ret ${func.cSymbol}($params);');
    }

    s.writeln();
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
