import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../app_providers.dart';
import '../../data/app_database.dart';
import '../../data/conversation_avatar_repository.dart';
import '../../l10n/generated/app_localizations.dart';

final class ChatParticipantAvatar extends ConsumerWidget {
  const ChatParticipantAvatar({
    super.key,
    required this.account,
    required this.actorType,
    required this.actorId,
    required this.displayName,
    this.size = 32,
  }) : assert(size > 0);

  final StoredAccount account;
  final String actorType;
  final String actorId;
  final String displayName;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final normalizedActorType = actorType.trim().toLowerCase();
    final normalizedActorId = actorId.trim();
    final normalizedDisplayName = _normalizeDisplayName(displayName);
    final strings =
        Localizations.of<AppLocalizations>(context, AppLocalizations) ??
        lookupAppLocalizations(Localizations.localeOf(context));
    final semanticsLabel = chatParticipantSemanticsLabel(
      actorType: normalizedActorType,
      displayName: normalizedDisplayName,
      strings: strings,
    );
    final fallback = _ParticipantFallback(
      actorType: normalizedActorType,
      displayName: normalizedDisplayName,
      size: size,
    );

    Widget avatar = fallback;
    if (normalizedActorType == 'users' && normalizedActorId.isNotEmpty) {
      final dark = Theme.of(context).brightness == Brightness.dark;
      final server = ServerBase.parse(account.serverUrl);
      final uri = server.uri.replace(
        pathSegments: [
          ...server.uri.pathSegments,
          'index.php',
          'avatar',
          normalizedActorId,
          '64',
          if (dark) 'dark',
        ],
      );
      final image = ref.watch(
        conversationAvatarProvider(
          ConversationAvatarProviderKey(
            account: account,
            uri: uri,
            versioned: false,
          ),
        ),
      );
      avatar = _NetworkParticipantAvatar(
        image: image,
        fallback: fallback,
        size: size,
      );
    }

    return Semantics(
      image: true,
      label: semanticsLabel,
      child: ExcludeSemantics(child: avatar),
    );
  }
}

String chatParticipantSemanticsLabel({
  required String actorType,
  required String displayName,
  required AppLocalizations strings,
}) {
  final normalizedDisplayName = _normalizeDisplayName(displayName);
  if (normalizedDisplayName.isNotEmpty) {
    return normalizedDisplayName;
  }
  return _fallbackSemanticsLabel(actorType.trim().toLowerCase(), strings);
}

final class _NetworkParticipantAvatar extends StatelessWidget {
  const _NetworkParticipantAvatar({
    required this.image,
    required this.fallback,
    required this.size,
  });

  final AsyncValue<ConversationAvatarImage?> image;
  final Widget fallback;
  final double size;

  @override
  Widget build(BuildContext context) {
    final loaded = image.asData?.value;
    if (loaded == null) {
      return fallback;
    }

    final content = loaded.contentType == 'image/svg+xml'
        ? SvgPicture.memory(
            loaded.body,
            fit: BoxFit.cover,
            placeholderBuilder: (_) => fallback,
          )
        : Image.memory(
            loaded.body,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
            cacheHeight: (size * MediaQuery.devicePixelRatioOf(context))
                .round(),
            errorBuilder: (_, _, _) => fallback,
          );
    return ClipOval(
      child: SizedBox.square(dimension: size, child: content),
    );
  }
}

final class _ParticipantFallback extends StatelessWidget {
  const _ParticipantFallback({
    required this.actorType,
    required this.displayName,
    required this.size,
  });

  final String actorType;
  final String displayName;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final icon = _iconForActorType(actorType);
    final initials = icon == null ? _initials(displayName) : '';
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: scheme.secondaryContainer,
      foregroundColor: scheme.onSecondaryContainer,
      child: icon != null || initials.isEmpty
          ? Icon(icon ?? Icons.person_rounded, size: size * 0.55)
          : Text(
              initials,
              maxLines: 1,
              style: TextStyle(
                color: scheme.onSecondaryContainer,
                fontSize: size * 0.38,
                fontWeight: FontWeight.w700,
                height: 1,
              ),
            ),
    );
  }
}

IconData? _iconForActorType(String actorType) {
  return switch (actorType) {
    'guests' || 'guest' => Icons.person_outline_rounded,
    'bots' || 'bot' => Icons.smart_toy_rounded,
    'bridged' || 'bridge' => Icons.cable_rounded,
    'system' => Icons.campaign_rounded,
    _ => null,
  };
}

String _normalizeDisplayName(String displayName) {
  return displayName.trim().replaceAll(RegExp(r'\s+'), ' ');
}

String _initials(String displayName) {
  if (displayName.isEmpty) {
    return '';
  }
  final words = displayName.split(' ');
  final first = String.fromCharCode(words.first.runes.first).toUpperCase();
  if (words.length == 1) {
    return first;
  }
  final last = String.fromCharCode(words.last.runes.first).toUpperCase();
  return '$first$last';
}

String _fallbackSemanticsLabel(String actorType, AppLocalizations strings) {
  return switch (actorType) {
    'guests' || 'guest' => strings.participantAvatarGuest,
    'bots' || 'bot' => strings.participantAvatarBot,
    'bridged' || 'bridge' => strings.participantAvatarBridge,
    'system' => strings.participantAvatarSystem,
    _ => strings.participantAvatarUnknown,
  };
}
