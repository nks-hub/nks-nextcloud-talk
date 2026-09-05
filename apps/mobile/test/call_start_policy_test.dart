import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/calls/call_state.dart';

/// Whether the application offers to START a call, which it could not do at
/// all until 5 September 2026. Every gate here is a fact the server states
/// plainly; none of it is inferred from local activity.
CachedConversation _conversation(Map<String, Object?> room) {
  return CachedConversation(
    accountId: 'account-a',
    token: 'rooma123',
    displayName: 'Room',
    description: '',
    lastActivity: 0,
    unreadMessages: 0,
    favorite: false,
    isArchived: false,
    readOnly: 0,
    roomType: 2,
    roomName: 'Room',
    objectType: '',
    avatarVersion: '',
    isCustomAvatar: false,
    rawJson: jsonEncode(room),
  );
}

void main() {
  group('ConversationCallStartPolicy', () {
    test('offers a call the participant may start', () {
      final policy = ConversationCallStartPolicy.fromConversation(
        _conversation(<String, Object?>{
          'hasCall': false,
          'canStartCall': true,
          'readOnly': 0,
          'lobbyState': 0,
          'permissions': 0,
          'participantType': 3,
        }),
      );
      expect(policy.canStart, isTrue);
      expect(policy.withVideo, isTrue);
    });

    test('offers nothing while a call is already running', () {
      // That one is joined from the banner, not started again.
      final policy = ConversationCallStartPolicy.fromConversation(
        _conversation(<String, Object?>{
          'hasCall': true,
          'canStartCall': true,
          'readOnly': 0,
          'lobbyState': 0,
          'permissions': 0,
          'participantType': 3,
        }),
      );
      expect(policy.canStart, isFalse);
    });

    test('follows the room when it says the participant may not start', () {
      final policy = ConversationCallStartPolicy.fromConversation(
        _conversation(<String, Object?>{
          'hasCall': false,
          'canStartCall': false,
          'readOnly': 0,
          'lobbyState': 0,
          'permissions': 0,
          'participantType': 3,
        }),
      );
      expect(policy.canStart, isFalse);
    });

    test('a read-only conversation offers nothing', () {
      final policy = ConversationCallStartPolicy.fromConversation(
        _conversation(<String, Object?>{
          'hasCall': false,
          'canStartCall': true,
          'readOnly': 1,
          'lobbyState': 0,
          'permissions': 0,
          'participantType': 3,
        }),
      );
      expect(policy.canStart, isFalse);
    });

    test('a lobby keeps everyone but a moderator out', () {
      Map<String, Object?> room(int participantType) => <String, Object?>{
        'hasCall': false,
        'canStartCall': true,
        'readOnly': 0,
        'lobbyState': 1,
        'permissions': 0,
        'participantType': participantType,
      };
      expect(
        ConversationCallStartPolicy.fromConversation(
          _conversation(room(3)),
        ).canStart,
        isFalse,
      );
      expect(
        ConversationCallStartPolicy.fromConversation(
          _conversation(room(2)),
        ).canStart,
        isTrue,
      );
    });

    test('custom permissions decide the start and the camera', () {
      // Bit 0 clear means these bits are the participant's own: 2 start,
      // 16 audio, 32 video (CallPermission in the protocol package).
      ConversationCallStartPolicy policy(int permissions) =>
          ConversationCallStartPolicy.fromConversation(
            _conversation(<String, Object?>{
              'hasCall': false,
              'canStartCall': true,
              'readOnly': 0,
              'lobbyState': 0,
              'permissions': permissions,
              'participantType': 3,
            }),
          );
      // Start and audio, no video: the audio call alone is offered.
      final audioOnly = policy(2 | 16);
      expect(audioOnly.canStart, isTrue);
      expect(audioOnly.withVideo, isFalse);
      // Everything: both.
      final full = policy(2 | 16 | 32);
      expect(full.canStart, isTrue);
      expect(full.withVideo, isTrue);
      // No start bit, and no microphone either: nothing.
      expect(policy(16).canStart, isFalse);
      expect(policy(2).canStart, isFalse);
    });

    test('a payload that cannot be read offers nothing', () {
      final broken = CachedConversation(
        accountId: 'account-a',
        token: 'rooma123',
        displayName: 'Room',
        description: '',
        lastActivity: 0,
        unreadMessages: 0,
        favorite: false,
        isArchived: false,
        readOnly: 0,
        roomType: 2,
        roomName: 'Room',
        objectType: '',
        avatarVersion: '',
        isCustomAvatar: false,
        rawJson: 'not json',
      );
      expect(
        ConversationCallStartPolicy.fromConversation(broken).canStart,
        isFalse,
      );
    });
  });
}
