// CocoaPods podspec snippet templates for `nitrogen init` and `nitrogen link`.
library;

import 'build_versions.dart';

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
    'HEADER_SEARCH_PATHS' => '\$(inherited) "\${PODS_ROOT}/../.symlinks/plugins/nitro/src/native" "\${PODS_TARGET_SRCROOT}/../src" "\${PODS_TARGET_SRCROOT}/../lib/src/generated/cpp"'
  }""";

// ── macOS xcconfig ────────────────────────────────────────────────────────────

/// The `pod_target_xcconfig` block for macOS podspecs.
///
/// Uses Flutter's macOS `.symlinks` path (`Flutter/ephemeral`) instead of the
/// iOS CocoaPods root path.
String get macosPodTargetXcconfig =>
    """s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => '${BuildVersions.podCxxStandard}',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'HEADER_SEARCH_PATHS' => '\$(inherited) "\${PODS_ROOT}/../Flutter/ephemeral/.symlinks/plugins/nitro/src/native" "\${PODS_TARGET_SRCROOT}/../src" "\${PODS_TARGET_SRCROOT}/../lib/src/generated/cpp"'
  }""";
