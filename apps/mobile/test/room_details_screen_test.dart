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
import 'package:nextcloudtalk/features/chat/chat_room_pane.dart';
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

  testWidgets('opening the chat room screen exposes an info action', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        home: ChatRoomScreen(account: account, conversation: conversation),
        client: participantsClient(const <Object?>[]),
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

  testWidgets('offers a retry when the participant list fails to load', (
    tester,
  ) async {
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
