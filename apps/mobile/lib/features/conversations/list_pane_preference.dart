import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Remembers whether the conversation list is folded away on a wide window.
///
/// A desktop app that forgets its layout on every launch is a desktop app that
/// gets refolded every launch. Not per-account, the same way the theme is not:
/// the fold is a property of how this person uses this window, and switching
/// accounts is no reason to unfold it.
abstract interface class ListPanePreferenceStore {
  Future<bool> readCollapsed();

  Future<void> writeCollapsed({required bool collapsed});
}

final class FileListPanePreferenceStore implements ListPanePreferenceStore {
  FileListPanePreferenceStore({this.directory});

  final Directory? directory;

  Future<File> _file() async {
    final target = directory ?? await getApplicationSupportDirectory();
    return File('${target.path}/conversation_list_collapsed.txt');
  }

  @override
  Future<bool> readCollapsed() async {
    try {
      final file = await _file();
      if (!file.existsSync()) {
        return false;
      }
      return (await file.readAsString()).trim() == 'collapsed';
    } on Object {
      // An unreadable preference is not worth a failed launch; the window
      // simply opens with the list shown, which is the safe direction — a
      // wrongly hidden list looks like lost conversations.
      return false;
    }
  }

  @override
  Future<void> writeCollapsed({required bool collapsed}) async {
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      await file.writeAsString(collapsed ? 'collapsed' : 'shown', flush: true);
    } on Object {
      // Losing the preference costs one click next launch. Nothing else.
    }
  }
}
