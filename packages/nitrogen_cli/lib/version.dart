/// The CLI's version. Kept in lockstep with `pubspec.yaml` by
/// `test/version_test.dart`, which fails the build if the two ever diverge —
/// previously this drifted (0.7.0 here vs 0.7.1 in the pubspec), so
/// `nitrogen --version` reported a version that did not exist and made
/// "is my globally-activated CLI stale?" impossible to answer.
const String nitrogenVersion = '0.7.1';

/// The version reported by `nitrogen --version` and the doctor/dashboard
/// headers.
const String activeVersion = nitrogenVersion;
