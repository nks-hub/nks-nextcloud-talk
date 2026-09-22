// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:talk_protocol/talk_protocol.dart';

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
      // Picked from the channel, not the host: the Apple side answers
      // `showLocalNotification` on its shared channel, the Windows side
      // answers `show` on its own. Deciding by `Platform.isMacOS` sent the
      // Apple method down a Windows channel whenever a caller named one.
      _sharesApplePushChannel ? 'showLocalNotification' : 'show',
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

/// Displays only notifications approved by the server, not unread counts.
final class WindowsNotificationService {
  WindowsNotificationService({
    required AccountRepository accounts,
    required WindowsNotificationChannel channel,
    required Future<List<Map<String, Object?>>?> Function(
      String accountId,
      Future<void> abortTrigger,
    )
    fetchNotifications,
  }) : _accounts = accounts,
       _channel = channel,
       _fetchNotifications = fetchNotifications;

  final AccountRepository _accounts;
  final WindowsNotificationChannel _channel;
  final Future<List<Map<String, Object?>>?> Function(
    String accountId,
    Future<void> abortTrigger,
  )
  _fetchNotifications;
  final Map<String, _DesktopNotificationAccount> _watched = {};

  WindowsNotificationChannel get channel => _channel;

  Future<void> follow(String accountId) {
    if (_watched.containsKey(accountId)) return refresh(accountId);
    final account = _DesktopNotificationAccount();
    _watched[accountId] = account;
    account.subscription = _accounts
        .watchConversations(accountId)
        .listen(
          (_) => unawaited(refresh(accountId)),
          onError: (Object _, StackTrace _) {},
        );
    // A room sync can arrive before the server stores its notification.
    account.timer = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(refresh(accountId));
    });
    return refresh(accountId);
  }

  Future<void> refresh(String accountId) {
    final account = _watched[accountId];
    if (account == null) return Future<void>.value();
    return account.refreshing ??= _refresh(accountId, account).whenComplete(() {
      account.refreshing = null;
    });
  }

  Future<void> _refresh(
    String accountId,
    _DesktopNotificationAccount account,
  ) async {
    try {
      final notifications = await _fetchNotifications(
        accountId,
        account.cancelled.future,
      );
      if (!identical(_watched[accountId], account) || notifications == null) {
        return;
      }
      final previous = account.highestId;
      var highest = previous ?? 0;
      for (final notification in notifications) {
        final id = notification['notification_id'];
        if (id is int && id > highest) highest = id;
      }
      account.highestId = highest;
      // The first successful fetch records old notifications without showing them.
      if (previous == null) return;
      final seen = <int>{};
      for (final notification in notifications.reversed) {
        if (!identical(_watched[accountId], account)) return;
        final id = notification['notification_id'];
        if (id is! int ||
            id <= previous ||
            !seen.add(id) ||
            notification['app'] != 'spreed' ||
            notification['object_type'] != 'chat' ||
            notification['shouldNotify'] == false) {
          continue;
        }
        final objectId = notification['object_id'];
        final title = notification['subject'];
        final body = notification['message'];
        if (objectId is! String || title is! String || body is! String) {
          continue;
        }
        final parts = objectId.split('/');
        final String roomToken;
        try {
          roomToken = ConversationToken.parse(
            parts.first,
            path: 'notification.object_id',
          ).value;
        } on TalkProtocolException {
          continue;
        }
        final messageId = parts.length > 1 ? int.tryParse(parts[1]) : null;
        await _channel.show(
          accountId: accountId,
          roomToken: roomToken,
          title: title,
          body: body,
          messageId: messageId != null && messageId > 0 ? messageId : null,
        );
      }
    } on Object {
      // Failed requests never fall back to unread counts. The next sync retries.
    }
  }

  Future<void> unfollow(String accountId) async {
    final account = _watched.remove(accountId);
    if (account == null) return;
    account.cancelled.complete();
    account.timer?.cancel();
    await account.subscription?.cancel();
  }

  Future<void> dispose() async {
    for (final accountId in _watched.keys.toList(growable: false)) {
      await unfollow(accountId);
    }
    await _channel.dispose();
  }
}

final class _DesktopNotificationAccount {
  final cancelled = Completer<void>();
  StreamSubscription<List<CachedConversation>>? subscription;
  Timer? timer;
  Future<void>? refreshing;
  int? highestId;
}
