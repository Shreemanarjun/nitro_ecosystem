part of '../swift_generator.dart';

void _emitSwiftProtocol(CodeWriter writer, BridgeSpec spec, SwiftTypeMapper mapper) {
  // ── Protocol ──────────────────────────────────────────────────────────
  writer.line('/**');
  writer.line(' * Protocol for the ${spec.dartClassName} module.');
  writer.line(' * Conform to this in your Swift source code.');
  writer.line(' * Nitro may call this implementation from any native thread.');
  writer.line(' * Keep mutable state thread-safe or marshal work onto your own queue/actor.');
  writer.line(' */');
  writer.line(
    'public protocol Hybrid${spec.dartClassName}Protocol: AnyObject {',
  );

  for (final func in spec.functions) {
    if (func.lineNumber != null) {
      writer.line('    // source: ${spec.sourceUri.split('/').last}:${func.lineNumber}');
    }
    final retType = mapper.swiftType(func.returnType.name, bridgeType: func.returnType);
    final params = func.params
        .map((p) {
          if (p.type.isFunction) {
            return '${p.name}: @escaping ${mapper.protocolCallbackType(p.type)}';
          }
          return '${p.name}: ${mapper.swiftType(p.type.name, bridgeType: p.type)}';
        })
        .join(', ');
    // @mainThread (issue #19): async requirements are marked @MainActor so
    // conforming impls infer MainActor isolation — their bodies genuinely run
    // on the main thread and every `await` hops there automatically. Sync
    // methods are dispatched via the _nitroMainSync helper instead (an actor
    // annotation here would make the synchronous @_cdecl call site illegal).
    final isolation = func.mainThread && (func.isAsync || func.isNativeAsync) ? '@MainActor ' : '';
    if (func.isGetter) {
      // Property form; effects go on the accessor: `{ get async throws }`.
      final effects = func.isAsync || func.isNativeAsync ? ' async throws' : (func.isResult ? ' throws' : '');
      writer.line('    ${isolation}var ${func.dartName}: $retType { get$effects }');
    } else if (func.isAsync || func.isNativeAsync) {
      writer.line(
        '    ${isolation}func ${func.dartName}($params) async throws -> $retType',
      );
    } else if (func.isResult) {
      writer.line('    func ${func.dartName}($params) throws -> $retType');
    } else {
      writer.line('    func ${func.dartName}($params) -> $retType');
    }
  }

  for (final prop in spec.properties) {
    final swiftType = mapper.swiftType(prop.type.name);
    if (prop.hasSetter) {
      writer.line('    var ${prop.dartName}: $swiftType { get set }');
    } else {
      writer.line('    var ${prop.dartName}: $swiftType { get }');
    }
  }

  for (final stream in spec.streams) {
    final itemType = mapper.swiftType(stream.itemType.name);
    writer.line(
      '    var ${stream.dartName}: AnyPublisher<$itemType, Never> { get }',
    );
  }

  writer.line('}');
  writer.blankLine();
}

void _emitSwiftRegistry(CodeWriter writer, BridgeSpec spec) {
  final name = spec.dartClassName;
  // ── Provider — lets the registry find the implementation by itself ────
  // Flutter calls the plugin's `register(with:)` before Dart runs. A host
  // that never does (DartNative) leaves the registry empty and every call
  // returned a default value, so the registry asks a provider class on
  // first use.
  writer.line('/// A class that adopts this registers the implementation. The registry asks it');
  writer.line('/// on first use when nothing has registered one: a host that never calls the');
  writer.line("/// plugin's `register(with:)` (DartNative).");
  writer.line('@objc public protocol ${name}ImplementationProvider {');
  writer.line('    static func register${name}Implementation()');
  writer.line('}');
  writer.blankLine();
  writer.line('public class ${name}Registry {');
  writer.line('    private static var _impl: Hybrid${name}Protocol?');
  writer.blankLine();
  writer.line('    public static var impl: Hybrid${name}Protocol? {');
  writer.line('        get {');
  writer.line('            if _impl == nil { _ = _askProvider }');
  writer.line('            return _impl');
  writer.line('        }');
  writer.line('        set { _impl = newValue }');
  writer.line('    }');
  writer.blankLine();
  writer.line('    public static func register(_ impl: Hybrid${name}Protocol) {');
  writer.line('        _impl = impl');
  writer.line('    }');
  writer.blankLine();
  writer.line('    /// Why a call cannot run. The bridge raises it (sync, @nitroAsync) or');
  writer.line('    /// writes it to the error slot (@nitroNativeAsync), so Dart throws');
  writer.line('    /// instead of receiving a default value.');
  writer.line('    static let notRegisteredReason = "$name has no registered implementation. Adopt ${name}ImplementationProvider on the plugin class or call ${name}Registry.register(_:)."');
  writer.blankLine();
  writer.line('    static func raiseNotRegistered() {');
  writer.line('        NSException(name: NSExceptionName("NotRegistered"), reason: notRegisteredReason, userInfo: nil).raise()');
  writer.line('    }');
  writer.blankLine();
  writer.line('    /// Runs once. Looks only at the classes of the image this module is linked');
  writer.line('    /// into: asking every class in the process touches ones that cannot be');
  writer.line('    /// messaged.');
  writer.line('    private static let _askProvider: Void = {');
  writer.line('        guard let image = class_getImageName(${name}Registry.self) else { return }');
  writer.line('        var count: UInt32 = 0');
  writer.line('        guard let names = objc_copyClassNamesForImage(image, &count) else { return }');
  writer.line('        defer { free(names) }');
  writer.line('        for i in 0..<Int(count) {');
  writer.line('            guard let cls = objc_lookUpClass(names[i]), class_conformsToProtocol(cls, ${name}ImplementationProvider.self) else { continue }');
  writer.line('            (cls as? ${name}ImplementationProvider.Type)?.register${name}Implementation()');
  writer.line('            if _impl != nil { return }');
  writer.line('        }');
  writer.line('        NSLog("$name: no implementation is registered, so calls throw. Adopt ${name}ImplementationProvider on the plugin class or call ${name}Registry.register(_:).")');
  writer.line('    }()');

  for (final stream in spec.streams) {
    writer.blankLine();
    writer.line(
      '    // Stream: ${stream.dartName} cancellables keyed by dartPort',
    );
    writer.line(
      '    public static var _${stream.dartName}Cancellables = [Int64: AnyCancellable]()',
    );
    if (stream.isBatch) {
      writer.line(
        '    public static var _${stream.dartName}FlushTimers: [Int64: DispatchSourceTimer] = [:]',
      );
    }
  }

  writer.line('}');
  writer.blankLine();
}
