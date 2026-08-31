import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
    required this.child,
  });

  final String accountId;
  final String roomToken;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = (accountId: accountId, roomToken: roomToken);
    final stored = ref.watch(chatBackgroundProvider(key)).valueOrNull;
    final scheme = Theme.of(context).colorScheme;
    final requested = parseChatBackgroundColor(stored);
    final background = requested == null
        ? scheme.surface
        : safeChatBackground(requested, scheme);
    return ColoredBox(
      key: const Key('chat-background-surface'),
      color: background,
      child: child,
    );
  }
}
