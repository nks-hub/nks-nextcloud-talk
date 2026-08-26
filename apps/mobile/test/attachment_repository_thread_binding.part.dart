part of 'attachment_repository_test.dart';

void _registerAttachmentRepositoryThreadBindingTests() {
  group('thread admission', () {
    for (final named in const <bool>[false, true]) {
      test(
        'classifier applies and matches a ${named ? 'named' : 'ordinary'} root',
        () async {
          final database = AppDatabase.forTesting(NativeDatabase.memory());
          addTearDown(database.close);
          await _insertAccount(database, 'account-a');
          await _insertCachedThreadRoot(database, rootId: 42, named: named);
          final root = await database
              .select(database.cachedChatMessages)
              .getSingle();
          final binding = AttachmentThreadBinding.fromCachedRoot(
            root: root,
            accountId: 'account-a',
            roomToken: 'rooma123',
            rootMessageId: 42,
          );
          final stale = AttachmentMetadata(
            kind: AttachmentMessageKind.file,
            replyTo: named ? 42 : null,
            threadId: named ? null : 42,
            threadTitle: named ? null : 'Synthetic thread',
            silent: false,
          );

          final current = binding.applyTo(stale);

          expect(binding.matches(stale), isFalse);
          expect(binding.matches(current), isTrue);
          expect(current.replyTo, named ? isNull : 42);
          expect(current.threadId, named ? 42 : isNull);
          expect(current.threadTitle, named ? 'Synthetic thread' : isNull);
        },
      );
    }

    for (final transition in const <({bool before, bool after})>[
      (before: false, after: true),
      (before: true, after: false),
    ]) {
      test('rejects a prepared ${transition.before ? 'named' : 'ordinary'} '
          'binding after the root becomes '
          '${transition.after ? 'named' : 'ordinary'}', () async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);
        await _insertAccount(database, 'account-a');
        await _insertCachedThreadRoot(
          database,
          rootId: 42,
          named: transition.before,
        );
        final stale = _runtime(
          accountId: 'account-a',
          sourceHandle: 'nctalk-media-v1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          replyTo: transition.before ? null : 42,
          threadId: transition.before ? 42 : null,
        );
        await _insertCachedThreadRoot(
          database,
          rootId: 42,
          named: transition.after,
        );
        final repository = AttachmentRepository(database);

        await expectLater(
          repository.persistAdmission(
            account: stale.snapshot.accounts.values.single,
            job: stale.job,
            metadata: stale.metadata,
            updatedAt: DateTime.utc(2026, 8, 26),
          ),
          throwsStateError,
        );
        expect(await database.select(database.attachmentJobs).get(), isEmpty);

        final current = _runtime(
          accountId: 'account-a',
          sourceHandle: 'nctalk-media-v1:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          replyTo: transition.after ? null : 42,
          threadId: transition.after ? 42 : null,
        );
        await repository.persistAdmission(
          account: current.snapshot.accounts.values.single,
          job: current.job,
          metadata: current.metadata,
          updatedAt: DateTime.utc(2026, 8, 26),
        );

        final stored = await database
            .select(database.attachmentJobs)
            .getSingle();
        expect(stored.replyTo, transition.after ? isNull : 42);
        expect(stored.threadId, transition.after ? 42 : isNull);
      });
    }

    test(
      'rejects a stale named-thread title without a durable insert',
      () async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);
        await _insertAccount(database, 'account-a');
        await _insertCachedThreadRoot(
          database,
          rootId: 42,
          named: true,
          title: 'Original title',
        );
        final stale = _runtime(
          accountId: 'account-a',
          sourceHandle: 'nctalk-media-v1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          threadId: 42,
          threadTitle: 'Original title',
        );
        await _insertCachedThreadRoot(
          database,
          rootId: 42,
          named: true,
          title: 'Current title',
        );

        await expectLater(
          AttachmentRepository(database).persistAdmission(
            account: stale.snapshot.accounts.values.single,
            job: stale.job,
            metadata: stale.metadata,
            updatedAt: DateTime.utc(2026, 8, 26),
          ),
          throwsStateError,
        );
        expect(await database.select(database.attachmentJobs).get(), isEmpty);
      },
    );

    test('fails closed for an oversized named-thread title', () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await _insertAccount(database, 'account-a');
      await _insertCachedThreadRoot(
        database,
        rootId: 42,
        named: true,
        title: 'x' * 201,
      );
      final root = await database
          .select(database.cachedChatMessages)
          .getSingle();

      expect(
        () => AttachmentThreadBinding.fromCachedRoot(
          root: root,
          accountId: 'account-a',
          roomToken: 'rooma123',
          rootMessageId: 42,
        ),
        throwsStateError,
      );
    });

    for (final scope in const <String>[
      'missing root',
      'other account',
      'other room',
      'deleted root',
      'invalid payload',
    ]) {
      test('fails closed for $scope', () async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);
        await _insertAccount(database, 'account-a');
        await _insertAccount(database, 'account-b');
        if (scope != 'missing root') {
          await _insertCachedThreadRoot(
            database,
            accountId: scope == 'other account' ? 'account-b' : 'account-a',
            roomToken: scope == 'other room' ? 'roomb456' : 'rooma123',
            rootId: 42,
            named: false,
            deleted: scope == 'deleted root',
            validPayload: scope != 'invalid payload',
          );
        }
        final runtime = _runtime(
          accountId: 'account-a',
          sourceHandle: 'nctalk-media-v1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          replyTo: 42,
          threadId: null,
        );

        await expectLater(
          AttachmentRepository(database).persistAdmission(
            account: runtime.snapshot.accounts.values.single,
            job: runtime.job,
            metadata: runtime.metadata,
            updatedAt: DateTime.utc(2026, 8, 26),
          ),
          throwsStateError,
        );
        expect(await database.select(database.attachmentJobs).get(), isEmpty);
      });
    }
  });
}

Future<void> _insertCachedThreadRoot(
  AppDatabase database, {
  String accountId = 'account-a',
  String roomToken = 'rooma123',
  required int rootId,
  required bool named,
  String title = 'Synthetic thread',
  bool deleted = false,
  bool validPayload = true,
}) {
  final response =
      readFixtureJson(
            'chat-messages/fixtures/chat-thread-future.response.json',
          )!
          as Map<String, Object?>;
  final ocs = response['ocs']! as Map<String, Object?>;
  final data = ocs['data']! as List<Object?>;
  final message = data.single! as Map<String, Object?>;
  final root = message['parent']! as Map<String, Object?>
    ..['id'] = rootId
    ..['token'] = roomToken
    ..['threadId'] = rootId
    ..['isThread'] = named
    ..['threadTitle'] = named ? title : null
    ..['threadReplies'] = named ? 0 : 1
    ..['deleted'] = deleted ? true : null;
  return database
      .into(database.cachedChatMessages)
      .insertOnConflictUpdate(
        CachedChatMessagesCompanion.insert(
          accountId: accountId,
          roomToken: roomToken,
          messageId: rootId,
          actorType: 'users',
          actorId: 'fixture-user',
          actorDisplayName: 'Fixture User',
          timestamp: 1770000000 + rootId,
          systemMessage: '',
          messageType: 'comment',
          referenceId: '',
          displayText: 'Thread root',
          deleted: deleted,
          threadId: Value(rootId),
          rawJson: validPayload ? jsonEncode(root) : '{invalid',
        ),
      );
}
