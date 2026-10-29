// Native implementation of the NitroRuntime startup sequence.
// Loaded when dart.library.io is present (all non-web platforms).

import 'package:flutter/foundation.dart';
import 'package:nitro/nitro.dart';

String? startupError;

Future<void> initNitroRuntime() async {
  // The @nitroAsync pool is automatic and adaptive — it sizes itself to the
  // CPU and grows under concurrent load, so there is nothing to configure.
  try {
    await NitroRuntime.init();
  } catch (e) {
    // IsolatePool spawn can fail on some devices; callAsync then falls back to
    // a fresh isolate per call (the pool simply isn't warmed).
    debugPrint('[NitroBenchmark] NitroRuntime.init() failed: $e. Continuing without a warmed pool.');
    startupError = e.toString();
  }
}
