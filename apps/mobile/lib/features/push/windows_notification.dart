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
  WindowsNotificationChannel({
    MethodChannel? channel,
    WindowsNotificationActionHandler? onNotificationAction,
  }) : _channel = channel ?? const MethodChannel(channelName),
       _onNotificationAction = onNotificationAction {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  static const channelName = 'com.nkshub.nextcloudtalk/windows_notification';

  final MethodChannel _channel;
  final WindowsNotificationActionHandler? _onNotificationAction;
  final List<WindowsNotificationOpen> _pendingOpens = [];
  final StreamController<void> _notificationOpenedController =
      StreamController<void>.broadcast();

  Stream<void> get notificationOpened => _notificationOpenedController.stream;

  WindowsNotificationOpen? takeNextNotificationOpen() =>
      _pendingOpens.isEmpty ? null : _pendingOpens.removeAt(0);

  Future<void> show({
    required String accountId,
    required String roomToken,
    required String title,
    required String body,
  }) {
    return _channel.invokeMethod<bool>('show', {
      'accountId': accountId,
      'roomToken': roomToken,
      'title': title,
      'body': body,
    });
  }

  Future<Object?> _handleNativeCall(MethodCall call) async {
    final args = call.arguments is Map
        ? Map<Object?, Object?>.from(call.arguments as Map)
        : null;
    final accountId = args?['accountId'] as String?;
    final roomToken = args?['roomToken'] as String?;
    if (accountId == null ||
        accountId.isEmpty ||
        roomToken == null ||
        roomToken.isEmpty) {
      return false;
    }
    switch (call.method) {
      case 'notificationOpened':
        if (_pendingOpens.length == 32) {
          _pendingOpens.removeAt(0);
        }
        _pendingOpens.add(
          WindowsNotificationOpen(accountId: accountId, roomToken: roomToken),
        );
        _notificationOpenedController.add(null);
        return true;
      case 'notificationAction':
        final kind = args?['kind'] as String?;
        if (kind != 'reply' && kind != 'markRead') {
          return false;
        }
        await _onNotificationAction?.call(
          kind: kind!,
          accountId: accountId,
          roomToken: roomToken,
          replyText: args?['replyText'] as String?,
        );
        return true;
      default:
        return false;
    }
  }

  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    _pendingOpens.clear();
    await _notificationOpenedController.close();
  }
}

typedef WindowsNotificationActionHandler =
    Future<void> Function({
      required String kind,
      required String accountId,
      required String roomToken,
      String? replyText,
    });

final class WindowsNotificationOpen {
  const WindowsNotificationOpen({
    required this.accountId,
    required this.roomToken,
  });

  final String accountId;
  final String roomToken;
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

  WindowsNotificationChannel get channel => _channel;

  /// Starts notifying for [accountId] on [serverUrl].
  ///
  /// The first emission only records the current counts. Announcing them would
  /// mean a burst of notifications for everything unread at startup.
  void follow(String accountId) {
    if (_watched.containsKey(accountId)) {
      return;
    }
    _watched[accountId] = _accounts
        .watchConversations(accountId)
        .listen(
          (conversations) => _apply(accountId, conversations),
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
    await _channel.dispose();
  }

  void _apply(String accountId, List<CachedConversation> conversations) {
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
              accountId: accountId,
              roomToken: conversation.token,
              title: conversation.displayName,
              body: body,
            )
            .catchError((Object _) {}),
      );
    }
  }
}
