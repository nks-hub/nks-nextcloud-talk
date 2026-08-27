// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/services.dart';

import '../../data/account_repository.dart';
import '../../data/app_database.dart';

/// Shows a Talk message as a Windows notification.
///
/// Windows has no way for a closed app to be woken by a push — that needs
/// Microsoft Store packaging — so this only covers the running app. Client
/// Push already keeps it in sync while it runs; the gap this fills is that
/// nothing ever told the user.
final class WindowsNotificationChannel {
  WindowsNotificationChannel({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'com.nkshub.nextcloudtalk/windows_notification';

  final MethodChannel _channel;

  Future<void> show({
    required String title,
    required String body,
    required Uri url,
  }) {
    return _channel.invokeMethod<bool>('show', {
      'title': title,
      'body': body,
      'url': url.toString(),
    });
  }
}

/// Turns a rise in an account's unread counts into notifications.
///
/// The content comes from the conversation rows a sync has already written —
/// the same rows the conversation list renders — so nothing is fetched twice.
/// It is also why no `app == "spreed"` filter is needed here the way it is on
/// Android: these rows only ever hold Talk conversations, so a Deck card can
/// never reach this path in the first place.
final class WindowsNotificationService {
  WindowsNotificationService({
    required AccountRepository accounts,
    required WindowsNotificationChannel channel,
  }) : _accounts = accounts,
       _channel = channel;

  final AccountRepository _accounts;
  final WindowsNotificationChannel _channel;
  final Map<String, StreamSubscription<List<CachedConversation>>> _watched = {};
  final Map<String, Map<String, int>> _seenUnread = {};

  /// Starts notifying for [accountId] on [serverUrl].
  ///
  /// The first emission only records the current counts. Announcing them would
  /// mean a burst of notifications for everything unread at startup.
  void follow(String accountId, String serverUrl) {
    if (_watched.containsKey(accountId)) {
      return;
    }
    final server = Uri.parse(serverUrl);
    _watched[accountId] = _accounts
        .watchConversations(accountId)
        .listen(
          (conversations) => _apply(accountId, server, conversations),
          onError: (Object _, StackTrace _) {},
        );
  }

  Future<void> unfollow(String accountId) async {
    _seenUnread.remove(accountId);
    await _watched.remove(accountId)?.cancel();
  }

  Future<void> dispose() async {
    for (final accountId in _watched.keys.toList(growable: false)) {
      await unfollow(accountId);
    }
  }

  void _apply(
    String accountId,
    Uri server,
    List<CachedConversation> conversations,
  ) {
    final previous = _seenUnread[accountId];
    _seenUnread[accountId] = <String, int>{
      for (final conversation in conversations)
        conversation.token: conversation.unreadMessages,
    };
    if (previous == null) {
      return;
    }
    for (final conversation in conversations) {
      final was = previous[conversation.token];
      if (was == null || conversation.unreadMessages <= was) {
        continue;
      }
      final body = conversation.lastMessageText;
      if (body == null || body.isEmpty) {
        continue;
      }
      unawaited(
        _channel
            .show(
              title: conversation.displayName,
              body: body,
              url: server.replace(path: '/call/${conversation.token}'),
            )
            .catchError((Object _) {}),
      );
    }
  }
}
