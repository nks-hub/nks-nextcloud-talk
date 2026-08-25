import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/conversations/conversation_presence.dart';
import 'package:nextcloudtalk/features/rooms/room_details_screen.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late MemoryCredentialVault vault;
  late StoredAccount account;
  late CachedConversation conversation;

  setUp(() async {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    vault = MemoryCredentialVault()..values['account-a'] = 'fixture-password';
    account = await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      talkFeatures: const {},
      createdAt: DateTime.utc(2026, 1, 1),
    );
    final roomJson = _conversationRoomJson();
    final room = ConversationRoom.fromJson(roomJson);
    await database
        .into(database.cachedConversations)
        .insert(
          CachedConversationsCompanion.insert(
            accountId: account.id,
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
    conversation = await database
        .select(database.cachedConversations)
        .getSingle();
  });

  tearDown(() => database.close());

  Widget app({
    required Widget home,
    required http.Client client,
    List<Override> overrides = const [],
  }) {
    final api = HttpNextcloudApi(client: client);
    return ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        credentialVaultProvider.overrideWithValue(vault),
        nextcloudApiProvider.overrideWithValue(api),
        chatAttachmentDependenciesProvider.overrideWith(
          (ref, key) => Future<ChatAttachmentDependencies>.error(
            StateError('attachment dependencies are not wired in this suite'),
            StackTrace.empty,
          ),
        ),
        ...overrides,
      ],
      child: localizedTestApp(home: home),
    );
  }

  http.Client participantsClient(Object? participantsJson) {
    return MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return http.Response(
          jsonEncode({
            'ocs': {
              'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
              'data': participantsJson,
            },
          }),
          200,
        );
      }
      return http.Response('', 404);
    });
  }

  testWidgets('shows conversation metadata and the participant list', (
    tester,
  ) async {
    _growViewport(tester);
    await tester.pumpWidget(
      app(
        home: RoomDetailsScreen(account: account, conversation: conversation),
        client: participantsClient([
          _participantJson(
            attendeeId: 1,
            participantType: 2,
            displayName: 'Synthetic Moderator',
            sessionIds: const ['session-a'],
            status: 'online',
          ),
          _participantJson(
            attendeeId: 2,
            actorType: 'guests',
            actorId: 'synthetic-guest-a',
            participantType: 4,
            displayName: 'Synthetic Guest',
            status: 'away',
          ),
        ]),
      ),
    );
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('room-participant-1')).evaluate().isNotEmpty,
    );

    expect(find.byKey(const Key('room-details-screen')), findsOneWidget);
    expect(find.text('Synthetic conversation A'), findsOneWidget);
    expect(find.text('Group conversation'), findsOneWidget);
    expect(find.text('No'), findsOneWidget);
    expect(find.text('All messages'), findsOneWidget);

    expect(find.byKey(const Key('room-participant-1')), findsOneWidget);
    expect(find.text('Synthetic Moderator'), findsOneWidget);
    expect(find.text('Moderator'), findsOneWidget);
    expect(find.byKey(const Key('room-participant-2')), findsOneWidget);
    expect(find.text('Synthetic Guest'), findsOneWidget);
    expect(find.text('Guest'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  // Both room surfaces the app really navigates to, not ChatRoomScreen:
  // that one is reachable from tests only, so asserting on it would prove
  // nothing about whether a user can open the details.
  for (final surface in <String, Widget Function()>{
    'the room screen': () => PresenceChatRoomScreen(
      account: account,
      conversation: conversation,
    ),
    'the room pane': () => Scaffold(
      body: PresenceChatRoomPane(account: account, conversation: conversation),
    ),
  }.entries) {
    testWidgets('${surface.key} exposes an info action', (tester) async {
      _growViewport(tester);
      await tester.pumpWidget(
        app(
          home: surface.value(),
          client: participantsClient(const <Object?>[]),
          overrides: [
            conversationsProvider.overrideWith(
              (ref, accountId) => Stream.value([conversation]),
            ),
          ],
        ),
      );
      await tester.pump();

      final infoButton = find.byKey(const Key('open-room-details'));
      expect(infoButton, findsOneWidget);
      await tester.tap(infoButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byKey(const Key('room-details-screen')), findsOneWidget);
      await _pumpUntil(
        tester,
        () => find.text('No participants found.').evaluate().isNotEmpty,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });
  }

  testWidgets('offers a retry when the participant list fails to load', (
    tester,
  ) async {
    _growViewport(tester);
    var requestCount = 0;
    final client = MockClient((request) async {
      requestCount++;
      return http.Response('not json', 200);
    });

    await tester.pumpWidget(
      app(
        home: RoomDetailsScreen(account: account, conversation: conversation),
        client: client,
      ),
    );
    await _pumpUntil(
      tester,
      () => find
          .text('Participants could not be loaded.')
          .evaluate()
          .isNotEmpty,
    );

    final retry = find.byKey(const Key('room-details-retry'));
    expect(retry, findsOneWidget);
    expect(requestCount, 1);

    await tester.tap(retry);
    await _pumpUntil(tester, () => requestCount == 2);
    await _pumpUntil(
      tester,
      () => find
          .text('Participants could not be loaded.')
          .evaluate()
          .isNotEmpty,
    );
    expect(
      find.text('Participants could not be loaded.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('a moderator can rename the conversation', (tester) async {
    _growViewport(tester);
    final renamedJson = Map<String, Object?>.from(_conversationRoomJson())
      ..['name'] = 'renamed-room'
      ..['displayName'] = 'Renamed Room';
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess(const <Object?>[]);
      }
      if (request.method == 'PUT' && request.url.path.endsWith('/rooma123')) {
        expect(request.bodyFields['roomName'], 'Renamed Room');
        return _ocsSuccess(renamedJson);
      }
      return http.Response('', 404);
    });

    await tester.pumpWidget(
      app(
        home: RoomDetailsScreen(account: account, conversation: conversation),
        client: client,
      ),
    );
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('room-details-rename')).evaluate().isNotEmpty,
    );
    expect(find.text('Synthetic room A'), findsOneWidget);

    await tester.tap(find.byKey(const Key('room-details-rename')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('room-details-rename-field')),
      'Renamed Room',
    );
    await tester.tap(find.byKey(const Key('room-details-rename-save')));
    await _pumpUntil(tester, () => _roomTitleText(tester) == 'Renamed Room');

    expect(find.text('Synthetic room A'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('a rename that the server rejects keeps the original name', (
    tester,
  ) async {
    _growViewport(tester);
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess(const <Object?>[]);
      }
      if (request.method == 'PUT' && request.url.path.endsWith('/rooma123')) {
        return _ocsFailure(403);
      }
      return http.Response('', 404);
    });

    await tester.pumpWidget(
      app(
        home: RoomDetailsScreen(account: account, conversation: conversation),
        client: client,
      ),
    );
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('room-details-rename')).evaluate().isNotEmpty,
    );

    await tester.tap(find.byKey(const Key('room-details-rename')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('room-details-rename-field')),
      'Renamed Room',
    );
    await tester.tap(find.byKey(const Key('room-details-rename-save')));
    await _pumpUntil(
      tester,
      () => find.text("You don't have permission to do this.").evaluate().isNotEmpty,
    );

    expect(find.text('Synthetic room A'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('changing the notification level updates the picker subtitle', (
    tester,
  ) async {
    _growViewport(tester);
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess(const <Object?>[]);
      }
      if (request.method == 'POST' && request.url.path.endsWith('/notify')) {
        expect(request.bodyFields['level'], '3');
        return _ocsSuccess(const <Object?>[]);
      }
      return http.Response('', 404);
    });

    await tester.pumpWidget(
      app(
        home: RoomDetailsScreen(account: account, conversation: conversation),
        client: client,
      ),
    );
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('room-details-notification-picker'))
          .evaluate()
          .isNotEmpty,
    );
    expect(_notificationSubtitleText(tester), 'All messages');

    await tester.tap(find.byKey(const Key('room-details-notification-picker')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('room-details-notification-never')));
    await _pumpUntil(tester, () => _notificationSubtitleText(tester) == 'Off');

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('hides moderator-only actions for a plain participant', (
    tester,
  ) async {
    _growViewport(tester);
    final memberConversation = await _insertConversation(
      database,
      account,
      overrides: {'participantType': 3, 'canLeaveConversation': true},
    );

    await tester.pumpWidget(
      app(
        home: RoomDetailsScreen(
          account: account,
          conversation: memberConversation,
        ),
        client: participantsClient(const <Object?>[]),
      ),
    );
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('room-details-notification-picker'))
          .evaluate()
          .isNotEmpty,
    );

    expect(find.byKey(const Key('room-details-rename')), findsNothing);
    expect(
      find.byKey(const Key('room-details-description-edit')),
      findsNothing,
    );
    expect(find.byKey(const Key('room-details-favorite-toggle')), findsOneWidget);
    expect(find.byKey(const Key('room-details-leave')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('offers moderation actions that match each attendee role', (
    tester,
  ) async {
    _growViewport(tester);
    await tester.pumpWidget(
      app(
        home: RoomDetailsScreen(account: account, conversation: conversation),
        client: participantsClient(_moderationParticipants()),
      ),
    );
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('room-participant-1')).evaluate().isNotEmpty,
    );

    // Owner: nothing can be done to them, so no menu at all.
    expect(find.byKey(const Key('room-participant-menu-1')), findsNothing);
    // Self: the signed-in moderator's own row stays action-free.
    expect(find.byKey(const Key('room-participant-menu-4')), findsNothing);

    await tester.tap(find.byKey(const Key('room-participant-menu-2')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('room-participant-2-demote')), findsOneWidget);
    expect(find.byKey(const Key('room-participant-2-promote')), findsNothing);
    expect(find.byKey(const Key('room-participant-2-remove')), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('room-participant-menu-3')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('room-participant-3-promote')), findsOneWidget);
    expect(find.byKey(const Key('room-participant-3-remove')), findsOneWidget);
    expect(find.byKey(const Key('room-participant-3-demote')), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('hides moderation menus from a plain participant', (
    tester,
  ) async {
    _growViewport(tester);
    final memberConversation = await _insertConversation(
      database,
      account,
      overrides: {'participantType': 3, 'canLeaveConversation': true},
    );

    await tester.pumpWidget(
      app(
        home: RoomDetailsScreen(
          account: account,
          conversation: memberConversation,
        ),
        client: participantsClient(_moderationParticipants()),
      ),
    );
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('room-participant-3')).evaluate().isNotEmpty,
    );

    expect(find.byType(PopupMenuButton<ParticipantModerationAction>), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('promoting a participant calls the API and reloads the list', (
    tester,
  ) async {
    _growViewport(tester);
    var promoted = false;
    var listRequests = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        listRequests++;
        return _ocsSuccess(
          promoted
              ? _moderationParticipants(promotedAttendeeType: 2)
              : _moderationParticipants(),
        );
      }
      if (request.method == 'POST' && request.url.path.endsWith('/moderators')) {
        expect(request.url.queryParameters['attendeeId'], '3');
        promoted = true;
        return _ocsSuccess();
      }
      return http.Response('', 404);
    });

    await tester.pumpWidget(
      app(
        home: RoomDetailsScreen(account: account, conversation: conversation),
        client: client,
      ),
    );
    await _pumpUntil(
      tester,
      () =>
          find.byKey(const Key('room-participant-menu-3')).evaluate().isNotEmpty,
    );

    await tester.tap(find.byKey(const Key('room-participant-menu-3')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('room-participant-3-promote')));
    await _pumpUntil(tester, () => promoted && listRequests == 2);
    // The reloaded row reports the moderator role, so it keeps only the
    // demote entry and the tile no longer offers promoting.
    await _pumpUntil(
      tester,
      () =>
          find.byKey(const Key('room-participant-3')).evaluate().isNotEmpty &&
          find
              .byKey(const Key('room-participant-menu-3'))
              .evaluate()
              .isNotEmpty,
    );
    await tester.tap(find.byKey(const Key('room-participant-menu-3')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('room-participant-3-demote')), findsOneWidget);
    expect(find.byKey(const Key('room-participant-3-promote')), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('removing a participant asks for confirmation first', (
    tester,
  ) async {
    _growViewport(tester);
    var removeRequests = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess(_moderationParticipants());
      }
      if (request.method == 'DELETE' && request.url.path.endsWith('/attendees')) {
        expect(request.url.queryParameters['attendeeId'], '3');
        removeRequests++;
        return _ocsSuccess();
      }
      return http.Response('', 404);
    });

    await tester.pumpWidget(
      app(
        home: RoomDetailsScreen(account: account, conversation: conversation),
        client: client,
      ),
    );
    await _pumpUntil(
      tester,
      () =>
          find.byKey(const Key('room-participant-menu-3')).evaluate().isNotEmpty,
    );

    await tester.tap(find.byKey(const Key('room-participant-menu-3')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('room-participant-3-remove')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('room-details-remove-participant-dialog')),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(removeRequests, 0);

    await tester.tap(find.byKey(const Key('room-participant-menu-3')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('room-participant-3-remove')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('room-details-remove-participant-confirm')),
    );
    await _pumpUntil(tester, () => removeRequests == 1);

    expect(find.byKey(const Key('room-details-screen')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('a moderation change the server rejects surfaces the reason', (
    tester,
  ) async {
    _growViewport(tester);
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess(_moderationParticipants());
      }
      if (request.url.path.endsWith('/attendees')) {
        return _ocsFailure(400);
      }
      return http.Response('', 404);
    });

    await tester.pumpWidget(
      app(
        home: RoomDetailsScreen(account: account, conversation: conversation),
        client: client,
      ),
    );
    await _pumpUntil(
      tester,
      () =>
          find.byKey(const Key('room-participant-menu-3')).evaluate().isNotEmpty,
    );

    await tester.tap(find.byKey(const Key('room-participant-menu-3')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('room-participant-3-remove')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('room-details-remove-participant-confirm')),
    );
    await _pumpUntil(
      tester,
      () => find
          .text('The server refused this change for this participant.')
          .evaluate()
          .isNotEmpty,
    );

    expect(find.byKey(const Key('room-participant-3')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('hides the leave action when the server disallows it', (
    tester,
  ) async {
    _growViewport(tester);
    final lockedConversation = await _insertConversation(
      database,
      account,
      overrides: {'canLeaveConversation': false},
    );

    await tester.pumpWidget(
      app(
        home: RoomDetailsScreen(
          account: account,
          conversation: lockedConversation,
        ),
        client: participantsClient(const <Object?>[]),
      ),
    );
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('room-details-notification-picker'))
          .evaluate()
          .isNotEmpty,
    );

    expect(find.byKey(const Key('room-details-leave')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('offers delete only to a moderator the server allows it to', (
    tester,
  ) async {
    _growViewport(tester);
    // A plain participant, even where the cached room still claims the flag.
    final memberConversation = await _insertConversation(
      database,
      account,
      overrides: {'participantType': 3, 'canDeleteConversation': true},
    );

    await tester.pumpWidget(
      app(
        home: RoomDetailsScreen(
          account: account,
          conversation: memberConversation,
        ),
        client: participantsClient(const <Object?>[]),
      ),
    );
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('room-details-notification-picker'))
          .evaluate()
          .isNotEmpty,
    );
    expect(find.byKey(const Key('room-details-delete')), findsNothing);

    // A moderator of a room the server refuses to delete, e.g. one-to-one.
    final lockedConversation = await _insertConversation(
      database,
      account,
      overrides: {'participantType': 1, 'canDeleteConversation': false},
    );
    await tester.pumpWidget(
      app(
        home: RoomDetailsScreen(
          account: account,
          conversation: lockedConversation,
        ),
        client: participantsClient(const <Object?>[]),
      ),
    );
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('room-details-notification-picker'))
          .evaluate()
          .isNotEmpty,
    );

    expect(find.byKey(const Key('room-details-delete')), findsNothing);
    expect(find.byKey(const Key('room-details-leave')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('cancelling the delete confirmation keeps the conversation', (
    tester,
  ) async {
    _growViewport(tester);
    var deleteRequests = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess(const <Object?>[]);
      }
      if (request.method == 'DELETE' &&
          request.url.path.endsWith('/room/rooma123')) {
        deleteRequests++;
        return _ocsSuccess(const <Object?>[]);
      }
      return http.Response('', 404);
    });

    await tester.pumpWidget(
      app(
        home: RoomDetailsScreen(account: account, conversation: conversation),
        client: client,
      ),
    );
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('room-details-delete')).evaluate().isNotEmpty,
    );

    await tester.tap(find.byKey(const Key('room-details-delete')));
    await tester.pump();
    expect(find.byKey(const Key('room-details-delete-dialog')), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump();

    expect(find.byKey(const Key('room-details-screen')), findsOneWidget);
    expect(deleteRequests, 0);
    expect(
      (await database.select(database.cachedConversations).getSingleOrNull())
          ?.token,
      'rooma123',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets(
    'confirming delete removes the conversation and returns to the list',
    (tester) async {
      _growViewport(tester);
      var deleteRequests = 0;
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/participants')) {
          return _ocsSuccess(const <Object?>[]);
        }
        if (request.method == 'DELETE' &&
            request.url.path.endsWith('/room/rooma123')) {
          deleteRequests++;
          return _ocsSuccess(const <Object?>[]);
        }
        return http.Response('', 404);
      });

      await tester.pumpWidget(
        app(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  key: const Key('open-room-details-from-list'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => RoomDetailsScreen(
                        account: account,
                        conversation: conversation,
                      ),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
          client: client,
        ),
      );
      await tester.tap(find.byKey(const Key('open-room-details-from-list')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await _pumpUntil(
        tester,
        () =>
            find.byKey(const Key('room-details-delete')).evaluate().isNotEmpty,
      );

      await tester.tap(find.byKey(const Key('room-details-delete')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('room-details-delete-confirm')));
      await _pumpUntil(
        tester,
        () => find.byKey(const Key('room-details-screen')).evaluate().isEmpty,
      );

      expect(deleteRequests, 1);
      expect(
        await database.select(database.cachedConversations).getSingleOrNull(),
        isNull,
      );
      expect(
        find.byKey(const Key('open-room-details-from-list')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  testWidgets('a refused delete keeps the room and explains the refusal', (
    tester,
  ) async {
    _growViewport(tester);
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess(const <Object?>[]);
      }
      if (request.method == 'DELETE' &&
          request.url.path.endsWith('/room/rooma123')) {
        return _ocsFailure(400);
      }
      return http.Response('', 404);
    });

    await tester.pumpWidget(
      app(
        home: RoomDetailsScreen(account: account, conversation: conversation),
        client: client,
      ),
    );
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('room-details-delete')).evaluate().isNotEmpty,
    );

    await tester.tap(find.byKey(const Key('room-details-delete')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('room-details-delete-confirm')));
    await _pumpUntil(
      tester,
      () => find
          .text(
            'This conversation cannot be deleted. You can only leave a '
            'one-to-one conversation.',
          )
          .evaluate()
          .isNotEmpty,
    );

    expect(find.byKey(const Key('room-details-screen')), findsOneWidget);
    expect(
      (await database.select(database.cachedConversations).getSingleOrNull())
          ?.token,
      'rooma123',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('cancelling the leave confirmation keeps the screen open', (
    tester,
  ) async {
    _growViewport(tester);
    var leaveRequests = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess(const <Object?>[]);
      }
      if (request.method == 'DELETE' &&
          request.url.path.endsWith('/participants/self')) {
        leaveRequests++;
        return _ocsSuccess(const <Object?>[]);
      }
      return http.Response('', 404);
    });

    await tester.pumpWidget(
      app(
        home: RoomDetailsScreen(account: account, conversation: conversation),
        client: client,
      ),
    );
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('room-details-leave')).evaluate().isNotEmpty,
    );

    await tester.tap(find.byKey(const Key('room-details-leave')));
    await tester.pump();
    expect(find.byKey(const Key('room-details-leave-dialog')), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump();

    expect(find.byKey(const Key('room-details-screen')), findsOneWidget);
    expect(leaveRequests, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets(
    'confirming leave calls the API and returns to the previous screen',
    (tester) async {
      _growViewport(tester);
      var leaveRequests = 0;
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/participants')) {
          return _ocsSuccess(const <Object?>[]);
        }
        if (request.method == 'DELETE' &&
            request.url.path.endsWith('/participants/self')) {
          leaveRequests++;
          return _ocsSuccess(const <Object?>[]);
        }
        return http.Response('', 404);
      });

      await tester.pumpWidget(
        app(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  key: const Key('open-room-details-from-list'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => RoomDetailsScreen(
                        account: account,
                        conversation: conversation,
                      ),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
          client: client,
        ),
      );
      await tester.tap(find.byKey(const Key('open-room-details-from-list')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await _pumpUntil(
        tester,
        () =>
            find.byKey(const Key('room-details-leave')).evaluate().isNotEmpty,
      );

      await tester.tap(find.byKey(const Key('room-details-leave')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('room-details-leave-confirm')));
      await _pumpUntil(
        tester,
        () =>
            find.byKey(const Key('room-details-screen')).evaluate().isEmpty,
      );

      expect(leaveRequests, 1);
      expect(
        find.byKey(const Key('open-room-details-from-list')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );
}

http.Response _ocsSuccess([Object? data = const <Object?>[]]) {
  return http.Response(
    jsonEncode({
      'ocs': {
        'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
        'data': data,
      },
    }),
    200,
  );
}

http.Response _ocsFailure(int statusCode) {
  return http.Response(
    jsonEncode({
      'ocs': {
        'meta': {'status': 'failure', 'statuscode': statusCode},
        'data': <Object?>[],
      },
    }),
    statusCode,
  );
}

Future<CachedConversation> _insertConversation(
  AppDatabase database,
  StoredAccount account, {
  required Map<String, Object?> overrides,
}) async {
  final roomJson = Map<String, Object?>.from(_conversationRoomJson())
    ..addAll(overrides);
  final room = ConversationRoom.fromJson(roomJson);
  await database
      .into(database.cachedConversations)
      .insertOnConflictUpdate(
        CachedConversationsCompanion.insert(
          accountId: account.id,
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
  return database.select(database.cachedConversations).getSingle();
}

/// One attendee of each role the moderation menu has to distinguish: an
/// owner (untouchable), a moderator (demote only), a plain user (promote or
/// remove) and the signed-in account itself.
List<Map<String, Object?>> _moderationParticipants({
  int promotedAttendeeType = 3,
}) {
  return [
    _participantJson(
      attendeeId: 1,
      actorId: 'synthetic-owner',
      participantType: 1,
      displayName: 'Synthetic Owner',
    ),
    _participantJson(
      attendeeId: 2,
      actorId: 'synthetic-moderator',
      participantType: 2,
      displayName: 'Synthetic Moderator',
    ),
    _participantJson(
      attendeeId: 3,
      actorId: 'synthetic-member',
      participantType: promotedAttendeeType,
      displayName: 'Synthetic Member',
    ),
    _participantJson(
      attendeeId: 4,
      actorId: 'fixture-user',
      participantType: 2,
      displayName: 'Signed-in Moderator',
    ),
  ];
}

Map<String, Object?> _participantJson({
  required int attendeeId,
  String actorType = 'users',
  String actorId = 'synthetic-user',
  required String displayName,
  required int participantType,
  List<String> sessionIds = const <String>[],
  String? status,
}) {
  return {
    'attendeeId': attendeeId,
    'actorType': actorType,
    'actorId': actorId,
    'displayName': displayName,
    'participantType': participantType,
    'lastPing': 1724300000,
    'sessionIds': sessionIds,
    'permissions': 254,
    'attendeePermissions': 0,
    'inCall': 0,
    'status': ?status,
  };
}

Map<String, Object?> _conversationRoomJson() {
  final root =
      _readFixtureJson(
            'conversation-list/fixtures/conversations-full.response.json',
          )!
          as Map<String, Object?>;
  final ocs = root['ocs']! as Map<String, Object?>;
  final rooms = ocs['data']! as List<Object?>;
  return Map<String, Object?>.from(rooms.first! as Map<String, Object?>);
}

Object? _readFixtureJson(String relativePath) {
  return jsonDecode(File('../../contracts/$relativePath').readAsStringSync());
}

/// Reads the live room title text by key rather than by string content, so
/// a still-closing rename dialog's own text field (which briefly carries the
/// same string while its dismiss transition plays) cannot be mistaken for
/// the summary having refreshed.
String? _roomTitleText(WidgetTester tester) {
  final finder = find.byKey(const Key('room-details-name'));
  if (finder.evaluate().isEmpty) {
    return null;
  }
  return tester.widget<Text>(finder).data;
}

/// Reads the notification picker's subtitle by key for the same reason as
/// [_roomTitleText]: the picker dialog's own option labels repeat these
/// strings and can still be mounted mid dismiss-transition.
String? _notificationSubtitleText(WidgetTester tester) {
  final finder = find.byKey(const Key('room-details-notification-subtitle'));
  if (finder.evaluate().isEmpty) {
    return null;
  }
  return tester.widget<Text>(finder).data;
}

/// The settings actions row pushes the participant list further down than
/// the default test surface; grow it so the whole screen builds without
/// needing to scroll to reach the participant tiles.
void _growViewport(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(400, 1600);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  int maxAttempts = 100,
}) async {
  for (var attempt = 0; attempt < maxAttempts; attempt++) {
    if (condition()) {
      return;
    }
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
  }
  fail('Condition was not reached');
}
