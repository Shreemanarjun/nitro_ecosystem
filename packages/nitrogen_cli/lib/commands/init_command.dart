import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

class InitCommand extends Command {
  @override
  final String name = 'init';
  
  @override
  final String description = 'Scaffolds a new Nitrogen FFI plugin project.';

  InitCommand() {
    argParser.addOption('org',
        defaultsTo: 'com.example',
        help: 'The organization (e.g., com.mycompany) for the plugin.');
  }

  @override
  void run() async {
    if (argResults!.rest.isEmpty) {
      stderr.writeln('❌ Please provide a plugin name: nitrogen init <plugin_name>');
      exit(1);
    }

    final pluginName = argResults!.rest.first;
    final org = argResults!['org'];
    final dir = Directory(pluginName);

    if (dir.existsSync()) {
      stderr.writeln('❌ Directory $pluginName already exists.');
      exit(1);
    }

    stdout.writeln('📦 Running flutter create for $pluginName...');
    final createResult = Process.runSync('flutter', [
      'create',
      '--template=plugin_ffi',
      '--platforms=android,ios',
      '--org=$org',
      pluginName,
    ]);

    if (createResult.exitCode != 0) {
      stderr.writeln(createResult.stderr);
      exit(createResult.exitCode);
    }

    // ── Update Pubspec ───────────────────────────────────────────────────────
    stdout.writeln('📝 Updating pubspec.yaml components...');
    final pubspecFile = File(p.join(pluginName, 'pubspec.yaml'));
    var pubspec = pubspecFile.readAsStringSync();
    
    if (!pubspec.contains('nitro:')) {
      pubspec = pubspec.replaceFirst(
        'dependencies:\n  flutter:\n    sdk: flutter',
        "dependencies:\n  flutter:\n    sdk: flutter\n  nitro:\n    path: ../packages/nitro", 
      );
    }
    
    // Remove ffigen/ffi since Nitro handles FFI generation completely
    pubspec = pubspec.replaceAll(RegExp(r'^\s*ffigen:.*$\n', multiLine: true), '');
    pubspec = pubspec.replaceAll(RegExp(r'^\s*ffi:.*$\n', multiLine: true), '');
    
    if (!pubspec.contains('nitrogen:')) {
      pubspec = pubspec.replaceFirst(
        '  flutter_lints:',
        "  build_runner: ^2.4.0\n  nitrogen:\n    path: ../packages/nitrogen\n  flutter_lints:",
      );
    }
    pubspecFile.writeAsStringSync(pubspec);

    // ── Create spec file ──────────────────────────────────────────────────────
    final libDir = Directory(p.join(pluginName, 'lib', 'src'));
    libDir.createSync(recursive: true);
    final specFile = File(p.join(libDir.path, '${pluginName}.native.dart'));

    final className = _capitalize(pluginName);
    
    specFile.writeAsStringSync('''
import 'package:nitro/nitro.dart';

part '${pluginName}.g.dart';

@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class $className extends HybridObject {
  static final $className instance = _${className}Impl(NitroRuntime.loadLib('$pluginName'));

  double add(double a, double b);

  @nitroAsync
  Future<String> getGreeting(String name);
}
''');

    // Remove Default main file and export ours
    final mainLib = File(p.join(pluginName, 'lib', '${pluginName}.dart'));
    mainLib.writeAsStringSync("export 'src/${pluginName}.native.dart';\n");

    // Clear old FFI C code to avoid conflicts
    final srcDir = Directory(p.join(pluginName, 'src'));
    if (srcDir.existsSync()) {
      for (var f in srcDir.listSync()) {
        if (f.path.endsWith('.c') || f.path.endsWith('.cpp') || f.path.endsWith('.h')) {
          f.deleteSync();
        }
      }
    }

    // Rewrite CMakeLists.txt to include Nitrogen
    final cmakeFile = File(p.join(pluginName, 'CMakeLists.txt'));
    cmakeFile.writeAsStringSync('''
cmake_minimum_required(VERSION 3.10)
project(${pluginName}_library VERSION 0.0.1 LANGUAGES C CXX)

# Include the Nitrogen generated module bindings
include(lib/src/generated/cmake/${pluginName}.CMakeLists.g.txt OPTIONAL)
''');

    // Rewrite example main.dart
    final exampleMainFile = File(p.join(pluginName, 'example', 'lib', 'main.dart'));
    if (exampleMainFile.existsSync()) {
      exampleMainFile.writeAsStringSync('''
import 'package:flutter/material.dart';
import 'package:$pluginName/$pluginName.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  double _result = 0;
  String _greeting = 'Loading...';

  @override
  void initState() {
    super.initState();
    // Example synchronous call
    try {
      _result = $className.instance.add(10, 20);
    } catch (e) {
      print('Native implementation may not be loaded yet: \$e');
    }

    // Example asynchronous call
    $className.instance.getGreeting('Flutter').then((val) {
      if (mounted) setState(() => _greeting = val);
    }).catchError((e) {
      if (mounted) setState(() => _greeting = 'Error: \$e');
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Nitrogen Plugin Example')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Sync Result: 10 + 20 = \$_result'),
              const SizedBox(height: 16),
              Text('Async Result: \$_greeting'),
            ],
          ),
        ),
      ),
    );
  }
}
''');
    }

    stdout.writeln('✨ $pluginName has been scaffolded for Nitrogen!');
    stdout.writeln('Next steps:');
    stdout.writeln('  cd $pluginName');
    stdout.writeln('  nitrogen generate');
  }

  String _capitalize(String name) {
    if (name.isEmpty) return name;
    return name.split('_').map((w) => w.substring(0, 1).toUpperCase() + w.substring(1)).join('');
  }
}
