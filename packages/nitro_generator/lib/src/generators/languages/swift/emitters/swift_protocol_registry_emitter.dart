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
  final params = func.params.map((p) {
    if (p.type.isFunction) {
      return '${p.name}: @escaping ${mapper.protocolCallbackType(p.type)}';
    }
    return '${p.name}: ${mapper.swiftType(p.type.name, bridgeType: p.type)}';
  }).join(', ');
  if (func.isAsync || func.isNativeAsync) {
    writer.line(
      '    func ${func.dartName}($params) async throws -> $retType',
    );
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
// ── Registry — pure Swift, no @objc / NSObject needed ─────────────────
writer.line('public class ${spec.dartClassName}Registry {');
writer.line(
  '    public static var impl: Hybrid${spec.dartClassName}Protocol?',
);
writer.blankLine();
writer.line(
  '    public static func register(_ impl: Hybrid${spec.dartClassName}Protocol) {',
);
writer.line('        ${spec.dartClassName}Registry.impl = impl');
writer.line('    }');

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
