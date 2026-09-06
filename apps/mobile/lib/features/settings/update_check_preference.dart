import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Whether the app may ask GitHub for the newest published build.
///
/// Off is the only defensible default. The check is an outbound request to a
/// third party that nothing else in the app talks to, and making it tells
/// GitHub that this installation exists and is running. That is the person's
/// call, not the build's, so nothing is asked until they say so.
abstract interface class UpdateCheckPreferenceStore {
  Future<bool> read();

  Future<void> write(bool enabled);
}

final class FileUpdateCheckPreferenceStore
    implements UpdateCheckPreferenceStore {
  FileUpdateCheckPreferenceStore({this._directory});

  final Directory? _directory;

  Future<File> _file() async {
    final dir = _directory ?? await getApplicationSupportDirectory();
    return File('${dir.path}/update_check_enabled.txt');
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
  Future<void> write(bool enabled) async {
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      await file.writeAsString(enabled ? 'true' : 'false');
    } on Object {
      // ponytail: best effort, same as the other local preferences — a failed
      // write costs the choice on the next start, nothing else.
    }
  }
}
