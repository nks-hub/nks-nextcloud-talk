// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../app_providers.dart';
import '../../data/app_database.dart';
import '../calls/call_signaling_session.dart';
import '../rooms/participants_service.dart';

typedef ChatTypingRoomKey = ({
  String accountId,
  String roomToken,
  String nextcloudSessionId,
});

typedef ChatTypingActivity = Future<void> Function(Object source, bool active);

enum ChatTypingAvailability { connecting, available, unavailable }

enum ChatTypingActivityUpdate { unchanged, active, inactive }

ChatTypingActivityUpdate chatTypingActivityUpdate({
  required bool composerChanged,
  required bool canPost,
  required bool hasFocus,
  required String text,
  bool forceInactive = false,
}) {
  if (forceInactive || !canPost || !hasFocus || text.trim().isEmpty) {
    return ChatTypingActivityUpdate.inactive;
  }
  return composerChanged
      ? ChatTypingActivityUpdate.active
      : ChatTypingActivityUpdate.unchanged;
}

final class ChatTypingParticipant {
  const ChatTypingParticipant({
    required this.peerId,
    required this.identity,
    required this.actorId,
    required this.displayName,
  });

  final String peerId;
  final String identity;
  final String actorId;
  final String displayName;

  @override
  bool operator ==(Object other) =>
      other is ChatTypingParticipant &&
      other.peerId == peerId &&
      other.identity == identity &&
      other.actorId == actorId &&
      other.displayName == displayName;

  @override
  int get hashCode => Object.hash(peerId, identity, actorId, displayName);
}

final class ChatTypingState {
  ChatTypingState({
    required this.availability,
    required Iterable<ChatTypingParticipant> participants,
  }) : participants = List<ChatTypingParticipant>.unmodifiable(participants);

  factory ChatTypingState.unavailable() => ChatTypingState(
    availability: ChatTypingAvailability.unavailable,
    participants: const <ChatTypingParticipant>[],
  );

  final ChatTypingAvailability availability;
  final List<ChatTypingParticipant> participants;
}

ChatTypingRoomKey? chatTypingRoomKeyFor({
  required StoredAccount account,
  required CachedConversation conversation,
}) {
  try {
    final features = (jsonDecode(account.talkFeaturesJson) as List<Object?>)
        .cast<String>()
        .toSet();
    if (!features.contains('signaling-v3') ||
        !features.contains('typing-privacy')) {
      return null;
    }
    final room = ConversationRoom.fromJson(jsonDecode(conversation.rawJson));
    if (room.token.value != conversation.token) {
      return null;
    }
    return (
      accountId: account.id,
      roomToken: conversation.token,
      nextcloudSessionId: room.sessionId.value,
    );
  } on Object {
    return null;
  }
}

bool chatTypingAllowed(CapabilitySnapshot snapshot) =>
    snapshot.context == CapabilityContext.authenticated &&
    snapshot.supportsTalk('signaling-v3') &&
    snapshot.supportsTalk('typing-privacy') &&
    snapshot.chatTypingPrivacy == ChatTypingPrivacy.public;

final chatTypingControllerProvider = FutureProvider.autoDispose
    .family<ChatTypingController, ChatTypingRoomKey>((ref, key) async {
      var disposed = false;
      ChatTypingController? owned;
      ref.onDispose(() {
        disposed = true;
        final controller = owned;
        if (controller != null) {
          unawaited(controller.dispose());
        }
      });

      final accounts = ref.watch(accountRepositoryProvider);
      final credentials = ref.watch(credentialVaultProvider);
      final api = ref.watch(nextcloudApiProvider);
      final account = await accounts.getAccount(key.accountId);
      final password = await credentials.readAppPassword(key.accountId);
      if (account == null || password == null) {
        return ChatTypingController.disabled(key);
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
        return ChatTypingController.disabled(key);
      }
      if (!chatTypingAllowed(capabilities)) {
        return ChatTypingController.disabled(key);
      }

      final participantsFuture = ref
          .watch(participantsServiceProvider)
          .fetchParticipants(accountId: key.accountId, roomToken: key.roomToken)
          .catchError((Object _) => const <Participant>[]);
      try {
        final session = await ref
            .watch(callSignalingCoordinatorProvider)
            .start(
              accountId: key.accountId,
              roomToken: key.roomToken,
              nextcloudSessionId: key.nextcloudSessionId,
            );
        final controller = ChatTypingController(
          key: key,
          localLoginName: account.loginName,
          initial: session.current,
          updates: session.updates,
          sendMessages: session.sendPeerMessages,
          release: session.release,
        );
        owned = controller;
        if (disposed) {
          await controller.dispose();
          owned = null;
          return ChatTypingController.disabled(key);
        }
        unawaited(
          participantsFuture.then(
            (participants) => controller.updateParticipantNames(
              _participantNames(participants),
            ),
          ),
        );
        return controller;
      } on Object {
        return ChatTypingController.disabled(key);
      }
    });

final chatTypingStateProvider = StreamProvider.autoDispose
    .family<ChatTypingState, ChatTypingRoomKey>((ref, key) async* {
      final controller = await ref.watch(
        chatTypingControllerProvider(key).future,
      );
      yield controller.current;
      yield* controller.updates;
    });

final chatTypingActivityProvider = Provider.autoDispose
    .family<ChatTypingActivity, ChatTypingRoomKey>((ref, key) {
      final controller = ref.watch(chatTypingControllerProvider(key).future);
      return (source, active) async {
        final resolved = await controller;
        await resolved.recordLocalActivity(source, active);
      };
    });

Map<String, String> _participantNames(List<Participant> participants) {
  final names = <String, String>{};
  for (final participant in participants) {
    final displayName = participant.displayName.trim();
    if (displayName.isEmpty) {
      continue;
    }
    names['actor:${participant.actorType}:${participant.actorId}'] =
        displayName;
    for (final sessionId in participant.sessionIds) {
      names['session:$sessionId'] = displayName;
    }
  }
  return names;
}

final class ChatTypingController {
  ChatTypingController({
    required this.key,
    required String localLoginName,
    required CallSignalingUpdate initial,
    required Stream<CallSignalingUpdate> updates,
    required Future<bool> Function(Iterable<SignalingPeerMessage>) sendMessages,
    required Future<void> Function() release,
    Map<String, String> participantNames = const <String, String>{},
    SignalingScheduler scheduler = const DartSignalingScheduler(),
  }) : _localLoginName = localLoginName,
       _sendMessages = sendMessages,
       _release = release,
       _participantNames = Map<String, String>.of(participantNames),
       _scheduler = scheduler,
       _current = ChatTypingState(
         availability: ChatTypingAvailability.connecting,
         participants: const <ChatTypingParticipant>[],
       ) {
    _applyUpdate(initial);
    _subscription = updates.listen(_applyUpdate, onDone: _handleTransportDone);
  }

  ChatTypingController.disabled(this.key)
    : _localLoginName = '',
      _sendMessages = _disabledSend,
      _release = _disabledRelease,
      _participantNames = const <String, String>{},
      _scheduler = const DartSignalingScheduler(),
      _current = ChatTypingState.unavailable();

  static Future<bool> _disabledSend(Iterable<SignalingPeerMessage> _) async =>
      false;

  static Future<void> _disabledRelease() async {}

  static const _remoteTimeout = Duration(seconds: 15);
  static const _localRefresh = Duration(seconds: 10);
  static const _localIdle = Duration(seconds: 5);

  final ChatTypingRoomKey key;
  final String _localLoginName;
  final Future<bool> Function(Iterable<SignalingPeerMessage>) _sendMessages;
  final Future<void> Function() _release;
  final Map<String, String> _participantNames;
  final SignalingScheduler _scheduler;
  final StreamController<ChatTypingState> _updates =
      StreamController<ChatTypingState>.broadcast(sync: true);
  final Map<SignalingPeerId, SignalingParticipant> _participants = {};
  final Map<SignalingPeerId, ChatTypingParticipant> _typing = {};
  final Map<SignalingPeerId, SignalingScheduledTask> _remoteTimeouts = {};
  final Set<SignalingPeerId> _advertisedPeers = {};

  StreamSubscription<CallSignalingUpdate>? _subscription;
  late ChatTypingState _current;
  Future<void> _serial = Future<void>.value();
  SignalingScheduledTask? _localRefreshTask;
  final Set<Object> _localActivitySources = Set<Object>.identity();
  final Map<Object, SignalingScheduledTask> _localIdleTasks = Map.identity();
  bool _localTyping = false;
  bool _disposed = false;

  ChatTypingState get current => _current;

  Stream<ChatTypingState> get updates => _updates.stream;

  bool get _localActivityRequested => _localActivitySources.isNotEmpty;

  Future<void> recordLocalActivity(Object source, bool active) {
    return _enqueue(() async {
      if (!active) {
        _localIdleTasks.remove(source)?.cancel();
        _localActivitySources.remove(source);
        if (!_localActivityRequested) {
          await _stopLocalTyping();
        }
        return;
      }
      _localActivitySources.add(source);
      _scheduleLocalIdle(source);
      if (_current.availability == ChatTypingAvailability.available &&
          !_localTyping) {
        await _startLocalTyping();
      }
    });
  }

  void updateParticipantNames(Map<String, String> names) {
    if (_disposed) {
      return;
    }
    _participantNames
      ..clear()
      ..addAll(names);
    var changed = false;
    for (final entry in _typing.entries.toList(growable: false)) {
      final participant = _participants[entry.key];
      if (participant == null) {
        continue;
      }
      final projected = _projectParticipant(participant);
      if (projected != entry.value) {
        _typing[entry.key] = projected;
        changed = true;
      }
    }
    if (changed) {
      _publish(_current.availability);
    }
  }

  void _applyUpdate(CallSignalingUpdate update) {
    if (_disposed ||
        update.key.accountId != key.accountId ||
        update.key.roomToken != key.roomToken) {
      return;
    }
    final wasAvailable =
        _current.availability == ChatTypingAvailability.available;
    final previousPeers = _participants.keys.toSet();
    _participants
      ..clear()
      ..addEntries(
        update.participants.map(
          (participant) => MapEntry(participant.peerId, participant),
        ),
      );
    final availability = _availability(update);
    if (availability != ChatTypingAvailability.available) {
      _clearRemoteTyping();
      _localTyping = false;
      _advertisedPeers.clear();
      _localRefreshTask?.cancel();
      _localRefreshTask = null;
    } else {
      for (final peer in _typing.keys.toList(growable: false)) {
        if (!_participants.containsKey(peer)) {
          _removeRemote(peer);
        }
      }
      for (final message in update.messages) {
        final sender = message.sender;
        if (sender == null) {
          continue;
        }
        final participant = _participants[sender];
        if (participant == null || _isSelf(participant)) {
          continue;
        }
        if (message.type == 'startedTyping') {
          _startRemote(participant);
        } else if (message.type == 'stoppedTyping') {
          _removeRemote(sender);
        }
      }
    }
    _publish(availability);

    if (availability == ChatTypingAvailability.available) {
      if (!wasAvailable && _localActivityRequested) {
        unawaited(_enqueue(_startLocalTyping));
      } else if (_localTyping) {
        final joined = _participants.keys
            .where((peer) => !previousPeers.contains(peer))
            .toList(growable: false);
        if (joined.isNotEmpty) {
          unawaited(_enqueue(() => _sendStarted(joined)));
        }
      }
    }
  }

  ChatTypingAvailability _availability(CallSignalingUpdate update) {
    if (update.failure != null ||
        update.phase == SignalingAccountPhase.unsupported ||
        update.phase == SignalingAccountPhase.terminated ||
        update.phase == SignalingAccountPhase.reauthenticationRequired) {
      return ChatTypingAvailability.unavailable;
    }
    if (update.transport == SignalingTransportKind.internal) {
      return ChatTypingAvailability.unavailable;
    }
    if (update.transport == SignalingTransportKind.externalHpb &&
        update.signalingReady &&
        update.roomConfirmed &&
        !update.federationInterrupted) {
      return ChatTypingAvailability.available;
    }
    return ChatTypingAvailability.connecting;
  }

  bool _isSelf(SignalingParticipant participant) =>
      participant.nextcloudSessionId?.value == key.nextcloudSessionId ||
      (!participant.federated &&
          (participant.actorId == _localLoginName ||
              participant.userId == _localLoginName));

  void _startRemote(SignalingParticipant participant) {
    final peer = participant.peerId;
    _remoteTimeouts.remove(peer)?.cancel();
    _typing[peer] = _projectParticipant(participant);
    late final SignalingScheduledTask timeout;
    timeout = _scheduler.schedule(_remoteTimeout, () {
      if (identical(_remoteTimeouts[peer], timeout)) {
        _remoteTimeouts.remove(peer);
        _typing.remove(peer);
        _publish(_current.availability);
      }
    });
    _remoteTimeouts[peer] = timeout;
  }

  ChatTypingParticipant _projectParticipant(SignalingParticipant participant) =>
      ChatTypingParticipant(
        peerId: participant.peerId.value,
        identity: participant.userId.isNotEmpty && !participant.federated
            ? 'user:${participant.userId}'
            : 'peer:${participant.peerId.value}',
        actorId: participant.actorId,
        displayName: _displayName(participant),
      );

  String _displayName(SignalingParticipant participant) {
    final sessionId = participant.nextcloudSessionId?.value;
    final resolved = sessionId == null
        ? null
        : _participantNames['session:$sessionId'];
    return (resolved ??
            _participantNames['actor:${participant.actorType}:${participant.actorId}'] ??
            participant.actorId.trim().takeIfNotEmpty ??
            participant.userId.trim().takeIfNotEmpty ??
            '')
        .trim();
  }

  void _removeRemote(SignalingPeerId peer) {
    _remoteTimeouts.remove(peer)?.cancel();
    _typing.remove(peer);
  }

  void _clearRemoteTyping() {
    for (final timeout in _remoteTimeouts.values) {
      timeout.cancel();
    }
    _remoteTimeouts.clear();
    _typing.clear();
  }

  Future<void> _startLocalTyping() async {
    if (_localTyping ||
        !_localActivityRequested ||
        _current.availability != ChatTypingAvailability.available) {
      return;
    }
    _localTyping = true;
    await _sendStarted(_participants.keys);
    _scheduleLocalRefresh();
  }

  Future<void> _sendStarted(Iterable<SignalingPeerId> peers) async {
    final targets = peers
        .where((peer) {
          final participant = _participants[peer];
          return participant != null &&
              !_isSelf(participant) &&
              !_advertisedPeers.contains(peer);
        })
        .toList(growable: false);
    if (targets.isEmpty) {
      return;
    }
    final accepted = await _send('startedTyping', targets);
    if (accepted && !_disposed) {
      _advertisedPeers.addAll(targets);
    }
  }

  Future<void> _refreshLocalTyping() async {
    if (!_localTyping ||
        !_localActivityRequested ||
        _current.availability != ChatTypingAvailability.available) {
      return;
    }
    final targets = _participants.entries
        .where((entry) => !_isSelf(entry.value))
        .map((entry) => entry.key)
        .toList(growable: false);
    await _send('startedTyping', targets);
    _advertisedPeers
      ..clear()
      ..addAll(targets);
    _scheduleLocalRefresh();
  }

  Future<void> _stopLocalTyping() async {
    _localRefreshTask?.cancel();
    _localRefreshTask = null;
    if (!_localTyping) {
      _advertisedPeers.clear();
      return;
    }
    _localTyping = false;
    final targets = _advertisedPeers.toList(growable: false);
    _advertisedPeers.clear();
    if (_current.availability == ChatTypingAvailability.available) {
      await _send('stoppedTyping', targets);
    }
  }

  Future<bool> _send(String type, Iterable<SignalingPeerId> peers) async {
    final messages = peers
        .map(
          (peer) => SignalingPeerMessage(
            type: type,
            roomType: '',
            sid: null,
            recipient: peer,
            sender: null,
            payload: null,
          ),
        )
        .toList(growable: false);
    if (messages.isEmpty) {
      return true;
    }
    try {
      return await _sendMessages(messages);
    } on Object {
      return false;
    }
  }

  void _scheduleLocalRefresh() {
    _localRefreshTask?.cancel();
    _localRefreshTask = _scheduler.schedule(_localRefresh, () {
      _localRefreshTask = null;
      unawaited(_enqueue(_refreshLocalTyping));
    });
  }

  void _scheduleLocalIdle(Object source) {
    _localIdleTasks.remove(source)?.cancel();
    late final SignalingScheduledTask task;
    task = _scheduler.schedule(_localIdle, () {
      if (identical(_localIdleTasks[source], task)) {
        _localIdleTasks.remove(source);
        unawaited(recordLocalActivity(source, false));
      }
    });
    _localIdleTasks[source] = task;
  }

  void _publish(ChatTypingAvailability availability) {
    _current = ChatTypingState(
      availability: availability,
      participants: _typing.values,
    );
    if (!_updates.isClosed) {
      _updates.add(_current);
    }
  }

  void _handleTransportDone() {
    if (_disposed) {
      return;
    }
    _clearRemoteTyping();
    _localTyping = false;
    _advertisedPeers.clear();
    _publish(ChatTypingAvailability.unavailable);
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    for (final task in _localIdleTasks.values) {
      task.cancel();
    }
    _localIdleTasks.clear();
    _localActivitySources.clear();
    await _enqueue(_stopLocalTyping);
    _disposed = true;
    _localRefreshTask?.cancel();
    _localRefreshTask = null;
    _clearRemoteTyping();
    await _subscription?.cancel();
    _subscription = null;
    await _release();
    await _updates.close();
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    if (_disposed) {
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _serial = _serial.catchError((_) {}).then((_) async {
      try {
        await operation();
        completer.complete();
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}

extension on String {
  String? get takeIfNotEmpty => isEmpty ? null : this;
}
