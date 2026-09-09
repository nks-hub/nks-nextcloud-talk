import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/chat/chat_message_actions_service.dart';
import 'package:nextcloudtalk/features/chat/outgoing_message_status.dart';
import 'package:nextcloudtalk/features/reminders/reminder_inbox.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  group('fan-out', () {
    // Room tokens and message IDs are per server, so nothing stops two
    // accounts from holding a reminder that agrees on both. They are two
    // reminders; a list keyed on the token would show one and delete the
    // wrong one.
    test(
      'two accounts colliding on token and message ID keep both rows',
      () async {
        final inbox = await loadReminderInbox(
          accounts: <StoredAccount>[_accountA, _accountB],
          lister: (accountId) async => <RichChatUpcomingReminder>[
            _reminder(
              deadline: accountId == 'account-a'
                  ? 1_789_041_873
                  : 1_789_045_473,
            ),
          ],
          conversationName: (accountId, roomToken) async =>
              accountId == 'account-a' ? 'Room on A' : 'Room on B',
        );

        expect(inbox.rows, hasLength(2));
        expect(inbox.unreadableAccounts, isEmpty);
        expect(inbox.rows.map((row) => row.identity).toSet(), hasLength(2));
        expect(inbox.rows.map((row) => row.roomToken).toSet(), <String>{
          'hqowhbbz',
        });
        expect(inbox.rows.map((row) => row.messageId).toSet(), <int>{79988});
        expect(inbox.rows.first.accountId, 'account-a');
        expect(inbox.rows.first.conversationName, 'Room on A');
        expect(inbox.rows.last.accountId, 'account-b');
        expect(inbox.rows.last.conversationName, 'Room on B');
      },
    );

    test('one unavailable account does not empty the list', () async {
      final inbox = await loadReminderInbox(
        accounts: <StoredAccount>[_accountA, _accountB],
        lister: (accountId) async {
          if (accountId == 'account-a') {
            throw const ChatMessageActionException(
              ChatMessageActionError.credentialMissing,
            );
          }
          return <RichChatUpcomingReminder>[_reminder()];
        },
        conversationName: (_, _) async => 'Room',
      );

      expect(inbox.rows, hasLength(1));
      expect(inbox.rows.single.accountId, 'account-b');
      expect(inbox.unreadableAccounts, <String>['user-a@a.example.invalid']);
      expect(inbox.everythingFailed, isFalse);
    });

    // No rows and no failures is "nothing pending"; no rows because every
    // account refused is "we do not know", and the screen must not claim the
    // first when it means the second.
    test('every account failing is not an empty inbox', () async {
      final inbox = await loadReminderInbox(
        accounts: <StoredAccount>[_accountA, _accountB],
        lister: (_) async => throw const ChatMessageActionException(
          ChatMessageActionError.network,
        ),
        conversationName: (_, _) async => 'Room',
      );

      expect(inbox.rows, isEmpty);
      expect(inbox.unreadableAccounts, hasLength(2));
      expect(inbox.everythingFailed, isTrue);
    });

    test('nothing pending anywhere is an empty inbox', () async {
      final inbox = await loadReminderInbox(
        accounts: <StoredAccount>[_accountA, _accountB],
        lister: (_) async => const <RichChatUpcomingReminder>[],
        conversationName: (_, _) async => 'Room',
      );

      expect(inbox.rows, isEmpty);
      expect(inbox.unreadableAccounts, isEmpty);
      expect(inbox.everythingFailed, isFalse);
    });

    test(
      'the fan-out never exceeds its limit and still asks everybody',
      () async {
        final accounts = <StoredAccount>[
          for (var index = 0; index < 7; index++)
            _accountA.copyWith(
              id: 'account-$index',
              serverUrl: 'https://s$index.example.invalid',
            ),
        ];
        final pending = <String, Completer<void>>{};
        var inFlight = 0;
        var peak = 0;
        final asked = <String>[];

        final future = loadReminderInbox(
          accounts: accounts,
          concurrency: 2,
          lister: (accountId) async {
            asked.add(accountId);
            inFlight++;
            peak = peak > inFlight ? peak : inFlight;
            final gate = pending[accountId] = Completer<void>();
            await gate.future;
            inFlight--;
            return const <RichChatUpcomingReminder>[];
          },
          conversationName: (_, _) async => 'Room',
        );

        // Release the requests one at a time; each release lets exactly one more
        // account start, so the count in flight can never pass the limit.
        for (var released = 0; released < accounts.length; released++) {
          await Future<void>.delayed(Duration.zero);
          expect(inFlight, lessThanOrEqualTo(2));
          pending.values.where((gate) => !gate.isCompleted).first.complete();
        }
        await future;

        expect(peak, 2);
        expect(asked, hasLength(7));
        expect(asked.toSet(), hasLength(7));
      },
    );

    test('rows come back soonest deadline first', () async {
      final inbox = await loadReminderInbox(
        accounts: <StoredAccount>[_accountA],
        lister: (_) async => <RichChatUpcomingReminder>[
          _reminder(messageId: 3, deadline: 1_789_045_473),
          _reminder(messageId: 1, deadline: 1_789_041_873),
          _reminder(messageId: 2, deadline: 1_789_043_000),
        ],
        conversationName: (_, _) async => 'Room',
      );

      expect(inbox.rows.map((row) => row.messageId).toList(), <int>[1, 2, 3]);
    });
  });

  group('screen', () {
    testWidgets('an empty inbox says so', (tester) async {
      await _pumpScreen(tester, accounts: <StoredAccount>[_accountA]);

      expect(find.byKey(const Key('reminder-inbox-empty')), findsOneWidget);
      expect(find.byKey(const Key('reminder-inbox-list')), findsNothing);
    });

    testWidgets('an unreadable account is named without hiding the rest', (
      tester,
    ) async {
      await _pumpScreen(
        tester,
        accounts: <StoredAccount>[_accountA, _accountB],
        lister: (accountId) async {
          if (accountId == 'account-a') {
            throw const ChatMessageActionException(
              ChatMessageActionError.network,
            );
          }
          return <RichChatUpcomingReminder>[_reminder()];
        },
      );

      expect(
        find.byKey(const Key('reminder-inbox-accounts-unavailable')),
        findsOneWidget,
      );
      expect(find.textContaining('user-a@a.example.invalid'), findsOneWidget);
      expect(find.byKey(const Key('reminder-inbox-list')), findsOneWidget);
      expect(
        find.byKey(const Key('reminder-inbox-row-account-b|hqowhbbz|79988')),
        findsOneWidget,
      );
    });

    testWidgets('every account failing does not read as an empty inbox', (
      tester,
    ) async {
      await _pumpScreen(
        tester,
        accounts: <StoredAccount>[_accountA],
        lister: (_) async => throw const ChatMessageActionException(
          ChatMessageActionError.network,
        ),
      );

      expect(
        find.byKey(const Key('reminder-inbox-unavailable')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('reminder-inbox-empty')), findsNothing);
    });

    testWidgets('one account signed in leaves the account line off', (
      tester,
    ) async {
      await _pumpScreen(
        tester,
        accounts: <StoredAccount>[_accountA],
        lister: (_) async => <RichChatUpcomingReminder>[_reminder()],
      );

      expect(find.text('Room on account-a'), findsOneWidget);
      expect(find.text('user-a@a.example.invalid'), findsNothing);
    });

    testWidgets('two accounts name themselves on every row', (tester) async {
      await _pumpScreen(
        tester,
        accounts: <StoredAccount>[_accountA, _accountB],
        lister: (_) async => <RichChatUpcomingReminder>[_reminder()],
      );

      expect(find.text('user-a@a.example.invalid'), findsOneWidget);
      expect(find.text('user-b@b.example.invalid'), findsOneWidget);
    });

    testWidgets('a row shows the deadline, author and message text', (
      tester,
    ) async {
      await _pumpScreen(
        tester,
        accounts: <StoredAccount>[_accountA],
        lister: (_) async => <RichChatUpcomingReminder>[_reminder()],
      );

      expect(
        find.textContaining('NCloudTalk Test: UP-20 reminder inbox probe'),
        findsOneWidget,
      );
      expect(find.textContaining('Due '), findsOneWidget);
    });

    // Both rows carry the same token and message ID, so a remover that is told
    // anything less than the account would remove the other account's
    // reminder.
    testWidgets('removing a colliding row removes exactly that one', (
      tester,
    ) async {
      final removed = <String>[];
      await _pumpScreen(
        tester,
        accounts: <StoredAccount>[_accountA, _accountB],
        lister: (_) async => <RichChatUpcomingReminder>[_reminder()],
        remover: (row) async => removed.add(row.identity),
      );

      await tester.tap(
        find.byKey(const Key('reminder-inbox-remove-account-b|hqowhbbz|79988')),
      );
      await tester.pumpAndSettle();

      expect(removed, <String>['account-b|hqowhbbz|79988']);
      expect(
        find.byKey(const Key('reminder-inbox-row-account-b|hqowhbbz|79988')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('reminder-inbox-row-account-a|hqowhbbz|79988')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('reminder-inbox-removed')), findsOneWidget);
    });

    testWidgets('a refused removal keeps the row and says so', (tester) async {
      await _pumpScreen(
        tester,
        accounts: <StoredAccount>[_accountA],
        lister: (_) async => <RichChatUpcomingReminder>[_reminder()],
        remover: (_) async => throw const ChatMessageActionException(
          ChatMessageActionError.serviceUnavailable,
        ),
      );

      await tester.tap(
        find.byKey(const Key('reminder-inbox-remove-account-a|hqowhbbz|79988')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('reminder-inbox-row-account-a|hqowhbbz|79988')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('reminder-inbox-remove-failed')),
        findsOneWidget,
      );
    });

    testWidgets('tapping a colliding row opens that account\'s reminder', (
      tester,
    ) async {
      final opened = <ReminderInboxRow>[];
      await _pumpScreen(
        tester,
        accounts: <StoredAccount>[_accountA, _accountB],
        lister: (_) async => <RichChatUpcomingReminder>[_reminder()],
        onOpen: opened.add,
      );

      await tester.tap(
        find.byKey(const Key('reminder-inbox-row-account-b|hqowhbbz|79988')),
      );
      await tester.pump();

      expect(opened, hasLength(1));
      expect(opened.single.accountId, 'account-b');
      expect(opened.single.roomToken, 'hqowhbbz');
      expect(opened.single.messageId, 79988);
    });
  });

  // These run the shipped service and protocol against a fake server, so the
  // request that leaves the app and the account it leaves under are the thing
  // under test, not a stand-in for it.
  group('route', () {
    late _RouteFixture fixture;

    setUp(() async => fixture = await _RouteFixture.create());
    tearDown(() => fixture.dispose());

    testWidgets('both servers are asked and both rows are listed', (
      tester,
    ) async {
      await tester.pumpWidget(fixture.app());
      await _pumpUntilFound(tester, _rowA);

      expect(fixture.listed.toSet(), <String>{
        'a.example.invalid',
        'b.example.invalid',
      });
      expect(find.byKey(_rowA), findsOneWidget);
      expect(find.byKey(_rowB), findsOneWidget);
    });

    // The two rows agree on token and message ID, so a delete addressed by
    // anything less than the account would hit the wrong server.
    testWidgets('removing a row deletes on that row\'s own server', (
      tester,
    ) async {
      await tester.pumpWidget(fixture.app());
      await _pumpUntilFound(tester, _rowB);

      await tester.tap(
        find.byKey(const Key('reminder-inbox-remove-account-b|hqowhbbz|79988')),
      );
      await _pumpUntil(tester, () => find.byKey(_rowB).evaluate().isEmpty);

      expect(fixture.deleted, <String>['b.example.invalid|user-b']);
      expect(find.byKey(_rowA), findsOneWidget);
    });

    // The shell underneath this route tracks one selected account, so opening
    // a row that belongs to the other one has to switch first. Asserted through
    // the presenter seam: pushing the real room drags its timers and its
    // network work into a test about a list, and that is what made the earlier
    // version of this test hang.
    testWidgets('opening a row selects the row account first', (
      tester,
    ) async {
      final seen = <String>[];
      await tester.pumpWidget(
        fixture.app(
          presentMessage:
              (
                context,
                {
                  required account,
                  required conversation,
                  required messageId,
                }
              ) async {
                seen.add('${account.id}|${conversation.token}|$messageId');
              },
        ),
      );
      await _pumpUntilFound(tester, _rowB);

      await tester.tap(find.byKey(_rowB));
      await _pumpUntil(tester, () => seen.isNotEmpty);

      // The second account's query streams close only when the scope goes, and
      // drift closes them on a grace timer. Tearing the tree down here lets
      // that timer fire inside the test; left to the harness it is still
      // pending at disposal and fails the test on the way out, saying nothing
      // about what was being tested.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 500));

      // The presenter is handed the row's own account, and by then the switch
      // has been written: the route awaits `selectAccount` before it presents.
      // Read outside the fake clock, because a drift query on it leaves a
      // cleanup timer behind and the tree is disposed with it still pending.
      expect(seen, <String>['account-b|hqowhbbz|79988']);
      String? stored;
      await tester.runAsync(() async {
        stored = [
          for (final account in await fixture.repository.listAccounts())
            if (account.selected) account.id,
        ].singleOrNull;
      });
      expect(stored, 'account-b');
    });

    testWidgets('one server refusing leaves the other row listed', (
      tester,
    ) async {
      fixture.refuse.add('a.example.invalid');
      await tester.pumpWidget(fixture.app());
      await _pumpUntilFound(
        tester,
        const Key('reminder-inbox-accounts-unavailable'),
      );

      expect(find.byKey(_rowA), findsNothing);
      expect(find.byKey(_rowB), findsOneWidget);
    });
  });
}

const _rowA = Key('reminder-inbox-row-account-a|hqowhbbz|79988');
const _rowB = Key('reminder-inbox-row-account-b|hqowhbbz|79988');

Future<void> _pumpUntilFound(WidgetTester tester, Key key) =>
    _pumpUntil(tester, () => find.byKey(key).evaluate().isNotEmpty);

/// Drives the frame clock while the real asynchronous work behind the screen
/// runs. `pumpAndSettle` cannot be used here: the loading spinner animates
/// forever, so the tree never settles even once the list has arrived.
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  int maximumPumps = 200,
}) async {
  for (var attempt = 0; attempt < maximumPumps; attempt++) {
    await tester.pump(const Duration(milliseconds: 10));
    if (condition()) {
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
  }
  fail('Condition was not reached');
}

/// A real database, real credentials and the shipped service, with two accounts
/// on two servers that answer with the same token and message ID.
final class _RouteFixture {
  _RouteFixture({
    required this.database,
    required this.repository,
    required this.credentials,
    required this.api,
    required this.accounts,
    required this.conversations,
    required this.listed,
    required this.deleted,
    required this.refuse,
  });

  final AppDatabase database;
  final AccountRepository repository;
  final MemoryCredentialVault credentials;
  final HttpNextcloudApi api;
  final List<StoredAccount> accounts;
  final Map<String, CachedConversation> conversations;

  /// Hosts that answered the account-wide list, in the order they were asked.
  final List<String> listed;

  /// `host|loginName` of every reminder delete that reached a server.
  final List<String> deleted;

  /// Hosts that answer the list with a `503`.
  final Set<String> refuse;

  static Future<_RouteFixture> create() async {
    final database = openTestDatabase();
    final repository = AccountRepository(database);
    final credentials = MemoryCredentialVault();
    final accounts = <StoredAccount>[];
    final conversations = <String, CachedConversation>{};
    for (final (id, host) in const <(String, String)>[
      ('account-a', 'a.example.invalid'),
      ('account-b', 'b.example.invalid'),
    ]) {
      accounts.add(
        await repository.upsertAccount(
          accountId: id,
          serverUrl: 'https://$host',
          loginName: 'user-${id.substring(id.length - 1)}',
          serverProductName: 'Nextcloud',
          createdAt: DateTime.utc(2026, 1, 1),
          talkFeatures: const <String>{
            'conversation-v4',
            'chat-v2',
            'remind-me-later',
            'upcoming-reminders',
          },
        ),
      );
      credentials.values[id] = 'fixture-app-password-$id';
      conversations[id] = await _insertConversation(database, id);
    }
    await repository.selectAccount('account-a');

    final listed = <String>[];
    final deleted = <String>[];
    final refuse = <String>{};
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        final host = request.url.host;
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return _json(
            capabilitiesJson(
              talkFeatures: const <String>[
                'conversation-v4',
                'chat-v2',
                'remind-me-later',
                'upcoming-reminders',
              ],
            ),
          );
        }
        if (request.method == 'GET' &&
            request.url.path.endsWith('/chat/upcoming-reminders')) {
          if (refuse.contains(host)) {
            return _json(_ocs(503, <Object?>[], status: 'failure'), 503);
          }
          listed.add(host);
          return _json(
            _ocs(200, <Object?>[
              <String, Object?>{
                'reminderTimestamp': host.startsWith('a')
                    ? 1_789_041_873
                    : 1_789_045_473,
                'roomToken': 'hqowhbbz',
                'messageId': 79988,
                'actorType': 'users',
                'actorId': 'nctalk-test',
                'actorDisplayName': 'NCloudTalk Test',
                'message': 'UP-20 reminder inbox probe',
                'messageParameters': <Object?>[],
              },
            ]),
          );
        }
        if (request.method == 'DELETE' &&
            request.url.path.endsWith('/chat/hqowhbbz/79988/reminder')) {
          deleted.add('$host|${_loginOf(request)}');
          return _json(_ocs(200, <Object?>[]));
        }
        return http.Response('', 404);
      }),
    );

    return _RouteFixture(
      database: database,
      repository: repository,
      credentials: credentials,
      api: api,
      accounts: accounts,
      conversations: conversations,
      listed: listed,
      deleted: deleted,
      refuse: refuse,
    );
  }

  Widget app({
    NavigatorObserver? observer,
    ReminderMessagePresenter? presentMessage,
  }) => ProviderScope(
    overrides: <Override>[
      appDatabaseProvider.overrideWithValue(database),
      credentialVaultProvider.overrideWithValue(credentials),
      nextcloudApiProvider.overrideWithValue(api),
      // Push keeps its own coverage and would open an unrelated watcher.
      clientPushEnabledProvider.overrideWithValue(false),
      accountsProvider.overrideWith((ref) => Stream.value(accounts)),
      conversationsProvider.overrideWith(
        (ref, accountId) =>
            Stream.value(<CachedConversation>[?conversations[accountId]]),
      ),
      chatMessagesProvider.overrideWith(
        (ref, key) => Stream.value(const <CachedChatMessage>[]),
      ),
      outgoingMessageStatusesProvider.overrideWith(
        (ref, key) => Stream.value(const <OutgoingMessageStatus>[]),
      ),
      textSendOperationsProvider.overrideWith(
        (ref, key) => Stream.value(const <StoredTextSendOperation>[]),
      ),
      chatScopeProvider.overrideWith((ref, key) => Stream.value(null)),
      connectivityWakeEventsProvider.overrideWithValue(
        const Stream<void>.empty(),
      ),
      chatAttachmentDependenciesProvider.overrideWith(
        (ref, key) => Future<ChatAttachmentDependencies>.error(
          StateError('attachment transport is outside this test'),
          StackTrace.empty,
        ),
      ),
    ],
    child: localizedTestApp(
      home: presentMessage == null
          ? const ReminderInboxRoute()
          : ReminderInboxRoute(presentMessage: presentMessage),
      navigatorObservers: <NavigatorObserver>[?observer],
    ),
  );

  Future<void> dispose() async {
    api.close();
    await database.close();
  }
}

String _loginOf(http.Request request) {
  final header = request.headers['Authorization'] ?? '';
  final decoded = utf8.decode(base64Decode(header.split(' ').last));
  return decoded.split(':').first;
}

http.Response _json(Map<String, Object?> body, [int status = 200]) =>
    http.Response(
      jsonEncode(body),
      status,
      headers: const <String, String>{
        'content-type': 'application/json; charset=utf-8',
      },
    );

Map<String, Object?> _ocs(
  int statusCode,
  Object? data, {
  String status = 'ok',
}) => <String, Object?>{
  'ocs': <String, Object?>{
    'meta': <String, Object?>{
      'status': status,
      'statuscode': statusCode,
      'message': 'OK',
    },
    'data': data,
  },
};

/// One cached conversation per account, named after the account so a test can
/// tell which account's copy it is looking at.
Future<CachedConversation> _insertConversation(
  AppDatabase database,
  String accountId,
) async {
  final fixture =
      readFixtureJson(
            'conversation-list/fixtures/conversations-full.response.json',
          )!
          as Map<String, Object?>;
  final ocs = fixture['ocs']! as Map<String, Object?>;
  final roomJson = Map<String, Object?>.from(
    (ocs['data']! as List<Object?>).first! as Map<String, Object?>,
  );
  roomJson['token'] = 'hqowhbbz';
  roomJson['displayName'] = 'Room on $accountId';
  roomJson.remove('remoteServer');
  // The preview carries the token too, and the room parser refuses a room
  // whose last message claims to belong somewhere else.
  final lastMessage = roomJson['lastMessage'];
  if (lastMessage is Map<String, Object?>) {
    roomJson['lastMessage'] = <String, Object?>{
      ...lastMessage,
      'token': 'hqowhbbz',
    };
  }
  final room = ConversationRoom.fromJson(roomJson);
  await database
      .into(database.cachedConversations)
      .insert(
        CachedConversationsCompanion.insert(
          accountId: accountId,
          token: room.token.value,
          displayName: room.displayName,
          description: room.description,
          lastActivity: room.lastActivity,
          unreadMessages: room.unreadMessages,
          favorite: room.isFavorite,
          readOnly: Value(room.readOnly),
          roomType: Value(room.type),
          roomName: Value(room.name),
          objectType: Value(room.objectType),
          avatarVersion: Value(room.avatarVersion),
          isCustomAvatar: Value(room.isCustomAvatar),
          rawJson: jsonEncode(roomJson),
        ),
      );
  return (database.select(
    database.cachedConversations,
  )..where((row) => row.accountId.equals(accountId))).getSingle();
}

Future<void> _pumpScreen(
  WidgetTester tester, {
  required List<StoredAccount> accounts,
  UpcomingReminderLister? lister,
  UpcomingReminderRemover? remover,
  ValueChanged<ReminderInboxRow>? onOpen,
}) async {
  await tester.pumpWidget(
    localizedTestApp(
      home: ReminderInboxScreen(
        accounts: accounts,
        lister: lister ?? (_) async => const <RichChatUpcomingReminder>[],
        remover: remover ?? (_) async {},
        conversationName: (accountId, _) async => 'Room on $accountId',
        onOpen: onOpen ?? (_) {},
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The exact entry the reference server answered with on 9 September 2026,
/// `messageParameters` as an empty list included.
RichChatUpcomingReminder _reminder({
  String roomToken = 'hqowhbbz',
  int messageId = 79988,
  int deadline = 1_789_041_873,
}) => RichChatUpcomingReminder.fromJson(
  jsonDecode(
    jsonEncode(<String, Object?>{
      'reminderTimestamp': deadline,
      'roomToken': roomToken,
      'messageId': messageId,
      'actorType': 'users',
      'actorId': 'nctalk-test',
      'actorDisplayName': 'NCloudTalk Test',
      'message': 'UP-20 reminder inbox probe',
      'messageParameters': <Object?>[],
    }),
  ),
);

const _accountA = StoredAccount(
  id: 'account-a',
  serverUrl: 'https://a.example.invalid',
  loginName: 'user-a',
  serverProductName: 'Nextcloud',
  talkFeaturesJson: '[]',
  selected: true,
  createdAtMillis: 0,
);

const _accountB = StoredAccount(
  id: 'account-b',
  serverUrl: 'https://b.example.invalid',
  loginName: 'user-b',
  serverProductName: 'Nextcloud',
  talkFeaturesJson: '[]',
  selected: false,
  createdAtMillis: 0,
);
