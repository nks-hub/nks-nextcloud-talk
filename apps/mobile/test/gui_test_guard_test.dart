import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/gui_test_guard.dart';

void main() {
  final ownerPc = {sha256.convert(utf8.encode('OWNER-PC')).toString()};

  test('refuses without the opt-in variable', () {
    expect(
      guiTestRefusal(hostname: 'TEST-VM-01', environment: const {}),
      contains('OWNTALK_ALLOW_GUI_TESTS'),
    );
    expect(
      guiTestRefusal(
        hostname: 'TEST-VM-01',
        environment: const {'OWNTALK_ALLOW_GUI_TESTS': '0'},
      ),
      isNotNull,
    );
  });

  test('allows an opted-in machine', () {
    expect(
      guiTestRefusal(
        hostname: 'TEST-VM-01',
        environment: const {
          'OWNTALK_ALLOW_GUI_TESTS': '1',
          'COMPUTERNAME': 'TEST-VM-01',
        },
        forbiddenHashes: ownerPc,
      ),
      isNull,
    );
  });

  test('always refuses a forbidden computer, even when opted in', () {
    for (final environment in [
      const {'OWNTALK_ALLOW_GUI_TESTS': '1'},
      const {'OWNTALK_ALLOW_GUI_TESTS': '1', 'COMPUTERNAME': 'owner-pc'},
    ]) {
      expect(
        guiTestRefusal(
          hostname: 'owner-pc',
          environment: environment,
          forbiddenHashes: ownerPc,
        ),
        contains('must never drive'),
      );
    }
    expect(
      guiTestRefusal(
        hostname: 'something-else',
        environment: const {
          'OWNTALK_ALLOW_GUI_TESTS': '1',
          'COMPUTERNAME': 'OWNER-PC',
        },
        forbiddenHashes: ownerPc,
      ),
      contains('must never drive'),
    );
  });

  test('the built-in list holds one hashed computer name', () {
    expect(guiTestForbiddenComputerHashes, hasLength(1));
    expect(
      guiTestForbiddenComputerHashes.single,
      matches(RegExp(r'^[0-9a-f]{64}$')),
    );
  });
}
