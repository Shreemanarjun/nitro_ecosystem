import '../../../../bridge_spec.dart';
import '../../../code_writer.dart';
import 'kotlin_type_mapper.dart';

/// Emits a Kotlin `sealed class` and its companion `fromReader` / `writeFields`
/// methods for a `@NitroVariant`-annotated sealed Dart class.
///
/// Wire format: `[1B tag 0..N] [optional field bytes — record codec]`
///
/// Example output:
/// ```kotlin
/// sealed class FilterResult {
///     data class Accepted(val id: String) : FilterResult()
///     data object Rejected : FilterResult()
///
///     companion object {
///         @JvmStatic fun fromReader(r: RecordReader): FilterResult {
///             return when (r.readInt8().toInt()) {
///                 0 -> Accepted(id = r.readString())
///                 1 -> Rejected
///                 else -> throw IllegalArgumentException("Unknown FilterResult tag: ${r}")
///             }
///         }
///     }
///
///     fun writeFields(w: RecordWriter) {
///         when (this) {
///             is Accepted -> { w.writeInt8(0); w.writeString(id) }
///             is Rejected -> w.writeInt8(1)
///         }
///     }
/// }
/// ```
class KotlinVariantEmitter {
  static void emit(CodeWriter writer, BridgeVariant variant, KotlinTypeMapper mapper) {
    final name = variant.name;

    writer.line('sealed class $name {');
    writer.indent(() {
      // ── Case sub-classes ─────────────────────────────────────────────────────
      for (final c in variant.cases) {
        if (c.isUnit) {
          writer.line('data object ${c.name} : $name()');
        } else {
          final params = c.fields.map((f) {
            final kt = _fieldKotlinType(f, mapper);
            return 'val ${f.name}: $kt';
          }).join(', ');
          writer.line('data class ${c.name}($params) : $name()');
        }
      }

      writer.blank();

      // ── companion object — fromReader ────────────────────────────────────────
      writer.line('companion object {');
      writer.indent(() {
        writer.line('@JvmStatic fun fromReader(r: RecordReader): $name {');
        writer.indent(() {
          writer.line('return when (r.readInt8().toInt()) {');
          writer.indent(() {
            for (var i = 0; i < variant.cases.length; i++) {
              final c = variant.cases[i];
              if (c.isUnit) {
                writer.line('$i -> ${c.name}');
              } else {
                final args = c.fields.map((f) => '${f.name} = ${_fieldReadExpr(f, mapper)}').join(', ');
                writer.line('$i -> ${c.name}($args)');
              }
            }
            writer.line('else -> throw IllegalArgumentException("Unknown $name tag")');
          });
          writer.line('}');
        });
        writer.line('}');
      });
      writer.line('}');

      writer.blank();

      // ── writeFields ──────────────────────────────────────────────────────────
      writer.line('fun writeFields(w: RecordWriter) {');
      writer.indent(() {
        writer.line('when (this) {');
        writer.indent(() {
          for (var i = 0; i < variant.cases.length; i++) {
            final c = variant.cases[i];
            if (c.isUnit) {
              writer.line('is ${c.name} -> w.writeInt8($i)');
            } else {
              writer.line('is ${c.name} -> {');
              writer.indent(() {
                writer.line('w.writeInt8($i)');
                for (final f in c.fields) {
                  writer.line(_fieldWriteStmt(f, mapper));
                }
              });
              writer.line('}');
            }
          }
        });
        writer.line('}');
      });
      writer.line('}');
    });
    writer.line('}');
    writer.blank();
  }

  // ── Type helpers ─────────────────────────────────────────────────────────────

  static String _fieldKotlinType(BridgeRecordField f, KotlinTypeMapper mapper) {
    final base = f.dartType.replaceFirst('?', '');
    final nullable = f.isNullable ? '?' : '';
    return switch (f.kind) {
      RecordFieldKind.primitive       => '${mapper.type(base)}$nullable',
      RecordFieldKind.enumValue       => '$base$nullable',
      RecordFieldKind.struct          => '$base$nullable',
      RecordFieldKind.recordObject    => '$base$nullable',
      RecordFieldKind.listPrimitive   => 'List<${mapper.type(f.itemTypeName ?? 'int')}?>$nullable',
      RecordFieldKind.listRecordObject => 'List<${f.itemTypeName ?? base}>$nullable',
      _                               => 'String$nullable',
    };
  }

  static String _fieldReadExpr(BridgeRecordField f, KotlinTypeMapper mapper) {
    final base = f.dartType.replaceFirst('?', '');
    return switch (f.kind) {
      RecordFieldKind.primitive when base == 'int'    => 'r.readInt64()',
      RecordFieldKind.primitive when base == 'double' => 'r.readFloat64()',
      RecordFieldKind.primitive when base == 'bool'   => 'r.readInt8() != 0.toByte()',
      RecordFieldKind.primitive                        => 'r.readString()',
      RecordFieldKind.enumValue                        => '$base.entries.first { it.ordinal == r.readInt64().toInt() }',
      RecordFieldKind.struct || RecordFieldKind.recordObject
                                                       => '${base}.fromReader(r)',
      RecordFieldKind.listPrimitive => () {
        final item = f.itemTypeName ?? 'int';
        return 'List(r.readInt32()) { ${_primitiveRead(item)} }';
      }(),
      RecordFieldKind.listRecordObject => () {
        final item = f.itemTypeName ?? base;
        return 'List(r.readInt32()) { ${item}.fromReader(r) }';
      }(),
      _ => 'r.readString()',
    };
  }

  static String _primitiveRead(String t) => switch (t) {
    'int'    => 'r.readInt64()',
    'double' => 'r.readFloat64()',
    'bool'   => 'r.readInt8() != 0.toByte()',
    'String' => 'r.readString()',
    _        => 'r.readInt64()',
  };

  static String _fieldWriteStmt(BridgeRecordField f, KotlinTypeMapper mapper) {
    final name = f.name;
    final base = f.dartType.replaceFirst('?', '');
    return switch (f.kind) {
      RecordFieldKind.primitive when base == 'int'    => 'w.writeInt64($name)',
      RecordFieldKind.primitive when base == 'double' => 'w.writeFloat64($name)',
      RecordFieldKind.primitive when base == 'bool'   => 'w.writeInt8(if ($name) 1 else 0)',
      RecordFieldKind.primitive                        => 'w.writeString($name)',
      RecordFieldKind.enumValue                        => 'w.writeInt64($name.ordinal.toLong())',
      RecordFieldKind.struct || RecordFieldKind.recordObject
                                                       => '$name.writeFields(w)',
      RecordFieldKind.listPrimitive => () {
        final item = f.itemTypeName ?? 'int';
        return 'w.writeInt32($name.size); $name.forEach { ${_primitiveWriteExpr(item, 'it')} }';
      }(),
      RecordFieldKind.listRecordObject => 'w.writeInt32($name.size); $name.forEach { it.writeFields(w) }',
      _                                => 'w.writeString($name)',
    };
  }

  static String _primitiveWriteExpr(String t, String varName) => switch (t) {
    'int'    => 'w.writeInt64($varName)',
    'double' => 'w.writeFloat64($varName)',
    'bool'   => 'w.writeInt8(if ($varName) 1 else 0)',
    'String' => 'w.writeString($varName)',
    _        => 'w.writeInt64($varName)',
  };
}
