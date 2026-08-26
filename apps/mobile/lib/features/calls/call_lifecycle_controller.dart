// ignore_for_file: prefer_initializing_formals

import 'dart:convert';

import 'package:talk_protocol/talk_protocol.dart';

import '../../data/account_repository.dart';
import '../conversations/conversation_sync_service.dart';
import 'call_lifecycle_service.dart';
import 'call_transport_service.dart';

/// Refreshes the room before a call request and returns its current Talk
/// session id. No cached id is admitted without a successful full refresh.
final class CallConversationSessionResolver {
  const CallConversationSessionResolver({
    required AccountRepository accounts,
    required ConversationSyncService conversations,
  }) : _accounts = accounts,
       _conversations = conversations;

  final AccountRepository _accounts;
  final ConversationSyncService _conversations;

  Future<ConversationSessionId?> refresh(
    String accountId,
    String roomToken,
  ) async {
    try {
      await _conversations.sync(accountId, forceFull: true);
    } on ConversationSyncException catch (error) {
      throw CallLifecycleException(_mapSyncError(error.code));
    }

    final cached = await _accounts.getConversation(
      accountId: accountId,
      token: roomToken,
    );
    if (cached == null ||
        cached.accountId != accountId ||
        cached.token != roomToken) {
      throw const CallLifecycleException(CallLifecycleError.roomMissing);
    }

    try {
      final room = ConversationRoom.fromJson(jsonDecode(cached.rawJson));
      if (room.token.value != roomToken) {
        throw const FormatException('Conversation authority mismatch');
      }
      return room.sessionId;
    } on CallLifecycleException {
      rethrow;
    } on Object {
      throw const CallLifecycleException(CallLifecycleError.invalidResponse);
    }
  }
}

final class CallLifecycleRoomStatus {
  const CallLifecycleRoomStatus({required this.key, required this.status});

  final CallRoomKey key;
  final CallLifecycleStatus status;

  bool matches(CallRoomKey expected) => key == expected;
}

/// Production UI boundary for call REST state. It exposes read/recovery only;
/// join/update/leave remain behind the media implementation boundary.
final class CallLifecycleController {
  const CallLifecycleController(this._service);

  final CallLifecycleService _service;

  Future<CallLifecycleRoomStatus> load(CallRoomKey key) async {
    final status = await _service.recoverStatus(
      accountId: key.accountId,
      roomToken: key.roomToken,
    );
    final authority = status.state?.authority;
    if ((authority != null &&
            (authority.accountId.value != key.accountId ||
                authority.roomToken.value != key.roomToken)) ||
        status.peers.any((peer) => peer.roomToken.value != key.roomToken)) {
      throw const CallLifecycleException(CallLifecycleError.invalidResponse);
    }
    return CallLifecycleRoomStatus(key: key, status: status);
  }
}

CallLifecycleError _mapSyncError(ConversationSyncError error) =>
    switch (error) {
      ConversationSyncError.accountMissing => CallLifecycleError.accountMissing,
      ConversationSyncError.credentialMissing =>
        CallLifecycleError.credentialMissing,
      ConversationSyncError.reauthenticationRequired =>
        CallLifecycleError.reauthenticationRequired,
      ConversationSyncError.rateLimited => CallLifecycleError.rateLimited,
      ConversationSyncError.serviceUnavailable =>
        CallLifecycleError.serviceUnavailable,
      ConversationSyncError.network => CallLifecycleError.network,
      ConversationSyncError.talkUnavailable ||
      ConversationSyncError.conversationProfileUnsupported ||
      ConversationSyncError.upgradeRequired => CallLifecycleError.unsupported,
      ConversationSyncError.invalidResponse =>
        CallLifecycleError.invalidResponse,
    };
