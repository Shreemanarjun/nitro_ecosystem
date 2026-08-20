// Native implementations of the harness's platform probes: the hand-written
// dart:ffi comparison tiers Nitro is benchmarked against, plus host identity.
// See native_probes.dart (the web twin) for the conditional-import wiring.
import 'dart:io' show Platform;

import 'package:nitro/nitro.dart';

String get harnessOperatingSystem => Platform.operatingSystem;

/// Raw FFI floor for add(double,double) — resolved explicitly so a failed
/// lookup is a hard error, never a silent fall-back to pure Dart.
double Function(double, double)? rawAddProbe() => NitroRuntime.loadLib('benchmark_cpp')
    .lookupFunction<
      Double Function(Double, Double),
      double Function(double, double)
    >('add_double', isLeaf: true);

/// Raw FFI sieve probe.
int Function(int)? rawSieveProbe() => NitroRuntime.loadLib('benchmark_cpp')
    .lookupFunction<Int64 Function(Int64), int Function(int)>('sieve_primes');

/// Raw dart:ffi FNV-1a probe: manual lookupFunction + arena copy per call —
/// the "vanilla FFI" tier every Nitro row is compared to.
int Function()? rawFfiHashProbe(Uint8List workload, int rounds) {
  final rawFnv = NitroRuntime.loadLib('benchmark_cpp')
      .lookupFunction<
        Uint64 Function(Pointer<Uint8>, Int64, Int64),
        int Function(Pointer<Uint8>, int, int)
      >('fnv1a_hash');
  return () => withArena(
    (arena) => rawFnv(workload.toPointer(arena), workload.length, rounds),
  );
}

/// Raw dart:ffi buffer-send probe: the manual copy is the real cost of
/// hand-written FFI here — Nitro's pinned path skips it entirely.
int Function()? rawBufferSendProbe(Uint8List buffer) {
  final rawSendNoop = NitroRuntime.loadLib('benchmark_cpp')
      .lookupFunction<
        Int64 Function(Pointer<Uint8>, Int64),
        int Function(Pointer<Uint8>, int)
      >('send_large_buffer_noop');
  return () => withArena(
    (arena) => rawSendNoop(buffer.toPointer(arena), buffer.length),
  );
}

/// A malloc'd scratch buffer for the unsafe-pointer tier.
({Object ptr, void Function() free})? allocUnsafeBuffer(int bytes) {
  final ptr = malloc<Uint8>(bytes);
  return (ptr: ptr, free: () => malloc.free(ptr));
}

Map<String, Object?> hostDeviceInfo() => {
  'os': '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
  'hostname': Platform.localHostname,
};
