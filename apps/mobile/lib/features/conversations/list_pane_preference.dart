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

  /// Width the person dragged the list to, or null while they never did.
  Future<double?> readWidth();

  Future<void> writeWidth(double width);
}

final class FileListPanePreferenceStore implements ListPanePreferenceStore {
  FileListPanePreferenceStore({this.directory});

  final Directory? directory;

  Future<File> _file() async {
    final target = directory ?? await getApplicationSupportDirectory();
    return File('${target.path}/conversation_list_collapsed.txt');
  }

  Future<File> _widthFile() async {
    final target = directory ?? await getApplicationSupportDirectory();
    return File('${target.path}/conversation_list_width.txt');
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

  @override
  Future<double?> readWidth() async {
    try {
      final file = await _widthFile();
      if (!file.existsSync()) {
        return null;
      }
      final stored = double.tryParse((await file.readAsString()).trim());
      // A stored width outside the range the splitter allows is not this
      // app's - clamping it silently would hide that; ignoring it opens the
      // window at the platform default, which is always usable.
      if (stored == null ||
          stored < kMinListPaneWidth ||
          stored > kMaxListPaneWidth) {
        return null;
      }
      return stored;
    } on Object {
      return null;
    }
  }

  @override
  Future<void> writeWidth(double width) async {
    try {
      final file = await _widthFile();
      await file.parent.create(recursive: true);
      await file.writeAsString(width.round().toString(), flush: true);
    } on Object {
      // Losing the width costs one drag next launch. Nothing else.
    }
  }
}

/// Narrowest the list may be dragged: a conversation row still has to show an
/// avatar, a name and the time beside it.
const double kMinListPaneWidth = 240;

/// Widest it may be dragged. Past this the list stops being a sidebar, and the
/// conversation is what the window is for.
const double kMaxListPaneWidth = 520;
