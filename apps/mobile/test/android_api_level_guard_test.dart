import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Types that only exist above `minSdk` and therefore may not be named by a
/// class the application loads on every device.
///
/// A field, a property or a lambda of such a type is resolved when its class is
/// loaded, which is long before any `Build.VERSION.SDK_INT` check inside a
/// method can run. The failure is not a caught exception either — it is
/// `NoClassDefFoundError` while the activity is being instantiated, so the
/// application does not start at all, and no emulator running a newer image
/// ever shows it.
///
/// Measured on a Galaxy S9+ (Android 10) with build 61: the app died at launch
/// with `Failed resolution of: Landroid/media/AudioManager$OnModeChangedListener`
/// because `CallAudioFocus` held the listener as a property. The fix is to keep
/// such a type inside a class of its own that nothing constructs below the
/// level it needs — `CallAudioModeWatcher` here.
const _apiGatedTypes = <String, String>{
  'OnModeChangedListener': 'CallAudioModeWatcher.kt',
};

void main() {
  test('an API-gated Android type stays in the class written for it', () async {
    final kotlin = Directory(
      '${Directory.current.path}${Platform.pathSeparator}android'
      '${Platform.pathSeparator}app${Platform.pathSeparator}src'
      '${Platform.pathSeparator}main${Platform.pathSeparator}kotlin',
    );
    expect(
      kotlin.existsSync(),
      isTrue,
      reason: 'the Kotlin sources moved; this guard has to move with them',
    );

    final sources = kotlin
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.kt'))
        .toList(growable: false);
    expect(sources, isNotEmpty);

    for (final entry in _apiGatedTypes.entries) {
      final offenders = <String>[];
      for (final file in sources) {
        final name = file.uri.pathSegments.last;
        if (name == entry.value) {
          continue;
        }
        // A mention inside a comment is how the reason is written down, and
        // that has to stay allowed; only code may not name the type.
        final code = file
            .readAsLinesSync()
            .where((line) {
              final trimmed = line.trimLeft();
              return !trimmed.startsWith('*') &&
                  !trimmed.startsWith('//') &&
                  !trimmed.startsWith('/*');
            })
            .join('\n');
        if (code.contains(entry.key)) {
          offenders.add(name);
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            '${entry.key} may only be named by ${entry.value}; naming it in '
            '${offenders.join(', ')} makes that class unloadable on a device '
            'below the API level the type needs, and the app will not start',
      );
    }
  });
}
