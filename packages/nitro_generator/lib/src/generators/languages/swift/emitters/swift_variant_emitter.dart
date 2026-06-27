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
/// public enum FilterResult: NitroEncodable {
///     case accepted(id: String)
///     case rejected
///
///     public static func fromReader(_ r: NitroRecordReader) -> FilterResult {
///         let tag = r.bytes[r.pos]; r.pos += 1
///         switch tag {
///         case 0: return .accepted(id: r.readString())
///         case 1: return .rejected
///         default: fatalError("Unknown FilterResult tag: \(tag)")
///         }
///     }
///
///     public func writeFields(to w: NitroRecordWriter) {
///         switch self {
///         case .accepted(let id):
///             w.bytes.append(0)
///             w.writeString(id)
///         case .rejected:
///             w.bytes.append(1)
///         }
///     }
/// }
/// ```
class SwiftVariantEmitter {
  static void emit(CodeWriter writer, BridgeVariant variant, SwiftTypeMapper mapper) {
    final name = variant.name;

    writer.line('public enum $name: NitroEncodable {');
    writer.indent(() {
      // ── Case declarations ──────────────────────────────────────────────────
      for (final c in variant.cases) {
        if (c.isUnit) {
          writer.line('case ${c.label}');
        } else {
          final params = c.fields.map((f) => '${f.name}: ${_fieldSwiftType(f, mapper)}').join(', ');
          writer.line('case ${c.label}($params)');
        }
      }

      writer.blank();

      // ── fromReader ─────────────────────────────────────────────────────────
      writer.line('public static func fromReader(_ r: NitroRecordReader) -> $name {');
      writer.indent(() {
        writer.line('let tag = r.bytes[r.pos]');
        writer.line('r.pos += 1');
        writer.line('switch tag {');
        for (var i = 0; i < variant.cases.length; i++) {
          final c = variant.cases[i];
          if (c.isUnit) {
            writer.line('case $i: return .${c.label}');
          } else {
            final args = c.fields.map((f) => '${f.name}: ${_fieldReadExpr(f, mapper)}').join(', ');
            writer.line('case $i: return .${c.label}($args)');
          }
        }
        writer.line('default: fatalError("Unknown $name tag: \\(tag)")');
        writer.line('}');
      });
      writer.line('}');

      writer.blank();

      // ── writeFields ────────────────────────────────────────────────────────
      writer.line('public func writeFields(to w: NitroRecordWriter) {');
      writer.indent(() {
        writer.line('switch self {');
        for (var i = 0; i < variant.cases.length; i++) {
          final c = variant.cases[i];
          if (c.isUnit) {
            writer.line('case .${c.label}:');
            writer.indent(() => writer.line('w.bytes.append(UInt8($i))'));
          } else {
            final pattern = c.fields.map((f) => 'let ${f.name}').join(', ');
            writer.line('case .${c.label}($pattern):');
            writer.indent(() {
              writer.line('w.bytes.append(UInt8($i))');
              for (final f in c.fields) {
                writer.line(_fieldWriteStmt(f, mapper));
              }
            });
          }
        }
        writer.line('}');
      });
      writer.line('}');
      writer.blank();
      writer.line('public func toNative() -> UnsafeMutablePointer<UInt8>? {');
      writer.indent(() {
        writer.line('let writer = NitroRecordWriter()');
        writer.line('writeFields(to: writer)');
        writer.line('return writer.toNative()');
      });
      writer.line('}');
    });
    writer.line('}');
    writer.blank();
  }

  // ── Type helpers ──────────────────────────────────────────────────────────────

  static String _fieldSwiftType(BridgeRecordField f, SwiftTypeMapper mapper) {
    final base = f.dartType.replaceFirst('?', '');
    final optional = f.isNullable ? '?' : '';
    return switch (f.kind) {
      RecordFieldKind.primitive => '${mapper.swiftType(base)}$optional',
      RecordFieldKind.enumValue => '$base$optional',
      RecordFieldKind.struct => '$base$optional',
      RecordFieldKind.recordObject => '$base$optional',
      RecordFieldKind.listPrimitive => '[${mapper.swiftType(f.itemTypeName ?? 'int')}]$optional',
      RecordFieldKind.listRecordObject => '[${f.itemTypeName ?? base}]$optional',
      _ => 'String$optional',
    };
  }

  static String _fieldReadExpr(BridgeRecordField f, SwiftTypeMapper mapper) {
    final base = f.dartType.replaceFirst('?', '');
    if (f.isNullable) {
      final nonNull = BridgeRecordField(
        name: f.name,
        dartType: base,
        kind: f.kind,
        itemTypeName: f.itemTypeName,
      );
      return 'r.readBool() ? ${_fieldReadExpr(nonNull, mapper)} : nil';
    }
    return switch (f.kind) {
      RecordFieldKind.primitive when base == 'int' => 'r.readInt()',
      RecordFieldKind.primitive when base == 'double' => 'r.readDouble()',
      RecordFieldKind.primitive when base == 'bool' => 'r.readBool()',
      RecordFieldKind.primitive => 'r.readString()',
      RecordFieldKind.enumValue => '$base(rawValue: r.readInt())!',
      RecordFieldKind.struct || RecordFieldKind.recordObject => '$base.fromReader(r)',
      RecordFieldKind.listPrimitive => () {
        final item = f.itemTypeName ?? 'int';
        return '(0..<Int(r.readInt32())).map { _ in ${_primitiveRead(item)} }';
      }(),
      RecordFieldKind.listRecordObject => () {
        final item = f.itemTypeName ?? base;
        return '(0..<Int(r.readInt32())).map { _ in $item.fromReader(r) }';
      }(),
      _ => 'r.readString()',
    };
  }

  static String _primitiveRead(String t) => switch (t) {
    'int' => 'r.readInt()',
    'double' => 'r.readDouble()',
    'bool' => 'r.readBool()',
    'String' => 'r.readString()',
    _ => 'r.readInt()',
  };

  static String _fieldWriteStmt(BridgeRecordField f, SwiftTypeMapper mapper) {
    if (f.isNullable) {
      return 'w.writeBool(${f.name} != nil); if let value = ${f.name} { ${_fieldWriteExpr(f, mapper, 'value')} }';
    }
    return _fieldWriteExpr(f, mapper, f.name);
  }

  static String _fieldWriteExpr(BridgeRecordField f, SwiftTypeMapper mapper, String expr) {
    final base = f.dartType.replaceFirst('?', '');
    return switch (f.kind) {
      RecordFieldKind.primitive when base == 'int' => 'w.writeInt($expr)',
      RecordFieldKind.primitive when base == 'double' => 'w.writeDouble($expr)',
      RecordFieldKind.primitive when base == 'bool' => 'w.writeBool($expr)',
      RecordFieldKind.primitive => 'w.writeString($expr)',
      RecordFieldKind.enumValue => 'w.writeInt($expr.rawValue)',
      RecordFieldKind.struct || RecordFieldKind.recordObject => '$expr.writeFields(w)',
      RecordFieldKind.listPrimitive => () {
        final item = f.itemTypeName ?? 'int';
        return 'w.writeInt32(Int32($expr.count)); $expr.forEach { ${_primitiveWriteExpr(item, r'$0')} }';
      }(),
      RecordFieldKind.listRecordObject => 'w.writeInt32(Int32($expr.count)); $expr.forEach { \$0.writeFields(w) }',
      _ => 'w.writeString($expr)',
    };
  }

  static String _primitiveWriteExpr(String t, String varName) => switch (t) {
    'int' => 'w.writeInt($varName)',
    'double' => 'w.writeDouble($varName)',
    'bool' => 'w.writeBool($varName)',
    'String' => 'w.writeString($varName)',
    _ => 'w.writeInt($varName)',
  };
}
