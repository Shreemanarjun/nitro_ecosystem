// Anti-drift tripwire for the conditional-export pairs: the web NitroRuntime
// must expose the same public static API as the native one (plus an explicit,
// documented allowlist of platform-specific members). Before 0.7.0 the web
// stub had silently drifted — wrong signatures, missing members — which this
// scan would have caught.
//
// Source-scan rather than analyzer-based on purpose: both files must be
// readable in one (VM) test run, and only NAME/staticness parity is needed —
// parameter types legitimately differ (Pointer vs WebNitroErrorSlot).
import 'dart:io';

import 'package:test/test.dart';

Set<String> _publicStaticMembers(String source) {
  // Strip comments so doc examples don't count.
  final noComments = source.replaceAll(RegExp(r'///.*|//.*'), '');
  // Type part is lazy; the member name may carry its own generic list
  // (`dispatch<T>(`), which the optional `<...>` group absorbs.
  final re = RegExp(
    r'^\s+static\s+(?:const\s+|final\s+|late\s+)?[\w<>,?\s]+?\b(\w+)\s*(?:<[^>]*>)?\s*(?:\(|=|;)',
    multiLine: true,
  );
  return re.allMatches(noComments).map((m) => m.group(1)!).where((name) => !name.startsWith('_')).toSet();
}

void main() {
  test('web NitroRuntime keeps static-API parity with the native runtime', () {
    final nativeSrc = File('lib/src/nitro_runtime.dart').readAsStringSync();
    final webSrc = File('lib/src/web/nitro_runtime_web.dart').readAsStringSync();

    final native = _publicStaticMembers(nativeSrc);
    final web = _publicStaticMembers(webSrc);

    // Sanity: the scan actually found the core API.
    for (final expected in ['callSync', 'callAsync', 'openNativeAsync', 'openStream', 'loadLib', 'releaseLib', 'checkAbiVersion', 'checkLinkChecksum', 'init', 'dispose', 'expectedAbiVersion', 'useNativeBindings', 'deferredClose', 'logLifecycle', 'checkError', 'loadLibForTargets', 'checkSupportedPlatform']) {
      expect(native, contains(expected), reason: 'scan regression: native runtime should declare $expected');
    }

    // Web-only additions (module loading is async on the web; callbacks live
    // in the module function table).
    // `retainLib` is web-only by nature: native's loadLib both opens the
    // library AND takes the per-instance reference in one step, so there is
    // nothing to port. Web splits them — the module loads asynchronously in
    // ensure<Class>Ready(), long before any instance exists — so the bridge
    // constructor needs a separate way to take its reference.
    const webOnly = {'loadWebModule', 'webModule', 'deferredCloseWebFunction', 'retainLib'};

    final missingOnWeb = native.difference(web);
    expect(
      missingOnWeb,
      isEmpty,
      reason: 'web NitroRuntime is missing native members — add them to '
          'lib/src/web/nitro_runtime_web.dart (or to the allowlist here with '
          'a reason): $missingOnWeb',
    );

    final extraOnWeb = web.difference(native).difference(webOnly);
    expect(
      extraOnWeb,
      isEmpty,
      reason: 'web NitroRuntime grew members the native runtime lacks — port '
          'them to native or add to the webOnly allowlist: $extraOnWeb',
    );
  });

  test('web IsolatePool keeps create/dispatch/dispose parity', () {
    final web = _publicStaticMembers(File('lib/src/web/isolate_pool_web.dart').readAsStringSync());
    expect(web, contains('create'));
    final webSrc = File('lib/src/web/isolate_pool_web.dart').readAsStringSync();
    expect(webSrc, contains('Future<T> dispatch<T>'));
    expect(webSrc, contains('void dispose()'));
  });

  test('web NitroCoalescer keeps the native member surface', () {
    final nativeSrc = File('lib/src/nitro_coalescer.dart').readAsStringSync();
    final webSrc = File('lib/src/web/nitro_coalescer_web.dart').readAsStringSync();
    for (final member in ['nativePort', 'sendPort', 'pendingCount', 'submit', 'dispose']) {
      expect(nativeSrc, contains(member));
      expect(webSrc, contains(member), reason: 'web coalescer must expose $member');
    }
  });
}
