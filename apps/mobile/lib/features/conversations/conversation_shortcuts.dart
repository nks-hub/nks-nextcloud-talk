import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../app_providers.dart';
import '../../data/app_database.dart';
import '../settings/app_lock/app_lock_controller.dart';

/// One launcher shortcut standing for a recently active conversation.
///
/// The payload is only ever the room's public deep link. Nothing
/// account-scoped leaves the app: the launcher hands the link back the way a
/// browser would and [DeepLinkResolver] decides which signed-in account, if
/// any, may open it.
@immutable
final class ConversationShortcut {
  const ConversationShortcut({
    required this.id,
    required this.label,
    required this.uri,
  });

  final String id;
  final String label;
  final Uri uri;

  Map<String, Object?> toMap() => <String, Object?>{
    'id': id,
    'label': label,
    'uri': uri.toString(),
  };

  @override
  bool operator ==(Object other) =>
      other is ConversationShortcut &&
      other.id == id &&
      other.label == label &&
      other.uri == uri;

  @override
  int get hashCode => Object.hash(id, label, uri);

  @override
  String toString() => 'ConversationShortcut($id, $label, $uri)';
}

/// How many shortcuts are offered at most. Launchers cap the list themselves
/// — the platform side asks the system for its own limit and trims again —
/// but ranking has to stop somewhere and four is what a long press shows.
const kMaxConversationShortcuts = 4;

/// Ranks the conversations of every signed-in account by last activity and
/// turns the busiest ones into launcher shortcuts.
///
/// An account whose stored server address no longer parses is skipped rather
/// than guessed at, which keeps every emitted link resolvable by the same
/// origin check that guards incoming links.
List<ConversationShortcut> conversationShortcuts({
  required List<StoredAccount> accounts,
  required Map<String, List<CachedConversation>> conversations,
  int limit = kMaxConversationShortcuts,
}) {
  final ranked = <({int lastActivity, ConversationShortcut shortcut})>[];
  for (final account in accounts) {
    final ServerBase server;
    try {
      server = ServerBase.parse(account.serverUrl);
    } on TalkProtocolException {
      continue;
    }
    for (final room in conversations[account.id] ?? const <CachedConversation>[]) {
      if (room.isArchived || room.token.isEmpty) {
        continue;
      }
      final label = room.displayName.trim();
      ranked.add((
        lastActivity: room.lastActivity,
        shortcut: ConversationShortcut(
          id: '${account.id}|${room.token}',
          label: label.isEmpty ? room.token : label,
          uri: server.uri.replace(
            path: '${server.basePath}/index.php/call/${room.token}',
          ),
        ),
      ));
    }
  }
  ranked.sort((a, b) {
    final byActivity = b.lastActivity.compareTo(a.lastActivity);
    return byActivity != 0 ? byActivity : a.shortcut.id.compareTo(b.shortcut.id);
  });
  return <ConversationShortcut>[
    for (final entry in ranked.take(limit < 0 ? 0 : limit)) entry.shortcut,
  ];
}

/// Hands a shortcut set to the platform launcher.
final class ConversationShortcutPublisher {
  ConversationShortcutPublisher({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'com.nkshub.nextcloudtalk/shortcuts';

  final MethodChannel _channel;

  Future<void> publish(List<ConversationShortcut> shortcuts) async {
    try {
      await _channel.invokeMethod<Object?>('publish', <String, Object?>{
        'shortcuts': <Map<String, Object?>>[
          for (final shortcut in shortcuts) shortcut.toMap(),
        ],
      });
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }
}

final conversationShortcutPublisherProvider =
    Provider<ConversationShortcutPublisher>(
      (ref) => ConversationShortcutPublisher(),
    );

/// Keeps the launcher's shortcut list in step with the conversation cache.
///
/// Mounted outside the app lock gate on purpose: a locked app has to be able
/// to take its conversation names back off the launcher, which it cannot do
/// from behind a gate that stops building its child.
final class ConversationShortcutsHost extends ConsumerStatefulWidget {
  const ConversationShortcutsHost({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<ConversationShortcutsHost> createState() =>
      _ConversationShortcutsHostState();
}

class _ConversationShortcutsHostState
    extends ConsumerState<ConversationShortcutsHost> {
  List<ConversationShortcut>? _published;
  var _scheduled = false;

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return widget.child;
    }
    final accounts =
        ref.watch(accountsProvider).valueOrNull ?? const <StoredAccount>[];
    // A locked app must not spell its conversation names out on a launcher
    // that needs no authentication to be long-pressed.
    final locked = ref.watch(appLockControllerProvider).enabled;
    final conversations = <String, List<CachedConversation>>{
      for (final account in accounts)
        account.id:
            ref.watch(conversationsProvider(account.id)).valueOrNull ??
            const <CachedConversation>[],
    };
    _schedule(
      locked
          ? const <ConversationShortcut>[]
          : conversationShortcuts(
              accounts: accounts,
              conversations: conversations,
            ),
    );
    return widget.child;
  }

  void _schedule(List<ConversationShortcut> next) {
    final published = _published;
    if (published != null && listEquals(published, next)) {
      return;
    }
    _published = next;
    if (_scheduled) {
      return;
    }
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      final pending = _published;
      if (!mounted || pending == null) {
        return;
      }
      unawaited(
        ref.read(conversationShortcutPublisherProvider).publish(pending),
      );
    });
  }
}
