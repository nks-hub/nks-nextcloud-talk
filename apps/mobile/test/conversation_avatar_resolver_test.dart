import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/conversations/conversation_avatar.dart';
import 'package:talk_protocol/talk_protocol.dart';

void main() {
  final server = ServerBase.parse('https://cloud.example.invalid/nextcloud');

  test('group room uses a versioned light conversation avatar', () {
    final source = resolveConversationAvatar(
      server: server,
      talkFeatures: const {'avatar'},
      roomToken: 'room-a',
      roomType: ConversationRoomType.group,
      roomName: 'synthetic-room-a',
      objectType: '',
      avatarVersion: '5',
      dark: false,
    );

    expect(source, isA<NetworkConversationAvatar>());
    final network = source as NetworkConversationAvatar;
    expect(network.versioned, isTrue);
    expect(
      network.uri.toString(),
      'https://cloud.example.invalid/nextcloud/'
      'ocs/v2.php/apps/spreed/api/v1/room/room-a/avatar'
      '?avatarVersion=5',
    );
  });

  test('local direct room uses the custom-aware user avatar endpoint', () {
    for (final version in ['', '7']) {
      final source =
          resolveConversationAvatar(
                server: server,
                talkFeatures: const {'avatar'},
                roomToken: 'room-a',
                roomType: ConversationRoomType.direct,
                roomName: 'peer name',
                objectType: '',
                avatarVersion: version,
                dark: true,
              )
              as NetworkConversationAvatar;

      expect(source.versioned, isFalse);
      expect(
        source.uri.path,
        endsWith('/index.php/avatar/peer%20name/64/dark'),
      );
      expect(source.uri.queryParameters, isEmpty);
    }
  });

  test('federated direct room keeps the Talk avatar proxy', () {
    final source =
        resolveConversationAvatar(
              server: server,
              talkFeatures: const {'avatar'},
              roomToken: 'room-a',
              roomType: ConversationRoomType.direct,
              roomName: 'peer@remote.example.invalid',
              objectType: '',
              avatarVersion: '',
              dark: true,
              federated: true,
            )
            as NetworkConversationAvatar;

    expect(source.versioned, isFalse);
    expect(source.uri.path, endsWith('/room/room-a/avatar/dark'));
    expect(source.uri.queryParameters, isEmpty);
  });

  test('direct fallback uses an encoded unversioned user avatar', () {
    final source =
        resolveConversationAvatar(
              server: server,
              talkFeatures: const {},
              roomToken: 'room-a',
              roomType: ConversationRoomType.formerDirect,
              roomName: 'peer/name',
              objectType: '',
              avatarVersion: '',
              dark: true,
            )
            as NetworkConversationAvatar;

    expect(source.versioned, isFalse);
    expect(
      source.uri.toString(),
      'https://cloud.example.invalid/nextcloud/'
      'index.php/avatar/peer%2Fname/64/dark',
    );
  });

  test('known room and object types keep meaningful local fallbacks', () {
    final cases =
        <({int type, String objectType, ConversationAvatarIcon icon})>[
          (
            type: ConversationRoomType.group,
            objectType: '',
            icon: ConversationAvatarIcon.group,
          ),
          (
            type: ConversationRoomType.public,
            objectType: '',
            icon: ConversationAvatarIcon.publicLink,
          ),
          (
            type: ConversationRoomType.system,
            objectType: '',
            icon: ConversationAvatarIcon.system,
          ),
          (
            type: ConversationRoomType.noteToSelf,
            objectType: '',
            icon: ConversationAvatarIcon.noteToSelf,
          ),
          (
            type: ConversationRoomType.group,
            objectType: 'share:password',
            icon: ConversationAvatarIcon.lock,
          ),
          (
            type: ConversationRoomType.group,
            objectType: 'file',
            icon: ConversationAvatarIcon.file,
          ),
        ];

    for (final testCase in cases) {
      final source = resolveConversationAvatar(
        server: server,
        talkFeatures: const {},
        roomToken: 'room-a',
        roomType: testCase.type,
        roomName: 'synthetic-room',
        objectType: testCase.objectType,
        avatarVersion: '',
        dark: false,
      );
      expect(
        source,
        LocalConversationAvatar(testCase.icon),
        reason: '${testCase.type}/${testCase.objectType}',
      );
    }
  });
}
