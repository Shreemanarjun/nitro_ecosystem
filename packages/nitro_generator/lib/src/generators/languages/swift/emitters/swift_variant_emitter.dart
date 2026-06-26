import '../../../../bridge_spec.dart';
import '../../../code_writer.dart';
import 'swift_type_mapper.dart';

/// Emits a Swift `enum` with associated-value cases and `fromReader` / `writeFields`
/// methods for a `@NitroVariant`-annotated sealed Dart class.
///
/// Wire format: `[1B tag 0..N] [optional field bytes — record codec]`
///
/// Example output:
/// ```swift
/// enum FilterResult {
///     case accepted(id: String)
///     case rejected
///
///     static func fromReader(_ r: RecordReader) -> FilterResult {
///         let tag = r.readInt8()
///         switch tag {
///         case 0: return .accepted(id: r.readString())
///         case 1: return .rejected
///         default: fatalError("Unknown FilterResult tag: \(tag)")
///         }
///     }
///
///     func writeFields(to w: RecordWriter) {
///         switch self {
///         case .accepted(let id):
///             w.writeInt8(0)
///             w.writeString(id)
///         case .rejected:
///             w.writeInt8(1)
///         }
///     }
/// }
/// ```
class SwiftVariantEmitter {
  static void emit(CodeWriter writer, BridgeVariant variant, SwiftTypeMapper mapper) {
    final name = variant.name;

    writer.line('enum $name {');
    writer.indent(() {
      // ── Case declarations ──────────────────────────────────────────────────
      for (final c in variant.cases) {
        if (c.isUnit) {
          writer.line('case ${c.label}');
        } else {
          final params = c.fields
              .map((f) => '${f.name}: ${_fieldSwiftType(f, mapper)}')
              .join(', ');
          writer.line('case ${c.label}($params)');
        }
      }

      writer.blank();

      // ── fromReader ─────────────────────────────────────────────────────────
      writer.line('static func fromReader(_ r: RecordReader) -> $name {');
      writer.indent(() {
        writer.line('let tag = r.readInt8()');
        writer.line('switch tag {');
        for (var i = 0; i < variant.cases.length; i++) {
          final c = variant.cases[i];
          if (c.isUnit) {
            writer.line('case $i: return .${c.label}');
          } else {
            final args = c.fields
                .map((f) => '${f.name}: ${_fieldReadExpr(f, mapper)}')
                .join(', ');
            writer.line('case $i: return .${c.label}($args)');
          }
        }
        writer.line('default: fatalError("Unknown $name tag: \\(tag)")');
        writer.line('}');
      });
      writer.line('}');

      writer.blank();

      // ── writeFields ────────────────────────────────────────────────────────
      writer.line('func writeFields(to w: RecordWriter) {');
      writer.indent(() {
        writer.line('switch self {');
        for (var i = 0; i < variant.cases.length; i++) {
          final c = variant.cases[i];
          if (c.isUnit) {
            writer.line('case .${c.label}:');
            writer.indent(() => writer.line('w.writeInt8($i)'));
          } else {
            final pattern = c.fields.map((f) => 'let ${f.name}').join(', ');
            writer.line('case .${c.label}($pattern):');
            writer.indent(() {
              writer.line('w.writeInt8($i)');
              for (final f in c.fields) {
                writer.line(_fieldWriteStmt(f, mapper));
              }
            });
          }
        }
        writer.line('}');
      });
      writer.line('}');
    });
    writer.line('}');
    writer.blank();
  }

  // ── Type helpers ──────────────────────────────────────────────────────────────

  static String _fieldSwiftType(BridgeRecordField f, SwiftTypeMapper mapper) {
    final base     = f.dartType.replaceFirst('?', '');
    final optional = f.isNullable ? '?' : '';
    return switch (f.kind) {
      RecordFieldKind.primitive        => '${mapper.swiftType(base)}$optional',
      RecordFieldKind.enumValue        => '$base$optional',
      RecordFieldKind.struct           => '$base$optional',
      RecordFieldKind.recordObject     => '$base$optional',
      RecordFieldKind.listPrimitive    => '[${mapper.swiftType(f.itemTypeName ?? 'int')}]$optional',
      RecordFieldKind.listRecordObject => '[${f.itemTypeName ?? base}]$optional',
      _                                => 'String$optional',
    };
  }

  static String _fieldReadExpr(BridgeRecordField f, SwiftTypeMapper mapper) {
    final base = f.dartType.replaceFirst('?', '');
    return switch (f.kind) {
      RecordFieldKind.primitive when base == 'int'    => 'r.readInt64()',
      RecordFieldKind.primitive when base == 'double' => 'r.readFloat64()',
      RecordFieldKind.primitive when base == 'bool'   => 'r.readInt8() != 0',
      RecordFieldKind.primitive                        => 'r.readString()',
      RecordFieldKind.enumValue                        => '$base(rawValue: Int(r.readInt64()))!',
      RecordFieldKind.struct || RecordFieldKind.recordObject
                                                       => '${base}.fromReader(r)',
      RecordFieldKind.listPrimitive => () {
        final item = f.itemTypeName ?? 'int';
        return '(0..<Int(r.readInt32())).map { _ in ${_primitiveRead(item)} }';
      }(),
      RecordFieldKind.listRecordObject => () {
        final item = f.itemTypeName ?? base;
        return '(0..<Int(r.readInt32())).map { _ in ${item}.fromReader(r) }';
      }(),
      _ => 'r.readString()',
    };
  }

  static String _primitiveRead(String t) => switch (t) {
    'int'    => 'r.readInt64()',
    'double' => 'r.readFloat64()',
    'bool'   => 'r.readInt8() != 0',
    'String' => 'r.readString()',
    _        => 'r.readInt64()',
  };

  static String _fieldWriteStmt(BridgeRecordField f, SwiftTypeMapper mapper) {
    final name = f.name;
    final base = f.dartType.replaceFirst('?', '');
    return switch (f.kind) {
      RecordFieldKind.primitive when base == 'int'    => 'w.writeInt64($name)',
      RecordFieldKind.primitive when base == 'double' => 'w.writeFloat64($name)',
      RecordFieldKind.primitive when base == 'bool'   => 'w.writeInt8($name ? 1 : 0)',
      RecordFieldKind.primitive                        => 'w.writeString($name)',
      RecordFieldKind.enumValue                        => 'w.writeInt64(Int64($name.rawValue))',
      RecordFieldKind.struct || RecordFieldKind.recordObject
                                                       => '$name.writeFields(to: w)',
      RecordFieldKind.listPrimitive => () {
        final item = f.itemTypeName ?? 'int';
        return 'w.writeInt32(Int32($name.count)); $name.forEach { ${_primitiveWriteExpr(item, r'$0')} }';
      }(),
      RecordFieldKind.listRecordObject => r'w.writeInt32(Int32(' + '$name.count)); $name.forEach { ' + r'$0' + '.writeFields(to: w) }',
      _                                => 'w.writeString($name)',
    };
  }

  static String _primitiveWriteExpr(String t, String varName) => switch (t) {
    'int'    => 'w.writeInt64($varName)',
    'double' => 'w.writeFloat64($varName)',
    'bool'   => 'w.writeInt8($varName ? 1 : 0)',
    'String' => 'w.writeString($varName)',
    _        => 'w.writeInt64($varName)',
  };
}
