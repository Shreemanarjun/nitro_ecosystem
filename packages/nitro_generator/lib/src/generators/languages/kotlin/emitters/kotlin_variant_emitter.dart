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
          final params = c.fields
              .map((f) {
                final kt = _fieldKotlinType(f, mapper);
                return 'val ${f.name}: $kt';
              })
              .join(', ');
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

      writer.blank();

      // ── encode ────────────────────────────────────────────────────────────────
      // Produces [4B length (little-endian)][tag byte][field bytes] so that
      // RecordReader.fromNative(ptr) on the Dart side can decode it correctly.
      writer.line('fun encode(): ByteArray {');
      writer.indent(() {
        writer.line('val w = RecordWriter()');
        writer.line('writeFields(w)');
        writer.line('val payload = w.toByteArray()');
        writer.line('val lenBuf = java.nio.ByteBuffer.allocate(4).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
        writer.line('lenBuf.putInt(payload.size)');
        writer.line('return lenBuf.array() + payload');
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
      RecordFieldKind.primitive => '${mapper.type(base)}$nullable',
      RecordFieldKind.enumValue => '$base$nullable',
      RecordFieldKind.struct => '$base$nullable',
      RecordFieldKind.recordObject => '$base$nullable',
      RecordFieldKind.listPrimitive => 'List<${mapper.type(f.itemTypeName ?? 'int')}>$nullable',
      RecordFieldKind.listRecordObject => 'List<${f.itemTypeName ?? base}>$nullable',
      _ => 'String$nullable',
    };
  }

  static String _fieldReadExpr(BridgeRecordField f, KotlinTypeMapper mapper) {
    final base = f.dartType.replaceFirst('?', '');
    if (f.isNullable) {
      final nonNull = BridgeRecordField(
        name: f.name,
        dartType: base,
        kind: f.kind,
        itemTypeName: f.itemTypeName,
      );
      return 'if (r.readBool()) ${_fieldReadExpr(nonNull, mapper)} else null';
    }
    return switch (f.kind) {
      RecordFieldKind.primitive when base == 'int' => 'r.readInt64()',
      RecordFieldKind.primitive when base == 'double' => 'r.readFloat64()',
      RecordFieldKind.primitive when base == 'bool' => 'r.readBool()',
      RecordFieldKind.primitive => 'r.readString()',
      RecordFieldKind.enumValue => '$base.fromNative(r.readInt64())',
      RecordFieldKind.struct || RecordFieldKind.recordObject => '$base.decodeFrom(r.buf)',
      RecordFieldKind.listPrimitive => () {
        final item = f.itemTypeName ?? 'int';
        return 'List(r.readInt32()) { ${_primitiveRead(item)} }';
      }(),
      RecordFieldKind.listRecordObject => () {
        final item = f.itemTypeName ?? base;
        return 'List(r.readInt32()) { $item.decodeFrom(r.buf) }';
      }(),
      _ => 'r.readString()',
    };
  }

  static String _primitiveRead(String t) => switch (t) {
    'int' => 'r.readInt64()',
    'double' => 'r.readFloat64()',
    'bool' => 'r.readBool()',
    'String' => 'r.readString()',
    _ => 'r.readInt64()',
  };

  static String _fieldWriteStmt(BridgeRecordField f, KotlinTypeMapper mapper) {
    if (f.isNullable) {
      return 'w.writeBool(${f.name} != null); ${f.name}?.let { ${_fieldWriteExpr(f, mapper, 'it')} }';
    }
    return _fieldWriteExpr(f, mapper, f.name);
  }

  static String _fieldWriteExpr(BridgeRecordField f, KotlinTypeMapper mapper, String expr) {
    final base = f.dartType.replaceFirst('?', '');
    return switch (f.kind) {
      RecordFieldKind.primitive when base == 'int' => 'w.writeInt64($expr)',
      RecordFieldKind.primitive when base == 'double' => 'w.writeFloat64($expr)',
      RecordFieldKind.primitive when base == 'bool' => 'w.writeBool($expr)',
      RecordFieldKind.primitive => 'w.writeString($expr)',
      RecordFieldKind.enumValue => 'w.writeInt64($expr.nativeValue)',
      RecordFieldKind.struct || RecordFieldKind.recordObject => '$expr.writeFieldsTo(w.out, w.tmp)',
      RecordFieldKind.listPrimitive => () {
        final item = f.itemTypeName ?? 'int';
        return 'w.writeInt32($expr.size); $expr.forEach { ${_primitiveWriteExpr(item, 'it')} }';
      }(),
      RecordFieldKind.listRecordObject => 'w.writeInt32($expr.size); $expr.forEach { it.writeFieldsTo(w.out, w.tmp) }',
      _ => 'w.writeString($expr)',
    };
  }

  static String _primitiveWriteExpr(String t, String varName) => switch (t) {
    'int' => 'w.writeInt64($varName)',
    'double' => 'w.writeFloat64($varName)',
    'bool' => 'w.writeBool($varName)',
    'String' => 'w.writeString($varName)',
    _ => 'w.writeInt64($varName)',
  };
}
