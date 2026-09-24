part of '../dart_ffi_generator.dart';

/// `mixin <Class>Defaults on <Class>` — every abstract member of the spec
/// class with a `throw UnimplementedError` body (#53).
///
/// Hand-written fakes and in-memory implementations apply it
/// (`class Fake extends <Class> with <Class>Defaults { ... }`) so that adding a
/// member to the spec stays additive: the fake still compiles and an
/// un-overridden member fails at call time with a clear message instead of
/// breaking the whole test binary at load time. It is the Dart twin of the
/// generated C++ mock, lives in the platform-neutral part (pure Dart, so it
/// works on web too), and exists for every spec that has a bridge class.
void _emitDefaultsMixin(CodeWriter w, BridgeSpec spec) {
  final cls = spec.dartClassName;
  w.blankLine();
  w.line('/// Default `throw UnimplementedError` bodies for every member of [$cls], so');
  w.line('/// hand-written fakes keep compiling when the spec grows:');
  w.line('/// `class Fake$cls extends $cls with ${cls}Defaults { /* overrides */ }`.');
  w.line('mixin ${cls}Defaults on $cls {');
  for (final f in spec.functions) {
    final ret = _defaultsReturnType(f);
    w.line('  @override');
    w.line("  $ret ${f.dartMember(_paramList(f.params))} => throw UnimplementedError('$cls.${f.dartName}');");
  }
  for (final p in spec.properties) {
    final rt = p.type.name;
    if (p.hasGetter) {
      w.line('  @override');
      w.line("  $rt get ${p.dartName} => throw UnimplementedError('$cls.${p.dartName}');");
    }
    if (p.hasSetter) {
      w.line('  @override');
      w.line("  set ${p.dartName}($rt value) => throw UnimplementedError('$cls.${p.dartName}');");
    }
  }
  for (final s in spec.streams) {
    final item = '${s.itemType.baseName}${s.itemType.isNullable ? '?' : ''}';
    w.line('  @override');
    w.line(s.isMethodStyle
        ? "  Stream<$item> ${s.dartName}() => throw UnimplementedError('$cls.${s.dartName}');"
        : "  Stream<$item> get ${s.dartName} => throw UnimplementedError('$cls.${s.dartName}');");
  }
  w.line('}');
}

/// The Dart return type exactly as the spec declares it (mirrors the impl
/// emitter: `NitroResultValue` for @NitroResult, `NativeHandle<T>` for handles,
/// Future<...> for async and native-async).
String _defaultsReturnType(BridgeFunction func) {
  final handleParam = func.returnType.nativeHandleTypeParam ?? 'Void';
  final inner = func.isResult
      ? 'NitroResultValue<${_nitroResultInnerType(func.returnType).name}>'
      : func.returnType.isNativeHandle
      ? 'NativeHandle<$handleParam>'
      : func.returnType.name;
  final wrapper = func.returnsFutureOr ? 'FutureOr' : 'Future';
  return (func.isAsync || func.isNativeAsync || func.inlineFuture) ? '$wrapper<$inner>' : inner;
}
