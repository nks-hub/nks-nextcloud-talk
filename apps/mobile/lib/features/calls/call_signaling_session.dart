// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:uuid/uuid.dart';

import '../../data/account_repository.dart';
import '../../data/call_session_repository.dart';
import '../../data/credential_vault.dart';
import '../../network/nextcloud_api.dart';
import 'hpb_socket_transport.dart';

part 'call_signaling_session_lane.dart';
part 'call_signaling_session_transport.dart';

typedef CallSignalingKey = ({String accountId, String roomToken});

typedef ConversationSessionRefresh =
    Future<ConversationSessionId?> Function(String accountId, String roomToken);

enum CallSignalingStartError {
  accountMissing,
  credentialMissing,
  invalidContext,
  disposed,
  suspended,
}

final class CallSignalingStartException implements Exception {
  const CallSignalingStartException(this.code);

  final CallSignalingStartError code;

  @override
  String toString() => 'CallSignalingStartException(${code.name})';
}

enum CallSignalingFailure { transport, protocol, persistence, roomRefresh }

/// Public, non-secret projection of a signaling runtime transition.
final class CallSignalingUpdate {
  CallSignalingUpdate({
    required this.key,
    required this.outcome,
    required this.phase,
    required this.transport,
    required this.topology,
    required Iterable<SignalingParticipant> participants,
    required this.roomConfirmed,
    required this.federationInterrupted,
    required this.renegotiationRequired,
    required Iterable<SignalingPeerMessage> messages,
    required Iterable<HpbControlMessage> controls,
    required this.chatRelay,
    required this.roomEpoch,
    required this.chatRelaySupported,
    required this.localPeerId,
    required Iterable<IceServerConfiguration> iceServers,
    required this.failure,
  }) : participants = List<SignalingParticipant>.unmodifiable(participants),
       messages = List<SignalingPeerMessage>.unmodifiable(messages),
       controls = List<HpbControlMessage>.unmodifiable(controls),
       iceServers = List<IceServerConfiguration>.unmodifiable(iceServers);

  final CallSignalingKey key;
  final SignalingRuntimeOutcome outcome;
  final SignalingAccountPhase phase;
  final SignalingTransportKind? transport;
  final SignalingTopology topology;
  final List<SignalingParticipant> participants;
  final bool roomConfirmed;
  final bool federationInterrupted;
  final bool renegotiationRequired;
  final List<SignalingPeerMessage> messages;
  final List<HpbControlMessage> controls;

  /// The raw `data.chat` object of a relayed chat event, or null when this
  /// transition carried none. Decoding it belongs to the chat layer.
  final Map<String, Object?>? chatRelay;

  /// Increments on every full HPB hello. A resume keeps it, and with it the
  /// promise that the relay replayed what the disconnect missed; a new epoch
  /// means the relay stream restarted and may have a hole in it.
  final int roomEpoch;

  /// Whether the connected signalling backend answered the `chat-relay`
  /// feature. Only an external HPB can, so this is false for internal
  /// signalling and stays false until the hello response lands.
  final bool chatRelaySupported;

  /// This client's own session id in the same namespace as the peer ids of
  /// [participants]: the signalling session with an HPB, the Nextcloud
  /// session with internal signalling. Mixing the two namespaces is what
  /// makes the offerer comparison in a mesh call agree with itself, so media
  /// must never substitute one for the other. Null until a session exists.
  final SignalingPeerId? localPeerId;

  /// STUN and TURN servers exactly as this room's signalling settings gave
  /// them. TURN credentials are short-lived, so they are read per session and
  /// never persisted.
  final List<IceServerConfiguration> iceServers;

  final CallSignalingFailure? failure;

  /// Whether relayed chat may be trusted right now: an external HPB that
  /// advertised `chat-relay` and has this room confirmed on a live session.
  bool get chatRelayActive =>
      chatRelaySupported &&
      roomConfirmed &&
      transport == SignalingTransportKind.externalHpb &&
      phase == SignalingAccountPhase.signalingReady;

  bool get signalingReady =>
      phase == SignalingAccountPhase.signalingReady ||
      phase == SignalingAccountPhase.internalReady ||
      phase == SignalingAccountPhase.internalPolling;

  @override
  String toString() =>
      'CallSignalingUpdate(outcome: ${outcome.name}, phase: ${phase.name}, '
      'participants: ${participants.length}, '
      'chatRelayActive: $chatRelayActive, failure: ${failure?.name})';
}

abstract interface class SignalingScheduledTask {
  bool get isActive;

  void cancel();
}

abstract interface class SignalingScheduler {
  SignalingScheduledTask schedule(Duration delay, void Function() callback);
}

final class DartSignalingScheduler implements SignalingScheduler {
  const DartSignalingScheduler();

  @override
  SignalingScheduledTask schedule(Duration delay, void Function() callback) {
    return _DartSignalingScheduledTask(Timer(delay, callback));
  }
}

final class _DartSignalingScheduledTask implements SignalingScheduledTask {
  const _DartSignalingScheduledTask(this._timer);

  final Timer _timer;

  @override
  bool get isActive => _timer.isActive;

  @override
  void cancel() => _timer.cancel();
}

/// Handle for one account-scoped signaling lane. It prepares signaling only;
/// it cannot join a Talk call or claim media readiness.
final class CallSignalingSession {
  CallSignalingSession._(this._lane);

  final _CallSignalingLane _lane;

  CallSignalingKey get key => _lane.key;

  CallSignalingUpdate get current => _lane.current;

  Stream<CallSignalingUpdate> get updates => _lane.updates;

  Future<bool> sendPeerMessage(SignalingPeerMessage message) {
    return _lane.sendPeerMessage(message);
  }

  /// Queues one transient peer message per recipient. Internal signaling sends
  /// bounded batches; HPB sends frames serially so no recipient is dropped
  /// while another frame is awaiting persistence or socket completion.
  Future<bool> sendPeerMessages(Iterable<SignalingPeerMessage> messages) {
    return _lane.sendPeerMessages(messages);
  }

  Future<bool> sendControl(HpbControlMessage control) {
    return _lane.sendControl(control);
  }

  Future<void> release() => _lane.release();
}

/// Owns at most one active signaling room for each account. All callbacks are
/// serialized inside that account lane and checked again by the pure runtime's
/// authority, connection-epoch and room-epoch guards before publication.
final class CallSignalingCoordinator {
  CallSignalingCoordinator({
    required AccountRepository accounts,
    required CallSessionRepository sessions,
    required CredentialVault credentials,
    required HttpNextcloudApi api,
    required ConversationSessionRefresh refreshConversationSession,
    HpbSocketConnector socketConnector = const IoHpbSocketConnector(),
    SignalingScheduler scheduler = const DartSignalingScheduler(),
    Uuid uuid = const Uuid(),
    int Function()? nowMicros,
    int Function()? reconnectJitterUnit,
  }) : _accounts = accounts,
       _sessions = sessions,
       _credentials = credentials,
       _api = api,
       _refreshConversationSession = refreshConversationSession,
       _socketConnector = socketConnector,
       _scheduler = scheduler,
       _uuid = uuid,
       _nowMicros =
           nowMicros ?? (() => DateTime.now().toUtc().microsecondsSinceEpoch),
       _reconnectJitterUnit =
           reconnectJitterUnit ?? (() => Random.secure().nextInt(1000001));

  final AccountRepository _accounts;
  final CallSessionRepository _sessions;
  final CredentialVault _credentials;
  final HttpNextcloudApi _api;
  final ConversationSessionRefresh _refreshConversationSession;
  final HpbSocketConnector _socketConnector;
  final SignalingScheduler _scheduler;
  final Uuid _uuid;
  final int Function() _nowMicros;
  final int Function() _reconnectJitterUnit;
  final Map<String, _CallSignalingLane> _lanes = {};
  final Set<String> _suspendedAccounts = {};
  Future<void> _gate = Future<void>.value();
  bool _disposed = false;

  Future<CallSignalingSession> start({
    required String accountId,
    required String roomToken,
    required String nextcloudSessionId,
  }) {
    return _synchronized(() async {
      if (_disposed) {
        throw const CallSignalingStartException(
          CallSignalingStartError.disposed,
        );
      }
      if (_suspendedAccounts.contains(accountId)) {
        throw const CallSignalingStartException(
          CallSignalingStartError.suspended,
        );
      }
      final parsedAccountId = AccountId.parse(accountId);
      final parsedRoomToken = ConversationToken.parse(
        roomToken,
        path: r'$.roomToken',
      );
      final parsedSessionId = ConversationSessionId.parse(nextcloudSessionId);
      final existing = _lanes[accountId];
      if (existing != null &&
          existing.key.roomToken == roomToken &&
          existing.authority.nextcloudSessionId == parsedSessionId) {
        existing.retain();
        return existing.handle;
      }
      if (existing != null) {
        await existing.shutdown(deleteDurableState: true);
        _lanes.remove(accountId);
      }

      final account = await _accounts.getAccount(accountId);
      if (_suspendedAccounts.contains(accountId)) {
        throw const CallSignalingStartException(
          CallSignalingStartError.suspended,
        );
      }
      if (account == null) {
        throw const CallSignalingStartException(
          CallSignalingStartError.accountMissing,
        );
      }
      final appPassword = await _credentials.readAppPassword(accountId);
      if (_suspendedAccounts.contains(accountId)) {
        throw const CallSignalingStartException(
          CallSignalingStartError.suspended,
        );
      }
      if (appPassword == null) {
        throw const CallSignalingStartException(
          CallSignalingStartError.credentialMissing,
        );
      }

      try {
        final server = ServerBase.parse(account.serverUrl);
        final profile = SignalingCapabilityProfile.fromTalkFeatures(
          jsonDecode(account.talkFeaturesJson),
        );
        var snapshot = await _sessions.recover(
          accountId: accountId,
          roomToken: roomToken,
        );
        SignalingAuthority authority;
        final recovered = snapshot?.accounts[parsedAccountId];
        if (recovered != null && recovered.server == server) {
          final profileChanged =
              recovered.profile.enabled != profile.enabled ||
              recovered.profile.chatRelay != profile.chatRelay;
          final sessionChanged =
              recovered.nextcloudSessionId != parsedSessionId;
          authority = SignalingAuthority(
            accountId: parsedAccountId,
            server: server,
            credentialGeneration: recovered.credentialGeneration,
            capabilityGeneration:
                recovered.capabilityGeneration + (profileChanged ? 1 : 0),
            settingsRevision: profileChanged || sessionChanged
                ? _uuid.v4()
                : recovered.settingsRevision,
            profile: profile,
            roomToken: parsedRoomToken,
            nextcloudSessionId: parsedSessionId,
          );
          if (profileChanged || sessionChanged) {
            final refreshed = refreshSignalingAuthority(
              snapshot!,
              authority: authority,
            );
            if (!refreshed.canCommit) {
              throw const CallSignalingStartException(
                CallSignalingStartError.invalidContext,
              );
            }
            snapshot = refreshed.plan!.commit(snapshot);
          }
        } else {
          snapshot = SignalingRuntimeSnapshot(
            accounts: const <AccountId, SignalingAccountState>{},
          );
          authority = SignalingAuthority(
            accountId: parsedAccountId,
            server: server,
            credentialGeneration: 1,
            capabilityGeneration: 1,
            settingsRevision: _uuid.v4(),
            profile: profile,
            roomToken: parsedRoomToken,
            nextcloudSessionId: parsedSessionId,
          );
          final added = addSignalingAccount(snapshot, authority: authority);
          snapshot = added.plan!.commit(snapshot);
        }

        final preparedSnapshot = snapshot;
        if (preparedSnapshot == null) {
          throw const CallSignalingStartException(
            CallSignalingStartError.invalidContext,
          );
        }
        await _sessions.persist(preparedSnapshot.accounts[parsedAccountId]!);
        if (_suspendedAccounts.contains(accountId)) {
          await _sessions.delete(accountId: accountId, roomToken: roomToken);
          throw const CallSignalingStartException(
            CallSignalingStartError.suspended,
          );
        }
        late final _CallSignalingLane lane;
        lane = _CallSignalingLane(
          snapshot: preparedSnapshot,
          authority: authority,
          loginName: account.loginName,
          appPassword: appPassword,
          sessions: _sessions,
          api: _api,
          socketConnector: _socketConnector,
          scheduler: _scheduler,
          refreshConversationSession: _refreshConversationSession,
          uuid: _uuid,
          nowMicros: _nowMicros,
          reconnectJitterUnit: _reconnectJitterUnit,
          onReleased: () {
            if (identical(_lanes[accountId], lane)) {
              _lanes.remove(accountId);
            }
          },
        );
        _lanes[accountId] = lane;
        lane.launch();
        return lane.handle;
      } on CallSignalingStartException {
        rethrow;
      } on Object {
        throw const CallSignalingStartException(
          CallSignalingStartError.invalidContext,
        );
      }
    });
  }

  Future<void> dispose() {
    return _synchronized(() async {
      if (_disposed) {
        return;
      }
      _disposed = true;
      final lanes = _lanes.values.toList(growable: false);
      _lanes.clear();
      for (final lane in lanes) {
        await lane.shutdown(deleteDurableState: false);
      }
    });
  }

  Future<void> shutdownAccount(String accountId) {
    _suspendedAccounts.add(accountId);
    return _synchronized(() async {
      final lane = _lanes.remove(accountId);
      if (lane != null) {
        await lane.shutdown(deleteDurableState: true);
      }
    });
  }

  Future<T> _synchronized<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _gate = _gate.catchError((_) {}).then((_) async {
      try {
        completer.complete(await operation());
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}
