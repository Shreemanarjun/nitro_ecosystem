part of '../spec_extractor.dart';

// The members of a `@NitroModule` class: methods, properties, streams, and
// the library's `@NitroEntryPoint` functions.

List<BridgeFunction> _extractFunctions(
  Iterable<ExecutableElement> methods,
  String ns,
  Set<String> recordTypeNames,
  Set<String> knownTypeNames, {
  Set<String> structTypeNames = const {},
  Set<String> enumTypeNames = const {},
  Set<String> variantTypeNames = const {},
  Set<String> tupleTypeNames = const {},
}) {
  const asyncChecker = TypeChecker.fromUrl('package:nitro_annotations/src/annotations.dart#NitroAsync');
  const nativeAsyncChecker = TypeChecker.fromUrl('package:nitro_annotations/src/annotations.dart#NitroNativeAsync');
  const zeroCopyChecker = TypeChecker.fromUrl('package:nitro_annotations/src/annotations.dart#ZeroCopy');
  const ownedChecker = TypeChecker.fromUrl('package:nitro_annotations/src/annotations.dart#NitroOwned');
  const fastChecker = TypeChecker.fromUrl('package:nitro_annotations/src/annotations.dart#NitroFast');
  const mainThreadChecker = TypeChecker.fromUrl('package:nitro_annotations/src/annotations.dart#MainThread');
  const resultChecker = TypeChecker.fromUrl('package:nitro_annotations/src/annotations.dart#NitroResult');

  return methods.map((m) {
    final isAsync = asyncChecker.hasAnnotationOf(m);
    final isNativeAsync = nativeAsyncChecker.hasAnnotationOf(m);

    // Read optional timeout from @NitroAsync(timeout: N)
    int? asyncTimeout;
    if (isAsync) {
      final asyncAnnotation = asyncChecker.firstAnnotationOf(m);
      if (asyncAnnotation != null) {
        final timeoutVal = asyncAnnotation.getField('timeout');
        if (timeoutVal != null && !timeoutVal.isNull) {
          asyncTimeout = timeoutVal.toIntValue();
        }
      }
    }

    if (isAsync && isNativeAsync) {
      throw InvalidGenerationSource(
        '@NitroAsync and @NitroNativeAsync cannot both be applied to "${m.name!}". '
        'Use @NitroNativeAsync when the native implementation posts the result '
        'directly via Dart_PostCObject_DL.',
      );
    }

    // Read optional custom release symbol from @NitroOwned(release: '...')
    final isOwned = ownedChecker.hasAnnotationOf(m);
    // Hot path: the annotation, or the legacy `...Fast` name suffix.
    final isFast = fastChecker.hasAnnotationOf(m) || m.name!.endsWith('Fast');
    String? releaseSymbol;
    if (isOwned) {
      final ownedAnnotation = ownedChecker.firstAnnotationOf(m);
      final releaseVal = ownedAnnotation?.getField('release');
      if (releaseVal != null && !releaseVal.isNull) {
        releaseSymbol = releaseVal.toStringValue();
      }
    }

    final isResult = resultChecker.hasAnnotationOf(m);
    DartType returnDartType = m.returnType;
    final returnsFutureOr = (isAsync || isNativeAsync) && returnDartType.isDartAsyncFutureOr;
    // Did the method DECLARE a Future/FutureOr (vs a bare type)? Captured before
    // the unwrap below, since Future<void> and bare void both end up 'void'.
    final declaredIsFuture = returnDartType.isDartAsyncFuture || returnsFutureOr;
    if ((isAsync || isNativeAsync) && declaredIsFuture) {
      final it = returnDartType as InterfaceType;
      if (it.typeArguments.isNotEmpty) returnDartType = it.typeArguments.first;
    }
    if (isResult && returnDartType is InterfaceType) {
      final elName = returnDartType.element.name;
      if (elName == 'NitroResultValue' && returnDartType.typeArguments.isNotEmpty) {
        returnDartType = returnDartType.typeArguments.first;
      }
    }

    return BridgeFunction(
      dartName: m.name!,
      cSymbol: '${ns}_${_toSnakeCase(m.name!)}',
      isAsync: isAsync,
      isNativeAsync: isNativeAsync && !isFast,
      // Fire-and-forget (issue #58): a @nitroNativeAsync method that did NOT
      // declare a Future — i.e. a bare `void`, the one native-async shape with
      // no result to await. Future<void> keeps declaredIsFuture and stays awaited.
      isFireAndForget: isNativeAsync && !isFast && !declaredIsFuture,
      inlineFuture: isNativeAsync && isFast,
      returnsFutureOr: returnsFutureOr,
      returnType: _makeBridgeType(
        returnDartType,
        recordTypeNames,
        isFuture: isAsync || isNativeAsync,
        knownTypeNames: knownTypeNames,
        structTypeNames: structTypeNames,
        enumTypeNames: enumTypeNames,
        variantTypeNames: variantTypeNames,
        tupleTypeNames: tupleTypeNames,
      ),
      zeroCopyReturn: zeroCopyChecker.hasAnnotationOf(m),
      isOwned: isOwned,
      isFast: isFast,
      releaseSymbol: releaseSymbol,
      mainThread: mainThreadChecker.hasAnnotationOf(m),
      asyncTimeout: asyncTimeout,
      isResult: isResult,
      resultField: isResult
          ? BridgeRecordField(
              name: 'value',
              dartType: returnDartType.getDisplayString(),
              kind: _recordFieldKind(returnDartType, recordTypeNames, structTypeNames, enumTypeNames),
              itemTypeName: _listItemTypeName(returnDartType),
              isNullable: returnDartType.nullabilitySuffix == NullabilitySuffix.question,
            )
          : null,
      isGetter: m is PropertyAccessorElement,
      params: m.formalParameters.map((p) {
        return BridgeParam(
          name: p.name!,
          type: _makeBridgeType(
            p.type,
            recordTypeNames,
            knownTypeNames: knownTypeNames,
            structTypeNames: structTypeNames,
            enumTypeNames: enumTypeNames,
            variantTypeNames: variantTypeNames,
            tupleTypeNames: tupleTypeNames,
          ),
          zeroCopy: zeroCopyChecker.hasAnnotationOf(p),
          isNamed: p.isNamed,
          isOptional: p.isOptional,
          defaultLiteral: p.defaultValueCode,
        );
      }).toList(),
      lineNumber: _lineOf(m),
    );
  }).toList();
}

/// Top-level functions annotated `@NitroEntryPoint` in the spec library.
/// Signature validity (supported types) is judged by [SpecValidator]; only
/// the annotation target is checked here because it needs the AST.
List<BridgeEntryPoint> _extractEntryPoints(
  LibraryReader library,
  Set<String> recordTypeNames,
  Set<String> knownTypeNames,
  Set<String> structTypeNames,
  Set<String> enumTypeNames,
  Set<String> variantTypeNames,
  Set<String> tupleTypeNames,
) {
  const checker = TypeChecker.fromUrl('package:nitro_annotations/src/annotations.dart#NitroEntryPoint');
  final out = <BridgeEntryPoint>[];
  for (final annotated in library.annotatedWith(checker)) {
    final el = annotated.element;
    if (el is! TopLevelFunctionElement) {
      throw SpecParseException(
        '@NitroEntryPoint is only valid on a top-level function (found on "${el.name}").',
        sourceUri: library.element.uri.toString(),
      );
    }
    BridgeType make(DartType t) => _makeBridgeType(
      t,
      recordTypeNames,
      knownTypeNames: knownTypeNames,
      structTypeNames: structTypeNames,
      enumTypeNames: enumTypeNames,
      variantTypeNames: variantTypeNames,
      tupleTypeNames: tupleTypeNames,
    );
    var ret = el.returnType;
    final isAsync = ret.isDartAsyncFuture || ret.isDartAsyncFutureOr;
    final isStream = ret.isDartAsyncStream;
    if ((isAsync || isStream) && ret is InterfaceType && ret.typeArguments.isNotEmpty) ret = ret.typeArguments.first;
    out.add(
      BridgeEntryPoint(
        name: el.name!,
        isAsync: isAsync,
        isStream: isStream,
        returnType: ret is VoidType ? BridgeType(name: 'void') : make(ret),
        params: el.formalParameters
            .map(
              (p) => BridgeParam(
                name: p.name!,
                type: make(p.type),
                isNamed: p.isNamed,
                isOptional: p.isOptional,
                defaultLiteral: p.defaultValueCode,
              ),
            )
            .toList(),
      ),
    );
  }
  return out;
}

({List<BridgeProperty> properties, List<BridgeStream> streams}) _extractPropertiesAndStreams(
  _ModuleMembers members,
  String ns,
  Set<String> recordTypeNames,
  Set<String> knownTypeNames, {
  Set<String> structTypeNames = const {},
  Set<String> enumTypeNames = const {},
  Set<String> variantTypeNames = const {},
  Set<String> tupleTypeNames = const {},
}) {
  const streamChecker = TypeChecker.fromUrl('package:nitro_annotations/src/annotations.dart#NitroStream');

  // Accumulate properties grouped by accessor name.
  final propMap = <String, Map<String, dynamic>>{};
  final streams = <BridgeStream>[];

  // ── Stream methods — `Stream<T> name()` style ────────────────────────────
  for (final m in members.streamMethods) {
    final retType = m.returnType as InterfaceType;
    final itemDartType = retType.typeArguments.isNotEmpty ? retType.typeArguments.first : null;

    Backpressure backpressure = Backpressure.dropLatest;
    int batchMaxSize = 64;
    final ann = streamChecker.firstAnnotationOf(m);
    if (ann != null) {
      final bpField = ann.getField('backpressure');
      final bpIndex = bpField?.getField('index')?.toIntValue() ?? 0;
      backpressure = Backpressure.values[bpIndex];
      batchMaxSize = ann.getField('batchMaxSize')?.toIntValue() ?? 64;
    }

    final name = m.name!;
    streams.add(
      BridgeStream(
        dartName: name,
        registerSymbol: '${ns}_register_${_toSnakeCase(name)}_stream',
        releaseSymbol: '${ns}_release_${_toSnakeCase(name)}_stream',
        itemType: itemDartType != null
            ? _makeBridgeType(
                itemDartType,
                recordTypeNames,
                knownTypeNames: knownTypeNames,
                structTypeNames: structTypeNames,
                enumTypeNames: enumTypeNames,
                variantTypeNames: variantTypeNames,
                tupleTypeNames: tupleTypeNames,
              )
            : BridgeType(name: 'dynamic'),
        backpressure: backpressure,
        batchMaxSize: batchMaxSize,
        isMethodStyle: true,
        isAnnotated: ann != null,
      ),
    );
  }

  // ── Getters ──────────────────────────────────────────────────────────────
  for (final ac in members.streamGetters) {
    final retType = ac.returnType as InterfaceType;
    final itemDartType = retType.typeArguments.isNotEmpty ? retType.typeArguments.first : null;

    Backpressure backpressure = Backpressure.dropLatest;
    int batchMaxSizeGetter = 64;
    final ann = streamChecker.firstAnnotationOf(ac);
    if (ann != null) {
      final bpField = ann.getField('backpressure');
      final bpIndex = bpField?.getField('index')?.toIntValue() ?? 0;
      backpressure = Backpressure.values[bpIndex];
      batchMaxSizeGetter = ann.getField('batchMaxSize')?.toIntValue() ?? 64;
    }

    final name = ac.displayName;
    streams.add(
      BridgeStream(
        dartName: name,
        registerSymbol: '${ns}_register_${_toSnakeCase(name)}_stream',
        releaseSymbol: '${ns}_release_${_toSnakeCase(name)}_stream',
        itemType: itemDartType != null
            ? _makeBridgeType(
                itemDartType,
                recordTypeNames,
                knownTypeNames: knownTypeNames,
                structTypeNames: structTypeNames,
                enumTypeNames: enumTypeNames,
                variantTypeNames: variantTypeNames,
                tupleTypeNames: tupleTypeNames,
              )
            : BridgeType(name: 'dynamic'),
        backpressure: backpressure,
        batchMaxSize: batchMaxSizeGetter,
        isAnnotated: ann != null,
      ),
    );
  }

  for (final ac in members.propertyGetters) {
    final name = ac.displayName;
    final type = ac.returnType;

    final entry = propMap.putIfAbsent(name, () => {'name': name, 'getter': false, 'setter': false});
    entry['getter'] = true;
    entry['dartType'] = type;
    entry['getFast'] = _hasAnnotation(ac, 'NitroFast');
    entry['getMainThread'] = _hasAnnotation(ac, 'MainThread');
  }

  // ── Setters ──────────────────────────────────────────────────────────────
  for (final ac in members.setters) {
    // Setter displayName includes '=' suffix (e.g. "myProp="); strip it.
    final name = ac.displayName.replaceFirst('=', '');
    final type = ac.formalParameters.first.type;

    final entry = propMap.putIfAbsent(name, () => {'name': name, 'getter': false, 'setter': false});
    entry['setter'] = true;
    entry['dartType'] ??= type;
    entry['setFast'] = _hasAnnotation(ac, 'NitroFast');
    entry['setMainThread'] = _hasAnnotation(ac, 'MainThread');
  }

  final properties = propMap.values.where((e) => e['dartType'] != null).map((e) {
    final name = e['name'] as String;
    final dartType = e['dartType'] as DartType;
    return BridgeProperty(
      dartName: name,
      type: _makeBridgeType(
        dartType,
        recordTypeNames,
        knownTypeNames: knownTypeNames,
        structTypeNames: structTypeNames,
        enumTypeNames: enumTypeNames,
        variantTypeNames: variantTypeNames,
        tupleTypeNames: tupleTypeNames,
      ),
      getSymbol: '${ns}_get_${_toSnakeCase(name)}',
      setSymbol: '${ns}_set_${_toSnakeCase(name)}',
      hasGetter: e['getter'] as bool,
      hasSetter: e['setter'] as bool,
      getFast: e['getFast'] == true,
      setFast: e['setFast'] == true,
      getMainThread: e['getMainThread'] == true,
      setMainThread: e['setMainThread'] == true,
    );
  }).toList();

  return (properties: properties, streams: streams);
}

bool _isStreamType(DartType type) {
  if (type is InterfaceType) {
    return type.element.name == 'Stream';
  }
  return false;
}

/// Returns the 1-based line number of [e] in its source file.
/// Returns null when source or offset information is absent.
int? _lineOf(Element e) {
  final elementName = e.displayName;
  String? sourceUri;
  try {
    final fragment = e.firstFragment;
    final source = fragment.libraryFragment?.source;
    sourceUri = source?.uri.toString();
    if (source == null) return null;
    final text = source.contents.data;
    final offset = fragment.nameOffset;
    if (offset == null || offset < 0 || offset >= text.length) return null;
    return text.substring(0, offset).split('\n').length;
  } catch (error, stackTrace) {
    throw SpecParseException(
      'Failed to resolve source line for "$elementName".',
      sourceUri: sourceUri,
      cause: error,
      stackTrace: stackTrace,
    );
  }
}

String _toSnakeCase(String text) {
  return text
      .replaceAllMapped(
        RegExp('([a-z0-9])([A-Z])'),
        (m) => '${m.group(1)}_${m.group(2)}',
      )
      .toLowerCase();
}
