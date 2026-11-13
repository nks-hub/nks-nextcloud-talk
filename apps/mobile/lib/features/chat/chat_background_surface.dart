import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../owntalk_extensions/chat_appearance.dart';
import '../owntalk_extensions/owntalk_image_cache.dart';
import '../owntalk_extensions/owntalk_room_extras.dart';
import 'chat_background_store.dart';
import 'chat_background_theme.dart';
import 'chat_wallpaper.dart';

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

  /// Background precedence: this device's own colour, then the photo shared by
  /// the conversation, then its wallpaper, then its colour, then the theme.
  /// Colours and wallpapers go through the same contrast fallback and a photo
  /// is veiled. While a photo loads, or when it cannot, the layers beneath it
  /// show.
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = (accountId: accountId, roomToken: roomToken);
    final stored = ref.watch(chatBackgroundProvider(key)).valueOrNull;
    final shared = sharedSettings
        ? ref.watch(ownTalkRoomExtrasProvider(key))
        : OwnTalkRoomExtras.none;
    final scheme = Theme.of(context).colorScheme;
    final local = parseChatBackgroundColor(stored);
    final requested =
        local ??
        parseChatBackgroundColor(
          shared.valueOf(OwnTalkSettingField.chatBackgroundColor),
        );
    final background = requested == null
        ? scheme.surface
        : safeChatBackground(requested, scheme);
    // A colour of this device hides the shared layers, so their photo is not
    // even downloaded.
    final wallpaper = local == null ? _sharedWallpaper(ref, shared) : null;
    return SharedChatAppearance.fromExtras(
      shared,
      child: Material(
        key: const Key('chat-background-surface'),
        color: background,
        // The layer slot stays in the tree whether or not there is a
        // wallpaper, so the chat below keeps its state when one appears.
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            Positioned.fill(
              child: wallpaper == null
                  ? const SizedBox.shrink()
                  : RepaintBoundary(
                      child: ExcludeSemantics(
                        child: IgnorePointer(child: wallpaper),
                      ),
                    ),
            ),
            ChatWallpaperScope(active: wallpaper != null, child: child),
          ],
        ),
      ),
    );
  }

  Widget? _sharedWallpaper(WidgetRef ref, OwnTalkRoomExtras shared) {
    final preset = chatWallpaperPresetById(
      shared.valueOf(OwnTalkSettingField.chatBackgroundPreset),
    );
    final sha = shared.valueOf(OwnTalkSettingField.chatBackgroundImage);
    final bytes = sha == null
        ? null
        : ref
              .watch(
                ownTalkRoomImageProvider((
                  accountId: accountId,
                  roomToken: roomToken,
                  sha256: sha,
                )),
              )
              .valueOrNull;
    if (preset == null && bytes == null) {
      return null;
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        if (preset != null)
          ChatWallpaper(
            key: const Key('chat-wallpaper-preset'),
            preset: preset,
          ),
        if (bytes != null)
          ChatWallpaperPhoto(
            key: const Key('chat-wallpaper-photo'),
            bytes: bytes,
          ),
      ],
    );
  }
}
