import '../../../../bridge_spec.dart';
import '../../../type_mapper.dart';

/// Type-mapping helpers for Swift `@_cdecl` bridge generation.
///
/// Constructed once per [BridgeSpec] so enum/struct/record lookups
/// are cached in O(1) sets rather than iterated per call.
///
/// Implements [TypeMapper] so it can be injected into any generator
/// that accepts a generic `TypeMapper`.
class SwiftTypeMapper implements TypeMapper {
  final BridgeSpec spec;

  // Cached name sets for O(1) lookups
  late final Set<String> _enumNames = spec.enums.map((e) => e.name).toSet();
  late final Set<String> _structNames = spec.structs.map((s) => s.name).toSet();
  late final Set<String> _recordNames = spec.recordTypes.map((r) => r.name).toSet();

  SwiftTypeMapper(this.spec);

  // ── Protocol / idiomatic Swift types ────────────────────────────────────────

  /// Idiomatic Swift type for a Dart type name.
  String swiftType(String t, {BridgeType? bridgeType}) {
    final name = t.replaceFirst('?', '');
    final isOptional = t.endsWith('?');
    if (bridgeType?.isNativeHandle == true) return 'UnsafeMutableRawPointer?';

    if (bridgeType != null && bridgeType.isFunction) {
      final returnType = bridgeType.functionReturnType ?? 'Void';
      final params = bridgeType.functionParams;
      final paramList = params.asMap().entries.map((e) => '_: ${swiftType(e.value.name, bridgeType: e.value)}').join(', ');
      return '($paramList) -> ${swiftType(returnType)}';
    }

    String baseType;
    switch (name) {
      case 'int':
        baseType = 'Int64';
        break;
      case 'double':
        baseType = 'Double';
        break;
      case 'bool':
        baseType = 'Bool';
        break;
      case 'String':
        baseType = 'String';
        break;
      case 'void':
        baseType = 'Void';
        break;
      case 'Uint8List':
      case 'Int8List':
        baseType = 'Data';
        break;
      case 'Int16List':
      case 'Uint16List':
        baseType = '[Int16]';
        break;
      case 'Int32List':
      case 'Uint32List':
        baseType = '[Int32]';
        break;
      case 'Float32List':
        baseType = '[Float]';
        break;
      case 'Float64List':
        baseType = '[Double]';
        break;
      case 'Int64List':
      case 'Uint64List':
        baseType = '[Int64]';
        break;
      default:
        if (_enumNames.contains(name)) {
          baseType = name;
        } else if (_structNames.contains(name)) {
          baseType = name;
        } else if (_recordNames.contains(name)) {
          baseType = name;
        } else if (name.startsWith('List<')) {
          final itemType = name.substring(5, name.length - 1);
          baseType = '[${swiftType(itemType)}]';
        } else {
          baseType = 'Any';
        }
    }
    return isOptional ? '$baseType?' : baseType;
  }

  /// C-ABI-compatible Swift type for a Dart type (for `@_cdecl` use).
  String swiftCType(String t, {bool isZeroCopy = false}) {
    final name = t.replaceFirst('?', '');
    switch (name) {
      case 'int':
        return 'Int64';
      case 'double':
        return 'Double';
      case 'bool':
        return 'Int8';
      case 'String':
        return 'UnsafeMutablePointer<Int8>?';
      case 'void':
        return 'Void';
      case 'Uint8List':
        return 'UnsafeMutablePointer<UInt8>?';
      case 'Int8List':
        return 'UnsafeMutablePointer<Int8>?';
      case 'Int16List':
        return 'UnsafeMutablePointer<Int16>?';
      case 'Uint16List':
        return 'UnsafeMutablePointer<UInt16>?';
      case 'Int32List':
        return 'UnsafeMutablePointer<Int32>?';
      case 'Uint32List':
        return 'UnsafeMutablePointer<UInt32>?';
      case 'Float32List':
        return isZeroCopy ? 'UnsafeMutablePointer<Float>?' : '[Float]';
      case 'Float64List':
        return isZeroCopy ? 'UnsafeMutablePointer<Double>?' : '[Double]';
      case 'Int64List':
      case 'Uint64List':
        return isZeroCopy ? 'UnsafeMutablePointer<Int64>?' : '[Int64]';
      default:
        if (_enumNames.contains(name)) return 'Int64';
        if (_structNames.contains(name)) return 'UnsafeMutableRawPointer?';
        if (_recordNames.contains(name) || name.startsWith('List<')) {
          return 'UnsafeMutablePointer<UInt8>?';
        }
        return 'Any?';
    }
  }

  // ── @_cdecl bridge types ─────────────────────────────────────────────────────

  /// C-ABI return type for a `@_cdecl` function bridge.
  String cdeclReturnType(BridgeFunction func) {
    if (func.returnType.isNativeHandle) return 'UnsafeMutableRawPointer?';
    final name = func.returnType.name.replaceFirst('?', '');
    if (name == 'void') return 'Void';
    if (func.returnType.name == 'int?' || func.returnType.name == 'double?' || func.returnType.name == 'bool?') return 'UnsafeMutablePointer<UInt8>?';
    if (name == 'bool') return 'Int8';
    if (name == 'String') return 'UnsafeMutablePointer<CChar>?';
    if (name.startsWith('Map<') || func.returnType.isMap) return 'UnsafeMutablePointer<UInt8>?';
    if (BridgeType(name: name).isTypedData) return 'UnsafeMutablePointer<UInt8>?';
    if (_structNames.contains(name)) return 'UnsafeMutableRawPointer?';
    if (_recordNames.contains(name) || name.startsWith('List<')) return 'UnsafeMutableRawPointer?';
    if (_enumNames.contains(name)) return 'Int64';
    return swiftType(name);
  }

  /// C-ABI parameter type for a `@_cdecl` function bridge.
  String cdeclParamType(String typeName, {BridgeType? bridgeType}) {
    if (bridgeType?.isNativeHandle == true) return 'UnsafeMutableRawPointer?';
    final name = typeName.replaceFirst('?', '');
    if (name == 'String') return 'UnsafePointer<CChar>?';
    if (typeName.endsWith('?') && name == 'bool') return 'UnsafeMutableRawPointer?';
    if (typeName.endsWith('?') && name == 'int') return 'UnsafeMutableRawPointer?';
    if (typeName.endsWith('?') && name == 'double') return 'UnsafeMutableRawPointer?';
    if (name == 'bool') return 'Int8';
    if (name.startsWith('Map<')) return 'UnsafeMutableRawPointer?';
    if (_recordNames.contains(name) || name.startsWith('List<')) return 'UnsafeMutableRawPointer?';
    if (_enumNames.contains(name)) return 'Int64';
    if (_structNames.contains(name)) return 'UnsafeRawPointer?';
    if (BridgeType(name: name).isTypedData) return swiftCType(name, isZeroCopy: true);
    return swiftType(name);
  }

  // ── Callback helpers ──────────────────────────────────────────────────────────

  /// Protocol-level callback type (idiomatic Swift function type).
  String protocolCallbackType(BridgeType cbType) {
    final retType = cbType.functionReturnType ?? 'void';
    final paramList = cbType.functionParams.map((p) => swiftType(p.name, bridgeType: p)).join(', ');
    return '($paramList) -> ${swiftType(retType)}';
  }

  /// `@convention(c)` C function pointer type for a callback parameter in `@_cdecl`.
  String cdeclCallbackType(BridgeType cbType) {
    final paramParts = <String>[];
    for (final t in cbType.functionParams) {
      final base = t.name.replaceFirst('?', '');
      final struct = spec.structs.where((s) => s.name == base).firstOrNull;
      if (struct != null && isExpandableCallbackStruct(struct)) {
        paramParts.addAll(struct.fields.map((_) => 'Int64'));
      } else {
        paramParts.add(callbackParamCDecl(t));
      }
    }
    final retDart = cbType.functionReturnType;
    final retSwift = switch (retDart) {
      null || 'void' => 'Void',
      'String' => 'UnsafeMutablePointer<CChar>?',
      _ => 'Int64',
    };
    return '@convention(c) (${paramParts.join(', ')}) -> $retSwift';
  }

  /// Maps a single callback parameter to its Swift `@convention(c)` C ABI type.
  String callbackParamCDecl(BridgeType t) {
    final base = t.name.replaceFirst('?', '');
    switch (base) {
      case 'int':
        return 'Int64';
      case 'double':
        return 'Int64'; // GP register (not FP)
      case 'bool':
        return 'Bool';
      case 'String':
        return 'UnsafePointer<CChar>?';
      default:
        if (_structNames.contains(base)) return 'UnsafeRawPointer?';
        if (_recordNames.contains(base)) return 'UnsafeMutablePointer<UInt8>?';
        return 'Int64'; // enum rawValue
    }
  }

  /// Returns `true` when all struct fields are numeric — can be expanded to
  /// individual `Int64` params for synchronous `NativeCallable.listener`.
  bool isExpandableCallbackStruct(BridgeStruct st) {
    const numeric = {'int', 'double', 'bool'};
    return st.fields.isNotEmpty && st.fields.every((f) => numeric.contains(f.type.name.replaceFirst('?', '')) && !f.type.isTypedData);
  }

  /// Swift closure that adapts protocol-level args to C function-pointer args.
  String callbackWrapper(BridgeParam p) {
    final cbType = p.type;
    final cbName = p.name;
    final params = cbType.functionParams;
    if (params.isEmpty) return '{ $cbName() }';

    final allArgDecls = <String>[];
    final shadowDecls = <String>[];
    final structShadowIndices = <int>[];
    final callArgsList = <String>[];

    for (var i = 0; i < params.length; i++) {
      final pt = params[i];
      final base = pt.name.replaceFirst('?', '');
      final expandStruct = spec.structs.where((s) => s.name == base).firstOrNull;
      if (expandStruct != null && isExpandableCallbackStruct(expandStruct)) {
        final argVar = 'arg$i';
        allArgDecls.add(argVar);
        for (final f in expandStruct.fields) {
          final fBase = f.type.name.replaceFirst('?', '');
          if (fBase == 'double') {
            callArgsList.add('Int64(bitPattern: $argVar.${f.name}.bitPattern)');
          } else if (fBase == 'bool') {
            callArgsList.add('$argVar.${f.name} ? 1 : 0');
          } else {
            callArgsList.add('$argVar.${f.name}');
          }
        }
      } else {
        final argVar = 'arg$i';
        allArgDecls.add(argVar);
        final isEnum = _enumNames.contains(base);
        if (isEnum) {
          callArgsList.add('$argVar.rawValue');
          continue;
        }
        if (base == 'String') {
          callArgsList.add('($argVar as NSString).utf8String');
          continue;
        }
        final isNonExpandStruct = _structNames.contains(base);
        if (isNonExpandStruct) {
          shadowDecls.add('var _s$i = _${base}C.fromSwift($argVar)');
          structShadowIndices.add(i);
          callArgsList.add('__sp$i');
          continue;
        }
        final isRecord = _recordNames.contains(base);
        if (isRecord) {
          callArgsList.add('$argVar.toNative()');
          continue;
        }
        if (base == 'double') {
          callArgsList.add('Int64(bitPattern: $argVar.bitPattern)');
          continue;
        }
        callArgsList.add(argVar);
      }
    }
    final argDecl = allArgDecls.join(', ');

    final retDart = p.type.functionReturnType;
    final needsReturn = retDart != null && retDart != 'void';
    final retName = retDart?.replaceFirst('?', '') ?? 'void';
    String callExpr = '$cbName(${callArgsList.join(', ')})';
    String bodyCall;
    if (!needsReturn) {
      bodyCall = callExpr;
    } else if (retDart == 'double') {
      bodyCall = 'Double(bitPattern: UInt64(bitPattern: $callExpr))';
    } else if (retDart == 'String') {
      bodyCall = '{ let _cs = $callExpr; let _str = _cs.map { String(cString: \$0) } ?? ""; _cs.map { free(\$0) }; return _str }()';
    } else if (retDart == 'bool') {
      bodyCall = '($callExpr) != 0';
    } else if (_enumNames.contains(retName)) {
      bodyCall = '$retName(rawValue: $callExpr)!';
    } else {
      bodyCall = callExpr;
    }

    String innerBody = bodyCall;
    for (final i in structShadowIndices.reversed) {
      final replaced = innerBody.replaceFirst('__sp$i', 'UnsafeRawPointer(_ptr$i)');
      innerBody = 'withUnsafePointer(to: &_s$i) { _ptr$i in $replaced }';
    }

    final closureBody = shadowDecls.isEmpty ? innerBody : '${shadowDecls.join('; ')}; $innerBody';
    final hasTypedParams = allArgDecls.any((d) => d.contains(': '));
    final paramList = hasTypedParams ? '($argDecl)' : argDecl;
    return '{ $paramList in $closureBody }';
  }

  // ── Default / fallback values ────────────────────────────────────────────────

  /// Default C-ABI value when the impl is not registered (guard fallback).
  String defaultCDeclValue(String t) {
    final isNullable = t.endsWith('?');
    final name = t.replaceFirst('?', '');
    switch (name) {
      case 'int':
        return isNullable ? 'nil' : '0';
      case 'double':
        return isNullable ? 'nil' : '0.0';
      case 'bool':
        return isNullable ? 'nil' : '0';
      case 'String':
        return 'strdup("")';
      default:
        if (_enumNames.contains(name)) return isNullable ? '-1' : '0';
        if (_structNames.contains(name)) return 'nil';
        if (name.startsWith('Map<')) return 'strdup("{}")';
        return '()';
    }
  }

  /// Returns `true` for `Data`-backed TypedData types (`Uint8List`, `Int8List`).
  static bool isDataBackedTypedData(String t) {
    final name = t.replaceFirst('?', '');
    return name == 'Uint8List' || name == 'Int8List';
  }

  // ── TypeMapper interface ─────────────────────────────────────────────────────

  @override
  String forSwift(BridgeType t, {bool forCDecl = false}) => forCDecl ? cdeclParamType(t.name, bridgeType: t) : swiftType(t.name, bridgeType: t);

  @override
  String forKotlin(BridgeType t, {bool forParam = false}) => throw UnimplementedError('SwiftTypeMapper does not map Kotlin types');

  @override
  String forDart(BridgeType t, {bool forNative = false}) => throw UnimplementedError('SwiftTypeMapper does not map Dart FFI types');

  @override
  String forC(BridgeType t) => throw UnimplementedError('SwiftTypeMapper does not map C types');
}
