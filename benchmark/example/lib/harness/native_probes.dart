// Web implementations of the harness's platform probes.
//
// The raw-FFI comparison tiers (hand-written dart:ffi lookups, malloc'd
// unsafe buffers) exist to measure what Nitro competes AGAINST on native;
// they have no meaning in a browser, so the probes return null and the
// harness skips those rows. Conditionally imported by bench_harness.dart via:
//   import 'native_probes.dart' if (dart.library.io) 'native_probes_native.dart';
import 'dart:typed_data';

/// 'web' here; Platform.operatingSystem on native.
const String harnessOperatingSystem = 'web';

/// Raw dart:ffi FNV-1a probe — native-only comparison tier.
int Function()? rawFfiHashProbe(Uint8List workload, int rounds) => null;

/// Raw dart:ffi add(double,double) probe — native-only comparison tier.
double Function(double, double)? rawAddProbe() => null;

/// Raw dart:ffi sieve probe — native-only comparison tier.
int Function(int)? rawSieveProbe() => null;

/// Raw dart:ffi buffer-copy probe — native-only comparison tier.
int Function()? rawBufferSendProbe(Uint8List buffer) => null;

/// A malloc'd scratch buffer for the unsafe-pointer tier — native-only.
({Object ptr, void Function() free})? allocUnsafeBuffer(int bytes) => null;

/// What Dart alone can see of the host.
///
/// `compiler` matters on web: dart2js and dart2wasm produce materially
/// different numbers for the same build, so an archived report is ambiguous
/// without it. On dart2js every int is a double, so `1` and `1.0` are the same
/// object; on dart2wasm they are distinct — that is the cheapest reliable
/// discriminator available at runtime.
Map<String, Object?> hostDeviceInfo() => {
  'os': 'web',
  'compiler': identical(1, 1.0) ? 'dart2js' : 'dart2wasm',
};
