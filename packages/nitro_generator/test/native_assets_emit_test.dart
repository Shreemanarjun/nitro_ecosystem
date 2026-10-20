// Perf lever 1 (opt-in `native_assets: true`): an all-C++ scalar module emits
// its Dart FFI impl using top-level `@Native` externals bound to the
// hook-built code asset, instead of `DynamicLibrary` + `lookupFunction`. This
// is the only form that resolves on Android (RTLD_LOCAL hides the symbols from
// `lookupFunction`). Call sites are unchanged — the bodies still call
// `_fooPtr(...)`, now a top-level @Native function of the same name.
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:test/test.dart';

import 'spec_from_source.dart';

const _scalarCpp = '''
import 'package:nitro_annotations/nitro_annotations.dart';
part 'calc.g.dart';
@NitroModule(ios: NativeImpl.cpp, android: NativeImpl.cpp, macos: NativeImpl.cpp)
abstract class Calc extends HybridObject {
  int add(int a, int b);
  double scale(double v);
  bool toggle(bool b);
  int get counter;
  set counter(int v);
}
''';

// Eligible: String params/returns are supported (body-local arena + the
// emitted alloc/free externals cover UTF-8 marshalling and native-owned frees).
const _stringCpp = '''
import 'package:nitro_annotations/nitro_annotations.dart';
part 'greet.g.dart';
@NitroModule(ios: NativeImpl.cpp, android: NativeImpl.cpp)
abstract class Greet extends HybridObject {
  int lengthOf(String s);
  String greet(String name);
  String? maybe(String? s);
}
''';

// Eligible: native-async (@nitroNativeAsync incl. fire-and-forget) routes
// through the emitted completion-batch externals + DL-API init.
const _asyncCpp = '''
import 'package:nitro_annotations/nitro_annotations.dart';
part 'aw.g.dart';
@NitroModule(ios: NativeImpl.cpp, android: NativeImpl.cpp)
abstract class Aw extends HybridObject {
  @nitroNativeAsync
  Future<int> fetch(int id);
  @nitroNativeAsync
  void push(int x); // fire-and-forget (void)
}
''';

// Eligible: @HybridRecord params/returns (binary-blob codec, no _dylib). The
// NativeFinalizer-based list path needs the _nitroFreeFinalizer raw pointer
// (Native.addressOf of the @Native free external).
const _recordCpp = '''
import 'package:nitro_annotations/nitro_annotations.dart';
part 'rec.g.dart';
@HybridRecord
class Pair {
  final int a;
  final int b;
  const Pair({required this.a, required this.b});
}
@NitroModule(ios: NativeImpl.cpp, android: NativeImpl.cpp)
abstract class Rec extends HybridObject {
  Pair swap(Pair p);
  Pair make(int a, int b);
}
''';

// Eligible: @HybridStruct (zero-copy proxy). The release symbol binds via
// Native.addressOf of a top-level @Native external — no DynamicLibrary.
const _structCpp = '''
import 'package:nitro_annotations/nitro_annotations.dart';
part 'pt.g.dart';
@HybridStruct(packed: true)
class Point {
  final double x;
  final double y;
  const Point({required this.x, required this.y});
}
@NitroModule(ios: NativeImpl.cpp, android: NativeImpl.cpp)
abstract class Pt extends HybridObject {
  Point scale(Point p, double f);
}
''';

// Eligible: a callback (function-type) param → NativeCallable (runtime, no
// _dylib). The cache + dispose-close + helpers are emitted on the @Native path.
const _callbackCpp = '''
import 'package:nitro_annotations/nitro_annotations.dart';
part 'cb.g.dart';
@NitroModule(ios: NativeImpl.cpp, android: NativeImpl.cpp)
abstract class Cb extends HybridObject {
  void onTick(void Function(int tick) cb);
}
''';

// Eligible: a Stream<scalar> — coalesced register/release externals + ack +
// DL-API init, no _dylib (struct-item streams are excluded for now).
const _streamCpp = '''
import 'dart:async';
import 'package:nitro_annotations/nitro_annotations.dart';
part 'ev.g.dart';
@NitroModule(ios: NativeImpl.cpp, android: NativeImpl.cpp)
abstract class Ev extends HybridObject {
  Stream<int> get ticks;
}
''';

// Eligible: a plain isolate-pool @nitroAsync (the timeout forces the pool path,
// not native dispatch) — uses callAsync + the get/clear error native pointers.
const _callAsyncCpp = '''
import 'dart:async';
import 'package:nitro_annotations/nitro_annotations.dart';
part 'pool.g.dart';
@NitroModule(ios: NativeImpl.cpp, android: NativeImpl.cpp)
abstract class Pool extends HybridObject {
  @NitroAsync(timeout: 1000)
  Future<int> slowAdd(int a, int b);
}
''';

// NOTE: @NitroResult eligibility (inner-type check when f.isResult) is wired in
// _nativeAssetsEligible and its decode (_emitResultDecode) uses only RecordReader
// + _nitroFree (no _dylib) — but SpecFromSource doesn't set isResult from the
// bare annotation, so it can't be unit-exercised here (needs real build_runner,
// like List<record>). The guard safely falls back when isResult is unset.

// Not eligible: Swift/Kotlin bridges aren't compiled by CBuilder, so the flag
// must be ignored for a non-all-C++ module.
const _swiftKotlin = '''
import 'package:nitro_annotations/nitro_annotations.dart';
part 'sk.g.dart';
@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class Sk extends HybridObject {
  int add(int a, int b);
}
''';

void main() {
  group('native-assets @Native emit (scalar all-C++, opt-in)', () {
    final spec = SpecFromSource.parse(_scalarCpp, sourceUri: 'package:calc/src/calc.native.dart')
      ..assetPackage = 'calc'
      ..nativeAssets = true;
    final out = DartFfiGenerator.generate(spec);

    test('emits top-level @Native externals bound to the code asset — no DynamicLibrary', () {
      expect(out, contains('@Native<'));
      expect(out, contains("assetId: 'package:calc/calc'"));
      // the core module symbols as @Native externals
      expect(out, contains("symbol: 'calc_create_instance'"));
      expect(out, contains('external int _createInstancePtr(Pointer<Utf8> _key);'));
      expect(out, contains('external void _destroyInstancePtr(int _id);'));
      // no runtime library loading on the native-assets path
      expect(out, isNot(contains('_dylib')));
      expect(out, isNot(contains('.lookupFunction')));
      expect(out, isNot(contains('DynamicLibrary')));
      expect(out, isNot(contains('_loadSupportedLibrary')));
    });

    test('each method/property becomes a same-named external the bodies still call', () {
      expect(out, contains('external int _addPtr('));
      expect(out, contains('external double _scalePtr('));
      expect(out, contains('external bool _togglePtr('));
      expect(out, contains('external int _getCounterPtr(int _id, Pointer<NitroErrorFfi> _err);'));
      expect(out, contains('external void _setCounterPtr(int _id, int _v, Pointer<NitroErrorFfi> _err);'));
      // the call sites (method bodies) are unchanged and reference those names
      expect(out, contains('_addPtr('));
      expect(out, contains('_getCounterPtr('));
    });

    test('every _xxxPtr the bodies call has a matching external declaration', () {
      final declared = RegExp(r'external [^;]*?\b(_\w+Ptr)\(')
          .allMatches(out)
          .map((m) => m.group(1)!)
          .toSet();
      final called = RegExp(r'\b(_\w+Ptr)\(')
          .allMatches(out)
          .map((m) => m.group(1)!)
          .toSet();
      final undeclared = called.difference(declared);
      expect(undeclared, isEmpty, reason: 'these are called but never declared as @Native: $undeclared');
    });

    test('impl class braces are balanced (setup leaves it open, stream emitter closes it)', () {
      final opens = '{'.allMatches(out).length;
      final closes = '}'.allMatches(out).length;
      expect(opens, closes, reason: 'unbalanced braces → malformed class');
    });

    test('hot scalar methods keep isLeaf on the @Native binding', () {
      // add(int,int)->int is a pure scalar leaf candidate; symbol + isLeaf are
      // on one @Native line (generate() output is unformatted).
      expect(out, matches(RegExp(r"symbol: 'calc_add'[^\n]*isLeaf: true")));
    });
  });

  group('native-assets @Native emit (String params/returns)', () {
    final spec = SpecFromSource.parse(_stringCpp, sourceUri: 'package:greet/src/greet.native.dart')
      ..assetPackage = 'greet'
      ..nativeAssets = true;
    final out = DartFfiGenerator.generate(spec);

    test('String methods bind via @Native with the alloc/free externals present', () {
      expect(out, contains('@Native<'));
      expect(out, isNot(contains('_dylib')));
      // string marshalling + native-owned return free come from these:
      expect(out, contains("symbol: 'greet_nitro_alloc'"));
      expect(out, contains("symbol: 'greet_nitro_free'"));
      expect(out, contains('external int _lengthOfPtr('));
      expect(out, contains('external Pointer<Utf8> _greetPtr('));
    });

    test('every _xxxPtr called has a matching external (strings included)', () {
      final declared = RegExp(r'external [^;]*?\b(_\w+Ptr)\(').allMatches(out).map((m) => m.group(1)!).toSet();
      final called = RegExp(r'\b(_\w+Ptr)\(').allMatches(out).map((m) => m.group(1)!).toSet();
      expect(called.difference(declared), isEmpty, reason: 'undeclared @Native: ${called.difference(declared)}');
    });

    test('braces balanced', () {
      expect('{'.allMatches(out).length, '}'.allMatches(out).length);
    });
  });

  group('native-assets @Native emit (native-async + fire-and-forget)', () {
    final spec = SpecFromSource.parse(_asyncCpp, sourceUri: 'package:aw/src/aw.native.dart')
      ..assetPackage = 'aw'
      ..nativeAssets = true;
    final out = DartFfiGenerator.generate(spec);

    test('emits the completion-batch + DL-API externals and the batch field', () {
      expect(out, contains('@Native<'));
      expect(out, isNot(contains('_dylib')));
      for (final s in ['aw_init_dart_api_dl', 'aw_nitro_bind', 'aw_nitro_ack', 'aw_nitro_arm', 'aw_nitro_disarm', 'aw_nitro_poll']) {
        expect(out, contains("symbol: '$s'"), reason: 'missing external for $s');
      }
      expect(out, contains('NitroCompletionBatch(bind: _nitroBindPtr'));
      expect(out, contains('_initDartApiDlPtr(NativeApi.initializeApiDLData)'));
    });

    test('fetch posts via batch; push is fire-and-forget (its _fnf symbol)', () {
      expect(out, contains('batch: _nitroBatch'));
      expect(out, contains("symbol: 'aw_push_fnf'"));
    });

    test('every _xxxPtr called has a matching external', () {
      final declared = RegExp(r'external [^;]*?\b(_\w+Ptr)\(').allMatches(out).map((m) => m.group(1)!).toSet();
      final called = RegExp(r'\b(_\w+Ptr)\(').allMatches(out).map((m) => m.group(1)!).toSet();
      expect(called.difference(declared), isEmpty, reason: 'undeclared @Native: ${called.difference(declared)}');
    });

    test('braces balanced', () {
      expect('{'.allMatches(out).length, '}'.allMatches(out).length);
    });
  });

  group('native-assets @Native emit (@HybridRecord params/returns)', () {
    final spec = SpecFromSource.parse(_recordCpp, sourceUri: 'package:rec/src/rec.native.dart')
      ..assetPackage = 'rec'
      ..nativeAssets = true;
    final out = DartFfiGenerator.generate(spec);

    test('record methods bind via @Native; free + raw-finalizer externals present', () {
      expect(out, contains('@Native<'));
      expect(out, isNot(contains('_dylib')));
      // record return is a tagged Pointer<Uint8> blob; param is a Pointer<Uint8>
      expect(out, contains('_swapPtr('));
      expect(out, contains('_makePtr('));
      // raw free pointer via Native.addressOf (NativeFinalizer owners / lists)
      expect(out, contains('Native.addressOf<NativeFunction<Void Function(Pointer<Void>)>>(_nitroFreePtr)'));
    });

    test('every _xxxPtr called has a matching external', () {
      final declared = RegExp(r'external [^;]*?\b(_\w+Ptr)\(').allMatches(out).map((m) => m.group(1)!).toSet();
      final called = RegExp(r'\b(_\w+Ptr)\(').allMatches(out).map((m) => m.group(1)!).toSet();
      expect(called.difference(declared), isEmpty, reason: 'undeclared @Native: ${called.difference(declared)}');
    });

    test('braces balanced', () {
      expect('{'.allMatches(out).length, '}'.allMatches(out).length);
    });
  });

  group('native-assets @Native emit (@HybridStruct zero-copy proxy)', () {
    final spec = SpecFromSource.parse(_structCpp, sourceUri: 'package:pt/src/pt.native.dart')
      ..assetPackage = 'pt'
      ..nativeAssets = true;
    final out = DartFfiGenerator.generate(spec);

    test('struct method binds via @Native; proxy release binds via Native.addressOf', () {
      expect(out, contains('@Native<'));
      expect(out, isNot(contains('_dylib')));
      // the proxy release symbol as a top-level @Native external + addressOf bind
      expect(out, contains("symbol: 'pt_release_Point'"));
      expect(out, contains('Native.addressOf<NativeFunction<Void Function(Pointer<Void>)>>(_pt_release_PointPtr)'));
      // _init() is parameterless (no DynamicLibrary) and called in the ctor
      expect(out, contains('PointProxy._init();'));
      expect(out, contains('_scalePtr('));
    });

    test('every _xxxPtr called has a matching external', () {
      final declared = RegExp(r'external [^;]*?\b(_\w+Ptr)\(').allMatches(out).map((m) => m.group(1)!).toSet();
      final called = RegExp(r'\b(_\w+Ptr)\(').allMatches(out).map((m) => m.group(1)!).toSet();
      expect(called.difference(declared), isEmpty, reason: 'undeclared @Native: ${called.difference(declared)}');
    });

    test('braces balanced', () {
      expect('{'.allMatches(out).length, '}'.allMatches(out).length);
    });
  });

  group('native-assets @Native emit (callback params → NativeCallable)', () {
    final spec = SpecFromSource.parse(_callbackCpp, sourceUri: 'package:cb/src/cb.native.dart')
      ..assetPackage = 'cb'
      ..nativeAssets = true;
    final out = DartFfiGenerator.generate(spec);

    test('callback method binds via @Native; NativeCallable cache + helpers emitted', () {
      expect(out, contains('@Native<'));
      expect(out, isNot(contains('_dylib')));
      expect(out, contains('_nativeCallbackCache'));
      expect(out, contains('NativeCallable<'));
      expect(out, contains('_onTickPtr('));
    });

    test('dispose closes the NativeCallables', () {
      expect(out, contains('callback.close();'));
      expect(out, contains('_nativeCallbackCache.clear();'));
    });

    test('every _xxxPtr called has a matching external', () {
      final declared = RegExp(r'external [^;]*?\b(_\w+Ptr)\(').allMatches(out).map((m) => m.group(1)!).toSet();
      final called = RegExp(r'\b(_\w+Ptr)\(').allMatches(out).map((m) => m.group(1)!).toSet();
      expect(called.difference(declared), isEmpty, reason: 'undeclared @Native: ${called.difference(declared)}');
    });

    test('braces balanced', () {
      expect('{'.allMatches(out).length, '}'.allMatches(out).length);
    });
  });

  group('native-assets @Native emit (Stream<scalar> coalesced)', () {
    final spec = SpecFromSource.parse(_streamCpp, sourceUri: 'package:ev/src/ev.native.dart')
      ..assetPackage = 'ev'
      ..nativeAssets = true;
    final out = DartFfiGenerator.generate(spec);

    test('stream register/release + ack + DL-init externals; no _dylib', () {
      expect(out, contains('@Native<'));
      expect(out, isNot(contains('_dylib')));
      expect(out, contains("symbol: 'ev_register_ticks_stream'"));
      expect(out, contains("symbol: 'ev_release_ticks_stream'"));
      expect(out, contains("symbol: 'ev_nitro_ack'"));
      expect(out, contains("symbol: 'ev_init_dart_api_dl'"));
      expect(out, contains('_registerTicksPtr(_instanceId'));
      expect(out, contains('ack: _nitroAckPtr'));
    });

    test('every _xxxPtr called has a matching external', () {
      final declared = RegExp(r'external [^;]*?\b(_\w+Ptr)\(').allMatches(out).map((m) => m.group(1)!).toSet();
      final called = RegExp(r'\b(_\w+Ptr)\(').allMatches(out).map((m) => m.group(1)!).toSet();
      expect(called.difference(declared), isEmpty, reason: 'undeclared @Native: ${called.difference(declared)}');
    });

    test('braces balanced', () {
      expect('{'.allMatches(out).length, '}'.allMatches(out).length);
    });
  });

  group('native-assets @Native emit (isolate-pool @nitroAsync / callAsync)', () {
    final spec = SpecFromSource.parse(_callAsyncCpp, sourceUri: 'package:pool/src/pool.native.dart')
      ..assetPackage = 'pool'
      ..nativeAssets = true;
    final out = DartFfiGenerator.generate(spec);

    test('callAsync path: get/clear error externals + Native.addressOf pointers', () {
      expect(out, contains('@Native<'));
      expect(out, isNot(contains('_dylib')));
      expect(out, contains("symbol: 'pool_get_error'"));
      expect(out, contains("symbol: 'pool_clear_error'"));
      expect(out, contains('Native.addressOf<NativeFunction<Pointer<NitroErrorFfi> Function()>>(_getErrorPtr)'));
      expect(out, contains('NitroRuntime.callAsync<'));
    });

    test('every _xxxPtr called has a matching external (getErrorPtr included)', () {
      final declared = RegExp(r'external [^;]*?\b(_\w+Ptr)\(').allMatches(out).map((m) => m.group(1)!).toSet();
      final called = RegExp(r'\b(_\w+Ptr)\(').allMatches(out).map((m) => m.group(1)!).toSet();
      expect(called.difference(declared), isEmpty, reason: 'undeclared @Native: ${called.difference(declared)}');
    });

    test('braces balanced', () {
      expect('{'.allMatches(out).length, '}'.allMatches(out).length);
    });
  });

  group('eligibility guard falls back to the _dylib path', () {
    test('flag OFF → _dylib + lookupFunction, no @Native', () {
      final spec = SpecFromSource.parse(_scalarCpp, sourceUri: 'package:calc/src/calc.native.dart')
        ..assetPackage = 'calc';
      // nativeAssets defaults false
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('_dylib'));
      expect(out, isNot(contains('@Native<')));
    });

    test('Swift/Kotlin module (not all-C++) → flag ignored', () {
      final spec = SpecFromSource.parse(_swiftKotlin, sourceUri: 'package:sk/src/sk.native.dart')
        ..assetPackage = 'sk'
        ..nativeAssets = true;
      expect(spec.useNativeAssets, isFalse);
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('_dylib'));
      expect(out, isNot(contains('@Native<')));
    });
  });
}
