// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  }) : _channel = channel ?? MethodChannel(resolveChannelName()),
       _onNotificationAction = onNotificationAction {
    // macOS shares the push channel, whose handler belongs to
    // ApplePushCoordinator: taps and actions on a local notification arrive
    // through the same route store as a push one, so installing a second
    // handler here would only unhook the first. The channel decides that, not
    // the host: a caller that names its own channel owns it on every platform.
    if (!_sharesApplePushChannel) {
      _channel.setMethodCallHandler(_handleNativeCall);
    }
  }

  static const channelName = 'com.nkshub.nextcloudtalk/windows_notification';

  /// macOS has no channel of its own; it raises local notifications through
  /// the Apple push channel, which already owns the notification categories.
  static const macosChannelName = 'com.nkshub.nextcloudtalk/apple_push';

  static String resolveChannelName() =>
      Platform.isMacOS ? macosChannelName : channelName;

  final MethodChannel _channel;

  bool get _sharesApplePushChannel => _channel.name == macosChannelName;

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
    int? messageId,
  }) {
    return _channel.invokeMethod<bool>(
      Platform.isMacOS ? 'showLocalNotification' : 'show',
      {
        'accountId': accountId,
        'roomToken': roomToken,
        'title': title,
        'body': body,
        'messageId': ?messageId,
      },
    );
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
        final messageId = args?['messageId'];
        await _onNotificationAction?.call(
          kind: kind!,
          accountId: accountId,
          roomToken: roomToken,
          replyText: args?['replyText'] as String?,
          messageId: messageId is int && messageId > 0 ? messageId : null,
        );
        return true;
      default:
        return false;
    }
  }

  Future<void> dispose() async {
    // Only ever unhook a handler this channel installed - clearing the shared
    // Apple push channel would take ApplePushCoordinator's routing with it.
    if (!_sharesApplePushChannel) {
      _channel.setMethodCallHandler(null);
    }
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
      int? messageId,
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
              messageId: _lastMessageId(conversation),
            )
            .catchError((Object _) {}),
      );
    }
  }

  /// Id of the message the notification shows, so a reply can quote it. The
  /// cached row keeps the room's raw JSON; anything unexpected is simply no
  /// quote.
  static int? _lastMessageId(CachedConversation conversation) {
    try {
      final room = jsonDecode(conversation.rawJson);
      final last = room is Map<String, Object?> ? room['lastMessage'] : null;
      final id = last is Map<String, Object?> ? last['id'] : null;
      return id is int && id > 0 ? id : null;
    } on FormatException {
      return null;
    }
  }
}
