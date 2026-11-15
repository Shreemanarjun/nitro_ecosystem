// CocoaPods podspec snippet templates for `nitrogen init` and `nitrogen link`.
library;

import 'build_versions.dart';

// The nitro runtime headers are read from the plugin's own copy in
// `src/native/`, which `nitrogen link` keeps up to date. `nitro` is not a
// Flutter plugin, so CocoaPods has no pod and no `.symlinks/plugins/nitro` for
// it; the same path therefore serves iOS and macOS.
const _podHeaderSearchPaths =
    '\$(inherited) "\${PODS_TARGET_SRCROOT}/../src/native" "\${PODS_TARGET_SRCROOT}/../src" "\${PODS_TARGET_SRCROOT}/../lib/src/generated/cpp"';

// ── iOS xcconfig ──────────────────────────────────────────────────────────────

/// The `pod_target_xcconfig` block for iOS podspecs.
///
/// Sets the header search paths so the generated C++ bridge headers are
/// visible to both Swift and Obj-C++ source files during pod compilation.
String get iosPodTargetXcconfig =>
    """s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => '${BuildVersions.podCxxStandard}',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'HEADER_SEARCH_PATHS' => '$_podHeaderSearchPaths'
  }""";

// ── macOS xcconfig ────────────────────────────────────────────────────────────

/// The `pod_target_xcconfig` block for macOS podspecs.
String get macosPodTargetXcconfig =>
    """s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => '${BuildVersions.podCxxStandard}',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'HEADER_SEARCH_PATHS' => '$_podHeaderSearchPaths'
  }""";
