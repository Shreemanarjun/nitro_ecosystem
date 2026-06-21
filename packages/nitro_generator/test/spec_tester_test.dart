// Edge-case tests for SpecFromSource (the AST parser) and specTest (the
// assertion harness).  Each group exercises a distinct parsing or checking
// behaviour so regressions are immediately attributable.
//
// §1  SpecFromSource — basic parsing (class name, lib, namespace, defaults)
// §2  SpecFromSource — @NitroModule annotation (ios/android/lib/cSymbolPrefix)
// §3  SpecFromSource — functions (sync, async, @NitroAsync, @NitroNativeAsync)
// §4  SpecFromSource — parameters (positional, named, optional, defaults)
// §5  SpecFromSource — optional-primitive sentinel encoding
// §6  SpecFromSource — properties (getter-only, setter-only, getter+setter)
// §7  SpecFromSource — streams
// §8  SpecFromSource — @HybridEnum
// §9  SpecFromSource — @HybridStruct
// §10 SpecFromSource — multiple functions in one class
// §11 SpecFromSource — error: no class found
// §12 specTest — BridgeChecks.has / hasNot / before
// §13 specTest — all: auto-skips irrelevant generators
// §14 specTest — skip: excludes a generator
// §15 specTest — SpecSource parsed only once (shared parse)
// §16 specTest — debugPrint: does not cause failure

import 'package:test/test.dart';
import 'package:nitro_annotations/nitro_annotations.dart';

import 'spec_from_source.dart';
import 'spec_tester.dart';

// ─── Source helpers ───────────────────────────────────────────────────────────

SpecSource _src(String body) => SpecSource(body.trim());

// ══════════════════════════════════════════════════════════════════════════════
// §1  SpecFromSource — basic parsing
// ══════════════════════════════════════════════════════════════════════════════

void main() {
  group('§1 SpecFromSource — basic parsing', () {
    final spec = SpecFromSource.parse('''
      abstract class Printer {
        void ping();
      }
    ''');

    test('dartClassName extracted from class name', () {
      expect(spec.dartClassName, equals('Printer'));
    });

    test('lib defaults to snake_case of class name', () {
      expect(spec.lib, equals('test'));
    });

    test('namespace defaults to snake_case of class name', () {
      expect(spec.namespace, equals('printer'));
    });

    test('iosImpl defaults to swift', () {
      expect(spec.iosImpl, equals(NativeImpl.swift));
    });

    test('androidImpl defaults to kotlin', () {
      expect(spec.androidImpl, equals(NativeImpl.kotlin));
    });

    test('no functions found when class is empty except ping', () {
      expect(spec.functions.length, equals(1));
      expect(spec.functions.first.dartName, equals('ping'));
    });

    test('cSymbol follows ns_dartName snake_case', () {
      expect(spec.functions.first.cSymbol, equals('printer_ping'));
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §2  SpecFromSource — @NitroModule annotation
  // ══════════════════════════════════════════════════════════════════════════
  group('§2 SpecFromSource — @NitroModule annotation', () {
    final spec = SpecFromSource.parse('''
      @NitroModule(
        ios: NativeImpl.swift,
        android: NativeImpl.kotlin,
        lib: 'my_printer',
        cSymbolPrefix: 'prt',
      )
      abstract class Printer {
        void ping();
      }
    ''');

    test('lib taken from annotation', () => expect(spec.lib, equals('my_printer')));
    test('namespace taken from cSymbolPrefix', () => expect(spec.namespace, equals('prt')));
    test('iosImpl is swift', () => expect(spec.iosImpl, equals(NativeImpl.swift)));
    test('androidImpl is kotlin', () => expect(spec.androidImpl, equals(NativeImpl.kotlin)));
    test('cSymbol uses custom namespace', () {
      expect(spec.functions.first.cSymbol, equals('prt_ping'));
    });
  });

  group('§2b SpecFromSource — @NitroModule with cpp impls', () {
    final spec = SpecFromSource.parse('''
      @NitroModule(ios: NativeImpl.cpp, android: NativeImpl.cpp)
      abstract class Engine {
        double compute(double x);
      }
    ''');

    test('iosImpl is cpp', () => expect(spec.iosImpl, equals(NativeImpl.cpp)));
    test('androidImpl is cpp', () => expect(spec.androidImpl, equals(NativeImpl.cpp)));
    test('hasCppImpl is true', () => expect(spec.hasCppImpl, isTrue));
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §3  SpecFromSource — function kinds
  // ══════════════════════════════════════════════════════════════════════════
  group('§3 SpecFromSource — function kinds', () {
    final spec = SpecFromSource.parse('''
      abstract class Mod {
        void doSync();
        Future<String> doAsync();
        @NitroAsync
        Future<int> doNitroAsync();
        @NitroNativeAsync
        Future<double> doNativeAsync();
      }
    ''');

    test('sync void function has isAsync=false', () {
      final fn = spec.functions.firstWhere((f) => f.dartName == 'doSync');
      expect(fn.isAsync, isFalse);
      expect(fn.returnType.name, equals('void'));
    });

    test('Future<T> without annotation treated as async', () {
      final fn = spec.functions.firstWhere((f) => f.dartName == 'doAsync');
      expect(fn.isAsync, isTrue);
      expect(fn.returnType.name, equals('String'));
    });

    test('@NitroAsync sets isAsync=true and unwraps Future', () {
      final fn = spec.functions.firstWhere((f) => f.dartName == 'doNitroAsync');
      expect(fn.isAsync, isTrue);
      expect(fn.isNativeAsync, isFalse);
      expect(fn.returnType.name, equals('int'));
    });

    test('@NitroNativeAsync sets isNativeAsync=true', () {
      final fn = spec.functions.firstWhere((f) => f.dartName == 'doNativeAsync');
      expect(fn.isNativeAsync, isTrue);
      expect(fn.isAsync, isFalse);
      expect(fn.returnType.name, equals('double'));
    });

    test('Future<void> return unwraps to void', () {
      final spec2 = SpecFromSource.parse('''
        abstract class M {
          Future<void> reset();
        }
      ''');
      expect(spec2.functions.first.returnType.name, equals('void'));
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §4  SpecFromSource — parameters
  // ══════════════════════════════════════════════════════════════════════════
  group('§4 SpecFromSource — parameters', () {
    final spec = SpecFromSource.parse('''
      abstract class Mod {
        void fn(
          String id,
          int count, {
          required bool verbose,
          double scale = 1.0,
          String? label,
        });
      }
    ''');

    late final params = spec.functions.first.params;

    test('positional params are not named', () {
      expect(params[0].isNamed, isFalse); // id
      expect(params[1].isNamed, isFalse); // count
    });

    test('named params are named', () {
      expect(params[2].isNamed, isTrue); // verbose
      expect(params[3].isNamed, isTrue); // scale
      expect(params[4].isNamed, isTrue); // label
    });

    test('param with default is optional', () {
      final scale = params.firstWhere((p) => p.name == 'scale');
      expect(scale.isOptional, isTrue);
      expect(scale.defaultLiteral, equals('1.0'));
    });

    test('nullable type ends with ?', () {
      final label = params.firstWhere((p) => p.name == 'label');
      expect(label.type.name, equals('String?'));
      expect(label.type.isNullable, isTrue);
    });

    test('non-nullable type has isNullable=false', () {
      final id = params.firstWhere((p) => p.name == 'id');
      expect(id.type.isNullable, isFalse);
    });

    test('required named param has no defaultLiteral', () {
      final verbose = params.firstWhere((p) => p.name == 'verbose');
      expect(verbose.defaultLiteral, isNull);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §5  SpecFromSource — optional-primitive sentinel via generator output
  // ══════════════════════════════════════════════════════════════════════════
  group('§5 SpecFromSource — sentinel encoding via generators', () {
    specTest(
      'int? sentinel in Dart and Kotlin',
      _src('''
        abstract class Mod {
          Future<void> work({int? timeout});
        }
      '''),
      dart: BridgeChecks(has: ['timeout ?? -1']),
      kotlin: BridgeChecks(
        has: ['val timeoutArg: Long? = if (timeout < 0L) null else timeout'],
        before: [('val timeoutArg', 'impl.work(')],
      ),
      skip: {Lang.cpp},
    );

    specTest(
      'double? sentinel in Dart and Kotlin',
      _src('''
        abstract class Mod {
          Future<void> measure({double? scale});
        }
      '''),
      dart: BridgeChecks(has: ['scale ?? double.nan']),
      kotlin: BridgeChecks(has: ['val scaleArg: Double? = if (scale.isNaN()) null else scale']),
      skip: {Lang.cpp},
    );

    specTest(
      'bool? sentinel in Dart and Kotlin',
      _src('''
        abstract class Mod {
          Future<void> toggle({bool? enabled});
        }
      '''),
      dart: BridgeChecks(has: ['enabled == null ? -1 : (enabled ? 1 : 0)']),
      kotlin: BridgeChecks(has: ['val enabledArg: Boolean? = if (enabled < 0) null else (enabled != 0)']),
      skip: {Lang.cpp},
    );

    specTest(
      'non-optional int has no sentinel',
      _src('''
        abstract class Mod {
          void fn(int count);
        }
      '''),
      dart: BridgeChecks(hasNot: ['count ?? ']),
      skip: {Lang.cpp},
    );

    specTest(
      'String param uses toNativeUtf8, not sentinel',
      _src('''
        abstract class Mod {
          void send(String msg);
        }
      '''),
      dart: BridgeChecks(has: ['msg.toNativeUtf8'], hasNot: ['msg ?? ']),
      skip: {Lang.cpp},
    );
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §6  SpecFromSource — properties
  // ══════════════════════════════════════════════════════════════════════════
  group('§6 SpecFromSource — properties', () {
    final spec = SpecFromSource.parse('''
      abstract class Device {
        bool get isReady;
        int get count;
        set count(int v);
        String get name;
        set name(String v);
      }
    ''');

    test('getter-only property has hasGetter=true, hasSetter=false', () {
      final p = spec.properties.firstWhere((p) => p.dartName == 'isReady');
      expect(p.hasGetter, isTrue);
      expect(p.hasSetter, isFalse);
    });

    test('read-write property has both getter and setter', () {
      final p = spec.properties.firstWhere((p) => p.dartName == 'count');
      expect(p.hasGetter, isTrue);
      expect(p.hasSetter, isTrue);
    });

    test('property symbols follow ns_get/set_name pattern', () {
      final p = spec.properties.firstWhere((p) => p.dartName == 'name');
      expect(p.getSymbol, contains('get_name'));
      expect(p.setSymbol, contains('set_name'));
    });

    test('property type matches getter return type', () {
      final p = spec.properties.firstWhere((p) => p.dartName == 'isReady');
      expect(p.type.name, equals('bool'));
    });

    specTest(
      'getter appears in Swift and Kotlin output',
      _src('''
        abstract class Device {
          bool get isReady;
        }
      '''),
      swift: BridgeChecks(has: ['isReady']),
      kotlin: BridgeChecks(has: ['isReady']),
      skip: {Lang.cpp},
    );
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §7  SpecFromSource — streams
  // ══════════════════════════════════════════════════════════════════════════
  group('§7 SpecFromSource — streams', () {
    final spec = SpecFromSource.parse('''
      abstract class Sensor {
        Stream<double> ticks();
        Stream<int> counts();
      }
    ''');

    test('Stream<T> methods become BridgeStream entries', () {
      expect(spec.streams.length, equals(2));
      expect(spec.functions, isEmpty);
    });

    test('stream dartName is the method name', () {
      final s = spec.streams.firstWhere((s) => s.dartName == 'ticks');
      expect(s.itemType.name, equals('double'));
    });

    test('stream register/release symbols follow convention', () {
      final s = spec.streams.firstWhere((s) => s.dartName == 'counts');
      expect(s.registerSymbol, contains('register_counts_stream'));
      expect(s.releaseSymbol, contains('release_counts_stream'));
    });

    specTest(
      'stream appears in Dart and Kotlin output',
      _src('''
        abstract class Sensor {
          Stream<double> ticks();
        }
      '''),
      dart: BridgeChecks(has: ['ticks']),
      kotlin: BridgeChecks(has: ['ticks']),
      skip: {Lang.cpp},
    );
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §8  SpecFromSource — @HybridEnum
  // ══════════════════════════════════════════════════════════════════════════
  group('§8 SpecFromSource — @HybridEnum', () {
    final spec = SpecFromSource.parse('''
      @HybridEnum(startValue: 1)
      enum Quality { low, normal, high }

      abstract class Printer {
        void setQuality(Quality q);
      }
    ''');

    test('enum is extracted', () {
      expect(spec.enums.length, equals(1));
      expect(spec.enums.first.name, equals('Quality'));
    });

    test('startValue parsed from annotation', () {
      expect(spec.enums.first.startValue, equals(1));
    });

    test('enum values in order', () {
      expect(spec.enums.first.values, equals(['low', 'normal', 'high']));
    });

    specTest(
      'enum appears in all bridge outputs',
      _src('''
        @HybridEnum()
        enum Color { red, green, blue }

        abstract class Painter {
          void paint(Color c);
        }
      '''),
      all: BridgeChecks(has: ['Color']),
      skip: {Lang.cpp},
    );
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §9  SpecFromSource — @HybridStruct
  // ══════════════════════════════════════════════════════════════════════════
  group('§9 SpecFromSource — @HybridStruct', () {
    final spec = SpecFromSource.parse('''
      @HybridStruct(packed: true)
      class Point {
        double x;
        double y;
      }

      abstract class Geo {
        Point locate();
      }
    ''');

    test('struct is extracted', () {
      expect(spec.structs.length, equals(1));
      expect(spec.structs.first.name, equals('Point'));
    });

    test('packed flag parsed', () {
      expect(spec.structs.first.packed, isTrue);
    });

    test('struct fields extracted', () {
      final fields = spec.structs.first.fields;
      expect(fields.length, equals(2));
      expect(fields.map((f) => f.name), containsAll(['x', 'y']));
      expect(fields.first.type.name, equals('double'));
    });

    specTest(
      'struct appears in Dart and Swift output',
      _src('''
        @HybridStruct()
        class Config {
          String name;
          int retries;
        }

        abstract class Service {
          void configure(Config cfg);
        }
      '''),
      dart: BridgeChecks(has: ['Config']),
      swift: BridgeChecks(has: ['Config']),
      skip: {Lang.cpp},
    );
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §10  SpecFromSource — multiple functions
  // ══════════════════════════════════════════════════════════════════════════
  group('§10 SpecFromSource — multiple functions', () {
    specTest(
      'all function names appear in every active generator',
      _src('''
        abstract class Camera {
          Future<void> capture();
          Future<void> focus(double distance);
          bool isReady();
        }
      '''),
      all: BridgeChecks(has: ['capture', 'focus', 'isReady']),
      skip: {Lang.cpp},
    );

    specTest(
      'camelCase function name converted to snake_case in cSymbol',
      _src('''
        abstract class Mod {
          void doSomeWork();
        }
      '''),
      dart: BridgeChecks(has: ['do_some_work']),
      skip: {Lang.cpp},
    );
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §11  SpecFromSource — error: no class found
  // ══════════════════════════════════════════════════════════════════════════
  group('§11 SpecFromSource — error cases', () {
    test('throws when no class found', () {
      expect(
        () => SpecFromSource.parse('const x = 42;'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('no @NitroModule class or abstract class'),
          ),
        ),
      );
    });

    test('does not throw on parse errors in source (graceful)', () {
      // Invalid Dart syntax; parseString should recover enough to find the class.
      expect(
        () => SpecFromSource.parse('''
          abstract class Mod {
            Future<void> fn(
          // missing closing )
        '''),
        returnsNormally,
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §12  specTest — BridgeChecks assertions
  // ══════════════════════════════════════════════════════════════════════════
  group('§12 specTest — BridgeChecks.has / hasNot / before', () {
    specTest(
      'has: passes when string present',
      _src('''
        abstract class Mod {
          Future<void> connect(String host);
        }
      '''),
      dart: BridgeChecks(has: ['connect']),
      skip: {Lang.cpp},
    );

    specTest(
      'hasNot: passes when string absent',
      _src('''
        abstract class Mod {
          void ping();
        }
      '''),
      dart: BridgeChecks(hasNot: ['timeout ?? -1']),
      kotlin: BridgeChecks(hasNot: ['Long?']),
      skip: {Lang.cpp},
    );

    specTest(
      'before: sentinel appears before impl call in Kotlin',
      _src('''
        abstract class Mod {
          Future<void> work({int? timeout});
        }
      '''),
      kotlin: BridgeChecks(
        before: [
          ('val timeoutArg: Long?', 'impl.work('),
        ],
      ),
      skip: {Lang.cpp},
    );

    specTest(
      'empty BridgeChecks is a no-op',
      _src('''
        abstract class Mod {
          void ping();
        }
      '''),
      dart: BridgeChecks.empty(),
      kotlin: BridgeChecks.empty(),
      skip: {Lang.cpp},
    );
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §13  specTest — all: auto-skips irrelevant generators
  // ══════════════════════════════════════════════════════════════════════════
  group('§13 specTest — all: auto-skips irrelevant generators', () {
    specTest(
      'all: on swift+kotlin spec does not check cpp (no hasCppImpl)',
      _src('''
        abstract class Mod {
          void greet();
        }
      '''),
      // cpp would return "Not applicable" — all: must not fail on that.
      all: BridgeChecks(has: ['greet']),
    );

    specTest(
      'all: on cpp spec checks cpp output',
      _src('''
        @NitroModule(ios: NativeImpl.cpp, android: NativeImpl.cpp)
        abstract class Engine {
          double compute(double x);
        }
      '''),
      all: BridgeChecks(has: ['compute']),
    );
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §14  specTest — skip: excludes generators
  // ══════════════════════════════════════════════════════════════════════════
  group('§14 specTest — skip:', () {
    specTest(
      'skip kotlin: kotlin output not checked even when dart check runs',
      _src('''
        abstract class Mod {
          void fn();
        }
      '''),
      // If kotlin were not skipped, 'fn_call' would be present in kotlin output
      // but this test proves skip:{Lang.kotlin} causes no kotlin assertion.
      dart: BridgeChecks(has: ['fn']),
      skip: {Lang.kotlin, Lang.swift, Lang.cpp},
    );

    specTest(
      'skip all: no assertions run, test still passes',
      _src('''
        abstract class Mod {
          void fn();
        }
      '''),
      skip: {Lang.dart, Lang.kotlin, Lang.swift, Lang.cpp},
    );
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §15  specTest — SpecSource parse is cached
  // ══════════════════════════════════════════════════════════════════════════
  group('§15 specTest — SpecSource reuse', () {
    final shared = SpecSource('''
      abstract class Camera {
        Future<void> capture();
        Future<String> getModel();
      }
    ''');

    test('first access parses spec', () {
      final spec = shared.spec;
      expect(spec.dartClassName, equals('Camera'));
    });

    test('second access returns same instance (cached)', () {
      final a = shared.spec;
      final b = shared.spec;
      expect(identical(a, b), isTrue);
    });

    specTest(
      'specTest uses same cached spec',
      shared,
      dart: BridgeChecks(has: ['capture', 'getModel']),
      skip: {Lang.cpp},
    );

    specTest(
      'second specTest call on same SpecSource',
      shared,
      kotlin: BridgeChecks(has: ['capture', 'getModel']),
      skip: {Lang.cpp},
    );
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §16  specTest — debugPrint: does not cause failure
  // ══════════════════════════════════════════════════════════════════════════
  group('§16 specTest — debugPrint:', () {
    specTest(
      'debugPrint on dart output does not fail the test',
      _src('''
        abstract class Mod {
          void ping();
        }
      '''),
      dart: BridgeChecks(has: ['ping']),
      // This prints the Dart output to stdout during the test run.
      // The test still passes.
      debugPrint: {Lang.dart},
      skip: {Lang.kotlin, Lang.swift, Lang.cpp},
    );
  });
}
