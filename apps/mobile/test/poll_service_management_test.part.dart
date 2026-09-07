part of 'poll_service_test.dart';

typedef _PollTestContext = ({
  AppDatabase database,
  AccountRepository accounts,
  ChatRepository chat,
  MemoryCredentialVault vault,
  StoredAccount account,
  CachedConversation conversation,
});

void _registerPollManagementTests(_PollTestContext Function() fixture) {
  _ManagedPollServer server() {
    final built = _ManagedPollServer(fixture());
    addTearDown(built.api.close);
    return built;
  }

  test('draft CRUD and publishing preserve the reusable template', () async {
    final backend = server();
    final draft = await backend.service.createDraft(
      key: backend.key,
      question: 'When?',
      options: ['Morning', 'Evening'],
      resultMode: PollResultMode.public,
      maxVotes: 1,
    );
    expect(draft.status, PollStatus.draft);
    final listed = await backend.service.listDrafts(key: backend.key);
    expect(listed.single.id, draft.id);
    final edited = await backend.service.editDraft(
      key: backend.key,
      draft: listed.single,
      question: 'Lunch?',
      options: ['A', 'B'],
      resultMode: PollResultMode.hiddenUntilClosed,
      maxVotes: 0,
    );
    expect(edited.question, 'Lunch?');
    final published = await backend.service.publishDraft(
      key: backend.key,
      draft: edited,
    );
    expect(published.status, PollStatus.open);
    expect(published.id, isNot(draft.id));
    expect(backend.polls[draft.id]!['status'], 2);
    expect(backend.polls[published.id]!['question'], 'Lunch?');
    await backend.service.deleteDraft(key: backend.key, draft: edited);
    expect(backend.polls.containsKey(draft.id), isFalse);
    expect(backend.polls.containsKey(published.id), isTrue);
    expect(backend.mutations.map((request) => request.method), [
      'POST',
      'POST',
      'POST',
      'DELETE',
    ]);
  });

  test(
    'fresh readonly moderator can list and delete drafts but cannot write or publish',
    () async {
      final backend = server()
        ..polls[7] = _managedPoll(status: 2)
        ..readOnly = true;
      final draft = (await backend.service.listDrafts(key: backend.key)).single;
      final access = await backend.service.managementAccess(
        key: backend.key,
        poll: draft,
      );
      expect(access.canListDrafts, isTrue);
      expect(access.canCreateDraft, isFalse);
      expect(access.canEditDraft, isFalse);
      expect(access.canPublish, isFalse);
      expect(access.canDeleteDraft, isTrue);
      await expectLater(
        backend.service.publishDraft(key: backend.key, draft: draft),
        _pollFailure(PollServiceError.permissionDenied),
      );
      expect(backend.mutations, isEmpty);
      await backend.service.deleteDraft(key: backend.key, draft: draft);
      expect(backend.mutations.single.method, 'DELETE');
    },
  );

  test('canonical author can close and export in a readonly room', () async {
    final backend = server()
      ..role = 3
      ..readOnly = true
      ..polls[7] = _managedPoll();
    final poll = await backend.service.load(key: backend.key, pollId: 7);
    final access = await backend.service.managementAccess(
      key: backend.key,
      poll: poll,
    );
    expect(access.canClose, isTrue);
    expect(access.canExport, isTrue);
    expect(access.canListDrafts, isFalse);
    final csv = await backend.service.export(
      key: backend.key,
      poll: poll,
      format: PollExportFormat.csv,
    );
    expect(utf8.decode(csv.bytes), 'Option,Votes\nA,1\n');
    expect(csv.fileName, 'poll-7.csv');
    expect(csv.mimeType, 'text/csv');
    final closed = await backend.service.close(key: backend.key, poll: poll);
    expect(closed.status, PollStatus.closed);
    final ods = await backend.service.export(
      key: backend.key,
      poll: closed,
      format: PollExportFormat.ods,
    );
    expect(ods.bytes, [0x50, 0x4b, 3, 4, 1, 2]);
    expect(backend.mutations, hasLength(1));
  });

  test(
    'login name is not treated as author and role 5 is not moderator',
    () async {
      final backend = server()
        ..role = 5
        ..polls[7] = _managedPoll(author: 'user-a');
      final poll = await backend.service.load(key: backend.key, pollId: 7);
      final access = await backend.service.managementAccess(
        key: backend.key,
        poll: poll,
      );
      expect(access.canClose, isFalse);
      expect(access.canExport, isFalse);
      expect(access.canListDrafts, isFalse);
      await expectLater(
        backend.service.close(key: backend.key, poll: poll),
        _pollFailure(PollServiceError.permissionDenied),
      );
      expect(backend.mutations, isEmpty);
    },
  );

  test(
    'an author with lobby-ignore may manage a poll while the lobby is active',
    () async {
      final backend = server()
        ..role = 3
        ..polls[7] = _managedPoll()
        ..roomOverrides = {'lobbyState': 1, 'permissions': 8};
      final poll = await backend.service.load(key: backend.key, pollId: 7);
      final access = await backend.service.managementAccess(
        key: backend.key,
        poll: poll,
      );
      expect(access.canClose, isTrue);
      expect(access.canExport, isTrue);
      await backend.service.close(key: backend.key, poll: poll);
      expect(backend.mutations, hasLength(1));
    },
  );

  test('a guest moderator may list but cannot delete draft polls', () async {
    final backend = server()
      ..role = 6
      ..polls[7] = _managedPoll(status: 2);
    final draft = (await backend.service.listDrafts(key: backend.key)).single;
    final access = await backend.service.managementAccess(
      key: backend.key,
      poll: draft,
    );
    expect(access.canListDrafts, isTrue);
    expect(access.canDeleteDraft, isFalse);
    await expectLater(
      backend.service.deleteDraft(key: backend.key, draft: draft),
      _pollFailure(PollServiceError.permissionDenied),
    );
    expect(backend.mutations, isEmpty);
  });

  test(
    'a fresh role revocation overrides an earlier advisory access snapshot',
    () async {
      final backend = server()..polls[7] = _managedPoll(author: 'other-user');
      final poll = await backend.service.load(key: backend.key, pollId: 7);
      expect(
        (await backend.service.managementAccess(
          key: backend.key,
          poll: poll,
        )).canClose,
        isTrue,
      );
      backend.role = 3;
      await expectLater(
        backend.service.close(key: backend.key, poll: poll),
        _pollFailure(PollServiceError.permissionDenied),
      );
      expect(backend.mutations, isEmpty);
    },
  );

  test('draft author may edit after losing moderator role', () async {
    final backend = server()..polls[7] = _managedPoll(status: 2);
    final draft = (await backend.service.listDrafts(key: backend.key)).single;
    backend.role = 3;
    final access = await backend.service.managementAccess(
      key: backend.key,
      poll: draft,
    );
    expect(access.canListDrafts, isFalse);
    expect(access.canEditDraft, isTrue);
    expect(access.canDeleteDraft, isFalse);
    final edited = await backend.service.editDraft(
      key: backend.key,
      draft: draft,
      question: 'Updated?',
      options: ['A', 'B'],
      resultMode: PollResultMode.public,
      maxVotes: 1,
    );
    expect(edited.question, 'Updated?');
  });

  test(
    'a known poll cannot be rebound to another room or rotated credential',
    () async {
      final backend = server()..polls[7] = _managedPoll();
      final poll = await backend.service.load(key: backend.key, pollId: 7);
      final other = (
        accountId: backend.key.accountId,
        roomToken: 'other123',
        threadId: null,
      );
      await expectLater(
        backend.service.close(key: other, poll: poll),
        _pollFailure(PollServiceError.contextMissing),
      );
      fixture().vault.values[backend.key.accountId] = 'replacement-password';
      await expectLater(
        backend.service.close(key: backend.key, poll: poll),
        _pollFailure(PollServiceError.contextMissing),
      );
      expect(backend.mutations, isEmpty);
    },
  );

  test(
    'credential rotation while capabilities load stops management before mutation',
    () async {
      final backend = server();
      backend.beforeReply = (request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          fixture().vault.values[backend.key.accountId] =
              'replacement-password';
        }
      };
      await expectLater(
        backend.service.createDraft(
          key: backend.key,
          question: 'When?',
          options: ['A', 'B'],
          resultMode: PollResultMode.public,
          maxVotes: 1,
        ),
        _pollFailure(PollServiceError.contextMissing),
      );
      expect(backend.mutations, isEmpty);
    },
  );

  test('a failed draft mutation is ambiguous and never replayed', () async {
    final backend = server()..failMutation = true;
    await expectLater(
      backend.service.createDraft(
        key: backend.key,
        question: 'When?',
        options: ['A', 'B'],
        resultMode: PollResultMode.public,
        maxVotes: 1,
      ),
      _pollFailure(PollServiceError.ambiguous),
    );
    expect(backend.mutations, hasLength(1));
  });

  test(
    'publish refuses a deleted thread before creating the ordinary poll',
    () async {
      final backend = server()..polls[7] = _managedPoll(status: 2);
      final draft = (await backend.service.listDrafts(key: backend.key)).single;
      await _insertThreadRoot(
        fixture().database,
        accountId: backend.key.accountId,
        roomToken: backend.key.roomToken,
        deleted: true,
      );
      await expectLater(
        backend.service.publishDraft(
          key: (
            accountId: backend.key.accountId,
            roomToken: backend.key.roomToken,
            threadId: 777,
          ),
          draft: draft,
        ),
        _pollFailure(PollServiceError.contextMissing),
      );
      expect(backend.mutations, isEmpty);
    },
  );
}

Matcher _pollFailure(PollServiceError code) =>
    throwsA(isA<PollServiceException>().having((e) => e.code, 'code', code));

Map<String, Object?> _managedPoll({
  int id = 7,
  int status = 0,
  String author = 'canonical-user',
}) => {
  'id': id,
  'question': 'When?',
  'options': ['A', 'B'],
  'actorType': 'users',
  'actorId': author,
  'actorDisplayName': 'User',
  'status': status,
  'resultMode': 0,
  'maxVotes': 1,
  if (status != 2) ...{
    'votes': <Object?>[],
    'votedSelf': <int>[],
    'numVoters': 0,
  },
};

final class _ManagedPollServer {
  _ManagedPollServer(this.context) {
    api = HttpNextcloudApi(client: MockClient(_handle));
    service = PollService(
      accounts: context.accounts,
      chat: context.chat,
      credentials: context.vault,
      api: api,
    );
  }
  final _PollTestContext context;
  late final HttpNextcloudApi api;
  late final PollService service;
  PollRoomKey get key => (
    accountId: context.account.id,
    roomToken: context.conversation.token,
    threadId: null,
  );
  final polls = <int, Map<String, Object?>>{};
  final mutations = <http.Request>[];
  int role = 2;
  bool readOnly = false;
  bool failMutation = false;
  Map<String, Object?> roomOverrides = {};
  Future<void> Function(http.Request)? beforeReply;
  final features = {
    'talk-polls',
    'talk-polls-drafts',
    'edit-draft-poll',
    'threads',
  };

  Future<http.Response> _handle(http.Request request) async {
    await beforeReply?.call(request);
    if (request.url.path.endsWith('/cloud/capabilities')) {
      return _capabilities(features);
    }
    if (request.url.path.endsWith('/cloud/user')) {
      return _reply({'id': 'canonical-user', 'displayname': 'User'});
    }
    if (request.url.path.endsWith('/api/v4/room')) {
      final room =
          Map<String, Object?>.from(
              jsonDecode(context.conversation.rawJson) as Map<String, Object?>,
            )
            ..['participantType'] = role
            ..['readOnly'] = readOnly ? 1 : 0
            ..addAll(roomOverrides);
      return _reply([room]);
    }
    if (!request.url.path.contains('/poll/')) {
      throw StateError('Unexpected endpoint');
    }
    if (request.method != 'GET') {
      mutations.add(request);
      if (failMutation) throw http.ClientException('connection lost');
    }
    final segments = request.url.pathSegments;
    if (segments.last == 'drafts') {
      return _reply(polls.values.where((p) => p['status'] == 2).toList());
    }
    if (segments.contains('export')) {
      return segments.last == 'csv'
          ? http.Response(
              'Option,Votes\nA,1\n',
              200,
              headers: {'content-type': 'text/csv'},
            )
          : http.Response.bytes(
              [0x50, 0x4b, 3, 4, 1, 2],
              200,
              headers: {
                'content-type':
                    'application/vnd.oasis.opendocument.spreadsheet',
              },
            );
    }
    final id = int.tryParse(segments.last);
    if (id != null) {
      final poll = polls[id];
      if (poll == null) return _reply(null, status: 404);
      if (request.method == 'DELETE') {
        if (poll['status'] == 2) {
          polls.remove(id);
          return _reply(null, status: 202);
        }
        poll['status'] = 1;
      } else if (request.method == 'POST') {
        poll.addAll((jsonDecode(request.body) as Map).cast<String, Object?>());
      }
      return _reply(poll);
    }
    final form = (jsonDecode(request.body) as Map).cast<String, Object?>();
    final next = polls.isEmpty
        ? 10
        : polls.keys.reduce((a, b) => a > b ? a : b) + 1;
    final draft = form.remove('draft') == true;
    final created = _managedPoll(id: next, status: draft ? 2 : 0)..addAll(form);
    polls[next] = created;
    return _reply(created, status: draft ? 200 : 201);
  }

  http.Response _reply(Object? data, {int status = 200}) => http.Response(
    jsonEncode({
      'ocs': {
        'meta': {
          'status': status < 400 ? 'ok' : 'failure',
          'statuscode': status,
          'message': '',
        },
        'data': data,
      },
    }),
    status,
    headers: {'content-type': 'application/json'},
  );
}
