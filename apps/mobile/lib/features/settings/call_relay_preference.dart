import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Whether calls are forced through a TURN relay instead of letting ICE pick
/// the shortest path it can find.
///
/// The relay servers themselves are never configured here and never in the
/// build: Talk hands them out per room in its signalling settings
/// (`$.ocs.data.turnservers`), with the credentials that go with them. This
/// setting only says which of the offered candidates ICE may use.
///
/// Off is the right default — a call that relays when it did not have to pays
/// latency and somebody else's bandwidth for nothing. On is for two cases: a
/// network where the direct path is blocked but the app cannot tell, and
/// proving that the relay path works at all, which cannot be measured where a
/// direct connection would always win.
abstract interface class CallRelayPreferenceStore {
  Future<bool> read();

  Future<void> write(bool relayOnly);
}

final class FileCallRelayPreferenceStore implements CallRelayPreferenceStore {
  FileCallRelayPreferenceStore({this._directory});

  final Directory? _directory;

  Future<File> _file() async {
    final dir = _directory ?? await getApplicationSupportDirectory();
    return File('${dir.path}/call_relay_only.txt');
  }

  @override
  Future<bool> read() async {
    try {
      final file = await _file();
      if (!file.existsSync()) {
        return false;
      }
      return (await file.readAsString()).trim() == 'true';
    } on Object {
      return false;
    }
  }

  @override
  Future<void> write(bool relayOnly) async {
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      await file.writeAsString(relayOnly ? 'true' : 'false');
    } on Object {
      // ponytail: best effort, same as the other local preferences — a failed
      // write costs the choice on the next start, nothing else.
    }
  }
}
