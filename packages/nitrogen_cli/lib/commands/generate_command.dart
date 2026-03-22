import 'dart:io';
import 'package:args/command_runner.dart';

class GenerateCommand extends Command {
  @override
  final String name = 'generate';
  
  @override
  final String description = 'Runs the nitrogen code generator (build_runner) for specs.';

  @override
  void run() {
    stdout.writeln('🚀 Starting Nitrogen generation pipeline...');
    
    // We run standard `flutter pub run build_runner build`
    // Using flutter or dart wrapper interchangeably.
    final result = Process.runSync(
      'flutter',
      ['pub', 'run', 'build_runner', 'build', '--delete-conflicting-outputs'],
    );
    
    stdout.write(result.stdout);
    if (result.stderr.toString().isNotEmpty) {
      stderr.write(result.stderr);
    }
    
    if (result.exitCode != 0) {
      stderr.writeln('❌ Nitrogen generation failed.');
      exit(result.exitCode);
    }
    
    stdout.writeln('✅ Nitrogen generation complete!');
  }
}
