// Tests for correct constructor-parameter style in struct code generation.
//
// A @HybridStruct can declare its constructor params as:
//   a) Named required   — `Foo({required this.x, required this.y})`
//   b) Named optional   — `Foo({this.debug = false, required this.name})`
//   c) Positional required — `Foo(this.x, this.y)`
//   d) Positional optional — `Foo([this.x = 0.0])`
//   e) Mixed            — some positional, then some named
//
// The generator must:
//   toDart()  — emit `f(posVal, namedField: namedVal)` (positional first, named after)
//   super()   — same ordering with zero-value defaults
//
// The FFI Struct, toNative(), Kotlin, Swift, and C typedef are NOT affected by
// named/positional — they always use field names directly.

import 'package:nitro_generator/src/generators/struct_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

void main() {
  // ── All-positional required params ────────────────────────────────────────
  group('All-positional required params', () {
    late String dartExt;
    late String dartProxy;

    setUp(() {
      dartExt   = StructGenerator.generateDartExtensions(positionalStructSpec());
      dartProxy = StructGenerator.generateDartProxies(positionalStructSpec());
    });

    test('toDart() emits positional args (no field: prefix)', () {
      // Should contain `Point(` followed by raw values, NOT `x: x`
      expect(dartExt, contains('return Point('));
      expect(dartExt, isNot(contains('x: x')));
      expect(dartExt, isNot(contains('y: y')));
    });

    test('toDart() positional args appear in declaration order', () {
      final idx = dartExt.indexOf('return Point(');
      final block = dartExt.substring(idx, dartExt.indexOf(');', idx) + 2);
      // x must appear before y in the positional arg list
      expect(block.indexOf('x,'), lessThan(block.indexOf('y,')));
    });

    test('proxy super() emits positional defaults (no field: prefix)', () {
      expect(dartProxy, isNot(contains('x: 0.0')));
      expect(dartProxy, isNot(contains('y: 0.0')));
      // zero-value doubles appear as positional values
      expect(dartProxy, contains('super(0.0, 0.0)'));
    });

    test('FFI Struct field declaration is unchanged (always uses field name)', () {
      expect(dartExt, contains('external double x;'));
      expect(dartExt, contains('external double y;'));
    });

    test('toNative() field assignment unchanged (always uses field name)', () {
      expect(dartExt, contains('ptr.ref.x = x'));
      expect(dartExt, contains('ptr.ref.y = y'));
    });

    test('Kotlin data class uses field names regardless of param style', () {
      final kotlin = StructGenerator.generateKotlin(positionalStructSpec());
      expect(kotlin, contains('val x: Double'));
      expect(kotlin, contains('val y: Double'));
    });

    test('Swift struct uses field names regardless of param style', () {
      final swift = StructGenerator.generateSwift(positionalStructSpec());
      expect(swift, contains('var x: Double'));
      expect(swift, contains('var y: Double'));
    });

    test('C typedef uses field names regardless of param style', () {
      final c = StructGenerator.generateCStructs(positionalStructSpec());
      expect(c, contains('double x;'));
      expect(c, contains('double y;'));
    });
  });

  // ── Named optional params ─────────────────────────────────────────────────
  group('Named optional params', () {
    late String dartExt;
    late String dartProxy;

    setUp(() {
      dartExt   = StructGenerator.generateDartExtensions(namedOptionalStructSpec());
      dartProxy = StructGenerator.generateDartProxies(namedOptionalStructSpec());
    });

    test('toDart() emits named args even for optional fields', () {
      expect(dartExt, contains('name: name.toDartString()'));
      expect(dartExt, contains('debug: debug != 0'));
      expect(dartExt, contains('level: level'));
    });

    test('proxy super() emits named defaults for all fields', () {
      expect(dartProxy, contains("name: ''"));
      expect(dartProxy, contains('debug: false'));
      expect(dartProxy, contains('level: 0'));
    });

    test('no positional args appear in toDart()', () {
      final idx = dartExt.indexOf('return Config(');
      final block = dartExt.substring(idx, dartExt.indexOf(');', idx) + 2);
      // Every non-whitespace token before the closing ')' should contain a ':'
      // — i.e. every arg has a label. A quick proxy: no bare 'name' without ':'
      expect(block, contains('name:'));
      expect(block, contains('debug:'));
      expect(block, contains('level:'));
    });
  });

  // ── Mixed positional + named params ───────────────────────────────────────
  group('Mixed positional + named params', () {
    late String dartExt;
    late String dartProxy;

    setUp(() {
      dartExt   = StructGenerator.generateDartExtensions(mixedParamsStructSpec());
      dartProxy = StructGenerator.generateDartProxies(mixedParamsStructSpec());
    });

    test('toDart() emits positional args before named args', () {
      final idx = dartExt.indexOf('return Rect(');
      final block = dartExt.substring(idx, dartExt.indexOf(');', idx) + 2);
      // x and y are positional — no labels
      expect(block, isNot(contains('x:')));
      expect(block, isNot(contains('y:')));
      // width and height are named
      expect(block, contains('width:'));
      expect(block, contains('height:'));
      // positional must come before named
      final lastPositional = [block.indexOf('x,'), block.indexOf('y,')].reduce((a, b) => a > b ? a : b);
      final firstNamed     = [block.indexOf('width:'), block.indexOf('height:')].reduce((a, b) => a < b ? a : b);
      expect(lastPositional, lessThan(firstNamed));
    });

    test('proxy super() emits positional defaults then named defaults', () {
      // Positional: 0.0, 0.0  (for x, y)
      // Named: width: 0.0, height: 0.0
      expect(dartProxy, contains('super(0.0, 0.0, width: 0.0, height: 0.0)'));
    });
  });

  // ── Named-required (default spec style) — regression ─────────────────────
  group('Named-required params (default) — regression', () {
    test('all fields still use named args when isNamed defaults to true', () {
      // richSpec() uses default BridgeField() without explicit isNamed
      final out = StructGenerator.generateDartExtensions(richSpec());
      expect(out, contains('value: value'));
      expect(out, contains('valid: valid != 0'));
    });

    test('proxy super() still emits named defaults', () {
      final out = StructGenerator.generateDartProxies(richSpec());
      expect(out, contains('value: 0.0'));
      expect(out, contains('valid: false'));
    });
  });

  // ── Nested positional-child struct ────────────────────────────────────────
  group('Nested positional-child: parent named, nested child positional', () {
    late String dartExt;
    late String dartProxy;

    setUp(() {
      dartExt   = StructGenerator.generateDartExtensions(nestedPositionalChildSpec());
      dartProxy = StructGenerator.generateDartProxies(nestedPositionalChildSpec());
    });

    test('Vec2 toDart() emits positional args', () {
      // Find the Vec2 toDart block
      final idx = dartExt.indexOf('return Vec2(');
      final block = dartExt.substring(idx, dartExt.indexOf(');', idx) + 2);
      expect(block, isNot(contains('x:')));
      expect(block, isNot(contains('y:')));
    });

    test('Line toDart() emits named args calling Vec2 via .ref.toDart()', () {
      expect(dartExt, contains('start: start.ref.toDart()'));
      expect(dartExt, contains('end: end.ref.toDart()'));
    });

    test('proxy super() for Vec2 uses positional zero-values', () {
      // Vec2 proxy super must be Vec2(0.0, 0.0), not Vec2(x: 0.0, y: 0.0)
      expect(dartProxy, contains('Vec2(0.0, 0.0)'));
      expect(dartProxy, isNot(contains('Vec2(x: 0.0')));
    });

    test('proxy super() for Line references the Vec2 positional zero constructor', () {
      expect(dartProxy, contains('start: Vec2(0.0, 0.0)'));
      expect(dartProxy, contains('end: Vec2(0.0, 0.0)'));
    });
  });

  // ── Edge cases ────────────────────────────────────────────────────────────
  group('Edge cases', () {
    test('single positional field', () {
      final spec = BridgeSpec(
        dartClassName: 'Wrap',
        lib: 'wrap',
        namespace: 'wrap',
        iosImpl: NativeImpl.swift,
        sourceUri: 'wrap.native.dart',
        structs: [
          BridgeStruct(
            name: 'Scalar',
            packed: false,
            fields: [
              BridgeField(
                name: 'val',
                type: BridgeType(name: 'double'),
                isNamed: false,
                isRequired: true,
              ),
            ],
          ),
        ],
        functions: [],
      );
      final out = StructGenerator.generateDartExtensions(spec);
      expect(out, contains('return Scalar('));
      expect(out, isNot(contains('val: val')));  // no label for positional
      expect(out, contains('val,'));              // raw value as positional arg
    });

    test('single named-optional field', () {
      final spec = BridgeSpec(
        dartClassName: 'Flags',
        lib: 'flags',
        namespace: 'flags',
        iosImpl: NativeImpl.swift,
        sourceUri: 'flags.native.dart',
        structs: [
          BridgeStruct(
            name: 'Flag',
            packed: false,
            fields: [
              BridgeField(
                name: 'enabled',
                type: BridgeType(name: 'bool'),
                isNamed: true,
                isRequired: false,
              ),
            ],
          ),
        ],
        functions: [],
      );
      final ext   = StructGenerator.generateDartExtensions(spec);
      final proxy = StructGenerator.generateDartProxies(spec);
      expect(ext,   contains('enabled: enabled != 0'));
      expect(proxy, contains('enabled: false'));
    });

    test('struct with only one positional field and one named field', () {
      final spec = BridgeSpec(
        dartClassName: 'Mix',
        lib: 'mix',
        namespace: 'mix',
        iosImpl: NativeImpl.swift,
        sourceUri: 'mix.native.dart',
        structs: [
          BridgeStruct(
            name: 'NamedValue',
            packed: false,
            fields: [
              BridgeField(name: 'id',   type: BridgeType(name: 'int'),    isNamed: false, isRequired: true),
              BridgeField(name: 'label', type: BridgeType(name: 'String'), isNamed: true,  isRequired: true),
            ],
          ),
        ],
        functions: [],
      );
      final ext   = StructGenerator.generateDartExtensions(spec);
      final proxy = StructGenerator.generateDartProxies(spec);
      // toDart() — `id` positional, `label` named
      expect(ext,   contains('id,'));
      expect(ext,   isNot(contains('id:')));
      expect(ext,   contains('label: label.toDartString()'));
      // super() — same order
      expect(proxy, contains("super(0, label: '')"));
    });

    test('all-positional struct with bool, string, int, enum fields', () {
      final spec = BridgeSpec(
        dartClassName: 'Multi',
        lib: 'multi',
        namespace: 'multi',
        iosImpl: NativeImpl.swift,
        sourceUri: 'multi.native.dart',
        enums: [
          BridgeEnum(name: 'Mode', startValue: 0, values: ['a', 'b']),
        ],
        structs: [
          BridgeStruct(
            name: 'Row',
            packed: false,
            fields: [
              BridgeField(name: 'count',  type: BridgeType(name: 'int'),    isNamed: false, isRequired: true),
              BridgeField(name: 'active', type: BridgeType(name: 'bool'),   isNamed: false, isRequired: true),
              BridgeField(name: 'label',  type: BridgeType(name: 'String'), isNamed: false, isRequired: true),
              BridgeField(name: 'mode',   type: BridgeType(name: 'Mode'),   isNamed: false, isRequired: true),
            ],
          ),
        ],
        functions: [],
      );
      final ext = StructGenerator.generateDartExtensions(spec);
      // No named labels — all positional
      expect(ext, isNot(contains('count:')));
      expect(ext, isNot(contains('active:')));
      expect(ext, isNot(contains('label:')));
      expect(ext, isNot(contains('mode:')));
      // Conversion expressions still correct
      expect(ext, contains('active != 0,'));
      expect(ext, contains('label.toDartString(),'));
      expect(ext, contains('mode.toMode(),'));
    });
  });
}
