import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// SHA-256 of the upper-case name of each computer whose desktop must never be
/// driven by a GUI test. Hashed so the public repository does not name the
/// machine.
const guiTestForbiddenComputerHashes = {
  '08664814b84053f8b61bf511d598aa4218765f542e153e575d917704b967aa50',
};

/// The environment variable a machine has to set to say that opening a window
/// and sending real input there is intended.
const guiTestAllowVariable = 'OWNTALK_ALLOW_GUI_TESTS';

String _computerHash(String name) =>
    sha256.convert(utf8.encode(name.toUpperCase())).toString();

/// Why a GUI test must not start on this machine, or null when it may.
///
/// Pure on purpose: the decision depends on the host name, the environment and
/// nothing else, so it can be checked without opening a window.
String? guiTestRefusal({
  required String hostname,
  required Map<String, String> environment,
  Set<String> forbiddenHashes = guiTestForbiddenComputerHashes,
}) {
  final names = {hostname, environment['COMPUTERNAME'] ?? ''}
    ..removeWhere((name) => name.isEmpty);
  final forbidden = names.where(
    (name) => forbiddenHashes.contains(_computerHash(name)),
  );
  if (forbidden.isNotEmpty) {
    return 'Refusing to run: ${forbidden.first} is a computer whose desktop a '
        'GUI test must never drive.';
  }
  if (environment[guiTestAllowVariable] != '1') {
    return 'Refusing to run: this test opens a real window and may send real '
        'input. Set $guiTestAllowVariable=1 on a machine meant for it.';
  }
  return null;
}

/// Call first in `main()` of every integration test that opens a window or
/// sends real input. Exits with code 2 before anything is shown.
void requireGuiTestHost() {
  final refusal = guiTestRefusal(
    hostname: Platform.localHostname,
    environment: Platform.environment,
  );
  if (refusal == null) return;
  stderr.writeln(refusal);
  exit(2);
}
