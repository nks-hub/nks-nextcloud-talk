import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/calls/call_state.dart';

void main() {
  CachedConversation conversation(Map<String, Object?> wire) {
    return CachedConversation(
      accountId: 'account-a',
      token: 'rooma123',
      displayName: 'Synthetic room A',
      description: '',
      lastActivity: 1724300000,
      unreadMessages: 0,
      favorite: false,
      readOnly: 0,
      roomType: 2,
      roomName: 'synthetic-room-a',
      objectType: '',
      avatarVersion: '',
      isCustomAvatar: false,
      rawJson: jsonEncode(wire),
    );
  }

  test('no call is reported without an explicit server flag', () {
    expect(
      ConversationCallState.fromConversation(conversation(const {})),
      isNull,
    );
    expect(
      ConversationCallState.fromConversation(
        conversation(const {'hasCall': false, 'callFlag': 7}),
      ),
      isNull,
      reason: 'a stale flag must not resurrect a finished call',
    );
  });

  test('malformed cached wire never fabricates a call', () {
    final broken = CachedConversation(
      accountId: 'account-a',
      token: 'rooma123',
      displayName: 'Synthetic room A',
      description: '',
      lastActivity: 1724300000,
      unreadMessages: 0,
      favorite: false,
      readOnly: 0,
      roomType: 2,
      roomName: 'synthetic-room-a',
      objectType: '',
      avatarVersion: '',
      isCustomAvatar: false,
      rawJson: 'not json',
    );
    expect(ConversationCallState.fromConversation(broken), isNull);
  });

  test('elapsed time comes from the server start time', () {
    final started = DateTime.utc(2026, 8, 25, 10);
    final state = ConversationCallState.fromConversation(
      conversation({
        'hasCall': true,
        'callStartTime': started.millisecondsSinceEpoch ~/ 1000,
      }),
    )!;

    expect(
      state.elapsed(now: started.add(const Duration(minutes: 3))),
      const Duration(minutes: 3),
    );
    expect(
      state.elapsed(now: started.subtract(const Duration(minutes: 1))),
      Duration.zero,
      reason: 'clock skew must not produce a negative call length',
    );

    final withoutStart = ConversationCallState.fromConversation(
      conversation(const {'hasCall': true}),
    )!;
    expect(withoutStart.elapsed(), isNull);
  });
}
