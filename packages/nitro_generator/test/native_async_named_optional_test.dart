// `@nitroNativeAsync Future<R> f(String a, {S? settings})` — a named OPTIONAL
// nullable @HybridRecord param on a native-async method that also returns a
// record. SYNC_RECORD_RETURN used to fire on it: the rule tested `!isAsync`
// and ignored `isNativeAsync`, so a method that returns a Future and has its
// result posted from native was reported as a blocking synchronous decode.
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/web/web_bridge_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

BridgeSpec _spec({required bool nativeAsync, required bool async}) => BridgeSpec(
  dartClassName: 'Printer', lib: 'printer', namespace: 'printer',
  iosImpl: NativeImpl.swift, androidImpl: NativeImpl.kotlin,
  sourceUri: 'printer.native.dart',
  recordTypes: [
    BridgeRecordType(name: 'PrintResult', fields: [
      BridgeRecordField(name: 'ok', dartType: 'bool', kind: RecordFieldKind.primitive),
    ]),
    BridgeRecordType(name: 'PrintSettings', fields: [
      BridgeRecordField(name: 'copies', dartType: 'int', kind: RecordFieldKind.primitive),
    ]),
  ],
  functions: [
    BridgeFunction(
      dartName: 'printText', cSymbol: 'printer_print_text',
      isAsync: async, isNativeAsync: nativeAsync,
      returnType: BridgeType(name: 'PrintResult', isRecord: true, isFuture: async || nativeAsync),
      params: [
        BridgeParam(name: 'text', type: BridgeType(name: 'String')),
        BridgeParam(
          name: 'settings',
          type: BridgeType(name: 'PrintSettings?', isRecord: true, isNullable: true),
          isNamed: true, isOptional: true,
        ),
      ],
    ),
  ],
);

Set<String> _codes(BridgeSpec s) => SpecValidator.validate(s).map((i) => i.code).toSet();

void main() {
  test('@NitroNativeAsync record return is NOT flagged as a sync record return', () {
    expect(_codes(_spec(nativeAsync: true, async: false)), isNot(contains('SYNC_RECORD_RETURN')));
  });

  test('@nitroAsync is still not flagged', () {
    expect(_codes(_spec(nativeAsync: false, async: true)), isNot(contains('SYNC_RECORD_RETURN')));
  });

  test('a genuinely synchronous record return IS still flagged', () {
    expect(_codes(_spec(nativeAsync: false, async: false)), contains('SYNC_RECORD_RETURN'));
  });

  test('the hint no longer claims records are JSON-serialized', () {
    final issue = SpecValidator.validate(_spec(nativeAsync: false, async: false))
        .firstWhere((i) => i.code == 'SYNC_RECORD_RETURN');
    expect(issue.hint, isNot(contains('JSON')));
    expect(issue.hint, contains('@NitroNativeAsync'));
  });

  group('the generated Dart preserves the signature', () {
    final out = DartFfiGenerator.generate(_spec(nativeAsync: true, async: false));

    test('named optional param stays named and optional', () {
      expect(out, contains('Future<PrintResult> printText(String text, {PrintSettings? settings})'));
    });

    test('a null named record param is passed as nullptr, not encoded', () {
      expect(out, contains('settings != null ? settings.toNative(arena) : nullptr'));
    });

    test('the record result is decoded from the posted pointer', () {
      expect(out, contains('PrintResultRecordExt.fromNative'));
    });
  });
  // The web bridge flattened named params into positional, so the generated
  // _XWebImpl was not a valid override of the spec — a compile error on web
  // for any method with a named param.
  group('web bridge keeps named params named', () {
    BridgeSpec webSpec() {
      final base = _spec(nativeAsync: true, async: false);
      return BridgeSpec(
        dartClassName: base.dartClassName, lib: base.lib, namespace: base.namespace,
        iosImpl: NativeImpl.cpp, androidImpl: NativeImpl.cpp, webImpl: NativeImpl.wasm,
        sourceUri: base.sourceUri, recordTypes: base.recordTypes, functions: base.functions,
      );
    }

    test('the named param survives in the web impl signature', () {
      final out = WebBridgeGenerator.generate(webSpec());
      expect(out, contains('printText(String text, {PrintSettings? settings})'));
      expect(
        out,
        isNot(contains('printText(String text, PrintSettings? settings)')),
        reason: 'positional here is not a valid override of the spec',
      );
    });

    test('the web and FFI emitters agree on the signature', () {
      final web = WebBridgeGenerator.generate(webSpec());
      final ffi = DartFfiGenerator.generate(_spec(nativeAsync: true, async: false));
      const sig = 'printText(String text, {PrintSettings? settings})';
      expect(web, contains(sig));
      expect(ffi, contains(sig));
    });
  });

}
