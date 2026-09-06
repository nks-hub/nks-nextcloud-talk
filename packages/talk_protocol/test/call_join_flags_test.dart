import 'dart:convert';
import 'dart:io';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

/// The flags a client joins a call with are not a formality: the server, and
/// this policy before it, refuses a join that asks for more than the
/// participant may publish. Asking for audio and video unconditionally
/// therefore locked out anybody whose moderator had taken publishing away —
/// they could not join to listen either.
void main() {
  final template = _room();

  CallRoomPolicy policyWith(int permissions) {
    final json = jsonDecode(jsonEncode(template)) as Map<String, Object?>;
    json['permissions'] = permissions;
    json['hasCall'] = true;
    return CallRoomPolicy.fromConversation(ConversationRoom.fromJson(json));
  }

  test('a participant who may publish both joins with both', () {
    final policy = policyWith(255);
    final flags = policy.permittedJoinFlags;

    expect(flags.contains(CallFlag.inCall), isTrue);
    expect(flags.contains(CallFlag.audio), isTrue);
    expect(flags.contains(CallFlag.video), isTrue);
    expect(policy.canJoinWith(flags), isTrue);
  });

  test('video taken away still joins, without video', () {
    // 255 minus PERMISSIONS_PUBLISH_VIDEO (32): a webinar attendee.
    final policy = policyWith(255 - 32);
    final flags = policy.permittedJoinFlags;

    expect(flags.contains(CallFlag.audio), isTrue);
    expect(flags.contains(CallFlag.video), isFalse);
    expect(
      policy.canJoinWith(flags),
      isTrue,
      reason: 'they may listen and speak, so they may join',
    );
    expect(
      policy.canJoinWith(CallInCallFlags.audioVideo()),
      isFalse,
      reason: 'asking for video anyway is what used to lock them out',
    );
  });

  test('publishing taken away entirely still joins as a listener', () {
    final policy = policyWith(255 - 32 - 16);
    final flags = policy.permittedJoinFlags;

    expect(flags.contains(CallFlag.inCall), isTrue);
    expect(flags.contains(CallFlag.audio), isFalse);
    expect(flags.contains(CallFlag.video), isFalse);
    expect(policy.canJoinWith(flags), isTrue);
  });

  test('a room that answers "use the defaults" grants everything', () {
    // Talk answers `permissions: 0` for "this conversation's defaults", and
    // the defaults are the full set. Reading its bits denies everything at
    // once — which would refuse the join, and compose flags with neither
    // microphone nor camera for anybody it did let through.
    final policy = policyWith(0);
    final flags = policy.permittedJoinFlags;

    expect(flags.contains(CallFlag.audio), isTrue);
    expect(flags.contains(CallFlag.video), isTrue);
    expect(policy.canPublishScreen, isTrue);
    expect(policy.canJoinWith(flags), isTrue);
  });

  test('no permission to join at all is still a refusal', () {
    // PERMISSIONS_CALL_JOIN (4) removed: nothing about the flags helps.
    final policy = policyWith(255 - 4);

    expect(policy.canJoinWith(policy.permittedJoinFlags), isFalse);
  });
}

Map<String, Object?> _room() {
  final raw = File(
    '../../contracts/conversation-list/fixtures/'
    'conversations-compact.response.json',
  ).readAsStringSync();
  final root = jsonDecode(raw) as Map<String, Object?>;
  final ocs = root['ocs']! as Map<String, Object?>;
  final data = ocs['data']! as List<Object?>;
  return data.first! as Map<String, Object?>;
}
