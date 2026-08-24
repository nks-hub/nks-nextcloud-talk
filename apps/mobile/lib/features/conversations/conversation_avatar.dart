import 'package:talk_protocol/talk_protocol.dart';

abstract final class ConversationRoomType {
  static const int direct = 1;
  static const int group = 2;
  static const int public = 3;
  static const int system = 4;
  static const int formerDirect = 5;
  static const int noteToSelf = 6;
}

enum ConversationAvatarIcon {
  user,
  group,
  publicLink,
  system,
  noteToSelf,
  lock,
  file,
}

sealed class ConversationAvatarSource {
  const ConversationAvatarSource();
}

final class LocalConversationAvatar extends ConversationAvatarSource {
  const LocalConversationAvatar(this.icon);

  final ConversationAvatarIcon icon;

  @override
  bool operator ==(Object other) =>
      other is LocalConversationAvatar && other.icon == icon;

  @override
  int get hashCode => icon.hashCode;
}

final class NetworkConversationAvatar extends ConversationAvatarSource {
  const NetworkConversationAvatar({
    required this.uri,
    required this.versioned,
    required this.fallback,
  });

  final Uri uri;
  final bool versioned;
  final ConversationAvatarIcon fallback;
}

ConversationAvatarSource resolveConversationAvatar({
  required ServerBase server,
  required Set<String> talkFeatures,
  required String roomToken,
  required int roomType,
  required String roomName,
  required String objectType,
  required String avatarVersion,
  required bool dark,
  bool federated = false,
}) {
  if (objectType == 'share:password') {
    return const LocalConversationAvatar(ConversationAvatarIcon.lock);
  }
  if (objectType == 'file') {
    return const LocalConversationAvatar(ConversationAvatarIcon.file);
  }
  if (roomType == ConversationRoomType.system) {
    return const LocalConversationAvatar(ConversationAvatarIcon.system);
  }
  if (roomType == ConversationRoomType.noteToSelf) {
    return const LocalConversationAvatar(ConversationAvatarIcon.noteToSelf);
  }

  final fallback = _fallbackForRoomType(roomType);
  if (roomType == ConversationRoomType.direct &&
      !federated &&
      roomName.isNotEmpty) {
    return NetworkConversationAvatar(
      uri: _userAvatarUri(server: server, roomName: roomName, dark: dark),
      versioned: false,
      fallback: fallback,
    );
  }
  if (talkFeatures.contains('avatar')) {
    if (roomType == ConversationRoomType.direct) {
      return NetworkConversationAvatar(
        uri: _conversationAvatarUri(
          server: server,
          roomToken: roomToken,
          dark: dark,
        ),
        versioned: false,
        fallback: fallback,
      );
    }
    if (avatarVersion.isNotEmpty) {
      return NetworkConversationAvatar(
        uri: _conversationAvatarUri(
          server: server,
          roomToken: roomToken,
          dark: dark,
          avatarVersion: avatarVersion,
        ),
        versioned: true,
        fallback: fallback,
      );
    }
  }

  if (roomType == ConversationRoomType.direct ||
      roomType == ConversationRoomType.formerDirect) {
    return NetworkConversationAvatar(
      uri: _userAvatarUri(server: server, roomName: roomName, dark: dark),
      versioned: false,
      fallback: fallback,
    );
  }
  return LocalConversationAvatar(fallback);
}

ConversationAvatarIcon _fallbackForRoomType(int roomType) {
  return switch (roomType) {
    ConversationRoomType.group => ConversationAvatarIcon.group,
    ConversationRoomType.public => ConversationAvatarIcon.publicLink,
    ConversationRoomType.system => ConversationAvatarIcon.system,
    ConversationRoomType.noteToSelf => ConversationAvatarIcon.noteToSelf,
    _ => ConversationAvatarIcon.user,
  };
}

Uri _conversationAvatarUri({
  required ServerBase server,
  required String roomToken,
  required bool dark,
  String? avatarVersion,
}) {
  return server.uri.replace(
    pathSegments: [
      ...server.uri.pathSegments,
      'ocs',
      'v2.php',
      'apps',
      'spreed',
      'api',
      'v1',
      'room',
      roomToken,
      'avatar',
      if (dark) 'dark',
    ],
    queryParameters: avatarVersion == null
        ? null
        : {'avatarVersion': avatarVersion},
  );
}

Uri _userAvatarUri({
  required ServerBase server,
  required String roomName,
  required bool dark,
}) {
  return server.uri.replace(
    pathSegments: [
      ...server.uri.pathSegments,
      'index.php',
      'avatar',
      roomName,
      '64',
      if (dark) 'dark',
    ],
  );
}
