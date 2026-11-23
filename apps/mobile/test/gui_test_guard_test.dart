import 'package:flutter_test/flutter_test.dart';

import '../integration_test/gui_test_guard.dart';

void main() {
  test('refuses without the opt-in variable', () {
    expect(
      guiTestRefusal(hostname: 'DESKTOP-KR5NK4H', environment: const {}),
      contains('OWNTALK_ALLOW_GUI_TESTS'),
    );
    expect(
      guiTestRefusal(
        hostname: 'DESKTOP-KR5NK4H',
        environment: const {'OWNTALK_ALLOW_GUI_TESTS': '0'},
      ),
      isNotNull,
    );
  });

  test('allows an opted-in machine', () {
    expect(
      guiTestRefusal(
        hostname: 'DESKTOP-KR5NK4H',
        environment: const {
          'OWNTALK_ALLOW_GUI_TESTS': '1',
          'COMPUTERNAME': 'DESKTOP-KR5NK4H',
        },
      ),
      isNull,
    );
  });

  test("always refuses the owner's computer, even when opted in", () {
    for (final environment in [
      const {'OWNTALK_ALLOW_GUI_TESTS': '1'},
      const {'OWNTALK_ALLOW_GUI_TESTS': '1', 'COMPUTERNAME': 'desktop-hd73v8a'},
    ]) {
      expect(
        guiTestRefusal(hostname: 'desktop-hd73v8a', environment: environment),
        contains('owner'),
      );
    }
    expect(
      guiTestRefusal(
        hostname: 'something-else',
        environment: const {
          'OWNTALK_ALLOW_GUI_TESTS': '1',
          'COMPUTERNAME': 'DESKTOP-HD73V8A',
        },
      ),
      contains('owner'),
    );
  });
}
