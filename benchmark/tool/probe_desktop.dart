// Standalone desktop diagnostic for the Nitro module libraries.
//
// Exercises each bundled module .so/.dll step by step with a print before
// every native call, so a segfault in CI pinpoints the exact failing call
// without needing a debugger on the runner.
//
// Zero package dependencies (dart:ffi + dart:io only) so it can be executed
// directly against a built bundle:
//
//   dart benchmark/tool/probe_desktop.dart \
//       benchmark/example/build/linux/x64/profile/bundle/lib
//
//   dart benchmark/tool/probe_desktop.dart \
//       benchmark/example/build/windows/x64/runner/Profile
import 'dart:ffi';
import 'dart:io';

void step(String s) {
  stdout.writeln('PROBE: $s');
  // Flush eagerly — if the next native call segfaults, this line must
  // already be on the wire.
}

void main(List<String> args) {
  final dir = args.isEmpty ? '.' : args[0];

  for (final name in ['benchmark', 'benchmark_cpp', 'nitro_ar']) {
    final path = Platform.isWindows
        ? '$dir${Platform.pathSeparator}$name.dll'
        : '$dir${Platform.pathSeparator}lib$name.so';
    if (!File(path).existsSync()) {
      step('$path MISSING — bundled_libraries did not deliver it');
      continue;
    }
    step('open $path');
    final lib = DynamicLibrary.open(path);

    step('  ${name}_init_dart_api_dl');
    final init = lib
        .lookupFunction<
          IntPtr Function(Pointer<Void>),
          int Function(Pointer<Void>)
        >('${name}_init_dart_api_dl');
    step('  init → ${init(NativeApi.initializeApiDLData)}');

    step('  ${name}_nitro_abi_version');
    final abi = lib.lookupFunction<Uint32 Function(), int Function()>(
      '${name}_nitro_abi_version',
    );
    step('  abi → ${abi()}');

    if (!lib.providesSymbol('${name}_create_instance')) {
      step('  ${name}_create_instance NOT EXPORTED');
      continue;
    }
    step('  ${name}_create_instance(null)');
    final create = lib
        .lookupFunction<
          Int64 Function(Pointer<Void>),
          int Function(Pointer<Void>)
        >('${name}_create_instance');
    final id = create(Pointer.fromAddress(0));
    step('  instanceId → $id');

    // add(): present on benchmark and benchmark_cpp. The desktop bridge
    // null-guards (or ignores) the NitroError out-param, so passing nullptr
    // is safe here.
    final addSym = '${name}_add';
    if (lib.providesSymbol(addSym)) {
      step('  $addSym(2, 3)');
      final add = lib
          .lookupFunction<
            Double Function(Int64, Double, Double, Pointer<Void>),
            double Function(int, double, double, Pointer<Void>)
          >(addSym);
      final v = add(id, 2.0, 3.0, Pointer.fromAddress(0));
      step(
        '  $addSym → $v ${v == 5.0 ? "OK" : "WRONG (impl not registered?)"}',
      );
      // Call it in a tight loop — some crashes only appear after warm-up.
      step('  $addSym ×1000 loop');
      var acc = 0.0;
      for (var i = 0; i < 1000; i++) {
        acc += add(id, 1.0, i.toDouble(), Pointer.fromAddress(0));
      }
      step('  loop done (acc=$acc)');
    }
  }
  step('ALL OK');
}
