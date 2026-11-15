// A @HybridStruct or @HybridEnum becomes a C typedef of the same name at file
// scope, and Foundation already defines `Point`, `Size`, `Duration` and many
// more. A bridge that imports Foundation used to fail to compile on iOS and
// macOS for those names, with nothing reported before the compiler did. The
// bridge now renames Foundation's names while it imports it; the one name the
// language itself defines is rejected up front.
import 'package:nitro_generator/src/apple_system_names.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

BridgeSpec _spec({String? struct, String? enumName, NativeImpl? ios, NativeImpl? macos, NativeImpl? android}) => BridgeSpec(
  dartClassName: 'Geo',
  lib: 'geo',
  namespace: 'geo',
  iosImpl: ios,
  macosImpl: macos,
  androidImpl: android,
  sourceUri: 'geo.native.dart',
  structs: [
    if (struct != null)
      BridgeStruct(
        name: struct,
        packed: false,
        fields: [BridgeField(name: 'x', type: BridgeType(name: 'double'))],
      ),
  ],
  enums: [if (enumName != null) BridgeEnum(name: enumName, startValue: 0, values: ['a', 'b'])],
);

List<ValidationIssue> _e021(BridgeSpec s) => SpecValidator.validate(s).where((i) => i.code == 'E021').toList();

void main() {
  group('the bridge renames Foundation names around its import', () {
    test('a struct and an enum named after Foundation types', () {
      final out = CppBridgeGenerator.generate(_spec(struct: 'Point', enumName: 'Style', ios: NativeImpl.swift, macos: NativeImpl.swift));
      final lines = out.split('\n');
      final import = lines.indexOf('#import <Foundation/Foundation.h>');
      expect(import, isNot(-1));
      for (final name in ['Point', 'Style']) {
        final define = lines.indexOf('#define $name NitroSystem_$name');
        final undef = lines.indexOf('#undef $name');
        expect(define, isNot(-1), reason: name);
        expect(define, lessThan(import), reason: '$name must be renamed before Foundation is read');
        expect(undef, greaterThan(import), reason: '$name must be free again for the bridge header');
        expect(undef, lessThan(lines.indexOf('#include "geo.bridge.g.h"')), reason: name);
      }
    });

    test('a name only macOS defines is renamed too', () {
      final out = CppBridgeGenerator.generate(_spec(struct: 'FileInfo', ios: NativeImpl.swift));
      expect(out, contains('#define FileInfo NitroSystem_FileInfo'));
    });

    test('other names leave the import as it was', () {
      final out = CppBridgeGenerator.generate(_spec(struct: 'GeoPoint', enumName: 'TextStyle', ios: NativeImpl.swift, macos: NativeImpl.swift));
      expect(out, contains('#if defined(__APPLE__)\n#import <Foundation/Foundation.h>\n#endif'));
      expect(out, isNot(contains('NitroSystem_')));
    });

    test('a module that is C++ on every platform imports no Foundation, so renames nothing', () {
      final out = CppBridgeGenerator.generate(_spec(struct: 'Point', ios: NativeImpl.cpp, macos: NativeImpl.cpp));
      expect(out, isNot(contains('Foundation/Foundation.h')));
      expect(out, isNot(contains('NitroSystem_')));
    });
  });

  group('validator', () {
    test('names the bridge can rename are accepted', () {
      expect(_e021(_spec(struct: 'Point', enumName: 'Duration', ios: NativeImpl.swift, macos: NativeImpl.swift)), isEmpty);
      expect(_e021(_spec(struct: 'Size', ios: NativeImpl.cpp, android: NativeImpl.kotlin)), isEmpty);
    });

    test('a struct named after a type built into Objective-C is an error', () {
      final issues = _e021(_spec(struct: 'Protocol', ios: NativeImpl.swift));
      expect(issues, hasLength(1));
      expect(issues.single.isError, isTrue);
      expect(issues.single.message, contains('@HybridStruct Protocol'));
      expect(issues.single.hint, contains('GeoProtocol'));
    });

    test('so is an enum, and so is a module that is C++ throughout', () {
      // The bridge is compiled as Objective-C++ on Apple whatever implements it.
      final issues = _e021(_spec(enumName: 'Protocol', ios: NativeImpl.cpp, macos: NativeImpl.cpp));
      expect(issues, hasLength(1));
      expect(issues.single.message, contains('@HybridEnum Protocol'));
    });

    test('a module with no Apple target is not affected', () {
      expect(_e021(_spec(struct: 'Protocol', android: NativeImpl.kotlin)), isEmpty);
    });

    test('the name that cannot be renamed is not offered for renaming', () {
      expect(foundationNamesIos, contains('Protocol'));
      expect(isRenamableFoundationName('Protocol'), isFalse);
      expect(isRenamableFoundationName('Point'), isTrue);
      expect(isRenamableFoundationName('GeoPoint'), isFalse);
    });
  });
}
