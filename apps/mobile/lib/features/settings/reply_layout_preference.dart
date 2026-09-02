import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// How a reply is shown in the room it was sent to.
///
/// Talk 22 puts every reply into a thread, and the server marks the row with
/// its thread id. [inline] keeps the classic layout: the reply stays in the
/// room timeline under a quoted copy of what it answers. [thread] hides
/// replies from the room and shows them only inside the thread pane.
enum ReplyLayout { inline, thread }

/// Persists the reply layout locally. Not per-account: it is a reading
/// preference, not something the server knows about.
abstract interface class ReplyLayoutPreferenceStore {
  Future<ReplyLayout> read();

  Future<void> write(ReplyLayout layout);
}

final class FileReplyLayoutPreferenceStore
    implements ReplyLayoutPreferenceStore {
  FileReplyLayoutPreferenceStore({this._directory});

  final Directory? _directory;

  Future<File> _file() async {
    final dir = _directory ?? await getApplicationSupportDirectory();
    return File('${dir.path}/reply_layout.txt');
  }

  @override
  Future<ReplyLayout> read() async {
    try {
      final file = await _file();
      if (!file.existsSync()) {
        return ReplyLayout.inline;
      }
      final raw = (await file.readAsString()).trim();
      return ReplyLayout.values.firstWhere(
        (layout) => layout.name == raw,
        orElse: () => ReplyLayout.inline,
      );
    } on Object {
      return ReplyLayout.inline;
    }
  }

  @override
  Future<void> write(ReplyLayout layout) async {
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      await file.writeAsString(layout.name);
    } on Object {
      // ponytail: best effort — a failed write just falls back to the last
      // in-memory choice for this session, no user-visible data loss.
    }
  }
}
