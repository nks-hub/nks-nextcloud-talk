import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../app_providers.dart';
import '../../network/nextcloud_api.dart';
import '../calls/call_signaling_session.dart';

typedef ChatRoomSignalingKey = ({String accountId, String roomToken});

/// One open room's signalling session, shared by everything in the chat that
/// needs it.
///
/// It exists once per room because activating a room session is exclusive:
/// `activateRoomSession` deactivates whatever the account held before, so a
/// second activation for the same room would take the first one's session id
/// away and tear its socket down. The typing indicator and the HPB chat relay
/// therefore ride the same session rather than each opening their own.
final class ChatRoomSignalingLease {
  const ChatRoomSignalingLease._({
    required this.session,
    required this.nextcloudSessionId,
    required this.capabilities,
    required this.loginName,
  });

  const ChatRoomSignalingLease.unavailable()
    : session = null,
      nextcloudSessionId = null,
      capabilities = null,
      loginName = null;

  /// Null when no session could be established — the window is in the
  /// background, the account cannot sign in, or the server has no signalling.
  final CallSignalingSession? session;

  /// The Talk session id the room was activated with.
  final String? nextcloudSessionId;
  final CapabilitySnapshot? capabilities;
  final String? loginName;

  bool get isAvailable => session != null;
}

/// Whether this server can carry a room signalling session at all. Narrower
/// gates — typing privacy, or the HPB answering `chat-relay` — belong to the
/// features that need them, not here.
bool chatRoomSignalingAllowed(CapabilitySnapshot snapshot) =>
    snapshot.context == CapabilityContext.authenticated &&
    snapshot.supportsTalk('signaling-v3');

/// How long the room session outlives its last reader.
///
/// Without it, a single frame in which no provider is listening costs the
/// session: `autoDispose` releases it, the next reader activates a new one, and
/// `activateRoomSession` is exclusive, so the new activation kills the old
/// session id. On 5 September 2026 the server logged that as four requests in
/// one second when a conversation was opened — POST, DELETE, POST, DELETE — and
/// because the last one is a DELETE the client was left holding no session at
/// all. The signalling lane had already started with one of the dead ids, its
/// first pull was answered 409, and a 409 terminates the lane for good, so a
/// joined call never negotiated with anybody.
///
/// Two seconds, the same grace [WindowActivity] already applies to a window
/// that briefly loses focus, and for the same reason: presence is worth
/// releasing when the user leaves, not when a widget tree rearranges itself.
const chatRoomSignalingGrace = Duration(seconds: 2);

final chatRoomSignalingProvider = FutureProvider.autoDispose
    .family<ChatRoomSignalingLease, ChatRoomSignalingKey>((ref, key) async {
      // Armed before anything else: the gap that costs the session can open
      // while the activation below is still in flight.
      final link = ref.keepAlive();
      Timer? expiry;
      ref.onCancel(() {
        expiry?.cancel();
        expiry = Timer(chatRoomSignalingGrace, link.close);
      });
      ref.onResume(() {
        expiry?.cancel();
        expiry = null;
      });

      var disposed = false;
      Future<void> Function()? owned;
      ref.onDispose(() {
        expiry?.cancel();
        disposed = true;
        final release = owned;
        if (release != null) {
          unawaited(release());
        }
      });

      // Presence is what silences the server. Holding a room session while
      // the window sits behind another one told Talk the user was reading the
      // conversation, so it suppressed every notification for it — the open
      // conversation that never notified. Watched, not read once: losing
      // focus has to tear the session down, and regaining it has to build one
      // again.
      if (!ref.watch(windowActiveProvider)) {
        return const ChatRoomSignalingLease.unavailable();
      }

      final accounts = ref.watch(accountRepositoryProvider);
      final credentials = ref.watch(credentialVaultProvider);
      final api = ref.watch(nextcloudApiProvider);
      final account = await accounts.getAccount(key.accountId);
      final password = await credentials.readAppPassword(key.accountId);
      if (account == null || password == null) {
        return const ChatRoomSignalingLease.unavailable();
      }

      final ServerBase server;
      final CapabilitySnapshot capabilities;
      try {
        server = ServerBase.parse(account.serverUrl);
        capabilities = (await api.getAuthenticatedCapabilitiesWithSource(
          server: server,
          loginName: account.loginName,
          appPassword: password,
        )).snapshot;
      } on Object {
        return const ChatRoomSignalingLease.unavailable();
      }
      if (!chatRoomSignalingAllowed(capabilities)) {
        return const ChatRoomSignalingLease.unavailable();
      }

      final chat = ref.watch(chatRepositoryProvider);
      final coordinator = ref.watch(callSignalingCoordinatorProvider);
      final activeRequest = ActiveRoomSessionRequest(
        accountId: AccountId.parse(key.accountId),
        server: server,
        roomToken: ConversationToken.parse(key.roomToken, path: r'$.roomToken'),
      );
      final ActiveRoomSessionActivation activation;
      try {
        activation = await api.activateRoomSession(
          activeRequest: activeRequest,
          loginName: account.loginName,
          appPassword: password,
        );
      } on Object {
        await api.clearAccountSession(key.accountId);
        return const ChatRoomSignalingLease.unavailable();
      }
      final lease = activation.lease;
      Future<void> deactivate() async {
        if (lease == null) return;
        try {
          await api.deactivateRoomSession(
            lease: lease,
            loginName: account.loginName,
            appPassword: password,
          );
        } on Object {
          await api.clearAccountSession(key.accountId);
        }
      }

      if (disposed) {
        await deactivate();
        return const ChatRoomSignalingLease.unavailable();
      }
      final active = activation.response;
      if (active is ActiveRoomSessionReauthenticationRequired) {
        await chat.markReauthenticationRequired(key.accountId);
      }
      if (active is! ActiveRoomSessionSuccess ||
          active.room.token.value != key.roomToken ||
          active.room.sessionId.value == '0') {
        await deactivate();
        return const ChatRoomSignalingLease.unavailable();
      }

      try {
        final session = await coordinator.start(
          accountId: key.accountId,
          roomToken: key.roomToken,
          nextcloudSessionId: active.room.sessionId.value,
        );
        Future<void> release() async {
          try {
            await session.release();
          } finally {
            await deactivate();
          }
        }

        owned = release;
        if (disposed) {
          owned = null;
          await release();
          return const ChatRoomSignalingLease.unavailable();
        }
        return ChatRoomSignalingLease._(
          session: session,
          nextcloudSessionId: active.room.sessionId.value,
          capabilities: capabilities,
          loginName: account.loginName,
        );
      } on Object {
        unawaited(deactivate());
        return const ChatRoomSignalingLease.unavailable();
      }
    });

/// Drives one room's [ChatRelayBinding] from the shared signalling session.
///
/// It is a pure pump: the session says whether the HPB advertised
/// `chat-relay` and has this room confirmed, and the binding decides what
/// that is worth. Without an external HPB — internal signalling, or a backend
/// without the feature — nothing here ever activates and the room keeps
/// polling exactly as before.
final chatRelayProvider = FutureProvider.autoDispose
    .family<void, ChatRoomSignalingKey>((ref, key) async {
      final lease = await ref.watch(chatRoomSignalingProvider(key).future);
      final session = lease.session;
      if (session == null) {
        return;
      }
      final binding = ref
          .watch(chatServiceProvider)
          .bindRelay(accountId: key.accountId, roomToken: key.roomToken);
      ref.onDispose(binding.close);

      void handle(CallSignalingUpdate update) {
        if (!update.chatRelayActive) {
          binding.deactivate();
          return;
        }
        binding.activate(update.roomEpoch);
        final chat = update.chatRelay;
        if (chat != null) {
          binding.receive(update.roomEpoch, chat);
        }
      }

      // `current` is a projection of the last transition, so its payload may
      // be one this binding already saw. Merging it again is harmless: a
      // relayed message is deduplicated by its server-assigned id.
      handle(session.current);
      final subscription = session.updates.listen(handle);
      ref.onDispose(subscription.cancel);
    });
