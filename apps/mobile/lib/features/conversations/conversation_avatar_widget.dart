import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../app_providers.dart';
import '../../data/app_database.dart';
import '../../data/conversation_avatar_repository.dart';
import '../../core/desktop_metrics.dart';
import '../calls/call_state.dart';
import 'conversation_avatar.dart';

final class ConversationAvatar extends ConsumerWidget {
  const ConversationAvatar({
    super.key,
    required this.account,
    required this.conversation,
    this.radius,
  });

  final StoredAccount account;
  final CachedConversation conversation;

  /// Defaults to the platform's list avatar size when omitted.
  final double? radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final radius = this.radius ?? context.listAvatarRadius;
    final source = resolveConversationAvatar(
      server: ServerBase.parse(account.serverUrl),
      talkFeatures: _talkFeatures[account] ??= _decodeTalkFeatures(
        account.talkFeaturesJson,
      ),
      roomToken: conversation.token,
      roomType: conversation.roomType,
      roomName: conversation.roomName,
      objectType: conversation.objectType,
      avatarVersion: conversation.avatarVersion,
      dark: dark,
      federated: _isFederatedConversation(conversation),
    );
    return Semantics(
      image: true,
      label: conversation.displayName,
      child: ExcludeSemantics(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius * 0.52),
          child: SizedBox.square(
            dimension: radius * 2,
            child: switch (source) {
              LocalConversationAvatar(:final icon) => _LocalAvatar(
                icon: icon,
                displayName: conversation.displayName,
                roomToken: conversation.token,
                radius: radius,
              ),
              NetworkConversationAvatar() => _NetworkAvatar(
                source: source,
                image: ref.watch(
                  conversationAvatarProvider(
                    ConversationAvatarProviderKey(
                      account: account,
                      uri: source.uri,
                      versioned: source.versioned,
                    ),
                  ),
                ),
                displayName: conversation.displayName,
                roomToken: conversation.token,
                radius: radius,
              ),
            },
          ),
        ),
      ),
    );
  }
}

final class _NetworkAvatar extends StatelessWidget {
  const _NetworkAvatar({
    required this.source,
    required this.image,
    required this.displayName,
    required this.roomToken,
    required this.radius,
  });

  final NetworkConversationAvatar source;
  final AsyncValue<ConversationAvatarImage?> image;
  final String displayName;
  final String roomToken;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final loaded = image.valueOrNull;
    final fallback = _LocalAvatar(
      icon: source.fallback,
      displayName: displayName,
      roomToken: roomToken,
      radius: radius,
    );
    if (loaded == null || loaded.isCustomAvatar == false) {
      return fallback;
    }
    return loaded.contentType == 'image/svg+xml'
        ? SvgPicture.memory(
            loaded.body,
            fit: BoxFit.cover,
            placeholderBuilder: (_) => fallback,
          )
        : Image.memory(
            loaded.body,
            fit: BoxFit.cover,
            // Avatars are square, so the width alone bounds the decode.
            cacheWidth: (radius * 2 * MediaQuery.devicePixelRatioOf(context))
                .round(),
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => fallback,
          );
  }
}

final class _LocalAvatar extends StatelessWidget {
  const _LocalAvatar({
    required this.icon,
    required this.displayName,
    required this.roomToken,
    required this.radius,
  });

  final ConversationAvatarIcon icon;
  final String displayName;
  final String roomToken;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (icon == ConversationAvatarIcon.group) {
      const covers = ['folds', 'knot', 'stripes'];
      final index = roomToken.codeUnits.fold(
        0,
        (value, unit) => (value * 31 + unit) % covers.length,
      );
      return Image.asset(
        'assets/rooms/${covers[index]}.webp',
        fit: BoxFit.cover,
      );
    }
    final initials = icon == ConversationAvatarIcon.user
        ? _initials(displayName)
        : '';
    return ColoredBox(
      color: scheme.primaryContainer,
      child: Center(
        child: initials.isEmpty
            ? Icon(
                _iconData(icon),
                size: radius,
                color: scheme.onPrimaryContainer,
              )
            : Padding(
                padding: EdgeInsets.all(radius * 0.2),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    initials,
                    maxLines: 1,
                    style: TextStyle(
                      color: scheme.onPrimaryContainer,
                      fontSize: radius * 0.8,
                      fontWeight: FontWeight.w700,
                      height: 1,
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}

IconData _iconData(ConversationAvatarIcon icon) {
  return switch (icon) {
    ConversationAvatarIcon.user => Icons.person_rounded,
    ConversationAvatarIcon.group => Icons.group_rounded,
    ConversationAvatarIcon.publicLink => Icons.link_rounded,
    ConversationAvatarIcon.system => Icons.campaign_rounded,
    ConversationAvatarIcon.noteToSelf => Icons.edit_note_rounded,
    ConversationAvatarIcon.lock => Icons.lock_rounded,
    ConversationAvatarIcon.file => Icons.insert_drive_file_rounded,
  };
}

// Every list row asks for the same account's features on every build.
final _talkFeatures = Expando<Set<String>>();

Set<String> _decodeTalkFeatures(String source) {
  try {
    final decoded = jsonDecode(source);
    if (decoded is List<Object?> && decoded.every((value) => value is String)) {
      return decoded.cast<String>().toSet();
    }
  } on FormatException {
    // A corrupt local capability cache falls back to capability-free behavior.
  }
  return const {};
}

bool _isFederatedConversation(CachedConversation conversation) {
  // Invalid room JSON decodes to nothing here; the account repository handles
  // it on the next sync.
  final remoteServer = decodedConversationJson(conversation)['remoteServer'];
  return remoteServer is String && remoteServer.trim().isNotEmpty;
}

String _initials(String displayName) {
  final words = displayName
      .trim()
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .toList(growable: false);
  if (words.isEmpty) {
    return '';
  }
  final first = String.fromCharCode(words.first.runes.first).toUpperCase();
  if (words.length == 1) {
    return first;
  }
  final last = String.fromCharCode(words.last.runes.first).toUpperCase();
  return '$first$last';
}
