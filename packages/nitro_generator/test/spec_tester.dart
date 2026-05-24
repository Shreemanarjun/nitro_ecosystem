// SpecTester — a source-string-first API for testing all four code generators
// against a single .native.dart spec in one call.
//
// Usage:
//
//   final src = SpecSource('''
//     abstract class Printer {
//       Future<void> print(String content, {int? copies});
//     }
//   ''');
//
//   specTest('copies sentinel', src,
//     dart:   BridgeChecks(has: ['copies ?? -1']),
//     kotlin: BridgeChecks(has: ['Long?'], before: [('val copiesArg', 'impl.print(')]),
//     skip:   {Lang.cpp},
//   );

import 'package:test/test.dart';

import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/swift_generator.dart';
import 'package:nitro_generator/src/generators/cpp_interface_generator.dart';

import 'spec_from_source.dart';

// ─── Public surface ───────────────────────────────────────────────────────────

/// Selects which code generator to run / check.
enum Lang { dart, kotlin, swift, cpp }

/// Assertions to run against one generator's output.
class BridgeChecks {
  const BridgeChecks({
    this.has = const [],
    this.hasNot = const [],
    this.before = const [],
  });

  /// Every string must appear somewhere in the output.
  final List<String> has;

  /// None of these strings may appear in the output.
  final List<String> hasNot;

  /// Ordering pairs: first element must appear before second element.
  /// Both must be present.
  final List<(String, String)> before;

  const BridgeChecks.empty() : has = const [], hasNot = const [], before = const [];
}

/// A parsed spec source. Parse is lazy and cached — multiple [specTest] calls
/// sharing the same [SpecSource] instance parse the source only once.
class SpecSource {
  SpecSource(this._source, {this.uri = 'test.native.dart'});

  final String _source;

  /// URI stored in [BridgeSpec.sourceUri].  Affects the default `lib` name
  /// when no `@NitroModule(lib:)` is provided.
  final String uri;

  BridgeSpec? _spec;

  /// Returns the parsed [BridgeSpec], computing it on first access.
  BridgeSpec get spec => _spec ??= SpecFromSource.parse(_source, sourceUri: uri);

  @override
  String toString() => _source;
}

/// Runs a [test] that generates all four bridge outputs from [source] and
/// asserts [BridgeChecks] for each selected language.
///
/// Parameters:
/// - [all]    — checks applied to every language not in [skip].
///              Automatically restricted to generators that apply to the spec
///              (e.g. cpp is skipped when no C++ impl is set).
/// - [dart] / [kotlin] / [swift] / [cpp] — language-specific checks.
/// - [skip]   — generators to exclude entirely (no output produced, no check).
/// - [debugPrint] — generators whose full output is printed before assertions,
///                  regardless of pass / fail (useful for debugging failures).
void specTest(
  String description,
  SpecSource source, {
  BridgeChecks? all,
  BridgeChecks? dart,
  BridgeChecks? kotlin,
  BridgeChecks? swift,
  BridgeChecks? cpp,
  Set<Lang> skip = const {},
  Set<Lang> debugPrint = const {},
}) {
  test(description, () {
    final spec = source.spec;

    // Generate outputs for every non-skipped language.
    final outputs = <Lang, String>{};
    for (final lang in Lang.values) {
      if (skip.contains(lang)) continue;
      outputs[lang] = _generate(lang, spec);
    }

    // Debug dump before assertions so failures still show the full output.
    for (final lang in debugPrint) {
      if (!outputs.containsKey(lang)) continue;
      // ignore: avoid_print
      print('══ ${lang.name.toUpperCase()} ══\n${outputs[lang]}\n');
    }

    // Apply `all:` only to generators that are meaningful for this spec.
    if (all != null) {
      for (final lang in Lang.values) {
        if (!outputs.containsKey(lang)) continue;
        if (!_langAppliesTo(lang, spec)) continue;
        _runChecks(lang, outputs[lang]!, all);
      }
    }

    // Language-specific checks.
    if (dart != null && outputs.containsKey(Lang.dart)) {
      _runChecks(Lang.dart, outputs[Lang.dart]!, dart);
    }
    if (kotlin != null && outputs.containsKey(Lang.kotlin)) {
      _runChecks(Lang.kotlin, outputs[Lang.kotlin]!, kotlin);
    }
    if (swift != null && outputs.containsKey(Lang.swift)) {
      _runChecks(Lang.swift, outputs[Lang.swift]!, swift);
    }
    if (cpp != null && outputs.containsKey(Lang.cpp)) {
      _runChecks(Lang.cpp, outputs[Lang.cpp]!, cpp);
    }
  });
}

// ─── Internals ────────────────────────────────────────────────────────────────

String _generate(Lang lang, BridgeSpec spec) {
  return switch (lang) {
    Lang.dart => DartFfiGenerator.generate(spec),
    Lang.kotlin => KotlinGenerator.generate(spec),
    Lang.swift => SwiftGenerator.generate(spec),
    Lang.cpp => CppInterfaceGenerator.generate(spec),
  };
}

/// Whether [lang] produces meaningful output for [spec].
/// Used by [all:] to auto-skip generators that don't apply.
bool _langAppliesTo(Lang lang, BridgeSpec spec) {
  return switch (lang) {
    Lang.dart => true,
    Lang.kotlin => spec.targetsAndroid,
    Lang.swift => spec.targetsIos || spec.targetsMacos,
    Lang.cpp => spec.hasCppImpl,
  };
}

void _runChecks(Lang lang, String out, BridgeChecks checks) {
  final label = lang.name.toUpperCase();

  for (final s in checks.has) {
    expect(out, contains(s), reason: '[$label] should contain: $s');
  }
  for (final s in checks.hasNot) {
    expect(out, isNot(contains(s)), reason: '[$label] should NOT contain: $s');
  }
  for (final (a, b) in checks.before) {
    final ia = out.indexOf(a);
    final ib = out.indexOf(b);
    expect(ia, greaterThan(-1), reason: '[$label] "$a" not found in output');
    expect(ib, greaterThan(-1), reason: '[$label] "$b" not found in output');
    expect(ia, lessThan(ib), reason: '[$label] "$a" must appear before "$b"');
  }
}
