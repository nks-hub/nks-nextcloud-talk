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
    this.header,
  });

  final String accountId;
  final String roomToken;

  /// Whether the conversation may carry shared settings; when false the
  /// extension is neither asked nor applied.
  final bool sharedSettings;
  final Widget child;

  /// The conversation header, laid out above [child] on the same background
  /// so a colour, wallpaper or photo reaches up behind it. `tinted` is true
  /// when something other than the theme surface is behind the header; it
  /// should then leave its own background transparent.
  final Widget Function(BuildContext context, bool tinted)? header;

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
    final layer = Positioned.fill(
      child: wallpaper == null
          ? const SizedBox.shrink()
          : RepaintBoundary(
              child: ExcludeSemantics(child: IgnorePointer(child: wallpaper)),
            ),
    );
    final chat = ChatWallpaperScope(active: wallpaper != null, child: child);
    final header = this.header;
    return SharedChatAppearance.fromExtras(
      shared,
      child: Material(
        key: const Key('chat-background-surface'),
        color: background,
        // The layer slot stays in the tree whether or not there is a
        // wallpaper, so the chat below keeps its state when one appears.
        child: header == null
            ? Stack(fit: StackFit.passthrough, children: [layer, chat])
            : Stack(
                fit: StackFit.expand,
                children: [
                  layer,
                  Column(
                    children: [
                      _HeaderVeil(
                        // A photo can be anything; the header text gets the
                        // same protection as text on a chip.
                        alpha: _hasPhoto(ref, shared, local)
                            ? wallpaperChipAlpha(scheme)
                            : wallpaper != null
                            ? 0.35
                            : 0,
                        child: header(
                          context,
                          requested != null || wallpaper != null,
                        ),
                      ),
                      Expanded(child: chat),
                    ],
                  ),
                ],
              ),
      ),
    );
  }

  bool _hasPhoto(WidgetRef ref, OwnTalkRoomExtras shared, Color? local) {
    final sha = shared.valueOf(OwnTalkSettingField.chatBackgroundImage);
    return local == null &&
        sha != null &&
        ref
                .watch(
                  ownTalkRoomImageProvider((
                    accountId: accountId,
                    roomToken: roomToken,
                    sha256: sha,
                  )),
                )
                .valueOrNull !=
            null;
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

/// A veil of the theme surface at [alpha] behind the header.
final class _HeaderVeil extends StatelessWidget {
  const _HeaderVeil({required this.alpha, required this.child});

  final double alpha;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (alpha == 0) {
      return child;
    }
    return ColoredBox(
      key: const Key('chat-header-veil'),
      color: Theme.of(context).colorScheme.surface.withValues(alpha: alpha),
      child: child,
    );
  }
}
