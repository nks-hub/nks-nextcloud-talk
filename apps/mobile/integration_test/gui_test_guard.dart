import 'dart:io';

/// The computer whose desktop must never be driven by a GUI test.
const guiTestForbiddenComputer = 'DESKTOP-HD73V8A';

/// The environment variable a machine has to set to say that opening a window
/// and sending real input there is intended.
const guiTestAllowVariable = 'OWNTALK_ALLOW_GUI_TESTS';

/// Why a GUI test must not start on this machine, or null when it may.
///
/// Pure on purpose: the decision depends on the host name, the environment and
/// nothing else, so it can be checked without opening a window.
String? guiTestRefusal({
  required String hostname,
  required Map<String, String> environment,
}) {
  final names = {hostname, environment['COMPUTERNAME'] ?? ''}
    ..removeWhere((name) => name.isEmpty);
  if (names.any(
    (name) => name.toUpperCase() == guiTestForbiddenComputer,
  )) {
    return 'Refusing to run: $guiTestForbiddenComputer is the owner\'s own '
        'computer and a GUI test would drive its desktop.';
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
