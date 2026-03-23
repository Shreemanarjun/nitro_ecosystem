#!/usr/bin/env dart
// Run with: dart run nitro_generator:organize [path-to-lib]
//
// Moves generated native bridge files into per-language sub-folders:
//   lib/src/math.bridge.g.kt   → lib/src/generated/kotlin/math.bridge.g.kt
//   lib/src/math.bridge.g.swift → lib/src/generated/swift/math.bridge.g.swift
//   lib/src/math.bridge.g.h    → lib/src/generated/cpp/math.bridge.g.h
//   lib/src/math.CMakeLists.g.txt → lib/src/generated/cmake/math.CMakeLists.g.txt

import 'dart:io';

void main(List<String> args) {
  final root = args.isNotEmpty ? args.first : 'lib';
  final dir = Directory(root);
  if (!dir.existsSync()) {
    stderr.writeln('Directory $root not found.');
    exit(1);
  }

  final rules = <String, String>{
    '.bridge.g.kt': 'generated/kotlin',
    '.bridge.g.swift': 'generated/swift',
    '.bridge.g.h': 'generated/cpp',
    '.CMakeLists.g.txt': 'generated/cmake',
  };

  var moved = 0;
  for (final entity in dir.listSync(recursive: true)) {
    if (entity is! File) continue;
    // Skip files that are already inside a generated/<lang>/ folder
    final relPath = entity.path.replaceFirst('$root/', '');
    if (relPath.startsWith('generated/')) continue;

    for (final entry in rules.entries) {
      if (entity.path.endsWith(entry.key)) {
        final parentDir = entity.parent.path;
        final fileName = entity.uri.pathSegments.last;
        final destFolder = Directory('$parentDir/${entry.value}');
        destFolder.createSync(recursive: true);
        final dest = File('${destFolder.path}/$fileName');
        entity.renameSync(dest.path);
        stdout.writeln('  moved ${entity.path} → ${dest.path}');
        moved++;
        break;
      }
    }
  }
  stdout.writeln('\nnitro_generator organize: moved $moved file(s).');
}
