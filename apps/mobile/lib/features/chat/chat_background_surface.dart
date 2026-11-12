import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../owntalk_extensions/chat_appearance.dart';
import '../owntalk_extensions/owntalk_room_extras.dart';
import 'chat_background_store.dart';
import 'chat_background_theme.dart';

final chatBackgroundStoreProvider = FutureProvider<ChatBackgroundStore>((
  ref,
) async {
  final store = await ChatBackgroundStore.openApplicationSupport();
  ref.onDispose(() => unawaited(store.close()));
  return store;
});

final chatBackgroundProvider = StreamProvider.autoDispose
    .family<String?, ChatBackgroundKey>((ref, key) async* {
      final store = await ref.watch(chatBackgroundStoreProvider.future);
      yield* store.watch(key);
    });

final class ChatBackgroundSurface extends ConsumerWidget {
  const ChatBackgroundSurface({
    super.key,
    required this.accountId,
    required this.roomToken,
    required this.sharedSettings,
    required this.child,
  });

  final String accountId;
  final String roomToken;

  /// Whether the conversation may carry shared settings; when false the
  /// extension is neither asked nor applied.
  final bool sharedSettings;
  final Widget child;

  /// Background precedence: this device's own colour, then the colour shared
  /// by the conversation, then the theme. Every layer goes through the same
  /// contrast fallback.
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = (accountId: accountId, roomToken: roomToken);
    final stored = ref.watch(chatBackgroundProvider(key)).valueOrNull;
    final shared = sharedSettings
        ? ref.watch(ownTalkRoomExtrasProvider(key))
        : OwnTalkRoomExtras.none;
    final scheme = Theme.of(context).colorScheme;
    final requested =
        parseChatBackgroundColor(stored) ??
        parseChatBackgroundColor(
          shared.valueOf(OwnTalkSettingField.chatBackgroundColor),
        );
    final background = requested == null
        ? scheme.surface
        : safeChatBackground(requested, scheme);
    return SharedChatAppearance.fromExtras(
      shared,
      child: Material(
        key: const Key('chat-background-surface'),
        color: background,
        child: child,
      ),
    );
  }
}
