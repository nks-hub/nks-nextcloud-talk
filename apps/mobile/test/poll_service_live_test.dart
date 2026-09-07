import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_repository.dart';
import 'package:nextcloudtalk/features/chat/chat_message_actions_service.dart';
import 'package:nextcloudtalk/features/chat/poll_service.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';
import 'package:uuid/uuid.dart';

import 'test_support.dart';

/// Opt-in writes only to a two-test-account group verified before mutations.
/// Credentials belong in runtime environment variables, never dart-defines.
/// Requires NCTALK_POLL_ORIGIN, NCTALK_POLL_ROOM_NAME, NCTALK_POLL_OWNER,
/// NCTALK_POLL_MEMBER and their respective _PASSWORD environment variables.
void main() {
  test(
    'live PollService owner/member lifecycle, drafts and exports',
    () async {
      final live = _LivePolls();
      try {
        await live.prepare();
        await live.exercise();
      } finally {
        try {
          await live.cleanup();
        } finally {
          stdout.writeln(jsonEncode(live.receipt));
          await live.dispose();
        }
      }
    },
    skip: Platform.environment['NCTALK_POLL_LIVE'] != 'YES'
        ? 'Set NCTALK_POLL_LIVE=YES and the dedicated test-room environment.'
        : false,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

String _environment(String name) {
  final value = Platform.environment[name];
  if (value == null || value.isEmpty) throw StateError('Missing $name');
  return value;
}

final class _LivePolls {
  final database = openTestDatabase();
  final vault = MemoryCredentialVault();
  final marker = 'Poll verification ${const Uuid().v4()}';
  final polls = <int, TalkPoll>{};
  final drafts = <int, TalkPoll>{};
  final createdIds = <int>{};
  final receipt = <String, Object?>{
    'event': 'poll-service-live',
    'exports': <Object?>[],
  };
  _LiveAccount? _owner;
  _LiveAccount? _member;
  _LiveAccount get owner => _owner!;
  _LiveAccount get member => _member!;
  late String roomName;
  bool dedicated = false;

  Future<void> prepare() async {
    final server = ServerBase.parse(_environment('NCTALK_POLL_ORIGIN'));
    if (server.uri.scheme != 'https') throw StateError('HTTPS is required');
    roomName = _environment('NCTALK_POLL_ROOM_NAME');
    if (!RegExp(r'e2e|test', caseSensitive: false).hasMatch(roomName)) {
      throw StateError('The dedicated room must be labelled as a test room');
    }
    _owner = _LiveAccount(
      'poll-owner',
      _environment('NCTALK_POLL_OWNER'),
      _environment('NCTALK_POLL_OWNER_PASSWORD'),
      server,
      database,
      vault,
    );
    _member = _LiveAccount(
      'poll-member',
      _environment('NCTALK_POLL_MEMBER'),
      _environment('NCTALK_POLL_MEMBER_PASSWORD'),
      server,
      database,
      vault,
    );
    if (owner.username == member.username ||
        ![
          owner.username,
          member.username,
        ].every((name) => name.toLowerCase().contains('test'))) {
      throw StateError('Two distinct dedicated test accounts are required');
    }
    await owner.prepare(roomName);
    await member.prepare(roomName);
    await verifyDedicatedRoom();
    dedicated = true;
    receipt['marker'] = marker;
  }

  Future<void> verifyDedicatedRoom() async {
    await owner.refreshExactRoom();
    await member.refreshExactRoom();
    if (owner.room.displayName != roomName ||
        member.room.displayName != roomName ||
        owner.room.token != member.room.token ||
        owner.room.type != 2 ||
        owner.room.participantType != 1 ||
        member.room.participantType != 3 ||
        owner.room.readOnly != 0 ||
        member.room.readOnly != 0 ||
        owner.room.hasCall ||
        member.room.hasCall) {
      throw StateError('Dedicated owner/member room admission failed');
    }
    final participants = await owner.api.getParticipants(
      participantsRequest: ParticipantsRequest(
        accountId: AccountId.parse(owner.id),
        server: owner.server,
        roomToken: owner.room.token,
        includeStatus: false,
      ),
      loginName: owner.username,
      appPassword: owner.password,
    );
    if (participants is! ParticipantsSuccess ||
        participants.participants.length != 2 ||
        participants.participants.any((actor) => actor.actorType != 'users') ||
        !participants.participants
            .map((actor) => actor.actorId)
            .toSet()
            .containsAll({owner.userId, member.userId})) {
      throw StateError(
        'The room must contain only the verified two test accounts',
      );
    }
  }

  Future<void> exercise() async {
    for (final mode in PollResultMode.values) {
      await verifyDedicatedRoom();
      var poll = await owner.service.create(
        key: owner.key,
        question: '$marker ${mode.name}',
        options: const ['First choice', 'Second choice'],
        resultMode: mode,
        maxVotes: 1,
      );
      track(poll);
      var peer = await member.service.load(key: member.key, pollId: poll.id);
      expect(peer.status, PollStatus.open);
      await expectLater(
        member.service.close(key: member.key, poll: peer),
        _failure(PollServiceError.permissionDenied),
      );
      await expectLater(
        member.service.close(key: member.key, poll: poll),
        _failure(PollServiceError.contextMissing),
      );
      peer = await member.service.vote(
        key: member.key,
        poll: peer,
        optionIds: [1],
      );
      expect(peer.votedSelf, [1]);
      if (mode == PollResultMode.hiddenUntilClosed) expect(peer.votes, isEmpty);
      poll = await owner.service.vote(
        key: owner.key,
        poll: poll,
        optionIds: [0],
      );
      track(poll);
      expect(poll.votedSelf, [0]);
      final closed = await owner.service.close(key: owner.key, poll: poll);
      expect(closed.status, PollStatus.closed);
      expect(closed.numVoters, 2);
      expect(closed.votes, {0: 1, 1: 1});
      polls.remove(poll.id);
      peer = await member.service.load(key: member.key, pollId: poll.id);
      expect(peer.status, PollStatus.closed);
      expect(peer.votes, {0: 1, 1: 1});
      for (final format in PollExportFormat.values) {
        await verifyExport(closed, format);
      }
    }

    await verifyDedicatedRoom();
    var draft = await owner.service.createDraft(
      key: owner.key,
      question: '$marker draft',
      options: const ['Early', 'Late'],
      resultMode: PollResultMode.public,
      maxVotes: 1,
    );
    if (draft.actorType != 'users' ||
        draft.actorId != owner.userId ||
        !draft.question.startsWith(marker)) {
      throw StateError('Draft confirmation was not owned by this run');
    }
    drafts[draft.id] = draft;
    receipt['createdDraftId'] = draft.id;
    expect(draft.status, PollStatus.draft);
    await expectLater(
      member.service.listDrafts(key: member.key),
      _failure(PollServiceError.permissionDenied),
    );
    final denied = await member.api.getPollDrafts(
      pollRequest: PollDraftListRequest(
        accountId: AccountId.parse(member.id),
        requestId: ChatRequestId.parse('live-draft-denial'),
        server: member.server,
        roomToken: member.room.token,
        pollsAvailable: true,
        draftsAvailable: true,
        isModerator: true,
      ),
      loginName: member.username,
      appPassword: member.password,
    );
    expect(denied.classification, PollResponseClassification.permissionDenied);
    expect(member.client.pollStatuses.last, 403);
    receipt['memberDraftListStatus'] = 403;
    draft = await owner.service.editDraft(
      key: owner.key,
      draft: draft,
      question: '$marker edited draft',
      options: const ['Early', 'Late'],
      resultMode: PollResultMode.hiddenUntilClosed,
      maxVotes: 0,
    );
    expect(draft.question == '$marker edited draft', isTrue);
    expect(draft.options, ['Early', 'Late']);
    expect(draft.resultMode, PollResultMode.hiddenUntilClosed);
    expect(draft.maxVotes, 0);
    drafts[draft.id] = draft;
    final listed = await owner.service.listDrafts(key: owner.key);
    final saved = listed.singleWhere((item) => item.id == draft.id);
    expect(saved.question == draft.question, isTrue);
    final published = await owner.service.publishDraft(
      key: owner.key,
      draft: saved,
    );
    track(published);
    expect(published.id == draft.id, isFalse);
    expect(published.question == draft.question, isTrue);
    expect(
      (await owner.service.listDrafts(
        key: owner.key,
      )).any((item) => item.id == draft.id),
      isTrue,
    );
    expect(
      (await owner.service.close(key: owner.key, poll: published)).status,
      PollStatus.closed,
    );
    polls.remove(published.id);
    await owner.service.deleteDraft(key: owner.key, draft: saved);
    drafts.remove(draft.id);
    expect(
      (await owner.service.listDrafts(
        key: owner.key,
      )).any((item) => item.id == draft.id),
      isFalse,
    );
    receipt['draftId'] = draft.id;
    receipt['publishedPollId'] = published.id;
    receipt['lifecyclePassed'] = true;
  }

  void track(TalkPoll poll) {
    if (poll.actorType != 'users' ||
        poll.actorId != owner.userId ||
        !poll.question.startsWith(marker)) {
      throw StateError('Server confirmation was not this run\'s poll');
    }
    createdIds.add(poll.id);
    receipt['createdPollIds'] = createdIds.toList();
    polls[poll.id] = poll;
  }

  Future<void> verifyExport(TalkPoll poll, PollExportFormat format) async {
    final file = await owner.service.export(
      key: owner.key,
      poll: poll,
      format: format,
    );
    expect(file.mimeType, format.mimeType);
    expect(file.fileName, 'poll-${poll.id}.${format.name}');
    final text = format == PollExportFormat.csv
        ? utf8.decode(file.bytes)
        : utf8.decode(_zipMember(file.bytes, 'content.xml'));
    expect(
      text.contains(poll.question),
      isTrue,
      reason: 'Export must contain this poll question',
    );
    expect(
      text.contains('First choice') && text.contains('Second choice'),
      isTrue,
    );
    if (format == PollExportFormat.ods) {
      expect(utf8.decode(_zipMember(file.bytes, 'mimetype')), format.mimeType);
      expect(
        text.contains('office:value="2"'),
        isTrue,
        reason: 'ODS must contain both voters',
      );
      expect(
        text.contains('table:name="Votes"'),
        poll.resultMode == PollResultMode.public,
        reason: 'Only a public poll export may include individual voters',
      );
    } else {
      expect(
        text.contains('total-voters,2'),
        isTrue,
        reason: 'CSV must contain both voters',
      );
      expect(
        text.contains('\nvoter,option'),
        poll.resultMode == PollResultMode.public,
        reason: 'Only a public poll export may include individual voters',
      );
    }
    (receipt['exports'] as List).add({
      'pollId': poll.id,
      'format': format.name,
      'bytes': file.bytes.length,
      'sha256': sha256.convert(file.bytes).toString(),
    });
  }

  Future<void> cleanup() async {
    if (!dedicated) return;
    await verifyDedicatedRoom();
    for (final draft in drafts.values.toList()) {
      await owner.service.deleteDraft(key: owner.key, draft: draft);
      drafts.remove(draft.id);
    }
    for (final poll in polls.values.toList()) {
      final latest = await owner.service.load(key: owner.key, pollId: poll.id);
      if (latest.status == PollStatus.open) {
        await owner.service.close(key: owner.key, poll: latest);
      }
      polls.remove(poll.id);
    }
    receipt['createdPollIds'] = createdIds.toList();
    receipt['openPollsLeft'] = polls.length;
    receipt['draftsLeft'] = drafts.length;
    await cleanupMessages();
  }

  Future<void> cleanupMessages() async {
    final history = await owner.api.getChat(
      chatRequest: ChatFetchRequest(
        accountId: AccountId.parse(owner.id),
        requestId: ChatRequestId.parse('poll-live-cleanup'),
        server: owner.server,
        roomToken: owner.room.token,
        profile: ChatCapabilityProfile.fromSnapshot(
          owner.capabilities,
          federated: false,
        ),
        direction: ChatFetchDirection.history,
        cursor: ChatCursor.parse('0'),
        lastCommonRead: ChatCursor.parse('0'),
        limit: 100,
        includeLastKnown: false,
        timeoutSeconds: 0,
        interactive: false,
      ),
      loginName: owner.username,
      appPassword: owner.password,
    );
    final removed = <int>[];
    final retained = <int>[];
    for (final message in history.messages) {
      final ours =
          message.actorType == 'users' &&
          {owner.userId, member.userId}.contains(message.actorId) &&
          message.roomToken == owner.room.token &&
          message.messageParameters.values.any(
            (parameter) =>
                parameter.type == 'talk-poll' &&
                createdIds.contains(int.tryParse(parameter.id ?? '')),
          );
      if (!ours) continue;
      // Talk permits deleting object_shared posts, but not poll_closed or
      // poll_voted system events (ChatController::deleteMessage returns 405).
      if (message.systemMessage.isNotEmpty &&
          message.systemMessage != 'object_shared') {
        retained.add(message.messageId);
        continue;
      }
      final actor = message.actorId == owner.userId ? owner : member;
      final actions = ChatMessageActionsService(
        accounts: AccountRepository(database),
        chat: ChatRepository(database),
        credentials: vault,
        api: actor.api,
      );
      try {
        await actions.deleteMessage(
          accountId: actor.id,
          roomToken: actor.room.token.value,
          messageId: message.messageId,
        );
        removed.add(message.messageId);
      } on ChatMessageActionException {
        retained.add(message.messageId);
      }
    }
    receipt['removedMessageIds'] = removed;
    receipt['retainedMessageIds'] = retained;
  }

  Future<void> dispose() async {
    _owner?.api.close();
    _member?.api.close();
    await database.close();
  }
}

Matcher _failure(PollServiceError code) =>
    throwsA(isA<PollServiceException>().having((e) => e.code, 'code', code));

final class _LiveAccount {
  _LiveAccount(
    this.id,
    this.username,
    this.password,
    this.server,
    this.database,
    this.vault,
  ) {
    api = HttpNextcloudApi(client: client);
    service = PollService(
      accounts: AccountRepository(database),
      chat: ChatRepository(database),
      credentials: vault,
      api: api,
    );
  }
  final String id;
  final String username;
  final String password;
  final ServerBase server;
  final AppDatabase database;
  final MemoryCredentialVault vault;
  final client = _PollHttpRecorder();
  late final HttpNextcloudApi api;
  late final PollService service;
  late CapabilitySnapshot capabilities;
  late ConversationRoom room;
  late final ConversationToken _verifiedRoomToken;
  late String userId;
  PollRoomKey get key =>
      (accountId: id, roomToken: room.token.value, threadId: null);

  Future<void> prepare(String roomName) async {
    capabilities = await api.getAuthenticatedCapabilities(
      server: server,
      loginName: username,
      appPassword: password,
    );
    if (!capabilities.talkFeatures.containsAll({
      'talk-polls',
      'talk-polls-drafts',
      'edit-draft-poll',
    })) {
      throw StateError('Required poll capabilities are absent');
    }
    userId = (await api.getOwnProfile(
      server: server,
      loginName: username,
      appPassword: password,
    )).userId;
    if (userId != username) {
      throw StateError('Canonical test identity did not match');
    }
    final response = await api.getConversations(
      conversationRequest: ConversationListRequest(
        accountId: AccountId.parse(id),
        requestId: ConversationRequestId.parse('poll-live-preflight'),
        server: server,
        mode: ConversationFetchMode.full,
        includeLastMessage: false,
      ),
      loginName: username,
      appPassword: password,
    );
    if (response is! ConversationListSuccess) {
      throw StateError('Room preflight was refused');
    }
    final matches = response.rooms.where(
      (room) => room.displayName == roomName && room.type == 2,
    );
    if (matches.length != 1) {
      throw StateError('Dedicated test room is not unique');
    }
    room = matches.single;
    _verifiedRoomToken = room.token;
    await AccountRepository(database).upsertAccount(
      accountId: id,
      serverUrl: server.uri.toString(),
      loginName: username,
      serverProductName: 'Nextcloud',
      talkFeatures: capabilities.talkFeatures,
      createdAt: DateTime.now().toUtc(),
    );
    vault.values[id] = password;
    await database
        .into(database.cachedConversations)
        .insert(
          CachedConversationsCompanion.insert(
            accountId: id,
            token: room.token.value,
            displayName: room.displayName,
            description: room.description,
            lastActivity: room.lastActivity,
            unreadMessages: room.unreadMessages,
            favorite: room.isFavorite,
            readOnly: Value(room.readOnly),
            roomType: Value(room.type),
            roomName: Value(room.name),
            rawJson: jsonEncode(room.wire),
          ),
        );
  }

  Future<void> refreshExactRoom() async {
    final response = await api.getConversations(
      conversationRequest: ConversationListRequest(
        accountId: AccountId.parse(id),
        requestId: ConversationRequestId.parse('poll-live-refresh'),
        server: server,
        mode: ConversationFetchMode.full,
        includeLastMessage: false,
      ),
      loginName: username,
      appPassword: password,
    );
    if (response is! ConversationListSuccess) {
      throw StateError('Dedicated room refresh was refused');
    }
    final matches = response.rooms.where(
      (room) => room.token == _verifiedRoomToken,
    );
    if (matches.length != 1) {
      throw StateError('Original dedicated room is no longer available');
    }
    room = matches.single;
  }
}

final class _PollHttpRecorder extends http.BaseClient {
  final _inner = http.Client();
  final pollStatuses = <int>[];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _inner.send(request);
    if (request.url.path.contains('/poll/')) {
      pollStatuses.add(response.statusCode);
    }
    return response;
  }

  @override
  void close() => _inner.close();
}

Uint8List _zipMember(Uint8List bytes, String wanted) {
  final data = ByteData.sublistView(bytes);
  int u16(int offset) => data.getUint16(offset, Endian.little);
  int u32(int offset) => data.getUint32(offset, Endian.little);
  var end = bytes.length - 22;
  while (end >= 0 && u32(end) != 0x06054b50) {
    end--;
  }
  if (end < 0 || u16(end + 10) > 100) throw StateError('Invalid ODS directory');
  var offset = u32(end + 16);
  for (var count = 0; count < u16(end + 10); count++) {
    if (u32(offset) != 0x02014b50) throw StateError('Invalid ODS entry');
    final length = u16(offset + 28);
    final name = utf8.decode(bytes.sublist(offset + 46, offset + 46 + length));
    if (name == wanted) {
      if (u16(offset + 8) & 1 != 0 || u32(offset + 24) > 2 * 1024 * 1024) {
        throw StateError('Unsupported ODS member');
      }
      final local = u32(offset + 42);
      if (u32(local) != 0x04034b50) throw StateError('Invalid ODS local entry');
      final start = local + 30 + u16(local + 26) + u16(local + 28);
      final packed = bytes.sublist(start, start + u32(offset + 20));
      if (u16(offset + 10) == 0) return packed;
      if (u16(offset + 10) != 8) {
        throw StateError('Unsupported ODS compression');
      }
      final sink = _BoundedBytes();
      ZLibDecoder(raw: true).startChunkedConversion(sink)
        ..add(packed)
        ..close();
      return sink.bytes.takeBytes();
    }
    offset += 46 + length + u16(offset + 30) + u16(offset + 32);
  }
  throw StateError('Required ODS member is absent');
}

final class _BoundedBytes extends ByteConversionSink {
  final bytes = BytesBuilder(copy: false);
  @override
  void add(List<int> chunk) {
    if (bytes.length + chunk.length > 2 * 1024 * 1024) {
      throw StateError('ODS member is too large');
    }
    bytes.add(chunk);
  }

  @override
  void close() {}
}
