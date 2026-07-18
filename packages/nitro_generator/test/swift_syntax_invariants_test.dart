// Cross-emitter syntax invariants for generated Swift (and C++).
//
// Issue #22: the record fromReader initializers emitted a trailing comma in
// the argument list — Swift 6.1+ syntax (SE-0439) that fails to parse on
// Xcode <= 16.2 ("Unexpected ',' separator"). Newer local toolchains accept
// it, so builds never caught it; these tests lock the syntax property itself.
//
// The invariant: NO comma directly before a closing parenthesis, anywhere in
// any generated output. This is illegal in argument lists, parameter lists,
// and tuples on pre-6.1 Swift and in ALL C/C++ — while trailing commas
// before `]`/`}` (array/dict/brace literals) are legal everywhere and NOT
// flagged. Scanning whole generated files keeps every current and future
// emitter honest, not just the two sites fixed for #22.
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_header_generator.dart';
import 'package:nitro_generator/src/generators/languages/cpp_native/cpp_interface_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

/// Matches a comma whose next non-whitespace character is `)` — spanning
/// newlines, so `foo(a,\n)` and `foo(a, )` both hit.
final RegExp _trailingCommaBeforeParen = RegExp(r',\s*\)');

/// Fails with the offending lines listed, so a regression names its emitter.
void expectNoParenTrailingCommas(String output, String label) {
  final hits = <String>[];
  for (final m in _trailingCommaBeforeParen.allMatches(output)) {
    final lineStart = output.lastIndexOf('\n', m.start) + 1;
    final lineEnd = output.indexOf('\n', m.start);
    final line = output.substring(lineStart, lineEnd == -1 ? output.length : lineEnd);
    hits.add(line.trim());
  }
  expect(hits, isEmpty, reason: '$label emits trailing comma(s) before ")" — Swift 6.1+-only / illegal C++ (issue #22): $hits');
}

/// A deliberately fat spec: every construct that emits argument or parameter
/// lists — single- and multi-field records, a struct embedded in a record
/// (RecordExt path), variants with and without fields, plain/batch/record
/// streams, sync + @nitroAsync + @nitroNativeAsync, @NitroResult, callbacks,
/// maps, lists of records, nullable prims, enums, owned NativeHandle.
BridgeSpec _fatSpec({NativeImpl iosImpl = NativeImpl.swift}) => BridgeSpec(
  dartClassName: 'Fat',
  lib: 'fat',
  namespace: 'fat',
  iosImpl: iosImpl,
  macosImpl: iosImpl,
  androidImpl: iosImpl == NativeImpl.cpp ? NativeImpl.cpp : NativeImpl.kotlin,
  sourceUri: 'fat.native.dart',
  enums: [
    BridgeEnum(name: 'Mode', startValue: 0, values: ['a', 'b', 'c']),
  ],
  structs: [
    BridgeStruct(
      name: 'Pt',
      packed: false,
      fields: [
        BridgeField(name: 'x', type: BridgeType(name: 'double')),
        BridgeField(name: 'y', type: BridgeType(name: 'double')),
      ],
    ),
  ],
  recordTypes: [
    BridgeRecordType(
      name: 'One',
      fields: [
        BridgeRecordField(name: 'a', dartType: 'int', kind: RecordFieldKind.primitive),
      ],
    ),
    BridgeRecordType(
      name: 'Many',
      fields: [
        BridgeRecordField(name: 'a', dartType: 'int', kind: RecordFieldKind.primitive),
        BridgeRecordField(name: 'b', dartType: 'String', kind: RecordFieldKind.primitive),
        BridgeRecordField(name: 'c', dartType: 'double?', kind: RecordFieldKind.primitive),
        BridgeRecordField(name: 'p', dartType: 'Pt', kind: RecordFieldKind.struct),
        BridgeRecordField(name: 'm', dartType: 'Mode', kind: RecordFieldKind.enumValue),
      ],
    ),
  ],
  variants: [
    BridgeVariant(
      name: 'Ev',
      cases: [
        BridgeVariantCase(
          name: 'EvA',
          label: 'a',
          fields: [
            BridgeRecordField(name: 'id', dartType: 'String', kind: RecordFieldKind.primitive),
            BridgeRecordField(name: 'n', dartType: 'int', kind: RecordFieldKind.primitive),
          ],
        ),
        BridgeVariantCase(name: 'EvB', label: 'b', fields: []),
      ],
    ),
  ],
  streams: [
    BridgeStream(
      dartName: 'ticks',
      registerSymbol: 'fat_reg_ticks',
      releaseSymbol: 'fat_rel_ticks',
      itemType: BridgeType(name: 'int'),
      backpressure: Backpressure.batch,
      batchMaxSize: 16,
      isMethodStyle: false,
    ),
    BridgeStream(
      dartName: 'evs',
      registerSymbol: 'fat_reg_evs',
      releaseSymbol: 'fat_rel_evs',
      itemType: BridgeType(name: 'Many', isRecord: true),
      backpressure: Backpressure.dropLatest,
      batchMaxSize: 64,
      isMethodStyle: false,
    ),
  ],
  functions: [
    BridgeFunction(
      dartName: 'echoMany',
      cSymbol: 'fat_echo_many',
      isAsync: false,
      returnType: BridgeType(name: 'Many', isRecord: true),
      params: [
        BridgeParam(name: 'v', type: BridgeType(name: 'Many', isRecord: true)),
        BridgeParam(name: 's', type: BridgeType(name: 'String')),
        BridgeParam(name: 'n', type: BridgeType(name: 'int?', isNullable: true)),
      ],
    ),
    BridgeFunction(
      dartName: 'listMany',
      cSymbol: 'fat_list_many',
      isAsync: true,
      returnType: BridgeType(name: 'List<Many>', isRecord: true, recordListItemType: 'Many'),
      params: [],
    ),
    BridgeFunction(
      dartName: 'naMany',
      cSymbol: 'fat_na_many',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'Many', isRecord: true),
      params: [],
    ),
    BridgeFunction(
      dartName: 'tryIt',
      cSymbol: 'fat_try_it',
      isAsync: false,
      returnType: BridgeType(name: 'One', isRecord: true),
      params: [],
      isResult: true,
    ),
    BridgeFunction(
      dartName: 'onTick',
      cSymbol: 'fat_on_tick',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'cb',
          type: BridgeType(
            name: 'void Function(int)',
            isFunction: true,
            functionReturnType: 'void',
            functionParams: [BridgeType(name: 'int')],
          ),
        ),
      ],
    ),
    BridgeFunction(
      dartName: 'acquire',
      cSymbol: 'fat_acquire',
      isAsync: false,
      returnType: BridgeType(name: 'NativeHandle<Void>', isNativeHandle: true, nativeHandleTypeParam: 'Void'),
      params: [],
      isOwned: true,
    ),
    BridgeFunction(
      dartName: 'mapIt',
      cSymbol: 'fat_map_it',
      isAsync: false,
      returnType: BridgeType(name: 'Map<String, int>', isMap: true, isRecord: true),
      params: [],
    ),
  ],
);

void main() {
  group('generated Swift — no trailing comma before ")" (issue #22)', () {
    test('Swift-impl bridge (full surface)', () {
      expectNoParenTrailingCommas(SwiftGenerator.generate(_fatSpec()), 'SwiftGenerator (swift impl)');
    });

    test('all-C++ module bridge (embeds the record codec)', () {
      expectNoParenTrailingCommas(SwiftGenerator.generate(_fatSpec(iosImpl: NativeImpl.cpp)), 'SwiftGenerator (cpp impl)');
    });

    test('record fromReader — the reported #22 shape, single and multi field', () {
      final out = SwiftGenerator.generate(_fatSpec());
      // Single-field record: exactly one argument, no comma at all.
      expect(out, contains('return One(\n      a: r.readInt()\n    )'));
      // Multi-field record: last argument bare.
      final manyIdx = out.indexOf('return Many(');
      expect(manyIdx, greaterThan(-1));
      // The initializer's closing paren sits alone on its own line — a bare
      // indexOf(')') would stop inside `r.readInt()`.
      final manyBlock = out.substring(manyIdx, out.indexOf('\n    )', manyIdx) + 6);
      expect(manyBlock, isNot(matches(RegExp(r',\s*\)'))));
      expect(manyBlock, contains('a: r.readInt(),'), reason: 'separating commas between arguments stay');
    });

    test('struct-embedded-in-record RecordExt fromReader has no trailing comma', () {
      final out = SwiftGenerator.generate(_fatSpec());
      final extIdx = out.indexOf('return Pt(');
      expect(extIdx, greaterThan(-1), reason: 'Pt is embedded in Many — RecordExt must be emitted');
      final block = out.substring(extIdx, out.indexOf('\n    )', extIdx) + 6);
      expect(block, isNot(matches(RegExp(r',\s*\)'))));
    });
  });

  group('generated C++ — no trailing comma before ")" (same bug class)', () {
    // Trailing commas in call/parameter lists are illegal in ALL C/C++ —
    // scanned here so a future emitter cannot introduce the C++ twin of #22.
    test('C bridge (mixed-platform)', () {
      expectNoParenTrailingCommas(CppBridgeGenerator.generate(_fatSpec()), 'CppBridgeGenerator');
    });

    test('C header', () {
      expectNoParenTrailingCommas(CppHeaderGenerator.generate(_fatSpec()), 'CppHeaderGenerator');
    });

    test('C++ interface + direct bridge (all-cpp)', () {
      final cppSpec = _fatSpec(iosImpl: NativeImpl.cpp);
      expectNoParenTrailingCommas(CppInterfaceGenerator.generate(cppSpec), 'CppInterfaceGenerator');
      expectNoParenTrailingCommas(CppBridgeGenerator.generate(cppSpec), 'CppBridgeGenerator (all-cpp)');
    });
  });
}
