// Tests for source-map comments emitted by generators.
//
// When BridgeFunction.lineNumber is non-null, each generator emits a
//   // source: <filename>:<lineNumber>
// comment immediately before the method declaration. When lineNumber is
// null (the default for manually constructed specs), no comment is emitted.
//
// Generators covered: SwiftGenerator (protocol + @_cdecl stubs),
// KotlinGenerator (interface + JniBridge _call methods),
// CppInterfaceGenerator (virtual methods).

import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/languages/cpp_native/cpp_interface_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

BridgeSpec _specWithLine(int? lineNumber) => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'mod.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'greet',
      cSymbol: 'mod_greet',
      isAsync: false,
      returnType: BridgeType(name: 'String'),
      params: [],
      lineNumber: lineNumber,
    ),
  ],
);

BridgeSpec _cppSpecWithLine(int? lineNumber) => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  iosImpl: NativeImpl.cpp,
  sourceUri: 'mod.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'greet',
      cSymbol: 'mod_greet',
      isAsync: false,
      returnType: BridgeType(name: 'String'),
      params: [],
      lineNumber: lineNumber,
    ),
  ],
);

void main() {
  // ── SwiftGenerator — protocol section ─────────────────────────────────────

  group('SwiftGenerator — source-map comments in protocol', () {
    test('emits source comment when lineNumber is set', () {
      final out = SwiftGenerator.generate(_specWithLine(42));
      expect(out, contains('// source: mod.native.dart:42'));
    });

    test('source comment appears before the func declaration', () {
      final out = SwiftGenerator.generate(_specWithLine(10));
      final commentIdx = out.indexOf('// source: mod.native.dart:10');
      final funcIdx = out.indexOf('func greet()');
      expect(commentIdx, lessThan(funcIdx));
    });

    test('does NOT emit source comment when lineNumber is null', () {
      final out = SwiftGenerator.generate(_specWithLine(null));
      expect(out, isNot(contains('// source:')));
    });

    test('source comment includes the base filename (not a full path)', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'lib/src/my/deep/path/mod.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'fn',
            cSymbol: 'mod_fn',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [],
            lineNumber: 7,
          ),
        ],
      );
      final out = SwiftGenerator.generate(spec);
      expect(out, contains('// source: mod.native.dart:7'));
      expect(out, isNot(contains('lib/src/my/deep')));
    });
  });

  // ── SwiftGenerator — @_cdecl stubs section ────────────────────────────────

  group('SwiftGenerator — source-map comments in @_cdecl stubs', () {
    test('emits source comment before @_cdecl stub when lineNumber is set', () {
      final out = SwiftGenerator.generate(_specWithLine(99));
      // The comment should appear twice: once in the protocol, once above the stub
      final all = RegExp(r'// source: mod\.native\.dart:99').allMatches(out);
      expect(all.length, greaterThanOrEqualTo(2));
    });

    test('does NOT emit source comment in stubs when lineNumber is null', () {
      final out = SwiftGenerator.generate(_specWithLine(null));
      expect(out, isNot(contains('// source:')));
    });
  });

  // ── KotlinGenerator — interface section ───────────────────────────────────

  group('KotlinGenerator — source-map comments in interface', () {
    test('emits source comment when lineNumber is set', () {
      final out = KotlinGenerator.generate(_specWithLine(15));
      expect(out, contains('// source: mod.native.dart:15'));
    });

    test('source comment appears before the fun declaration', () {
      final out = KotlinGenerator.generate(_specWithLine(20));
      final commentIdx = out.indexOf('// source: mod.native.dart:20');
      final funcIdx = out.indexOf('fun greet()');
      expect(commentIdx, lessThan(funcIdx));
    });

    test('does NOT emit source comment when lineNumber is null', () {
      final out = KotlinGenerator.generate(_specWithLine(null));
      expect(out, isNot(contains('// source:')));
    });
  });

  // ── KotlinGenerator — JniBridge _call section ─────────────────────────────

  group('KotlinGenerator — source-map comments in JniBridge _call', () {
    test('emits source comment before _call when lineNumber is set', () {
      final out = KotlinGenerator.generate(_specWithLine(30));
      // Should appear at least twice: interface decl + bridge _call
      final all = RegExp(r'// source: mod\.native\.dart:30').allMatches(out);
      expect(all.length, greaterThanOrEqualTo(2));
    });
  });

  // ── CppInterfaceGenerator — virtual methods ────────────────────────────────

  group('CppInterfaceGenerator — source-map comments in virtual methods', () {
    test('emits source comment when lineNumber is set', () {
      final out = CppInterfaceGenerator.generate(_cppSpecWithLine(55));
      expect(out, contains('// source: mod.native.dart:55'));
    });

    test('source comment appears before virtual method declaration', () {
      final out = CppInterfaceGenerator.generate(_cppSpecWithLine(55));
      final commentIdx = out.indexOf('// source: mod.native.dart:55');
      // Search for the greet method's virtual line specifically, not the destructor
      final virtualIdx = out.indexOf('virtual std::string greet()');
      expect(commentIdx, lessThan(virtualIdx));
    });

    test('does NOT emit source comment when lineNumber is null', () {
      final out = CppInterfaceGenerator.generate(_cppSpecWithLine(null));
      expect(out, isNot(contains('// source:')));
    });
  });
}
