// Native implementation of the NitroRuntime startup sequence.
// Loaded when dart.library.io is present (all non-web platforms).

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:nitro/nitro.dart';

String? startupError;

Future<void> initNitroRuntime() async {
  NitroConfig.instance.isolatePoolSize = Platform.numberOfProcessors;
  try {
    await NitroRuntime.init();
  } catch (e) {
    // IsolatePool.create() can fail on some devices — retry with pool disabled.
    debugPrint(
      '[NitroBenchmark] NitroRuntime.init() failed: $e. Retrying with isolatePoolSize=0.',
    );
    NitroConfig.instance.isolatePoolSize = 0;
    try {
      await NitroRuntime.init();
    } catch (e2) {
      debugPrint(
        '[NitroBenchmark] NitroRuntime.init() failed again: $e2. Running without runtime.',
      );
      startupError = e2.toString();
    }
  }
}
