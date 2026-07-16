// Parses a raw .native.dart source string into a [BridgeSpec] without
// needing a file on disk or a build_runner context.
//
// Uses the analyzer's syntactic (unresolved) AST — enough to extract class
// names, method signatures, annotations, enums, and structs, because the
// generators work entirely with string type names.
//
// Supported source shapes
//   • @NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin, ...) class
//   • Bare abstract class (no annotation) — defaults to swift/kotlin impls
//   • @HybridEnum enum  / @HybridStruct class declarations at top level

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:nitro_annotations/nitro_annotations.dart';

import 'package:nitro_generator/src/bridge_spec.dart';

class SpecFromSource {
  /// Parses [source] (raw `.native.dart` content) into a [BridgeSpec].
  ///
  /// [sourceUri] is used only for the spec's `sourceUri` field and for
  /// deriving the default `lib` name when no `@NitroModule` annotation
  /// provides one.
  static BridgeSpec parse(String source, {String sourceUri = 'test.native.dart'}) {
    final result = parseString(content: source, throwIfDiagnostics: false);
    return _fromUnit(result.unit, sourceUri);
  }

  // ─── Top-level parsing ────────────────────────────────────────────────────

  static BridgeSpec _fromUnit(CompilationUnit unit, String sourceUri) {
    final enums = _extractEnums(unit);
    final structs = _extractStructs(unit);
    final records = _extractRecords(unit, enums, structs);
    final enumNames = enums.map((e) => e.name).toSet();
    final structNames = structs.map((s) => s.name).toSet();
    final recordNames = records.map((r) => r.name).toSet();

    // Look for @NitroModule class first; fall back to first abstract class.
    ClassDeclaration? moduleClass;
    Annotation? moduleAnn;

    for (final decl in unit.declarations) {
      if (decl is! ClassDeclaration) continue;
      for (final ann in decl.metadata) {
        if (_annName(ann) == 'NitroModule') {
          moduleClass = decl;
          moduleAnn = ann;
          break;
        }
      }
      if (moduleClass != null) break;
    }

    // Fallback: first abstract class (bare class without annotation).
    if (moduleClass == null) {
      for (final decl in unit.declarations) {
        if (decl is ClassDeclaration && decl.abstractKeyword != null) {
          moduleClass = decl;
          break;
        }
      }
    }

    if (moduleClass == null) {
      throw ArgumentError(
        'specFromSource: no @NitroModule class or abstract class found in source.',
      );
    }

    // ── Annotation args ────────────────────────────────────────────────────
    NativeImpl? iosImpl;
    NativeImpl? androidImpl;
    NativeImpl? macosImpl;
    NativeImpl? windowsImpl;
    NativeImpl? linuxImpl;
    NativeImpl? webImpl;
    String? lib;
    String? cSymbolPrefix;

    if (moduleAnn?.arguments != null) {
      for (final arg in moduleAnn!.arguments!.arguments) {
        if (arg is! NamedExpression) continue;
        final label = arg.name.label.name;
        final expr = arg.expression;
        switch (label) {
          case 'ios':
            iosImpl = _parseNativeImpl(expr);
          case 'android':
            androidImpl = _parseNativeImpl(expr);
          case 'macos':
            macosImpl = _parseNativeImpl(expr);
          case 'windows':
            windowsImpl = _parseNativeImpl(expr);
          case 'linux':
            linuxImpl = _parseNativeImpl(expr);
          case 'web':
            webImpl = _parseNativeImpl(expr);
          case 'lib':
            lib = _stringValue(expr);
          case 'cSymbolPrefix':
            cSymbolPrefix = _stringValue(expr);
        }
      }
    }

    // Defaults when annotation is absent or fields are unset.
    iosImpl ??= NativeImpl.swift;
    androidImpl ??= NativeImpl.kotlin;

    final className = moduleClass.namePart.typeName.lexeme;
    final sourceFile = sourceUri.split('/').last.replaceFirst('.native.dart', '');
    final libName = lib ?? _toSnakeCase(sourceFile).replaceAll('-', '_');
    final ns = cSymbolPrefix ?? _toSnakeCase(className);

    // ── Extract members ────────────────────────────────────────────────────
    final functions = <BridgeFunction>[];
    final properties = <BridgeProperty>[];
    final streams = <BridgeStream>[];
    final propMap = <String, _PropEntry>{};

    for (final member in (moduleClass.body as BlockClassBody).members) {
      if (member is! MethodDeclaration) continue;
      if (!member.isAbstract) continue;
      _processMember(member, ns, enumNames, structNames, recordNames, functions, propMap, streams);
    }

    // Flush property map → list (preserving insertion order).
    for (final entry in propMap.values) {
      properties.add(
        BridgeProperty(
          dartName: entry.name,
          type: BridgeType(name: entry.typeName, isNullable: entry.typeName.endsWith('?')),
          getSymbol: '${ns}_get_${_toSnakeCase(entry.name)}',
          setSymbol: '${ns}_set_${_toSnakeCase(entry.name)}',
          hasGetter: entry.hasGetter,
          hasSetter: entry.hasSetter,
        ),
      );
    }

    return BridgeSpec(
      dartClassName: className,
      lib: libName,
      namespace: ns,
      iosImpl: iosImpl,
      androidImpl: androidImpl,
      macosImpl: macosImpl,
      windowsImpl: windowsImpl,
      linuxImpl: linuxImpl,
      webImpl: webImpl,
      sourceUri: sourceUri,
      functions: functions,
      properties: properties,
      streams: streams,
      enums: enums,
      structs: structs,
      recordTypes: records,
    );
  }

  // ─── Member dispatch ──────────────────────────────────────────────────────

  static void _processMember(
    MethodDeclaration m,
    String ns,
    Set<String> enumNames,
    Set<String> structNames,
    Set<String> recordNames,
    List<BridgeFunction> functions,
    Map<String, _PropEntry> propMap,
    List<BridgeStream> streams,
  ) {
    final name = m.name.lexeme;
    final retSrc = m.returnType?.toSource() ?? 'void';

    // ── Getter / setter → property ─────────────────────────────────────────
    if (m.isGetter) {
      final e = propMap.putIfAbsent(name, () => _PropEntry(name, retSrc));
      e.hasGetter = true;
      e.typeName = retSrc;
      return;
    }
    if (m.isSetter) {
      final paramType = m.parameters?.parameters.firstOrNull.let(_typeSrc) ?? 'dynamic';
      final e = propMap.putIfAbsent(name, () => _PropEntry(name, paramType));
      e.hasSetter = true;
      return;
    }

    // ── Stream return ──────────────────────────────────────────────────────
    final baseRetSrc = retSrc.replaceAll('?', '').trim();
    if (baseRetSrc.startsWith('Stream<') || baseRetSrc == 'Stream') {
      final itemType = _genericArg(retSrc) ?? 'dynamic';
      final itemBase = itemType.replaceAll('?', '');
      streams.add(
        BridgeStream(
          dartName: name,
          registerSymbol: '${ns}_register_${_toSnakeCase(name)}_stream',
          releaseSymbol: '${ns}_release_${_toSnakeCase(name)}_stream',
          itemType: _makeType(itemType, itemBase, enumNames, structNames, recordNames),
          backpressure: Backpressure.dropLatest,
        ),
      );
      return;
    }

    // ── Function ───────────────────────────────────────────────────────────
    final isAsync = m.metadata.any((a) => _annName(a) == 'NitroAsync') || (!m.metadata.any((a) => _annName(a) == 'NitroNativeAsync') && retSrc.startsWith('Future<'));
    final isNativeAsync = m.metadata.any((a) => _annName(a) == 'NitroNativeAsync');
    // Accept both the const shorthand (@mainThread) and class form (@MainThread()).
    final isMainThread = m.metadata.any((a) => _annName(a) == 'mainThread' || _annName(a) == 'MainThread');

    final isFuture = retSrc.startsWith('Future<') || isAsync || isNativeAsync;
    final effectiveReturn = isFuture ? (_genericArg(retSrc) ?? 'void') : retSrc;
    final effectiveBase = effectiveReturn.replaceAll('?', '');

    final params = m.parameters?.parameters.map((p) => _extractParam(p, enumNames, structNames, recordNames)).toList() ?? [];

    functions.add(
      BridgeFunction(
        dartName: name,
        cSymbol: '${ns}_${_toSnakeCase(name)}',
        isAsync: isAsync,
        isNativeAsync: isNativeAsync,
        mainThread: isMainThread,
        returnType: _makeType(effectiveReturn, effectiveBase, enumNames, structNames, recordNames, isFuture: isFuture),
        params: params,
      ),
    );
  }

  /// Builds a [BridgeType] from a type name string, setting `isAnyMap`, `isRecord`,
  /// etc. based on known type sets.
  static BridgeType _makeType(
    String typeSrc,
    String typeBase,
    Set<String> enumNames,
    Set<String> structNames,
    Set<String> recordNames, {
    bool isFuture = false,
  }) {
    final isNullable = typeSrc.endsWith('?');
    if (typeBase == 'NitroAnyMap') {
      return BridgeType(name: 'NitroAnyMap', isAnyMap: true, isNullable: isNullable, isFuture: isFuture);
    }
    if (recordNames.contains(typeBase)) {
      return BridgeType(name: typeSrc, isRecord: true, isNullable: isNullable, isFuture: isFuture);
    }
    return BridgeType(name: typeSrc, isNullable: isNullable, isFuture: isFuture);
  }

  // ─── Parameter extraction ─────────────────────────────────────────────────

  static BridgeParam _extractParam(
    FormalParameter p,
    Set<String> enumNames,
    Set<String> structNames,
    Set<String> recordNames,
  ) {
    String typeSrc = 'dynamic';
    String? defaultValue;

    FormalParameter inner = p;
    if (p is DefaultFormalParameter) {
      defaultValue = p.defaultValue?.toSource();
      inner = p.parameter;
    }

    if (inner is SimpleFormalParameter) {
      typeSrc = inner.type?.toSource() ?? 'dynamic';
    }

    final typeBase = typeSrc.replaceAll('?', '');
    return BridgeParam(
      name: p.name?.lexeme ?? '',
      type: _makeType(typeSrc, typeBase, enumNames, structNames, recordNames),
      isNamed: p.isNamed,
      isOptional: p.isOptional,
      defaultLiteral: defaultValue,
    );
  }

  // ─── Enum extraction ──────────────────────────────────────────────────────

  static List<BridgeEnum> _extractEnums(CompilationUnit unit) {
    final result = <BridgeEnum>[];
    for (final decl in unit.declarations) {
      if (decl is! EnumDeclaration) continue;
      if (!decl.metadata.any((a) => _annName(a) == 'HybridEnum')) continue;
      final startValue = _namedIntArg(decl.metadata, 'HybridEnum', 'startValue') ?? 0;
      result.add(
        BridgeEnum(
          name: decl.namePart.typeName.lexeme,
          startValue: startValue,
          values: decl.body.constants.map((c) => c.name.lexeme).toList(),
        ),
      );
    }
    return result;
  }

  // ─── Struct extraction ────────────────────────────────────────────────────

  static List<BridgeStruct> _extractStructs(CompilationUnit unit) {
    final result = <BridgeStruct>[];
    for (final decl in unit.declarations) {
      if (decl is! ClassDeclaration) continue;
      if (!decl.metadata.any((a) => _annName(a) == 'HybridStruct')) continue;
      final packed = _namedBoolArg(decl.metadata, 'HybridStruct', 'packed') ?? false;
      final fields = <BridgeField>[];
      for (final member in (decl.body as BlockClassBody).members) {
        if (member is! FieldDeclaration || member.isStatic) continue;
        final typeSrc = member.fields.type?.toSource() ?? 'dynamic';
        for (final v in member.fields.variables) {
          fields.add(
            BridgeField(
              name: v.name.lexeme,
              type: BridgeType(name: typeSrc, isNullable: typeSrc.endsWith('?')),
            ),
          );
        }
      }
      result.add(BridgeStruct(name: decl.namePart.typeName.lexeme, packed: packed, fields: fields));
    }
    return result;
  }

  // ─── Record extraction ────────────────────────────────────────────────────

  static List<BridgeRecordType> _extractRecords(
    CompilationUnit unit,
    List<BridgeEnum> enums,
    List<BridgeStruct> structs,
  ) {
    final enumNames = enums.map((e) => e.name).toSet();
    final structNames = structs.map((s) => s.name).toSet();
    final result = <BridgeRecordType>[];
    for (final decl in unit.declarations) {
      if (decl is! ClassDeclaration) continue;
      if (!decl.metadata.any((a) => _annName(a) == 'HybridRecord')) continue;
      final fields = <BridgeRecordField>[];
      for (final member in (decl.body as BlockClassBody).members) {
        if (member is! FieldDeclaration || member.isStatic) continue;
        final typeSrc = member.fields.type?.toSource() ?? 'dynamic';
        final typeBase = typeSrc.replaceAll('?', '');
        final isNullable = typeSrc.endsWith('?');
        final kind = _recordFieldKind(typeBase, typeSrc, enumNames, structNames);
        final itemType = typeBase.startsWith('List<') ? _genericArg(typeBase) : null;
        for (final v in member.fields.variables) {
          fields.add(
            BridgeRecordField(
              name: v.name.lexeme,
              dartType: typeSrc,
              kind: kind,
              itemTypeName: itemType,
              isNullable: isNullable,
            ),
          );
        }
      }
      result.add(BridgeRecordType(name: decl.namePart.typeName.lexeme, fields: fields));
    }
    return result;
  }

  static RecordFieldKind _recordFieldKind(
    String typeBase,
    String typeSrc,
    Set<String> enumNames,
    Set<String> structNames,
  ) {
    if (enumNames.contains(typeBase)) return RecordFieldKind.enumValue;
    if (structNames.contains(typeBase)) return RecordFieldKind.struct;
    if (typeBase.startsWith('List<')) {
      final item = _genericArg(typeBase) ?? '';
      if (enumNames.contains(item)) return RecordFieldKind.listEnumValue;
      if (const {'int', 'double', 'bool', 'String'}.contains(item)) return RecordFieldKind.listPrimitive;
      return RecordFieldKind.listRecordObject;
    }
    if (const {'Uint8List', 'Int8List', 'Int16List', 'Int32List', 'Int64List', 'Float32List', 'Float64List'}.contains(typeBase)) {
      return RecordFieldKind.typedData;
    }
    return RecordFieldKind.primitive;
  }

  // ─── AST helpers ──────────────────────────────────────────────────────────

  static String _annName(Annotation ann) => ann.name.name;

  static NativeImpl _parseNativeImpl(Expression expr) {
    if (expr is PrefixedIdentifier) {
      switch (expr.identifier.name) {
        case 'swift':
          return NativeImpl.swift;
        case 'kotlin':
          return NativeImpl.kotlin;
        case 'cpp':
          return NativeImpl.cpp;
        case 'wasm':
          return NativeImpl.wasm;
      }
    }
    return NativeImpl.swift;
  }

  static String? _stringValue(Expression expr) {
    if (expr is StringLiteral) return expr.stringValue;
    return null;
  }

  // Extracts the single type argument from a generic type string.
  // Handles nested generics: `Future<Map<String, int>>` → `Map<String, int>`.
  static String? _genericArg(String typeSrc) {
    final start = typeSrc.indexOf('<');
    if (start < 0) return null;
    // Walk from end to find the matching '>'.
    var depth = 0;
    for (var i = typeSrc.length - 1; i > start; i--) {
      if (typeSrc[i] == '>') depth++;
      if (typeSrc[i] == '<') depth--;
      if (depth == 0) return typeSrc.substring(start + 1, i).trim();
    }
    return typeSrc.substring(start + 1, typeSrc.length - 1).trim();
  }

  static String _typeSrc(FormalParameter p) {
    if (p is DefaultFormalParameter) {
      final inner = p.parameter;
      if (inner is SimpleFormalParameter) return inner.type?.toSource() ?? 'dynamic';
    }
    if (p is SimpleFormalParameter) return p.type?.toSource() ?? 'dynamic';
    return 'dynamic';
  }

  static int? _namedIntArg(NodeList<Annotation> meta, String annName, String argName) {
    for (final ann in meta) {
      if (_annName(ann) != annName) continue;
      for (final arg in ann.arguments?.arguments ?? []) {
        if (arg is NamedExpression && arg.name.label.name == argName) {
          final v = arg.expression;
          if (v is IntegerLiteral) return v.value;
        }
      }
    }
    return null;
  }

  static bool? _namedBoolArg(NodeList<Annotation> meta, String annName, String argName) {
    for (final ann in meta) {
      if (_annName(ann) != annName) continue;
      for (final arg in ann.arguments?.arguments ?? []) {
        if (arg is NamedExpression && arg.name.label.name == argName) {
          final v = arg.expression;
          if (v is BooleanLiteral) return v.value;
        }
      }
    }
    return null;
  }

  static String _toSnakeCase(String text) => text.replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m.group(1)}_${m.group(2)}').toLowerCase();
}

// ─── Internal helpers ─────────────────────────────────────────────────────────

class _PropEntry {
  _PropEntry(this.name, this.typeName);
  final String name;
  String typeName;
  bool hasGetter = false;
  bool hasSetter = false;
}

extension _Let<T> on T? {
  R? let<R>(R? Function(T) f) {
    final v = this;
    return v == null ? null : f(v);
  }
}
