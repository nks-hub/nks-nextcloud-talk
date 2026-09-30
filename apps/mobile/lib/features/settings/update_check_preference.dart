import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'update_check_service.dart';

/// Whether the app may ask GitHub for the newest published build.
///
/// Desktop checks default to on; an explicit saved choice takes precedence.
abstract interface class UpdateCheckPreferenceStore {
  Future<bool> read();

  Future<void> write(bool enabled);
}

final class FileUpdateCheckPreferenceStore
    implements UpdateCheckPreferenceStore {
  FileUpdateCheckPreferenceStore({this.directory});

  final Directory? directory;

  Future<File> _file() async {
    final dir = directory ?? await getApplicationSupportDirectory();
    return File('${dir.path}/update_check_enabled.txt');
  }

  @override
  Future<bool> read() async {
    try {
      final file = await _file();
      if (!file.existsSync()) {
        return isDesktopUpdateCheckPlatform;
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
