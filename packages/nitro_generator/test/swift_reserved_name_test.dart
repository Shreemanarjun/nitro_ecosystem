// A name from the spec is written into the Swift bridge as it is. A Swift
// keyword there (`where`, or the `default` that a variant case class named
// ModeDefault becomes) did not compile on iOS or macOS, with nothing reported
// before the compiler did. E022 reports it.
//
// The table behind the rule was taken from swiftc, position by position. These
// tests pin the rule and the cases that are easy to get wrong: a word only some
// positions reject, a module whose parameters are never more than labels, and a
// module with no Swift bridge at all.
import 'package:nitro_generator/src/swift_reserved_names.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

BridgeSpec _spec({
  NativeImpl? ios = NativeImpl.swift,
  NativeImpl? macos,
  NativeImpl? android,
  String method = 'run',
  String param = 'amount',
  String property = 'level',
  String stream = 'ticks',
  String field = 'x',
  String enumValue = 'idle',
  String variantClass = 'ModeTap',
  String variantLabel = 'tap',
  String variantField = 'at',
}) => BridgeSpec(
  dartClassName: 'Geo',
  lib: 'geo',
  namespace: 'geo',
  iosImpl: ios,
  macosImpl: macos,
  androidImpl: android,
  sourceUri: 'geo.native.dart',
  structs: [
    BridgeStruct(
      name: 'Box',
      packed: false,
      fields: [BridgeField(name: field, type: BridgeType(name: 'double'))],
    ),
  ],
  enums: [
    BridgeEnum(name: 'Kind', startValue: 0, values: [enumValue, 'busy']),
  ],
  variants: [
    BridgeVariant(
      name: 'Mode',
      cases: [
        BridgeVariantCase(
          name: variantClass,
          label: variantLabel,
          fields: [BridgeRecordField(name: variantField, dartType: 'int', kind: RecordFieldKind.primitive)],
        ),
      ],
    ),
  ],
  functions: [
    BridgeFunction(
      dartName: method,
      cSymbol: 'geo_run',
      isAsync: false,
      returnType: BridgeType(name: 'int'),
      params: [BridgeParam(name: param, type: BridgeType(name: 'int'))],
    ),
  ],
  properties: [
    BridgeProperty(dartName: property, type: BridgeType(name: 'double'), getSymbol: 'geo_get_level'),
  ],
  streams: [
    BridgeStream(
      dartName: stream,
      registerSymbol: 'geo_register_ticks_stream',
      releaseSymbol: 'geo_release_ticks_stream',
      itemType: BridgeType(name: 'double'),
      backpressure: Backpressure.dropLatest,
    ),
  ],
);

List<String> _e022(BridgeSpec s) => SpecValidator.validate(s).where((i) => i.code == 'E022').map((i) => i.message).toList();

void main() {
  test('a spec with ordinary names has nothing to report', () {
    expect(_e022(_spec()), isEmpty);
    expect(_e022(_spec(macos: NativeImpl.swift, android: NativeImpl.kotlin)), isEmpty);
  });

  group('a Swift keyword is an error wherever the bridge declares it', () {
    test('a method', () {
      final issues = SpecValidator.validate(_spec(method: 'where')).where((i) => i.code == 'E022').toList();
      expect(issues, hasLength(1));
      expect(issues.single.isError, isTrue);
      expect(issues.single.message, contains('Method "where"'));
      expect(issues.single.hint, contains('Rename'));
    });

    test('a parameter, a property, a stream, a struct field, an enum value', () {
      expect(_e022(_spec(param: 'repeat')).single, contains('Parameter of run() "repeat"'));
      expect(_e022(_spec(property: 'internal')).single, contains('Property "internal"'));
      expect(_e022(_spec(stream: 'defer')).single, contains('Stream "defer"'));
      expect(_e022(_spec(field: 'func')).single, contains('Field of Box "func"'));
      expect(_e022(_spec(enumValue: 'init')).single, contains('Value of Kind "init"'));
    });

    test('a variant case takes its Swift name from the class, so a word Dart reserves can arrive too', () {
      final message = _e022(_spec(variantClass: 'ModeDefault', variantLabel: 'default')).single;
      expect(message, contains('ModeDefault'));
      expect(message, contains('"default"'));
      expect(_e022(_spec(variantField: 'guard')).single, contains('Field of ModeTap "guard"'));
    });
  });

  group('only what swiftc rejects is reported', () {
    test('a word Swift reserves in some contexts only is a fine name', () {
      for (final word in ['get', 'set', 'open', 'async', 'lazy', 'left', 'optional', 'required', 'type', 'actor', 'value', 'result']) {
        expect(_e022(_spec(method: word, param: word, property: word, field: word, enumValue: word, variantLabel: word, variantField: word)), isEmpty, reason: word);
      }
    });

    test('a word only some positions reject is reported for those alone', () {
      // `Type` and `Protocol` are metatype members: no good as a property, fine as a method.
      expect(_e022(_spec(method: 'Type', param: 'Protocol')), isEmpty);
      expect(_e022(_spec(property: 'Type')), hasLength(1));
      expect(_e022(_spec(field: 'Protocol')), hasLength(1));
      // `await` is fine as a method and rejected as a stored name.
      expect(_e022(_spec(method: 'await')), isEmpty);
      expect(_e022(_spec(field: 'await')), hasLength(1));
      expect(_e022(_spec(param: 'await')), hasLength(1));
      // `self` is rejected as a member and accepted as a parameter.
      expect(_e022(_spec(param: 'self')), isEmpty);
      expect(_e022(_spec(method: 'self')), hasLength(1));
    });

    test('impl is not a Swift word: the call stub has a local of that name', () {
      expect(_e022(_spec(param: 'impl')).single, contains('Parameter of run() "impl"'));
      expect(_e022(_spec(method: 'impl', property: 'impl', field: 'impl')), isEmpty);
    });
  });

  group('which modules are checked', () {
    test('C++ on every Apple platform: a parameter is only ever a label there', () {
      // No @_cdecl stubs, and Swift takes any word but `inout` as an argument label.
      expect(_e022(_spec(ios: NativeImpl.cpp, macos: NativeImpl.cpp, param: 'where')), isEmpty);
      expect(_e022(_spec(ios: NativeImpl.cpp, param: 'impl')), isEmpty);
      expect(_e022(_spec(ios: NativeImpl.cpp, macos: NativeImpl.cpp, param: 'inout')), hasLength(1));
      // The protocol still declares the method.
      expect(_e022(_spec(ios: NativeImpl.cpp, macos: NativeImpl.cpp, method: 'where')), hasLength(1));
    });

    test('Swift on one Apple platform and C++ on the other has the stubs', () {
      expect(_e022(_spec(ios: NativeImpl.swift, macos: NativeImpl.cpp, param: 'where')), hasLength(1));
      expect(_e022(_spec(ios: NativeImpl.cpp, macos: NativeImpl.swift, param: 'where')), hasLength(1));
    });

    test('a module that is Swift on macOS alone is checked', () {
      expect(_e022(_spec(ios: null, macos: NativeImpl.swift, method: 'where')), hasLength(1));
    });

    test('a module with no Swift bridge is not', () {
      expect(_e022(_spec(ios: null, android: NativeImpl.kotlin, method: 'where', param: 'func')), isEmpty);
      expect(_e022(_spec(ios: null, macos: NativeImpl.cpp, method: 'where')), isEmpty);
    });
  });

  test('the table itself: reserved everywhere, and the per-position additions', () {
    expect(swiftReservedWords, containsAll(['where', 'default', 'func', 'init', 'in', 'Any']));
    expect(swiftRejectsName('where', SwiftNameUse.method), isTrue);
    expect(swiftRejectsName('where', SwiftNameUse.parameter, hasCallStubs: false), isFalse);
    expect(swiftRejectsName('inout', SwiftNameUse.parameter, hasCallStubs: false), isTrue);
    expect(swiftRejectsName('Self', SwiftNameUse.variantField), isTrue);
    expect(swiftRejectsName('self', SwiftNameUse.variantField), isFalse);
  });
}
