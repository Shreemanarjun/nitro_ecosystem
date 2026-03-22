import '../bridge_spec.dart';

class CppHeaderGenerator {
  static String generate(BridgeSpec spec) {
    final s = StringBuffer();
    s.writeln('#pragma once');
    s.writeln();
    s.writeln('#include <stdint.h>');
    s.writeln('#include <stdbool.h>');
    s.writeln();
    s.writeln('#ifdef __cplusplus');
    s.writeln('extern "C" {');
    s.writeln('#endif');
    s.writeln();

    for (final func in spec.functions) {
      final returnType = _toCType(func.returnType);
      final params = func.params.map((p) => '${_toCType(p.type)} ${p.name}').join(', ');
      s.writeln('$returnType ${func.cSymbol}($params);');
    }

    s.writeln();
    s.writeln('#ifdef __cplusplus');
    s.writeln('}');
    s.writeln('#endif');
    return s.toString();
  }

  static String _toCType(BridgeType type) {
    switch (type.name.toLowerCase()) {
      case 'int': return 'int64_t';
      case 'double': return 'double';
      case 'bool': return 'bool';
      case 'string': return 'const char*';
      case 'void': return 'void';
      default: return 'void*'; // Handle properly later
    }
  }
}
