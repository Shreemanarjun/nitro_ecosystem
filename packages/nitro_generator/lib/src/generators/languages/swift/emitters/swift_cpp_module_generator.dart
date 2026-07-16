part of '../swift_generator.dart';

/// Generates a reduced Swift bridge for [NativeImpl.cpp] modules.
///
/// C++ modules use the `.mm` shim (which calls `mylib_xxx` C functions from
/// the generated `.bridge.g.cpp`). They do NOT use `@_cdecl` Swift stubs:
///
/// - The C++ bridge never calls `_call_add` etc. — it calls `mylib_add`.
/// - Emitting `@_cdecl("_call_add")` here would duplicate the symbol
///   already exported by the Swift (non-cpp) module's bridge, causing a
///   "duplicate symbol" Swift compiler error when both are in the same target.
/// - Shared types (BenchmarkPoint, BenchmarkBox, NitroRecordWriter, etc.)
///   are already declared in the Swift module's `.bridge.g.swift`. Both
///   files are compiled into the same Swift module, so redeclaring them
///   causes "Invalid redeclaration of '…'" errors.
///
/// This method only emits the protocol and registry — everything the user
/// needs to implement and register their C++ class in Swift/ObjC++.
String _generateCppModuleBridge(BridgeSpec spec) {
  final mapper = SwiftTypeMapper(spec);
  final nodes = <CodeNode>[
    CodeSnippet(generatedFileHeader('//', sourceUri: spec.sourceUri)),
    const CodeLine('import Foundation'),
    const CodeLine('import Combine'),
    const BlankLine(),
    const CodeLine(
      '// This file is SELF-CONTAINED: the shared codec types (NitroEncodable,',
    ),
    const CodeLine(
      '// NitroRecordWriter, NitroRecordReader) are emitted below so an all-C++',
    ),
    const CodeLine(
      '// plugin (no Swift-impl module anywhere) still compiles. When a sibling',
    ),
    const CodeLine(
      '// Swift-impl bridge is compiled into the same module, nitrogen\'s sync',
    ),
    const CodeLine(
      '// dedup pass keeps exactly one copy of each shared declaration.',
    ),
    const CodeLine('//'),
    const CodeLine(
      '// No @_cdecl stubs are generated: the C++ bridge (.bridge.g.mm) calls',
    ),
    CodeLine(
      '// ${spec.namespace}_xxx C functions directly — Swift @_cdecl stubs are unused',
    ),
    const CodeLine(
      '// and would conflict with the Swift module\'s exported symbols.',
    ),
    const BlankLine(),
  ];

  // The record structs below conform to NitroEncodable and use the
  // Reader/Writer codec — emit those shared types HERE so the file compiles
  // standalone (issue #14: with zero Swift-impl modules in the plugin,
  // nothing else ever declared them and every Apple build broke).
  if (spec.recordTypes.isNotEmpty || spec.variants.isNotEmpty) {
    final protocolWriter = CodeWriter();
    SwiftGenerator._emitSwiftEncodableProtocol(protocolWriter);
    nodes.add(CodeSnippet(protocolWriter.toString()));
  }

  final swiftEnums = EnumGenerator.generateSwift(spec);
  if (swiftEnums.isNotEmpty) nodes.add(CodeSnippet(swiftEnums));

  final swiftStructs = StructGenerator.generateSwift(spec);
  if (swiftStructs.isNotEmpty) nodes.add(CodeSnippet(swiftStructs));

  // emitBoilerplate: true so NitroRecordWriter/NitroRecordReader (and the
  // nitro library record structs) land in this file too — see the
  // self-contained note above.
  final swiftRecords = RecordGenerator.generateSwift(spec);
  if (swiftRecords.isNotEmpty) nodes.add(CodeSnippet(swiftRecords));

  // Protocol
  nodes.addAll([
    const CodeLine('/**'),
    CodeLine(' * Protocol for the ${spec.dartClassName} module (NativeImpl.cpp).'),
    const CodeLine(
      ' * Conform to this in your Swift/ObjC++ source code if you want',
    ),
    const CodeLine(
      ' * to delegate from the C++ HybridObject to a Swift implementation.',
    ),
    const CodeLine(' * Nitro may call this implementation from any native thread.'),
    const CodeLine(
      ' * Keep mutable state thread-safe or marshal work onto your own queue/actor.',
    ),
    const CodeLine(' */'),
    CodeLine('public protocol Hybrid${spec.dartClassName}Protocol: AnyObject {'),
  ]);

  for (final func in spec.functions) {
    final retType = mapper.swiftType(func.returnType.name);
    final params = func.params.map((p) => '${p.name}: ${mapper.swiftType(p.type.name)}').join(', ');
    // @mainThread: same @MainActor rule as the Swift-impl protocol — async
    // requirements only (see swift_protocol_registry_emitter.dart).
    final isolation = func.mainThread && (func.isAsync || func.isNativeAsync) ? '@MainActor ' : '';
    if (func.isAsync || func.isNativeAsync) {
      nodes.add(
        CodeLine('    ${isolation}func ${func.dartName}($params) async throws -> $retType'),
      );
    } else {
      nodes.add(CodeLine('    func ${func.dartName}($params) -> $retType'));
    }
  }
  for (final prop in spec.properties) {
    final swiftType = mapper.swiftType(prop.type.name);
    if (prop.hasSetter) {
      nodes.add(CodeLine('    var ${prop.dartName}: $swiftType { get set }'));
    } else {
      nodes.add(CodeLine('    var ${prop.dartName}: $swiftType { get }'));
    }
  }
  for (final stream in spec.streams) {
    final itemType = mapper.swiftType(stream.itemType.name);
    nodes.add(
      CodeLine(
        '    var ${stream.dartName}: AnyPublisher<$itemType, Never> { get }',
      ),
    );
  }
  nodes.addAll(const [
    CodeLine('}'),
    BlankLine(),
  ]);

  // Registry
  nodes.addAll([
    CodeLine('public class ${spec.dartClassName}Registry {'),
    CodeLine('    public static var impl: Hybrid${spec.dartClassName}Protocol?'),
    const BlankLine(),
    CodeLine(
      '    public static func register(_ impl: Hybrid${spec.dartClassName}Protocol) {',
    ),
    CodeLine('        ${spec.dartClassName}Registry.impl = impl'),
    const CodeLine('    }'),
  ]);
  for (final stream in spec.streams) {
    nodes.add(const BlankLine());
    nodes.add(
      CodeLine('    // Stream: ${stream.dartName} cancellables keyed by dartPort'),
    );
    nodes.add(
      CodeLine(
        '    public static var _${stream.dartName}Cancellables = [Int64: AnyCancellable]()',
      ),
    );
  }
  nodes.addAll([
    const CodeLine('}'),
    const BlankLine(),
    const CodeLine(
      '// NOTE: @_cdecl bridge stubs are NOT generated for NativeImpl.cpp modules.',
    ),
    CodeLine(
      '// The .bridge.g.mm C++ shim calls ${spec.namespace}_xxx() C functions directly.',
    ),
  ]);

  return CodeFile(nodes).render();
}
