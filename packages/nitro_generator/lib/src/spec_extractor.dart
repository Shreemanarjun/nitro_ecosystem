import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:source_gen/source_gen.dart';
import 'package:nitro/nitro.dart';
import 'bridge_spec.dart';

class SpecExtractor {
  static BridgeSpec extract(LibraryReader library) {
    final modules = library.annotatedWith(TypeChecker.fromRuntime(NitroModule));
    if (modules.isEmpty) {
      throw InvalidGenerationSourceError('No @NitroModule annotated classes found.');
    }

    final module = modules.first;
    final element = module.element as ClassElement;
    final annotation = module.annotation;

    final iosImpl = _getNativeImpl(annotation.read('ios').objectValue);
    final androidImpl = _getNativeImpl(annotation.read('android').objectValue);
    final cSymbolPrefix = annotation.read('cSymbolPrefix').isNull
        ? null
        : annotation.read('cSymbolPrefix').stringValue;
    final lib =
        annotation.read('lib').isNull ? null : annotation.read('lib').stringValue;
    final sourceFile = library.element.source.uri.pathSegments.last.replaceFirst('.native.dart', '');
    final libName = lib ?? sourceFile.replaceAll('-', '_');
    final ns = cSymbolPrefix ?? _toSnakeCase(element.name);

    return BridgeSpec(
      dartClassName: element.name,
      lib: libName,
      namespace: ns,
      iosImpl: iosImpl,
      androidImpl: androidImpl,
      sourceUri: library.element.source.uri.toString(),
      functions: _extractFunctions(element, ns),
      properties: _extractProperties(element, ns),
      streams: _extractStreams(element, ns),
      structs: _extractStructs(library),
      enums: _extractEnums(library),
    );
  }

  static NativeImpl _getNativeImpl(DartObject object) {
    final index =
        object.getField('index')?.toIntValue() ?? NativeImpl.cpp.index;
    return NativeImpl.values[index];
  }

  // ─── Functions ───────────────────────────────────────────────────────────────

  static List<BridgeFunction> _extractFunctions(ClassElement element, String ns) {
    final asyncChecker =
        TypeChecker.fromUrl('package:nitro/src/annotations.dart#NitroAsync');
    final zeroCopyChecker =
        TypeChecker.fromUrl('package:nitro/src/annotations.dart#ZeroCopy');

    // Skip abstract getters annotated with @NitroStream or abstract getters/setters
    return element.methods.where((m) => m.isAbstract).map((m) {
      final isAsync = asyncChecker.hasAnnotationOf(m);

      DartType returnType = m.returnType;
      if (isAsync && returnType.isDartAsyncFuture) {
        final it = returnType as InterfaceType;
        if (it.typeArguments.isNotEmpty) returnType = it.typeArguments.first;
      }

      return BridgeFunction(
        dartName: m.name,
        cSymbol: '${ns}_${_toSnakeCase(m.name)}',
        isAsync: isAsync,
        returnType: BridgeType(
          name: returnType.getDisplayString(withNullability: true),
          isFuture: isAsync,
        ),
        params: m.parameters.map((p) {
          return BridgeParam(
            name: p.name,
            type: BridgeType(name: p.type.getDisplayString(withNullability: true)),
            zeroCopy: zeroCopyChecker.hasAnnotationOf(p),
          );
        }).toList(),
      );
    }).toList();
  }

  // ─── Properties ──────────────────────────────────────────────────────────────

  static List<BridgeProperty> _extractProperties(ClassElement element, String ns) {
    // Group accessors by name
    final map = <String, Map<String, dynamic>>{};

    for (final ac in element.accessors) {
      if (!ac.isAbstract) {
        continue;
      }
      final name = ac.displayName.replaceFirst('=', '');
      final entry = map.putIfAbsent(name, () => {'name': name, 'getter': false, 'setter': false});
      
      if (ac.isGetter) {
        final type = ac.returnType;
        if (type.isDartCoreFunction || _isStreamType(type)) continue;
        entry['getter'] = true;
        entry['type'] = type;
      } else {
        final type = ac.parameters.first.type;
        if (type.isDartCoreFunction || _isStreamType(type)) continue;
        entry['setter'] = true;
        entry['type'] ??= type;
      }
    }

    return map.values.where((e) => e['type'] != null).map((e) {
      final name = e['name'] as String;
      final type = e['type'] as DartType;
      return BridgeProperty(
        dartName: name,
        type: BridgeType(name: type.getDisplayString(withNullability: true)),
        getSymbol: '${ns}_get_${_toSnakeCase(name)}',
        setSymbol: '${ns}_set_${_toSnakeCase(name)}',
        hasGetter: e['getter'] as bool,
        hasSetter: e['setter'] as bool,
      );
    }).toList();
  }

  // ─── Streams ─────────────────────────────────────────────────────────────────

  static List<BridgeStream> _extractStreams(ClassElement element, String ns) {
    final streamChecker =
        TypeChecker.fromUrl('package:nitro/src/annotations.dart#NitroStream');
    final results = <BridgeStream>[];

    for (final accessor in element.accessors) {
      if (!accessor.isAbstract || !accessor.isGetter) {
        continue;
      }
      final retType = accessor.returnType;
      if (!_isStreamType(retType)) {
        continue;
      }

      // Get item type T from Stream<T>
      final streamType = retType as InterfaceType;
      final itemTypeName = streamType.typeArguments.isNotEmpty
          ? streamType.typeArguments.first.getDisplayString(withNullability: true)
          : 'dynamic';

      // Read backpressure from @NitroStream annotation, default dropLatest
      Backpressure backpressure = Backpressure.dropLatest;
      final ann = streamChecker.firstAnnotationOf(accessor);
      if (ann != null) {
        final bpField = ann.getField('backpressure');
        final bpIndex = bpField?.getField('index')?.toIntValue() ?? 0;
        backpressure = Backpressure.values[bpIndex];
      }

      final name = accessor.displayName;
      results.add(BridgeStream(
        dartName: name,
        registerSymbol: '${ns}_register_${_toSnakeCase(name)}_stream',
        releaseSymbol: '${ns}_release_${_toSnakeCase(name)}_stream',
        itemType: BridgeType(name: itemTypeName),
        backpressure: backpressure,
      ));
    }

    return results;
  }

  static bool _isStreamType(DartType type) {
    if (type is InterfaceType) {
      return type.element.name == 'Stream';
    }
    return false;
  }

  // ─── Structs ─────────────────────────────────────────────────────────────────

  static List<BridgeStruct> _extractStructs(LibraryReader library) {
    final checker = TypeChecker.fromRuntime(HybridStruct);
    final results = <BridgeStruct>[];

    for (final ann in library.annotatedWith(checker)) {
      final cls = ann.element;
      if (cls is! ClassElement) {
        continue;
      }

      final packed =
          ann.annotation.read('packed').literalValue as bool? ?? false;
      final zeroCopyFields = ann.annotation
          .read('zeroCopy')
          .listValue
          .map((v) => v.toStringValue() ?? '')
          .toSet();

      final fields = cls.fields
          .where((f) => !f.isStatic && !f.isSynthetic)
          .map((f) => BridgeField(
                name: f.name,
                type: BridgeType(
                    name: f.type.getDisplayString(withNullability: true)),
                zeroCopy: zeroCopyFields.contains(f.name),
              ))
          .toList();

      results.add(BridgeStruct(name: cls.name, packed: packed, fields: fields));
    }
    return results;
  }

  // ─── Enums ───────────────────────────────────────────────────────────────────

  static List<BridgeEnum> _extractEnums(LibraryReader library) {
    final checker = TypeChecker.fromRuntime(HybridEnum);
    final results = <BridgeEnum>[];

    for (final ann in library.annotatedWith(checker)) {
      final cls = ann.element;
      if (cls is! EnumElement) {
        continue;
      }

      final startValue =
          ann.annotation.read('startValue').literalValue as int? ?? 0;

      results.add(BridgeEnum(
        name: cls.name,
        startValue: startValue,
        values: cls.fields
            .where((f) => f.isEnumConstant)
            .map((f) => f.name)
            .toList(),
      ));
    }
    return results;
  }

  static String _toSnakeCase(String text) {
    return text
        .replaceAllMapped(
            RegExp('([a-z0-9])([A-Z])'), (m) => '${m.group(1)}_${m.group(2)}')
        .toLowerCase();
  }
}
