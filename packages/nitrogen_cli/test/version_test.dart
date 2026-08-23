import 'dart:io';

import 'package:nitrogen_cli/version.dart';
import 'package:test/test.dart';

void main() {
  test('nitrogenVersion matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final declared = RegExp(r'^version:\s*(\S+)\s*$', multiLine: true).firstMatch(pubspec)?.group(1);
    expect(declared, isNotNull, reason: 'pubspec.yaml has no version: line');
    expect(
      nitrogenVersion,
      declared,
      reason: 'lib/version.dart drifted from pubspec.yaml — `nitrogen --version` would lie',
    );
  });
}
