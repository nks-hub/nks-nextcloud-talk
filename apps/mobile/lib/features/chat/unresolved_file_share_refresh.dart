import 'dart:async';
import 'dart:convert';

import 'package:talk_protocol/talk_protocol.dart';

import '../../data/app_database.dart';

/// Re-reads the file shares a room shows as Talk's stand-in for a share it
/// could not resolve for this reader yet.
///
/// The cursors never read a cached id again, so that stand-in ("shared a file
/// which is no longer available") stayed for good. Seen on Talk 35
/// (2026-11-22): it arrived 3 s after the send, and a later read of the same
/// id returned the file. Every row is re-read once; one still unresolved and
/// younger than [retryWindow] is tried again after each of [retryDelays],
/// since a re-read right after a live arrival can meet the same race.
final class UnresolvedFileShareRefresh {
  UnresolvedFileShareRefresh({
    this.retryDelays = const [Duration(seconds: 10), Duration(seconds: 60)],
    this.retryWindow = const Duration(minutes: 10),
  });

  final List<Duration> retryDelays;

  /// An older stand-in most likely names a file that really is gone.
  final Duration retryWindow;

  final _checked = <int>{};
  final _timers = <Timer>{};
  var _generation = 0;

  /// Takes one emission of the room's rows. [reread] asks the server for one
  /// message again and returns its row as cached afterwards.
  void observe(
    Iterable<CachedChatMessage> messages,
    Future<CachedChatMessage?> Function(int messageId) reread,
  ) {
    final stale = [
      for (final message in messages)
        if (_checked.add(message.messageId) && isUnresolvedFileShare(message))
          message,
    ];
    if (stale.isEmpty) {
      return;
    }
    final generation = _generation;
    // Not from inside the build that delivered the rows.
    scheduleMicrotask(() => _reread(stale, reread, generation, 0));
  }

  /// Stops every re-read of the room left behind, including one under way.
  void reset() {
    _generation++;
    _checked.clear();
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
  }

  Future<void> _reread(
    List<CachedChatMessage> stale,
    Future<CachedChatMessage?> Function(int messageId) reread,
    int generation,
    int attempt,
  ) async {
    for (final message in stale) {
      if (generation != _generation) {
        return;
      }
      CachedChatMessage? row = message;
      try {
        row = await reread(message.messageId);
      } on Object {
        // Offline or refused: decided like an answer that is still unresolved.
      }
      if (generation != _generation) {
        return;
      }
      if (row == null ||
          attempt >= retryDelays.length ||
          !isUnresolvedFileShare(row) ||
          DateTime.now().difference(
                DateTime.fromMillisecondsSinceEpoch(row.timestamp * 1000),
              ) >
              retryWindow) {
        continue;
      }
      final retry = row;
      late final Timer timer;
      timer = Timer(retryDelays[attempt], () {
        _timers.remove(timer);
        unawaited(_reread([retry], reread, generation, attempt + 1));
      });
      _timers.add(timer);
    }
  }
}

/// Talk's stand-in for a file share it cannot resolve: a comment that still
/// names the sharing `{actor}` but carries neither `{file}` nor `{object}`.
bool isUnresolvedFileShare(CachedChatMessage message) {
  if (message.deleted ||
      message.messageType != 'comment' ||
      message.systemMessage.isNotEmpty ||
      !message.rawJson.contains('"actor":')) {
    return false;
  }
  try {
    final parameters = ChatMessage.fromJson(
      jsonDecode(message.rawJson),
    ).messageParameters;
    return parameters.containsKey('actor') &&
        !parameters.containsKey('file') &&
        !parameters.containsKey('object');
  } on Object {
    return false;
  }
}
