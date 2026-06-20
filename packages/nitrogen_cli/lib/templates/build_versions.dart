/// Centralized build/toolchain versions used by generated Nitro plugin files.
///
/// Keep these constants as the single source of truth for scaffold, link,
/// doctor, and migration helpers so generated platform files do not drift.
abstract final class BuildVersions {
  static const cmakeMinimum = '3.10';
  static const cmakeCxxStandard = '17';
  static const swiftTools = '5.9';
  static const iosDeployment = '13';
  static const iosPlatformSpec = 'iOS(.v$iosDeployment)';
  static const macosDeployment = '10_15';
  static const macosPlatformSpec = 'macOS(.v$macosDeployment)';
  static const podSwiftVersion = '5.9';
  static const podCxxStandard = 'c++17';
  static const spmCxxFlag = '-std=c++17';
  static const androidNdk = '27.0.12077973';
  static const androidJvmTarget = '17';
  static const androidJavaVersion = 'VERSION_17';
  static const androidCompileSdk = '36';
  static const androidMinSdk = '24';
  static const kotlinCoroutines = '1.7.3';
}
