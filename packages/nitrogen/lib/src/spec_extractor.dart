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
    final cSymbolPrefix = annotation.read('cSymbolPrefix').isNull ? null : annotation.read('cSymbolPrefix').stringValue;
    final lib = annotation.read('lib').isNull ? null : annotation.read('lib').stringValue;

    return BridgeSpec(
      dartClassName: element.name,
      lib: lib ?? element.name.toLowerCase(),
      namespace: cSymbolPrefix ?? _toSnakeCase(element.name),
      iosImpl: iosImpl,
      androidImpl: androidImpl,
      sourceUri: library.element.source.uri.toString(),
      functions: _extractFunctions(element),
      structs: [],
      enums: [],
      streams: [],
      properties: [],
    );
  }

  static NativeImpl _getNativeImpl(DartObject object) {
    final index = object.getField('index')?.toIntValue() ?? NativeImpl.cpp.index;
    return NativeImpl.values[index];
  }

  static List<BridgeFunction> _extractFunctions(ClassElement element) {
    final asyncChecker = TypeChecker.fromUrl('package:nitro/src/annotations.dart#NitroAsync');

    return element.methods.where((m) => m.isAbstract).map((m) {
      final isAsync = asyncChecker.hasAnnotationOf(m);
      
      DartType returnType = m.returnType;
      if (isAsync && returnType.isDartAsyncFuture) {
        // Extract T from Future<T>
        final interfaceType = returnType as InterfaceType;
        if (interfaceType.typeArguments.isNotEmpty) {
          returnType = interfaceType.typeArguments.first;
        }
      }

      return BridgeFunction(
        dartName: m.name,
        cSymbol: '${_toSnakeCase(element.name)}_${_toSnakeCase(m.name)}',
        isAsync: isAsync,
        returnType: BridgeType(
          name: returnType.getDisplayString(withNullability: true),
          isFuture: isAsync,
        ),
        params: m.parameters.map((p) => BridgeParam(
          name: p.name,
          type: BridgeType(name: p.type.getDisplayString(withNullability: true)),
        )).toList(),
      );
    }).toList();
  }

  static String _toSnakeCase(String text) {
    return text.replaceAllMapped(RegExp('([a-z0-9])([A-Z])'), (match) => '${match.group(1)}_${match.group(2)}').toLowerCase();
  }
}
