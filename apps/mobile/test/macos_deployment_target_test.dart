import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('macOS runner meets the native plugin deployment target', () {
    final project = File(
      'macos/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();
    final targets = RegExp(
      r'MACOSX_DEPLOYMENT_TARGET = ([0-9.]+);',
    ).allMatches(project).map((match) => match.group(1)).toList();

    expect(targets, isNotEmpty);
    expect(
      targets,
      everyElement(
        predicate<String>(
          (target) => int.parse(target.split('.').first) >= 11,
          'macOS 11.0 or newer',
        ),
      ),
    );
  });
}
