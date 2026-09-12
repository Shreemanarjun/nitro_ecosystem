import '../../../bridge_spec.dart';
import '../../code_writer.dart';

/// `@NitroEntryPoint` helpers shared by the dart:ffi and web generators.

/// Dart parameter list for the typed runner / web stub, mirroring the entry.
String entryPointSignature(BridgeEntryPoint e) {
  final positional = e.params.where((p) => !p.isNamed && !p.isOptional).map((p) => '${p.type.name} ${p.name}');
  final optional = e.params.where((p) => !p.isNamed && p.isOptional).map((p) => '${p.type.name} ${p.name}${p.defaultLiteral != null ? ' = ${p.defaultLiteral}' : ''}');
  final named = e.params.where((p) => p.isNamed).map((p) => '${p.isOptional ? '' : 'required '}${p.type.name} ${p.name}${p.defaultLiteral != null ? ' = ${p.defaultLiteral}' : ''}');
  return [
    ...positional,
    if (optional.isNotEmpty) '[${optional.join(', ')}]',
    if (named.isNotEmpty) '{${named.join(', ')}}',
  ].join(', ');
}

/// Forwarding call arguments matching [entryPointSignature].
String entryPointCallArgs(BridgeEntryPoint e) => [
  for (final p in e.params.where((p) => !p.isNamed)) p.name,
  for (final p in e.params.where((p) => p.isNamed)) '${p.name}: ${p.name}',
].join(', ');

/// Public names the platform shim re-exports (web-split layout).
List<String> entryPointExports(BridgeSpec spec) => [
  if (spec.entryPoints.isNotEmpty) 'has${spec.dartClassName}BackgroundHost',
  if (spec.entryPoints.isNotEmpty) 'active${spec.dartClassName}BackgroundJobs',
  for (final e in spec.entryPoints) e.runnerName,
];

/// Web twin of the typed runners: the same public names, all throwing — there
/// is no headless engine and no isolate on web.
void emitEntryPointWebStubs(CodeWriter w, BridgeSpec spec) {
  if (spec.entryPoints.isEmpty) return;
  w.blankLine();
  w.line('/// Always false on web: entry points cannot run in the background here.');
  w.line('bool has${spec.dartClassName}BackgroundHost() => false;');
  w.blankLine();
  w.line('/// Always 0 on web: nothing can be queued.');
  w.line('int active${spec.dartClassName}BackgroundJobs() => 0;');
  for (final e in spec.entryPoints) {
    final ret = e.returnsVoid ? 'void' : e.returnType.name;
    w.blankLine();
    w.line('${e.isStream ? 'Stream' : 'Future'}<$ret> ${e.runnerName}(${entryPointSignature(e)}) =>');
    w.line("    throw UnsupportedError('@NitroEntryPoint ${e.name}: background entry points are not available on web');");
  }
}
