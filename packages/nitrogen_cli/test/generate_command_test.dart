import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:nitrogen_cli/commands/generate_command.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('GenerateCommand planning modes', () {
    late Directory originalDir;
    late Directory tempDir;

    setUp(() {
      originalDir = Directory.current;
      tempDir = Directory.systemTemp.createTempSync('nitrogen_generate_dry_run_');
      Directory.current = tempDir;
    });

    tearDown(() {
      Directory.current = originalDir;
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('--dry-run prints the generation plan without creating build or generated files', () async {
      _writePluginFixture(tempDir);
      final command = _TestGenerateCommand();
      final runner = CommandRunner<void>('nitrogen', 'test')..addCommand(command);

      await runner.run(['generate', '--dry-run', '--no-ui']);

      expect(command.exitCode, 0);
      expect(Directory(p.join(tempDir.path, '.dart_tool')).existsSync(), isFalse);
      expect(Directory(p.join(tempDir.path, 'lib', 'src', 'generated')).existsSync(), isFalse);
      expect(File(p.join(tempDir.path, 'lib', 'src', 'camera.g.dart')).existsSync(), isFalse);
    });

    test('--check returns 3 when generated files are missing', () async {
      _writePluginFixture(tempDir);
      final command = _TestGenerateCommand();
      final runner = CommandRunner<void>('nitrogen', 'test')..addCommand(command);

      await runner.run(['generate', '--check', '--no-ui']);

      expect(command.exitCode, 3);
      expect(Directory(p.join(tempDir.path, '.dart_tool')).existsSync(), isFalse);
      expect(Directory(p.join(tempDir.path, 'lib', 'src', 'generated')).existsSync(), isFalse);
    });

    test('--check returns 0 when all generated files are newer than the spec', () async {
      final specFile = _writePluginFixture(tempDir);
      final generatedAt = specFile.lastModifiedSync().add(const Duration(seconds: 5));
      for (final output in _expectedGeneratedOutputs(tempDir)) {
        output.parent.createSync(recursive: true);
        output.writeAsStringSync('// generated');
        output.setLastModifiedSync(generatedAt);
      }

      final command = _TestGenerateCommand();
      final runner = CommandRunner<void>('nitrogen', 'test')..addCommand(command);

      await runner.run(['generate', '--check', '--no-ui']);

      expect(command.exitCode, 0);
    });

    test('--check --targets=dart ignores stale native outputs outside the target set', () async {
      final specFile = _writePluginFixture(tempDir);
      final generatedAt = specFile.lastModifiedSync().add(const Duration(seconds: 5));
      final dartOutput = File(p.join(tempDir.path, 'lib', 'src', 'camera.g.dart'));
      dartOutput.parent.createSync(recursive: true);
      dartOutput.writeAsStringSync('// generated dart');
      dartOutput.setLastModifiedSync(generatedAt);

      final command = _TestGenerateCommand();
      final runner = CommandRunner<void>('nitrogen', 'test')..addCommand(command);

      await runner.run(['generate', '--check', '--targets=dart', '--no-ui']);

      expect(command.exitCode, 0);
      expect(Directory(p.join(tempDir.path, 'lib', 'src', 'generated')).existsSync(), isFalse);
    });

    test('--check --targets=swift returns 3 when only Swift output is missing', () async {
      _writePluginFixture(tempDir);
      final command = _TestGenerateCommand();
      final runner = CommandRunner<void>('nitrogen', 'test')..addCommand(command);

      await runner.run(['generate', '--check', '--targets=swift', '--no-ui']);

      expect(command.exitCode, 3);
    });

    test('--targets rejects unknown target names', () async {
      _writePluginFixture(tempDir);
      final command = _TestGenerateCommand();
      final runner = CommandRunner<void>('nitrogen', 'test')..addCommand(command);

      await runner.run(['generate', '--check', '--targets=bogus', '--no-ui']);

      expect(command.exitCode, 1);
    });
  });

  group('IncrementalGenerationCache', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('nitrogen_incremental_cache_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('treats every spec as changed when no manifest exists', () {
      final spec = _writePluginFixture(tempDir);
      final output = File(p.join(tempDir.path, 'lib', 'src', 'camera.g.dart'));
      output.parent.createSync(recursive: true);
      output.writeAsStringSync('// generated');

      final cache = IncrementalGenerationCache(tempDir.path);
      final plan = cache.plan(
        specs: [spec],
        outputPathsForSpec: (_) => [output.path],
      );

      expect(plan.changedSpecs, equals([spec]));
    });

    test('skips unchanged specs when hashes and outputs match the manifest', () {
      final spec = _writePluginFixture(tempDir);
      final output = File(p.join(tempDir.path, 'lib', 'src', 'camera.g.dart'));
      output.parent.createSync(recursive: true);
      output.writeAsStringSync('// generated');

      final cache = IncrementalGenerationCache(tempDir.path);
      cache.write(
        specs: [spec],
        outputPathsForSpec: (_) => [output.path],
      );

      final plan = cache.plan(
        specs: [spec],
        outputPathsForSpec: (_) => [output.path],
      );

      expect(plan.changedSpecs, isEmpty);
    });

    test('marks only edited specs as changed', () {
      final camera = _writePluginFixture(tempDir);
      final audio = _writeSpec(tempDir, 'audio');
      final cameraOutput = File(p.join(tempDir.path, 'lib', 'src', 'camera.g.dart'));
      final audioOutput = File(p.join(tempDir.path, 'lib', 'src', 'audio.g.dart'));
      for (final output in [cameraOutput, audioOutput]) {
        output.parent.createSync(recursive: true);
        output.writeAsStringSync('// generated');
      }

      final cache = IncrementalGenerationCache(tempDir.path);
      cache.write(
        specs: [camera, audio],
        outputPathsForSpec: (spec) => [
          p.join(tempDir.path, 'lib', 'src', '${p.basenameWithoutExtension(p.basenameWithoutExtension(spec.path))}.g.dart'),
        ],
      );

      audio.writeAsStringSync('${audio.readAsStringSync()}\n// changed\n');

      final plan = cache.plan(
        specs: [camera, audio],
        outputPathsForSpec: (spec) => [
          p.join(tempDir.path, 'lib', 'src', '${p.basenameWithoutExtension(p.basenameWithoutExtension(spec.path))}.g.dart'),
        ],
      );

      expect(plan.changedSpecs, equals([audio]));
    });
  });
}

class _TestGenerateCommand extends GenerateCommand {
  int? exitCode;

  @override
  Future<void> run() async {
    exitCode = await execute();
  }
}

File _writePluginFixture(Directory root) {
  File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('''
name: dry_run_plugin
dependencies:
  nitro: any
dev_dependencies:
  nitro_generator: any
  build_runner: any
''');
  final specDir = Directory(p.join(root.path, 'lib', 'src'))..createSync(recursive: true);
  return File(p.join(specDir.path, 'camera.native.dart'))..writeAsStringSync('''
import 'package:nitro/nitro.dart';

@NitroModule(lib: 'camera')
abstract class CameraSpec {}
''');
}

File _writeSpec(Directory root, String stem) {
  final specDir = Directory(p.join(root.path, 'lib', 'src'))..createSync(recursive: true);
  return File(p.join(specDir.path, '$stem.native.dart'))..writeAsStringSync('''
import 'package:nitro/nitro.dart';

@NitroModule(lib: '$stem')
abstract class ${stem[0].toUpperCase()}${stem.substring(1)}Spec {}
''');
}

List<File> _expectedGeneratedOutputs(Directory root) {
  final base = p.join(root.path, 'lib', 'src');
  return [
    File(p.join(base, 'camera.g.dart')),
    File(p.join(base, 'generated', 'kotlin', 'camera.bridge.g.kt')),
    File(p.join(base, 'generated', 'swift', 'camera.bridge.g.swift')),
    File(p.join(base, 'generated', 'cpp', 'camera.bridge.g.h')),
    File(p.join(base, 'generated', 'cpp', 'camera.bridge.g.cpp')),
    File(p.join(base, 'generated', 'cmake', 'camera.CMakeLists.g.txt')),
    File(p.join(base, 'generated', 'cpp', 'camera.native.g.h')),
    File(p.join(base, 'generated', 'cpp', 'test', 'camera.mock.g.h')),
    File(p.join(base, 'generated', 'cpp', 'test', 'camera.test.g.cpp')),
  ];
}
