import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/chat/chat_posting_access.dart';

CachedConversation _conversation({
  int readOnly = 0,
  Map<String, Object?>? room,
  String? rawJson,
}) {
  return CachedConversation(
    accountId: 'account-a',
    token: 'rooma123',
    displayName: 'Room A',
    description: '',
    lastActivity: 1724300000,
    unreadMessages: 0,
    favorite: false,
    isArchived: false,
    readOnly: readOnly,
    roomType: 2,
    roomName: 'Room A',
    objectType: '',
    avatarVersion: '',
    isCustomAvatar: false,
    rawJson: rawJson ?? jsonEncode(room ?? const <String, Object?>{}),
  );
}

void main() {
  test('an ordinary participant may post', () {
    // Measured on the reference server (Nextcloud 34): the room's permissions
    // come back resolved, 502 for a plain user and 510 for an owner. 502 is
    // 510 without bit 8, so an ordinary participant keeps chat and only lacks
    // the right to walk past a lobby.
    final access = ChatPostingAccess.fromCachedConversation(
      _conversation(
        room: const {'permissions': 502, 'lobbyState': 0, 'participantType': 3},
      ),
    );
    expect(access.canPost, isTrue);
    expect(access.block, isNull);
  });

  test('an owner may post', () {
    final access = ChatPostingAccess.fromCachedConversation(
      _conversation(
        room: const {'permissions': 510, 'lobbyState': 0, 'participantType': 1},
      ),
    );
    expect(access.canPost, isTrue);
  });

  test('a participant without the chat bit may not post', () {
    // 502 with bit 128 taken away.
    final access = ChatPostingAccess.fromCachedConversation(
      _conversation(
        room: const {'permissions': 374, 'lobbyState': 0, 'participantType': 3},
      ),
    );
    expect(access.block, ChatPostingBlock.noChatPermission);
  });

  test('a lobby holds an ordinary participant', () {
    final access = ChatPostingAccess.fromCachedConversation(
      _conversation(
        room: const {'permissions': 502, 'lobbyState': 1, 'participantType': 3},
      ),
    );
    expect(access.block, ChatPostingBlock.lobby);
  });

  test('a lobby does not hold a moderator', () {
    for (final type in const <int>[1, 2, 6]) {
      final access = ChatPostingAccess.fromCachedConversation(
        _conversation(
          room: {'permissions': 502, 'lobbyState': 1, 'participantType': type},
        ),
      );
      expect(
        access.canPost,
        isTrue,
        reason: 'participant type $type moderates and passes the lobby',
      );
    }
  });

  test('the ignore-lobby permission passes the lobby', () {
    final access = ChatPostingAccess.fromCachedConversation(
      _conversation(
        room: const {'permissions': 510, 'lobbyState': 1, 'participantType': 3},
      ),
    );
    expect(access.canPost, isTrue);
  });

  test('read-only outranks the permission bits', () {
    final access = ChatPostingAccess.fromCachedConversation(
      _conversation(
        readOnly: 1,
        room: const {'permissions': 510, 'lobbyState': 0, 'participantType': 1},
      ),
    );
    expect(access.block, ChatPostingBlock.readOnly);
  });

  group('a payload that says nothing reads as "may post"', () {
    // Guessing the other way would silence a composer that works. The server
    // still refuses whatever it refuses, so the worst case is today's
    // behaviour, not a room nobody can write in.
    test('empty room body', () {
      expect(
        ChatPostingAccess.fromCachedConversation(_conversation()).canPost,
        isTrue,
      );
    });

    test(
      'bare zero permissions mean the server defaults, which include chat',
      () {
        expect(
          ChatPostingAccess.fromCachedConversation(
            _conversation(room: const {'permissions': 0, 'lobbyState': 0}),
          ).canPost,
          isTrue,
        );
      },
    );

    test('unparseable payload', () {
      expect(
        ChatPostingAccess.fromCachedConversation(
          _conversation(rawJson: 'not json'),
        ).canPost,
        isTrue,
      );
    });

    test('payload that is not an object', () {
      expect(
        ChatPostingAccess.fromCachedConversation(
          _conversation(rawJson: '[1, 2]'),
        ).canPost,
        isTrue,
      );
    });

    test('permissions of the wrong type', () {
      expect(
        ChatPostingAccess.fromCachedConversation(
          _conversation(room: const {'permissions': '502'}),
        ).canPost,
        isTrue,
      );
    });
  });
}
