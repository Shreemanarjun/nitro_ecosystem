// Drift-prevention test: build.yaml and NitroGeneratorBuilder.buildExtensions
// must declare the same set of output paths.
//
// build_runner uses the `buildExtensions` getter in code as the source of truth
// at runtime, but `build.yaml` is what human readers and tooling (including
// build_runner's static analysis hooks) see. If the two drift, a contributor
// can edit build.yaml thinking it controls outputs — and silently produce a
// broken build.
import 'dart:io';
// Import only the extension map, not the full builder — avoids pulling in
// source_gen which imports dart:mirrors (unavailable in flutter test runner).
import 'package:nitro_generator/src/build_extensions.dart';
import 'package:test/test.dart';

void main() {
  test('build.yaml build_extensions matches NitroGeneratorBuilder.buildExtensions', () {
    // Ignore whether the test is invoked from the package root or the
    // workspace root — try both.
    final candidates = [
      File('build.yaml'),
      File('packages/nitro_generator/build.yaml'),
    ];
    final buildYaml = candidates.firstWhere(
      (f) => f.existsSync(),
      orElse: () => throw StateError(
        'build.yaml not found. Tried: ${candidates.map((f) => f.path).join(', ')}',
      ),
    );
    final yamlText = buildYaml.readAsStringSync();

    final expected = nitroBuilderExtensions.values.expand((v) => v).toSet();

    final missing = <String>[];
    for (final output in expected) {
      // build.yaml quotes outputs: `- 'lib/{{dir}}/...'`
      final quoted = "'$output'";
      if (!yamlText.contains(quoted)) {
        missing.add(output);
      }
    }

    expect(
      missing,
      isEmpty,
      reason:
          'build.yaml is missing output entries declared in '
          'NitroGeneratorBuilder.buildExtensions. Add the following entries '
          'under build_extensions in ${buildYaml.path}:\n'
          '${missing.map((m) => "  - '$m'").join('\n')}',
    );
  });
}
