// Per-call overhead of a generated `...Fast` method vs a hand-rolled
// `isLeaf: true` dart:ffi binding of the SAME C symbol (issue #51).
// Run (AOT numbers need profile mode):
//   flutter drive --profile -d macos --driver=test_driver/integration_test.dart \
//     --target=integration_test/fast_path_bench_test.dart
import 'package:benchmark/benchmark.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nitro/nitro.dart';

typedef _AddFastC = Double Function(Int64, Double, Double, Pointer<NitroErrorFfi>);
typedef _AddFastDart = double Function(int, double, double, Pointer<NitroErrorFfi>);
late final void Function(Pointer<Void>) _nitroFreeRaw;
void _nitroFree(Pointer<NativeType> p) => _nitroFreeRaw(p.cast());

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('generated addFast vs hand-rolled leaf FFI', () {
    final lib = NitroRuntime.loadLibForTargets('benchmark', ios: true, android: true, macos: true, windows: true, linux: true, web: false);
    final create = lib.lookupFunction<Int64 Function(Pointer<Utf8>), int Function(Pointer<Utf8>)>('benchmark_create_instance');
    final addFast = lib.lookupFunction<_AddFastC, _AddFastDart>('benchmark_add_fast', isLeaf: true);
    final key = 'bench-hand'.toNativeUtf8();
    final id = create(key);
    final err = calloc<NitroErrorFfi>();
    final gen = Benchmark.instance;

    const n = 2000000;
    double sink = 0;
    double nsPerCall(void Function() body) {
      body(); // warm-up
      final sw = Stopwatch()..start();
      body();
      return sw.elapsedMicroseconds * 1000 / n;
    }

    final hand = nsPerCall(() {
      for (var i = 0; i < n; i++) {
        sink += addFast(id, 1.5, 2.5, err);
      }
    });
    // The shape every generated sync method had before #51: the call inside a
    // callSync closure (captures id/err, escapes → allocated per call).
    final closure = nsPerCall(() {
      for (var i = 0; i < n; i++) {
        sink += NitroRuntime.callSync(() {
          final res = addFast(id, 1.5, 2.5, err);
          return res;
        }, methodName: 'addFast');
      }
    });
    final generated = nsPerCall(() {
      for (var i = 0; i < n; i++) {
        sink += gen.addFast(1.5, 2.5);
      }
    });
    _nitroFreeRaw = lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('benchmark_nitro_free');
    final handChecked = nsPerCall(() {
      for (var i = 0; i < n; i++) {
        final res = addFast(id, 1.5, 2.5, err);
        NitroRuntime.throwIfOutParamError(err, nativeFree: _nitroFree, methodName: 'add');
        sink += res;
      }
    });
    final handTimed = nsPerCall(() {
      for (var i = 0; i < n; i++) {
        final t0 = NitroRuntime.syncStart('add');
        try {
          sink += addFast(id, 1.5, 2.5, err);
        } finally {
          NitroRuntime.syncEnd(t0, 'add');
        }
      }
    });
    final handBoth = nsPerCall(() {
      for (var i = 0; i < n; i++) {
        final t0 = NitroRuntime.syncStart('add');
        try {
          final res = addFast(id, 1.5, 2.5, err);
          NitroRuntime.throwIfOutParamError(err, nativeFree: _nitroFree, methodName: 'add');
          sink += res;
        } finally {
          NitroRuntime.syncEnd(t0, 'add');
        }
      }
    });
    final generatedChecked = nsPerCall(() {
      for (var i = 0; i < n; i++) {
        sink += gen.add(1.5, 2.5);
      }
    });
    // ignore: avoid_print
    print('CHECKED hand leaf+errcheck: ${handChecked.toStringAsFixed(1)} | hand leaf+syncStart/End: ${handTimed.toStringAsFixed(1)} | hand both: ${handBoth.toStringAsFixed(1)} | generated add (checked): ${generatedChecked.toStringAsFixed(1)} ns/call');
    calloc.free(err);
    malloc.free(key);
    expect(sink, greaterThan(0));
    // ignore: avoid_print
    print('FASTPATH hand-rolled isLeaf: ${hand.toStringAsFixed(1)} ns/call | callSync-closure (old shape): ${closure.toStringAsFixed(1)} ns/call | generated addFast (now): ${generated.toStringAsFixed(1)} ns/call');
  });
}
